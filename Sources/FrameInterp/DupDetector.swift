import CoreVideo
import Foundation

/// 重复帧检测（混合判定）：每 step 像素抽样一个亮度值，和"上一个唯一帧"的抽样比较。
///   meanDiff   = 平均绝对差（0..255）
///   changedPct = |差| > pixelDelta 的抽样点占比（%）
/// meanDiff >= thr 或 changedPct >= pct → 新帧（后者防止只有准星/小块画面在动时被平均掉）。
/// 参考帧只存抽样值，不持有采集缓冲（AVFoundation 会回收它）。
final class DupDetector {
    struct Result {
        var isNew: Bool
        var meanDiff: Double
        var changedPct: Double
    }

    let step: Int
    var threshold: Double
    var changedPct: Double
    var pixelDelta: Int

    /// 自动适应噪声：记住最近重复帧里最大的差值（慢慢衰减），判断线至少比它高一半。
    /// iPad / 采集卡的画面是压缩过的，重复帧之间也有噪声（实测最高 0.49，几乎碰到默认线 0.5）。
    /// 上限：平均差最多 2.0、变化点最多 0.5%，免得把真正的小动作也吞掉。
    /// 噪声估计。2026-11-13 采集卡实测出过问题：旧做法把"判成重复帧"的差值当噪声、判断线 = 1.5 × 噪声，
    /// 带小变化的帧被判成重复 → 判断线升高 → 更大的变化也被判成重复……一路涨到上限，12 分钟里 95% 的秒数没有新画面。
    /// 现在：最近 2 秒（120 帧）所有帧差值的第 20 百分位当噪声（不管判成了什么，所以判断线不会自己抬自己）。
    /// 30 帧游戏里至少一半的帧是真正的重复帧，第 20 百分位就是它们的噪声；判断线 = max(基准, 3 × 噪声)，上限 1.5 / 0.2%。
    private var noiseMean = 0.0, noisePct = 0.0
    private var histMean = [Double](repeating: 0, count: 120), histPct = [Double](repeating: 0, count: 120)
    private var histN = 0
    var effectiveThreshold: Double { min(max(threshold, noiseMean * 3), max(threshold, 1.5)) }
    var effectivePct: Double { min(max(changedPct, noisePct * 3), max(changedPct, 0.2)) }

    private func updateNoise(mean: Double, pct: Double) {
        histMean[histN % 120] = mean; histPct[histN % 120] = pct
        histN += 1
        guard histN >= 60, histN % 30 == 0 else { return }
        let n = min(histN, 120)
        let m = histMean.prefix(n).sorted(), q = histPct.prefix(n).sorted()
        // 只有差值明显分成两堆（一堆接近 0 = 重复帧，一堆大 = 新画面）时，小的那堆才是噪声。
        // 60 帧游戏没有重复帧、静止画面全是重复帧，都不分两堆，这时不抬高判断线（2026-11-13 地平线 4 实测：
        // 不加这个判断，60 帧画面里的小幅运动被当成噪声，判断线被推到上限，新画面掉到每秒 10~35）
        let p20 = m[n / 5], p80 = m[n * 4 / 5]
        noiseMean = p20 < p80 * 0.25 ? p20 : 0
        let q20 = q[n / 5], q80 = q[n * 4 / 5]
        noisePct = q20 < q80 * 0.25 ? q20 : 0
    }
    /// 连续判成重复帧的次数。30 帧游戏在 60Hz 采集里每帧最多重复 2~3 次
    private var dupRun = 0
    private(set) var forcedNew = 0 // 保险机制强制放行的次数（统计用）

    private var reference: [UInt8] = []
    private var current: [UInt8] = []
    private var refW = 0, refH = 0

    init(step: Int, threshold: Double, changedPct: Double, pixelDelta: Int) {
        self.step = step
        self.threshold = threshold
        self.changedPct = changedPct
        self.pixelDelta = pixelDelta
    }

    func reset() { reference.removeAll(keepingCapacity: true); noiseMean = 0; noisePct = 0; histN = 0 }

    func check(_ pb: CVPixelBuffer) -> Result {
        sample(pb)
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        if reference.count != current.count || w != refW || h != refH {
            swap(&reference, &current)
            refW = w; refH = h
            return Result(isNew: true, meanDiff: 255, changedPct: 100)
        }
        var sum = 0, changed = 0
        let pd = pixelDelta
        reference.withUnsafeBufferPointer { r in
            current.withUnsafeBufferPointer { c in
                for i in 0..<c.count {
                    let d = abs(Int(c[i]) - Int(r[i]))
                    sum &+= d
                    if d > pd { changed &+= 1 }
                }
            }
        }
        let n = Double(max(1, current.count))
        let mean = Double(sum) / n
        let pct = 100.0 * Double(changed) / n
        let thr = effectiveThreshold, pthr = effectivePct
        var isNew = mean >= thr || pct >= pthr
        // 保险：已经连续 3 帧判成重复、但这一帧和参考帧还是有些不同（超过判断线的 30%），就当新画面放行，
        // 画面不会因为判断线不对而卡住。真正静止的画面差值只有零点几，不会触发
        if !isNew && dupRun >= 3 && (mean > thr * 0.3 || pct > pthr * 0.3) {
            isNew = true
            forcedNew += 1
        }
        updateNoise(mean: mean, pct: pct)
        if isNew {
            swap(&reference, &current)
            dupRun = 0
        } else {
            dupRun += 1
        }
        return Result(isNew: isNew, meanDiff: mean, changedPct: pct)
    }

    /// 抽样亮度到 current。支持双平面 YUV（plane 0 = Y）和 BGRA（按 Rec.709 近似算亮度）。
    private func sample(_ pb: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        // 2K / 4K 画面按比例加大抽样间隔：抽样点数和 1080p 差不多，耗时不随分辨率翻倍
        let st = step * max(1, w / 1920)
        let sx = (w + st - 1) / st, sy = (h + st - 1) / st
        let count = sx * sy
        if current.count != count { current = [UInt8](repeating: 0, count: count) }
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        current.withUnsafeMutableBufferPointer { out in
            if CVPixelBufferIsPlanar(pb) {
                guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return }
                let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
                let is16 = fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                    || fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
                    || fmt == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
                var k = 0
                for y in 0..<sy {
                    let row = base.advanced(by: y * st * bpr)
                    if is16 {
                        let p = row.assumingMemoryBound(to: UInt16.self)
                        for x in 0..<sx { out[k] = UInt8(truncatingIfNeeded: p[x * st] >> 8); k += 1 }
                    } else {
                        let p = row.assumingMemoryBound(to: UInt8.self)
                        for x in 0..<sx { out[k] = p[x * st]; k += 1 }
                    }
                }
            } else {
                guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
                let bpr = CVPixelBufferGetBytesPerRow(pb)
                var k = 0
                if fmt == kCVPixelFormatType_422YpCbCr8_yuvs || fmt == kCVPixelFormatType_422YpCbCr8 {
                    // yuvs = Y0 U Y1 V；2vuy = U Y0 V Y1
                    let yOff = fmt == kCVPixelFormatType_422YpCbCr8_yuvs ? 0 : 1
                    for y in 0..<sy {
                        let p = base.advanced(by: y * st * bpr).assumingMemoryBound(to: UInt8.self)
                        for x in 0..<sx { out[k] = p[x * st * 2 + yOff]; k += 1 }
                    }
                } else {
                    // 按 BGRA 处理
                    for y in 0..<sy {
                        let p = base.advanced(by: y * st * bpr).assumingMemoryBound(to: UInt8.self)
                        for x in 0..<sx {
                            let o = x * st * 4
                            let v = (Int(p[o]) * 18 + Int(p[o + 1]) * 183 + Int(p[o + 2]) * 54) >> 8
                            out[k] = UInt8(truncatingIfNeeded: v); k += 1
                        }
                    }
                }
            }
        }
    }
}
