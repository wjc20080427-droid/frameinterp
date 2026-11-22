import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// 窗口输入（ScreenCaptureKit）：用来抓"iPhone 镜像"窗口测试补帧，不需要采集卡。
/// 注意：ScreenCaptureKit 只在窗口内容变化时才送帧，所以"采集帧率"不会固定在 60，
/// 而是取决于 iPhone 镜像本身送来的帧率（重复帧检测仍然有用：镜像流也会有重复 / 不规则的帧）。
final class WindowCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    var onStop: ((String) -> Void)?
    let queue = DispatchQueue(label: "capture.window", qos: .userInteractive)
    private var stream: SCStream?
    private(set) var width = 0, height = 0
    private(set) var title = ""

    static func describe(_ w: SCWindow) -> String {
        let app = w.owningApplication?.applicationName ?? "?"
        return "\(app) — \(w.title ?? "") (\(Int(w.frame.width))x\(Int(w.frame.height)) pt) id=\(w.windowID)"
    }

    /// 2026-11-20：也列出系统全屏（绿色按钮，单独一个桌面）的窗口——它不在当前桌面，"只要屏幕上的窗口"会把它漏掉。
    /// 其他桌面上的普通窗口、最小化的窗口仍不列（采不到新画面）
    static func windows() async throws -> [SCWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        return content.windows.filter {
            $0.frame.width >= 100 && $0.frame.height >= 100 && $0.windowLayer == 0
                && !($0.owningApplication?.applicationName ?? "").isEmpty
                && ($0.isOnScreen || isNativeFullScreen($0)) // 不在当前桌面的窗口只要全屏的（其他桌面的普通窗口、最小化的窗口采不到新画面）
        }
    }

    /// 系统全屏（单独一个桌面）的窗口：和某块屏幕一样宽、左边对齐、高度超过屏幕六成。
    /// 高度不能要求等于屏幕：有刘海的屏幕少一条菜单栏（1470×923），Chrome 全屏还显示标签栏时更矮（实测 1470×835，上面另有几条工具栏窗口）
    static func isNativeFullScreen(_ w: SCWindow) -> Bool { isFullWidth(w.frame) }
    static func isFullWidth(_ f: CGRect) -> Bool {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &n)
        return ids.prefix(Int(n)).contains { id in
            let b = CGDisplayBounds(id)
            return abs(b.width - f.width) < 2 && abs(b.minX - f.minX) < 2 && f.height > b.height * 0.6
        }
    }

    static func printList() async {
        do {
            for w in try await windows() { print("• \(describe(w))") }
        } catch {
            print("⚠ 读不到窗口列表：\(error)\n  需要屏幕录制权限：系统设置 → 隐私与安全性 → 录屏与系统录音，打开终端，然后重开终端")
        }
    }

    /// name 为空时自动找 iPhone 镜像
    static func pick(_ name: String?) async throws -> SCWindow? {
        let all = try await windows()
        if let name, !name.isEmpty {
            return all.first {
                ($0.owningApplication?.applicationName ?? "").localizedCaseInsensitiveContains(name)
                    || ($0.title ?? "").localizedCaseInsensitiveContains(name)
            }
        }
        return all.first {
            let app = ($0.owningApplication?.applicationName ?? "").lowercased()
            let bid = ($0.owningApplication?.bundleIdentifier ?? "").lowercased()
            return bid.contains("screencontinuity") || app.contains("iphone")
        }
    }

    /// 串流 App 的窗口吗（PS Remote Play、Chiaki、Moonlight、浏览器里的 Xbox 云游戏…）：窗口列表里排在前面、标"串流"
    static func isStreaming(_ w: SCWindow) -> Bool {
        let s = ((w.owningApplication?.applicationName ?? "") + " " + (w.owningApplication?.bundleIdentifier ?? "") + " " + (w.title ?? "")).lowercased()
        return ["remote play", "remoteplay", "ps remote", "playstation", "chiaki", "moonlight", "greenlight", "xbox", "xcloud",
                "parsec", "steam link", "geforce now", "onecast", "shadow pc", "rainway", "sunshine", "boosteroid", "串流", "远程游玩"]
            .contains { s.contains($0) }
    }

    /// 浏览器里的 Xbox 网页串流（xbox.com/play）：暂不支持。
    /// 2026-11-22 用户实测是硬伤：浏览器一失去焦点网页就暂停（「点击继续」），而 FrameInterp 要在前台显示补帧画面，两者冲突；
    /// 试过让浏览器留在前台、FrameInterp 只盖一层显示（覆盖模式），补帧不稳定。以后打算把网页内嵌进 FrameInterp 解决
    static func isWebXbox(_ w: SCWindow) -> Bool {
        let app = ((w.owningApplication?.applicationName ?? "") + " " + (w.owningApplication?.bundleIdentifier ?? "")).lowercased()
        let browser = ["chrome", "edge", "safari", "firefox", "arc", "brave", "opera", "vivaldi", "browser"].contains { app.contains($0) }
        let t = (w.title ?? "").lowercased()
        return browser && (t.contains("xbox") || t.contains("xcloud"))
    }

    /// 排序优先级：串流 App 在前，普通窗口在后，暂不支持的网页 Xbox 串流放最后
    static func rank(_ w: SCWindow) -> Int { isWebXbox(w) ? 2 : (isStreaming(w) ? 0 : 1) }

    /// 自动裁掉标题栏和黑边（设置里可关）
    var autoCrop = true
    var onLog: ((String) -> Void)?
    static let titleBar: CGFloat = 32          // macOS 26 标准标题栏高度（点；实测 640×360 的窗口整体是 640×392）
    private(set) var windowID: CGWindowID = 0
    private var windowSize = CGSize.zero
    private var src = CGRect.zero              // 截取窗口的哪一块（点，窗口左上角为原点），始终是 16:9
    private var frameNo = 0
    private var found: (x0: Int, y0: Int, x1: Int, y1: Int)?
    private var cropDone = false
    private var watching = false

    /// 2026-11-20 改：按窗口画面的原始像素采集（Retina 上 1 点 = 2 像素），不再固定 1920×1080。
    /// 用户反馈串流画质糊：原来窗口画面先被系统缩到 1920×1080（系统的缩放偏软），补帧后再放大到全屏，多缩放一次。
    /// 现在原始像素直接进来：不补帧时清晰放大一步缩放到屏幕；补帧时和 2K / 4K 采集卡一样，在补帧器里按面积平均缩到 1080p。
    /// 窗口画面不到 1920 宽时仍按 1920×1080 采（补帧器只接受 1920×1080 / 1280×720）。最大 3840×2160。
    /// 原来的说明（输出固定 1920×1080：Apple 低延迟补帧只接受 1920×1080 / 1280×720）：
    /// 2026-11-19 用户反馈"左边窄右边宽、不够大、有黑边"，要求按比例铺满 16:9。现在：
    ///   1. 去掉窗口标题栏（32 点），在剩下的画面中间取最大的 16:9 区域，铺满 1920×1080（不留黑边、不偏）；
    ///   2. 开始后 3 秒内识别四周的纯黑边（取这段时间内容范围的并集，暗场景不会误裁），再按游戏画面重新取 16:9 铺满；
    ///   3. 每 3 秒看一次窗口大小，变了就重新来一遍（自适应）。
    /// （试过用 destinationRect 指定画在哪：系统实际画的位置不对，画面缩在左上角，所以改成只用 sourceRect 取 16:9）
    func configure(window: SCWindow, scale: CGFloat) {
        title = WindowCapture.describe(window)
        windowID = window.windowID
        windowSize = window.frame.size
        fullScreen = WindowCapture.isNativeFullScreen(window)
        self.scale = scale
        src = WindowCapture.fill16x9(baseContent())
        (width, height) = WindowCapture.outputSize(src, scale)
        onLog?("窗口采集：画面 \(Int(src.width))×\(Int(src.height)) 点 = \(Int(src.width * scale))×\(Int(src.height * scale)) 像素，按 \(width)×\(height) 采")
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let s = SCStream(filter: filter, configuration: makeConfig(), delegate: self)
        try? s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        stream = s
    }

    private var scale: CGFloat = 2
    private var fullScreen = false   // 系统全屏的窗口没有标题栏，不用裁顶上 32 点
    /// 窗口变大 / 变小很多、采集尺寸需要换时调用（主程序重新打开这个窗口）
    var onNeedRestart: (() -> Void)?

    /// 采集尺寸：16:9 画面的原始像素（宽取 32 的倍数，高 = 宽 × 9 / 16 正好是偶数），1920×1080 ~ 3840×2160
    static func outputSize(_ src: CGRect, _ scale: CGFloat) -> (Int, Int) {
        let pw = Int(src.width * scale)
        guard pw > 1920 else { return (1920, 1080) }
        let w = min(pw, 3840) / 32 * 32
        return (w, w * 9 / 16)
    }

    /// 窗口里游戏画面的初始范围：去掉标题栏（关掉自动裁剪时就是整个窗口）
    private func baseContent() -> CGRect {
        if autoCrop, windowSize.height > 200, !fullScreen {
            return CGRect(x: 0, y: WindowCapture.titleBar, width: windowSize.width, height: windowSize.height - WindowCapture.titleBar)
        }
        return CGRect(origin: .zero, size: windowSize)
    }

    /// 在 r 的正中间取最大的 16:9 区域（按比例铺满：多出来的两边 / 上下裁掉）
    static func fill16x9(_ r: CGRect) -> CGRect {
        guard r.width > 0, r.height > 0 else { return r }
        if r.width / r.height > 16.0 / 9.0 {
            let w = r.height * 16 / 9
            return CGRect(x: r.minX + (r.width - w) / 2, y: r.minY, width: w, height: r.height).integral
        } else {
            let h = r.width * 9 / 16
            return CGRect(x: r.minX, y: r.minY + (r.height - h) / 2, width: r.width, height: h).integral
        }
    }

    private func makeConfig() -> SCStreamConfiguration {
        let cfg = SCStreamConfiguration()
        cfg.width = width
        cfg.height = height
        cfg.sourceRect = src          // 已经是 16:9，按原始像素采（窗口小于 1920 宽时放大到 1920×1080）
        cfg.scalesToFit = true
        cfg.preservesAspectRatio = true
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        // 帧率不设上限：2026-11-19 实测设成 60 时 60 帧的窗口只收到 57 帧/秒（每秒丢 3 帧，可能丢掉游戏的新画面），
        // 不设上限收满 60，补帧后显示帧率 52 → 55；缓存 3 / 5 / 8 帧对延迟没有影响（采集到程序都不到 1ms）。
        // 测试用：FI_SCK_DEPTH = 缓存几帧，FI_SCK_FPS = 最高帧率（0 = 不限）
        let env = ProcessInfo.processInfo.environment
        let fps = Int(env["FI_SCK_FPS"] ?? "") ?? 0
        cfg.minimumFrameInterval = fps > 0 ? CMTime(value: 1, timescale: CMTimeScale(fps)) : .zero
        cfg.queueDepth = Int(env["FI_SCK_DEPTH"] ?? "") ?? 5
        cfg.showsCursor = false
        // 只截串流窗口本身，不截挂在它上面的子窗口：macOS 26 会在一些窗口左上角放一个系统的浮动小按钮
        // （窗口控制），它是子窗口，默认会被一起截进画面（用户反馈"左上角有个系统的标"）
        cfg.includeChildWindows = false
        cfg.capturesAudio = false // 串流 App 的声音本来就从 Mac 播放
        return cfg
    }

    /// 找画面里"不是纯黑"的范围（亮度 > 40，每行 / 每列至少 2% 的抽样点），和之前的结果取并集
    private func scan(_ pb: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0)?.assumingMemoryBound(to: UInt8.self) else { return }
        let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let st = 4
        var rows = [Int](repeating: 0, count: (h - 1) / st + 1), cols = [Int](repeating: 0, count: (w - 1) / st + 1)
        for (ri, y) in stride(from: 0, to: h, by: st).enumerated() {
            let row = base.advanced(by: y * bpr)
            for (ci, x) in stride(from: 0, to: w, by: st).enumerated() where row[x] > 40 {
                rows[ri] += 1; cols[ci] += 1
            }
        }
        let rowNeed = max(1, cols.count / 50), colNeed = max(1, rows.count / 50)
        guard let r0 = rows.firstIndex(where: { $0 >= rowNeed }), let r1 = rows.lastIndex(where: { $0 >= rowNeed }),
              let c0 = cols.firstIndex(where: { $0 >= colNeed }), let c1 = cols.lastIndex(where: { $0 >= colNeed }) else { return }
        let b = (c0 * st, r0 * st, min(w, c1 * st + st), min(h, r1 * st + st))
        // 内容太少（暗场景、加载画面）不算
        guard Double((b.2 - b.0) * (b.3 - b.1)) > 0.3 * Double(w * h) else { return }
        if let f = found {
            found = (min(f.x0, b.0), min(f.y0, b.1), max(f.x1, b.2), max(f.y1, b.3))
        } else {
            found = b
        }
    }

    /// 把找到的游戏画面范围换算回窗口坐标，在里面取 16:9 铺满（每边黑边超过 2% 才算）
    private func applyCrop() {
        cropDone = true
        guard let f = found else { onLog?("自动裁黑边：画面一直太暗，没裁"); return }
        let W = CGFloat(width), H = CGFloat(height)
        let l = CGFloat(f.x0) > W * 0.02 ? CGFloat(f.x0) : 0
        let r = W - CGFloat(f.x1) > W * 0.02 ? CGFloat(f.x1) : W
        let t = CGFloat(f.y0) > H * 0.02 ? CGFloat(f.y0) : 0
        let b = H - CGFloat(f.y1) > H * 0.02 ? CGFloat(f.y1) : H
        guard l > 0 || r < W || t > 0 || b < H else { onLog?("自动裁黑边：没有黑边，按 16:9 铺满"); return }
        let kx = src.width / W, ky = src.height / H
        let content = CGRect(x: src.minX + l * kx, y: src.minY + t * ky, width: (r - l) * kx, height: (b - t) * ky)
        guard content.width * content.height > 0.3 * src.width * src.height else { onLog?("自动裁黑边：要裁的太多，可能是暗场景，没裁"); return }
        src = WindowCapture.fill16x9(content)
        onLog?("自动裁黑边：游戏画面 \(Int(content.width))×\(Int(content.height)) 点，取 16:9 区域 \(Int(src.minX)),\(Int(src.minY)) \(Int(src.width))×\(Int(src.height)) 铺满 \(width)×\(height)")
        stream?.updateConfiguration(makeConfig()) { _ in }
    }

    /// 每 3 秒看一次窗口大小，变了就重新取 16:9 并重新识别黑边
    private func watchWindowSize() {
        guard !watching else { return }
        watching = true
        Task { [weak self] in
            while let self, self.stream != nil {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let wins = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false),
                      let w = wins.windows.first(where: { $0.windowID == self.windowID }) else { continue }
                let size = w.frame.size
                let fs = WindowCapture.isNativeFullScreen(w)
                self.queue.async {
                    self.fullScreen = fs
                    guard abs(size.width - self.windowSize.width) > 1 || abs(size.height - self.windowSize.height) > 1 else { return }
                    self.windowSize = size
                    self.src = WindowCapture.fill16x9(self.baseContent())
                    self.found = nil; self.cropDone = false; self.frameNo = 0
                    self.onLog?("窗口大小变成 \(Int(size.width))×\(Int(size.height))，重新铺满")
                    // 原始像素变了 10% 以上：采集尺寸要换，补帧器也要按新尺寸重建
                    let ns = WindowCapture.outputSize(self.src, self.scale)
                    if ns != (self.width, self.height), abs(Double(ns.0 - self.width)) > 0.1 * Double(self.width) {
                        self.onLog?("采集尺寸 \(self.width)×\(self.height) → \(ns.0)×\(ns.1)，重新打开窗口")
                        self.onNeedRestart?()
                        return
                    }
                    self.stream?.updateConfiguration(self.makeConfig()) { _ in }
                }
            }
        }
    }

    func start() async throws {
        try await stream?.startCapture()
        watchWindowSize()
    }
    func stop() {
        stream?.stopCapture { _ in }
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        // 只要内容完整的帧（idle / blank 帧没有新画面）
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = atts.first?[.status] as? Int, let st = SCFrameStatus(rawValue: raw), st != .complete {
            return
        }
        // 窗口在采集中途改变了尺寸：丢掉（补帧器尺寸固定）
        guard CVPixelBufferGetWidth(pb) == width, CVPixelBufferGetHeight(pb) == height else { return }
        // 开始后 3 秒内每 10 帧看一次四周黑边，到第 180 帧裁一次
        frameNo += 1
        if autoCrop, !cropDone {
            if frameNo % 10 == 0 { scan(pb) }
            if frameNo >= 180 { applyCrop() }
        }
        onFrame?(pb, CMSampleBufferGetPresentationTimeStamp(sb))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?("窗口采集停止：\(error)")
    }
}
