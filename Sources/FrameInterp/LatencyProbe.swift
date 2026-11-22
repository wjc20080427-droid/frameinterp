import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// 显示延迟测量（开发用，环境变量 FI_LATTEST=1 + --test）：
/// 测试图案在每一帧左上角写一个 16 位帧号（16 个黑白方块），并记下生成时间；
/// 再用 ScreenCaptureKit 录本程序自己的画面区域，读出每一帧"真正上屏"的时间（displayTime）和帧号，
/// 两者相减 = 从画面到达程序到真正显示在屏幕上的时间（不含采集卡本身）。
enum FrameStamp {
    static let lock = NSLock()
    static var enabled = false
    static let byContent = ProcessInfo.processInfo.environment["FI_STAMP"] == "content"
    /// FI_STAMPPOS=center：帧号写在画面正中（准星保护区域的核心，补出来的帧里也是真实帧的内容），
    /// 这样能测到"补出来的帧第一次显示新内容"的时间 = 第一反应的延迟
    static let center = ProcessInfo.processInfo.environment["FI_STAMPPOS"] == "center"
    /// 第 i 位方块的中心（1920×1080 坐标）和半边长
    static func block(_ i: Int) -> (x: Int, y: Int, half: Int) {
        if center { return (912 + (i % 8) * 12 + 6, 496 + (i / 8) * 12 + 6, 6) }
        return (i * 24 + 12, 12, 12)
    }
    static var genMs = [Int: Double]()

    static func record(_ n: Int) {
        lock.lock(); genMs[n & 0xFFFF] = nowMs(); lock.unlock()
    }
    static func gen(_ n: Int) -> Double? {
        lock.lock(); defer { lock.unlock() }; return genMs[n]
    }

    /// 在 420v 缓冲左上角写帧号：第 i 位为 1 → 第 i 个 24×24 方块是白的
    static func draw(_ n: Int, into pb: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0)?.assumingMemoryBound(to: UInt8.self) else { return }
        let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        for i in 0..<16 {
            let v: UInt8 = (n >> i) & 1 == 1 ? 235 : 16
            let b = block(i)
            for r in (b.y - b.half)..<(b.y + b.half) { memset(y.advanced(by: r * bpr + b.x - b.half), Int32(v), 2 * b.half) }
        }
    }
}

final class LatencyProbe: NSObject, SCStreamOutput, @unchecked Sendable {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "latency.probe")
    private var samples: [Double] = []
    private var seen = Set<Int>()
    private var timebase = mach_timebase_info_data_t()
    let label: String

    init(label: String) {
        self.label = label
        super.init()
        mach_timebase_info(&timebase)
    }

    /// rect：画面区域在窗口里的位置（点，左上角为原点）
    func start(windowID: CGWindowID, rect: CGRect, scale: CGFloat) async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let win = content.windows.first(where: { $0.windowID == windowID }) else {
            Log.write("显示延迟测试：找不到自己的窗口")
            return
        }
        let cfg = SCStreamConfiguration()
        cfg.sourceRect = rect
        cfg.width = Int(rect.width * scale); cfg.height = Int(rect.height * scale)
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.queueDepth = 6
        cfg.showsCursor = false
        let s = SCStream(filter: SCContentFilter(desktopIndependentWindow: win), configuration: cfg, delegate: nil)
        try? s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        stream = s
        do { try await s.startCapture() } catch { Log.write("显示延迟测试启动失败：\(error)") }
    }

    func stopAndReport() {
        stream?.stopCapture { _ in }
        queue.sync {
            let v = samples.sorted()
            guard !v.isEmpty else { Log.write("显示延迟测试（\(label)）：没有读到帧号"); return }
            func p(_ q: Double) -> Double { v[min(v.count - 1, Int(Double(v.count) * q))] }
            Log.write(String(format: "显示延迟测试（%@）：中位 %.1fms，10%% %.1fms，90%% %.1fms，样本 %d",
                             label, p(0.5), p(0.1), p(0.9), v.count))
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pb = CMSampleBufferGetImageBuffer(sb),
              let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = atts.first, let st = info[.status] as? Int, st == SCFrameStatus.complete.rawValue,
              let disp = info[.displayTime] as? UInt64 else { return }
        let dispMs = Double(disp) * Double(timebase.numer) / Double(timebase.denom) / 1e6
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else { return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
        var n = 0
        for i in 0..<16 {
            let b = FrameStamp.block(i)
            let xx = Int(Double(b.x) / 1920.0 * Double(w)), yy = Int(Double(b.y) / 1080.0 * Double(h))
            let o = yy * bpr + xx * 4
            let v = Int(base[o + 1])
            if v > 60 && v < 190 { return } // 方块是灰的 = 补出来的帧（两个帧号混在一起），不算
            if v >= 190 { n |= 1 << i }
        }
        guard !seen.contains(n) else { return } // 同一个画面只算第一次出现
        seen.insert(n)
        if let g = FrameStamp.gen(n) {
            let d = dispMs - g
            if d > 0 && d < 300 { samples.append(d) }
        }
    }
}
