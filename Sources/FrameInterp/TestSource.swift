import CoreMedia
import CoreVideo
import Foundation

/// 内置测试图案：模拟采集卡的 60Hz 输出，内容约 30 帧且重复节奏不规则，并加一点低幅噪声（模拟压缩噪声）。
/// 画面：斜向移动的竖条 + 方块 + 固定的"界面"条，每隔几秒一次切场景（整屏换亮度）。
final class TestSource {
    /// 测试图案的尺寸：默认 1080p；环境变量 FI_TESTRES=1440 / 2160 测 2K / 4K
    let width: Int, height: Int
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    private let queue = DispatchQueue(label: "test.source", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var pool: CVPixelBufferPool?
    private var tick = 0
    private var contentIndex = 0
    private var repeatLeft = 0
    // 重复次数序列，平均 2（即 30 帧内容），但不规则
    private let cadence = [2, 2, 1, 3, 2, 2, 2, 1, 3, 2, 2, 2]
    private var cadenceIdx = 0
    private var rng = SystemRandomNumberGenerator()

    static let yuvsMode = ProcessInfo.processInfo.environment["FI_TEST422"] == "1"

    init() {
        switch ProcessInfo.processInfo.environment["FI_TESTRES"] {
        case "1440": (width, height) = (2560, 1440)
        case "2160": (width, height) = (3840, 2160)
        default: (width, height) = (1920, 1080)
        }
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: TestSource.yuvsMode ? kCVPixelFormatType_422YpCbCr8_yuvs : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
    }

    func start() {
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now(), repeating: .nanoseconds(16_666_667), leeway: .microseconds(200))
        t.setEventHandler { [weak self] in self?.step() }
        timer = t
        t.resume()
    }

    func stop() { timer?.cancel() }

    private func step() {
        let newContent = repeatLeft == 0
        if repeatLeft == 0 {
            contentIndex += 1
            repeatLeft = cadence[cadenceIdx % cadence.count]
            cadenceIdx += 1
        }
        repeatLeft -= 1
        tick += 1
        var pb: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess, let pb else { return }
        draw(pb, content: contentIndex)
        tagBT709(pb)
        if FrameStamp.enabled {
            if FrameStamp.byContent {
                // 补帧模式测延迟：按"内容帧号"打标记，时间记在这个内容第一次出现的那一帧（重复帧同号）
                FrameStamp.draw(contentIndex, into: pb)
                if newContent { FrameStamp.record(contentIndex) }
            } else {
                FrameStamp.draw(tick, into: pb)
                FrameStamp.record(tick)
            }
        }
        onFrame?(pb, CMClockGetTime(CMClockGetHostTimeClock()))
    }

    /// 测试用：FI_TESTSTILL=1 时画"加载画面"——静止背景 + 右下角一个 60×60 的小块在转（30 帧内容）
    static let stillMode = ProcessInfo.processInfo.environment["FI_TESTSTILL"] == "1"

    private func drawStill(_ pb: CVPixelBuffer, content n: Int) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
        let ybpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self)
        let uvbpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        for row in 0..<height { memset(y.advanced(by: row * ybpr), 30, width) }
        for row in 0..<(height / 2) { memset(uv.advanced(by: row * uvbpr), 128, width) }
        // 转圈：以 (1820, 980) 为中心，一根 30 像素长的"指针"每个内容帧转 30°
        let a = Double(n) * .pi / 6
        for k in 0..<30 {
            let cx = 1820 + Int(Double(k) * cos(a)), cy = 980 + Int(Double(k) * sin(a))
            for dy in -3...3 { for dx in -3...3 { y[(cy + dy) * ybpr + cx + dx] = 230 } }
        }
    }

    /// 测试用：FI_TESTDETAIL=1 时画 1 像素宽的黑白竖条 + 横条（检查显示有没有被糊掉）
    static let detailMode = ProcessInfo.processInfo.environment["FI_TESTDETAIL"] == "1"

    private func draw(_ pb: CVPixelBuffer, content n: Int) {
        if TestSource.yuvsMode {
            // yuvs = Y0 U Y1 V；左半：红蓝相间的 2 像素竖条（4:2:2 能保住，4:2:0 也能）；
            // 右半：红蓝相间的 1 行横条（4:2:2 保得住，4:2:0 会把相邻两行颜色混成紫色）
            CVPixelBufferLockBaseAddress(pb, [])
            defer { CVPixelBufferUnlockBaseAddress(pb, []) }
            let b = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
            let bpr = CVPixelBufferGetBytesPerRow(pb)
            let red: (UInt8, UInt8, UInt8) = (63, 102, 240), blue: (UInt8, UInt8, UInt8) = (32, 240, 118) // (Y, U, V)
            for row in 0..<height {
                let line = b.advanced(by: row * bpr)
                for px in stride(from: 0, to: width, by: 2) {
                    let c = px < width / 2 ? ((px / 2) & 1 == 0 ? red : blue) : (row & 1 == 0 ? red : blue)
                    let o = px * 2
                    line[o] = c.0; line[o + 1] = c.1; line[o + 2] = c.0; line[o + 3] = c.2
                }
            }
            return
        }
        if TestSource.stillMode { drawStill(pb, content: n); return }
        if TestSource.detailMode {
            CVPixelBufferLockBaseAddress(pb, [])
            defer { CVPixelBufferUnlockBaseAddress(pb, []) }
            let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
            let ybpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            let uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self)
            let uvbpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
            for row in 0..<height {
                let line = y.advanced(by: row * ybpr)
                for x in 0..<width { line[x] = (x < width / 2 ? (x & 1) : (row & 1)) == 0 ? 235 : 16 }
            }
            for row in 0..<(height / 2) { memset(uv.advanced(by: row * uvbpr), 128, width) }
            return
        }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
        let ybpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self)
        let uvbpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        let scene = (n / 300) % 2 // 约每 10 秒切一次场景
        let bg: UInt8 = scene == 0 ? 40 : 190
        let barX = (n * 24) % width           // 竖条每个内容帧移动 24 像素（60fps 补帧后每帧 12）
        let boxX = (n * 16) % (width - 200), boxY = 300 + Int(200 * sin(Double(n) / 15))
        for row in 0..<height {
            let line = y.advanced(by: row * ybpr)
            memset(line, Int32(bg), width)
            // 竖条（宽 80）
            for x in barX..<min(barX + 80, width) { line[x] = 235 }
            // 方块
            if row >= boxY && row < boxY + 200 {
                for x in boxX..<boxX + 200 { line[x] = scene == 0 ? 160 : 60 }
            }
            // 固定"界面"：左上角条
            if row >= 40 && row < 90 { for x in 40..<500 { line[x] = 220 } }
        }
        // 低幅噪声：随机几百个点 ±2
        for _ in 0..<400 {
            let r = Int.random(in: 0..<height, using: &rng), c = Int.random(in: 0..<width, using: &rng)
            let p = y.advanced(by: r * ybpr + c)
            p.pointee = p.pointee &+ UInt8.random(in: 0...2, using: &rng)
        }
        for row in 0..<(height / 2) { memset(uv.advanced(by: row * uvbpr), 128, width) }
    }
}
