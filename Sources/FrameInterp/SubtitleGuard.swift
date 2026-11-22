import CoreVideo
import Foundation

/// 字幕保护：只管画面下方中间的字幕区。
/// 问题（2026-11-19 用户在 GTA 6 里反馈）：字幕不动、背景在动，Apple 补帧把字幕跟着背景"拖"一点，
/// 补出来的帧里字幕变形、真实帧里清楚，一帧一帧交替看起来就是字幕在闪；转视角时尤其明显。
/// 做法：字幕区里"连续 5 个真实帧都没变、而且是文字边缘"的像素（再向外扩 2 像素盖住抗锯齿），
/// 在补出来的帧里换回真实帧的内容。字幕一般停好几秒，很容易满足；在动的背景不会被换。
/// 和以前删掉的"界面保护"不同：只看字幕这一小块，不在整个画面里猜界面在哪。
/// 全在 CPU 上做，只处理字幕区（1080p 时约 1344×184），每帧不到 1ms。只处理 420v。
final class SubtitleGuard: @unchecked Sendable {
    var enabled = true
    /// 保护哪一块（占画面的比例）和"有几个文字边缘像素才算有字"
    let name: String
    let region: (x0: Double, x1: Double, y0: Double, y1: Double)
    let minSeeds: Int
    /// 也保护"不动的彩色实心块"（血量条这类粉 / 青 / 紫填充）：只看边缘时条中间仍是补帧的颜色，会变色
    let colorFill: Bool
    static let colorSat = 22               // 色度离灰色多远算"彩色"（|Cb-128|+|Cr-128|）

    /// 2026-11-19 按用户 GTA 6 截图定的几块：
    ///   字幕：下方中间，约 35%~64% 宽、87%~92% 高，放宽到能放两行长字幕；
    ///   右上：金钱、荣誉值、「地图已更新」这类提示（约 87%~98% 宽、3%~29% 高）；
    ///   右下：短信 / 来电消息框（约 87%~98% 宽、88%~98% 高）；
    ///   左上：血量、体力等状态条和图标（约 2%~13% 宽、3%~9% 高）；
    ///   左下：地点名（如"杰森的房子"，约 2%~17% 宽、94%~97% 高）。左下的小地图会动，在动的像素不会被换，不用单独排除。
    /// 右边两块字小、字少，"有字"的门槛低一些
    static func gtaSet() -> [SubtitleGuard] {
        [SubtitleGuard(name: "字幕", region: (0.18, 0.78, 0.80, 0.97), minSeeds: 400),
         SubtitleGuard(name: "右上提示", region: (0.78, 1.0, 0.0, 0.36), minSeeds: 120),
         SubtitleGuard(name: "右下消息", region: (0.78, 1.0, 0.80, 1.0), minSeeds: 150),
         SubtitleGuard(name: "左上状态", region: (0.0, 0.20, 0.0, 0.14), minSeeds: 100, colorFill: true),
         SubtitleGuard(name: "左下地点", region: (0.0, 0.22, 0.90, 1.0), minSeeds: 100)]
    }

    init(name: String = "字幕", region: (x0: Double, x1: Double, y0: Double, y1: Double) = (0.18, 0.78, 0.80, 0.97), minSeeds: Int = 400,
         colorFill: Bool = false) {
        self.name = name; self.region = region; self.minSeeds = minSeeds; self.colorFill = colorFill
    }
    static let stillFrames: UInt8 = 5     // 连续几个真实帧没变才算字幕
    static let stillDiff = 12             // 亮度差 ≤ 这个算没变（串流画面有压缩噪声）
    static let edge = 36                  // 文字边缘：左右或上下亮度差超过这个
    static let dilate = 2                 // 向外扩几像素

    private let lock = NSLock()
    private var w = 0, h = 0, rx = 0, ry = 0, rw = 0, rh = 0
    private var prev: [UInt8] = []
    private var still: [UInt8] = []
    private var mask: [UInt8] = []        // 1 = 这个像素用真实帧
    private(set) var maskCount = 0        // 当前保护的像素数（0 = 没有字幕，补帧原样显示）
    private var hasPrev = false

    func reset() { lock.lock(); hasPrev = false; maskCount = 0; lock.unlock() }

    private func setup(_ width: Int, _ height: Int) {
        guard width != w || height != h else { return }
        w = width; h = height
        rx = Int(Double(w) * region.x0) & ~1
        ry = Int(Double(h) * region.y0) & ~1
        rw = (Int(Double(w) * region.x1) & ~1) - rx
        rh = (Int(Double(h) * region.y1) & ~1) - ry
        prev = [UInt8](repeating: 0, count: rw * rh)
        still = [UInt8](repeating: 0, count: rw * rh)
        mask = [UInt8](repeating: 0, count: rw * rh)
        hasPrev = false
        maskCount = 0
    }

    /// 每个真实的新画面调一次（显示分辨率的 420v 拷贝）：更新"哪些像素没变"，算出字幕的保护范围
    func observe(_ pb: CVPixelBuffer) {
        guard enabled, CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else { return }
        lock.lock(); defer { lock.unlock() }
        setup(CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb))
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0)?.assumingMemoryBound(to: UInt8.self) else { return }
        let cBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1)?.assumingMemoryBound(to: UInt8.self)
        let cbpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let rw = rw, rh = rh, rx = rx, ry = ry
        // 1. 没变的计数
        prev.withUnsafeMutableBufferPointer { pv in
            still.withUnsafeMutableBufferPointer { st in
                for y in 0..<rh {
                    let row = yBase.advanced(by: (ry + y) * bpr + rx)
                    let o = y * rw
                    for x in 0..<rw {
                        let v = row[x]
                        if hasPrev, abs(Int(v) - Int(pv[o + x])) <= SubtitleGuard.stillDiff {
                            if st[o + x] < 250 { st[o + x] += 1 }
                        } else {
                            st[o + x] = 0
                        }
                        pv[o + x] = v
                    }
                }
            }
        }
        hasPrev = true
        // 2. 种子 = 没变够久 + 是文字边缘；3. 向外扩
        var seed = [UInt8](repeating: 0, count: rw * rh)
        var seeds = 0
        still.withUnsafeBufferPointer { st in
            for y in 1..<(rh - 1) {
                let row = yBase.advanced(by: (ry + y) * bpr + rx)
                let up = yBase.advanced(by: (ry + y - 1) * bpr + rx), dn = yBase.advanced(by: (ry + y + 1) * bpr + rx)
                for x in 1..<(rw - 1) where st[y * rw + x] >= SubtitleGuard.stillFrames {
                    let gx = abs(Int(row[x + 1]) - Int(row[x - 1])), gy = abs(Int(dn[x]) - Int(up[x]))
                    if max(gx, gy) > SubtitleGuard.edge { seed[y * rw + x] = 1; seeds += 1; continue }
                    // 彩色实心块：不动、而且颜色明显（血量条的填充）
                    if colorFill, let cb = cBase {
                        let c = cb.advanced(by: ((ry + y) / 2) * cbpr + ((rx + x) / 2) * 2)
                        if abs(Int(c[0]) - 128) + abs(Int(c[1]) - 128) > SubtitleGuard.colorSat { seed[y * rw + x] = 1; seeds += 1 }
                    }
                }
            }
        }
        for i in mask.indices { mask[i] = 0 }
        maskCount = 0
        // 一行字幕有上千个边缘像素；只有零星几百个（场景里不动的边）说明没有字幕，不保护
        guard seeds >= minSeeds else { return }
        let r = SubtitleGuard.dilate
        for y in 0..<rh {
            for x in 0..<rw where seed[y * rw + x] == 1 {
                for yy in max(0, y - r)...min(rh - 1, y + r) {
                    for xx in max(0, x - r)...min(rw - 1, x + r) where mask[yy * rw + xx] == 0 {
                        mask[yy * rw + xx] = 1
                        maskCount += 1
                    }
                }
            }
        }
    }

    /// 补出来的一帧（和 real 同尺寸的 420v）：字幕像素换回真实帧（较新的那一帧）。原地修改 interp
    func compose(interp: CVPixelBuffer, real: CVPixelBuffer) {
        guard enabled else { return }
        lock.lock(); defer { lock.unlock() }
        guard maskCount > 0, CVPixelBufferGetWidth(interp) == w, CVPixelBufferGetHeight(interp) == h,
              CVPixelBufferGetWidth(real) == w, CVPixelBufferGetHeight(real) == h,
              CVPixelBufferGetPixelFormatType(interp) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetPixelFormatType(real) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else { return }
        CVPixelBufferLockBaseAddress(interp, [])
        CVPixelBufferLockBaseAddress(real, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(real, .readOnly)
            CVPixelBufferUnlockBaseAddress(interp, [])
        }
        guard let iY = CVPixelBufferGetBaseAddressOfPlane(interp, 0)?.assumingMemoryBound(to: UInt8.self),
              let rY = CVPixelBufferGetBaseAddressOfPlane(real, 0)?.assumingMemoryBound(to: UInt8.self),
              let iC = CVPixelBufferGetBaseAddressOfPlane(interp, 1)?.assumingMemoryBound(to: UInt8.self),
              let rC = CVPixelBufferGetBaseAddressOfPlane(real, 1)?.assumingMemoryBound(to: UInt8.self) else { return }
        let ibY = CVPixelBufferGetBytesPerRowOfPlane(interp, 0), rbY = CVPixelBufferGetBytesPerRowOfPlane(real, 0)
        let ibC = CVPixelBufferGetBytesPerRowOfPlane(interp, 1), rbC = CVPixelBufferGetBytesPerRowOfPlane(real, 1)
        let rw = rw, rh = rh, rx = rx, ry = ry
        mask.withUnsafeBufferPointer { m in
            for y in 0..<rh {
                let io = iY.advanced(by: (ry + y) * ibY + rx), ro = rY.advanced(by: (ry + y) * rbY + rx)
                for x in 0..<rw where m[y * rw + x] == 1 { io[x] = ro[x] }
            }
            // 色度是半分辨率：2×2 里有一个要保护就换
            for cy in 0..<(rh / 2) {
                let io = iC.advanced(by: (ry / 2 + cy) * ibC + rx), ro = rC.advanced(by: (ry / 2 + cy) * rbC + rx)
                for cx in 0..<(rw / 2) {
                    let a = (2 * cy) * rw + 2 * cx
                    if m[a] | m[a + 1] | m[a + rw] | m[a + rw + 1] != 0 {
                        io[2 * cx] = ro[2 * cx]; io[2 * cx + 1] = ro[2 * cx + 1]
                    }
                }
            }
        }
    }
}
