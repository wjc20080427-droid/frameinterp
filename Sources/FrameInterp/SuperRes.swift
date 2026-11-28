import AppKit
import CoreImage
import CoreVideo
import QuartzCore
import VideoToolbox

// MARK: - AI 超分：720p → 1080p（2026-11-28）
// 用 Apple 的 VTLowLatencySuperResolutionScaler（低延迟、给视频通话这类压缩过的低清画面用的）。
// 限制（本机实测 M2 / macOS 27）：输入最大 1280×1280，1280×720 只能放大 1.5 倍 = 1920×1080；只收 420v；每帧约 2.9ms（最慢 3.3ms）。
// 所以只用在原生 Xbox 串流走公网、主机只给 720p 的时候：先超分到 1080p 再进管线（补帧本来就在 1080p 上做）。
// 上次（2.5.3）拿干净的 GTA 6 截图比，它比清晰放大糊；这次是压缩很重的串流画面，正是它擅长的，所以做成开关让用户自己比。
// 开关 UserDefaults xboxSR.v1（默认开）；FI_XSR=0 强制关；FI_XSRDUMP=1 连上 10 秒后存一组对比图到日志文件夹 sr-compare/。

final class SuperRes720: @unchecked Sendable {
    static let inW = 1280, inH = 720, outW = 1920, outH = 1080

    /// 用户开关（任何线程读）
    static var enabled: Bool {
        if let f = ProcessInfo.processInfo.environment["FI_XSR"] { return f != "0" }
        return UserDefaults.standard.object(forKey: "xboxSR.v1") as? Bool ?? true
    }
    static func setEnabled(_ on: Bool) { UserDefaults.standard.set(on, forKey: "xboxSR.v1") }

    private let processor = VTFrameProcessor()
    private let cfg = VTLowLatencySuperResolutionScalerConfiguration(frameWidth: inW, frameHeight: inH, scaleFactor: 1.5)
    private var srcPool: CVPixelBufferPool?
    private var dstPool: CVPixelBufferPool?
    private var transfer: VTPixelTransferSession?
    private var ready = false
    private var failed = false
    private let lock = NSLock()
    private var msSum = 0.0, msMax = 0.0, n = 0, errors = 0
    private var dumped = false
    var forceDump = false
    private let t0 = CACurrentMediaTime()

    init?() {
        guard VTLowLatencySuperResolutionScalerConfiguration.isSupported,
              VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors(frameWidth: Self.inW, frameHeight: Self.inH).contains(1.5)
        else { Log.write("AI 超分：这台 Mac 不支持 720p → 1080p"); return nil }
        srcPool = Self.pool(cfg.sourcePixelBufferAttributes, Self.inW, Self.inH)
        dstPool = Self.pool(cfg.destinationPixelBufferAttributes, Self.outW, Self.outH)
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
        do {
            try processor.startSession(configuration: cfg)
            ready = true
        } catch {
            Log.write("AI 超分：启动失败 \(error)")
            return nil
        }
    }

    deinit { if ready { processor.endSession() } }

    private static func pool(_ attrs: [String: Any], _ w: Int, _ h: Int) -> CVPixelBufferPool? {
        var a = attrs
        a[kCVPixelBufferWidthKey as String] = w; a[kCVPixelBufferHeightKey as String] = h
        a[kCVPixelBufferPixelFormatTypeKey as String] = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        if a[kCVPixelBufferIOSurfacePropertiesKey as String] == nil { a[kCVPixelBufferIOSurfacePropertiesKey as String] = [:] as [String: Any] }
        var p: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 6] as CFDictionary, a as CFDictionary, &p)
        return p
    }

    /// 是 1280×720 420v 就超分成 1920×1080，否则原样返回。同步（在调用线程等结果，约 3ms），出错也原样返回
    func process(_ src: CVPixelBuffer, pts: CMTime) -> CVPixelBuffer {
        guard ready, !failed, Self.enabled,
              CVPixelBufferGetWidth(src) == Self.inW, CVPixelBufferGetHeight(src) == Self.inH,
              CVPixelBufferGetPixelFormatType(src) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              let srcPool, let dstPool, let transfer else { return src }
        let t = CACurrentMediaTime()
        // 输入要用处理器要求的缓冲（带扩展边），先拷一份（约 0.2ms）
        var inBuf: CVPixelBuffer?, outBuf: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, srcPool, &inBuf)
        CVPixelBufferPoolCreatePixelBuffer(nil, dstPool, &outBuf)
        guard let inBuf, let outBuf, VTPixelTransferSessionTransferImage(transfer, from: src, to: inBuf) == noErr,
              let fs = VTFrameProcessorFrame(buffer: inBuf, presentationTimeStamp: pts),
              let fd = VTFrameProcessorFrame(buffer: outBuf, presentationTimeStamp: pts) else { return src }
        let params = VTLowLatencySuperResolutionScalerParameters(sourceFrame: fs, destinationFrame: fd)
        let sem = DispatchSemaphore(value: 0)
        var err: Error?
        processor.process(parameters: params) { _, e in err = e; sem.signal() }
        if sem.wait(timeout: .now() + 0.1) == .timedOut { err = NSError(domain: "sr", code: 1, userInfo: [NSLocalizedDescriptionKey: "超时 100ms"]) }
        let ms = (CACurrentMediaTime() - t) * 1000
        lock.lock()
        if let err {
            errors += 1
            let e = errors
            lock.unlock()
            if e <= 3 { Log.write("AI 超分：处理失败 \(err.localizedDescription)") }
            if e >= 30 { failed = true; Log.write("AI 超分：连续出错，这次连接先关掉超分") }
            return src
        }
        msSum += ms; msMax = max(msMax, ms); n += 1
        lock.unlock()
        CVBufferPropagateAttachments(src, outBuf)
        if !dumped, forceDump || (ProcessInfo.processInfo.environment["FI_XSRDUMP"] == "1" && CACurrentMediaTime() - t0 > 10) {
            dumped = true
            Self.dump(src: src, sr: outBuf)
        }
        return outBuf
    }

    /// 统计（取完清零）：(平均 ms, 最大 ms, 帧数)
    func takeStats() -> (Double, Double, Int) {
        lock.lock(); defer { msSum = 0; msMax = 0; n = 0; lock.unlock() }
        return (n > 0 ? msSum / Double(n) : 0, msMax, n)
    }

    /// 存对比图：原始 720p、普通放大（Lanczos）1080p、AI 超分 1080p，外加中间区域 2 倍裁切
    private static func dump(src: CVPixelBuffer, sr: CVPixelBuffer) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/FrameInterp/sr-compare", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        let ctx = CIContext()
        func save(_ img: CIImage, _ name: String) {
            guard let cg = ctx.createCGImage(img, from: img.extent) else { return }
            let rep = NSBitmapImageRep(cgImage: cg)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(stamp)-\(name).png"))
        }
        let a = CIImage(cvPixelBuffer: src), b = CIImage(cvPixelBuffer: sr)
        let lanczos = a.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": 1.5, "inputAspectRatio": 1.0])
        save(a, "720p原图"); save(lanczos, "1080p普通放大"); save(b, "1080p-AI超分")
        // 中间 640×360 区域放大 2 倍，方便看细节
        let crop = CGRect(x: 640, y: 360, width: 640, height: 360)
        func zoom(_ i: CIImage) -> CIImage {
            i.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
                .samplingNearest().transformed(by: CGAffineTransform(scaleX: 2, y: 2))
        }
        save(zoom(lanczos), "细节-普通放大"); save(zoom(b), "细节-AI超分")
        Log.write("AI 超分：对比图存在 \(dir.path)（\(stamp)-*.png）")
    }
}

/// FI_SRTEST=1：不用串流，画一张 720p 测试图（文字、细线、斜线、渐变）过一遍 AI 超分，记速度、存对比图
enum SuperResTest {
    static func run() {
        DispatchQueue.global().async {
            guard let sr = SuperRes720() else { Log.write("AI 超分自测：这台 Mac 用不了"); return }
            let w = 1280, h = 720
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]] as CFDictionary, &pb)
            guard let pb else { return }
            // 用 AppKit 画一张图，再转成 420v
            let img = NSImage(size: NSSize(width: w, height: h), flipped: true) { r in
                NSGradient(colors: [.systemTeal, .systemIndigo])?.draw(in: r, angle: 30)
                for i in 0..<40 { NSColor.white.setStroke(); let p = NSBezierPath(); p.move(to: NSPoint(x: 40 + i * 6, y: 60)); p.line(to: NSPoint(x: 40 + i * 6 + 120, y: 300)); p.lineWidth = 1; p.stroke() }
                for i in 0..<20 { NSColor.black.setFill(); NSRect(x: 700 + i * 4, y: 80, width: 2, height: 200).fill() }
                let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.white]
                ("任务：前往目的地  Mission: reach the destination  距离 1.2 km" as NSString).draw(at: NSPoint(x: 60, y: 420), withAttributes: a)
                ("小字测试 Small text 0123456789" as NSString).draw(at: NSPoint(x: 60, y: 470), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.white])
                NSColor.orange.setFill(); NSBezierPath(ovalIn: NSRect(x: 900, y: 380, width: 220, height: 220)).fill()
                return true
            }
            guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            CIContext().render(CIImage(cgImage: cg), to: pb)
            sr.forceDump = true
            var outW = 0
            for i in 0..<60 {
                let out = sr.process(pb, pts: CMTime(value: CMTimeValue(i), timescale: 60))
                outW = CVPixelBufferGetWidth(out)
                if i == 0 { sr.forceDump = false }
            }
            let (avg, mx, n) = sr.takeStats()
            Log.write(String(format: "AI 超分自测：输出宽 %d，%d 帧，平均 %.2fms，最慢 %.2fms", outW, n, avg, mx))
        }
    }
}
