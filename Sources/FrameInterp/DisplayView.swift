import AVFoundation
import AppKit
import CoreMedia
import QuartzCore

/// 显示：AVSampleBufferDisplayLayer + NSView.displayLink（每个刷新周期从队列取一帧，DisplayImmediately 入队）
final class DisplayView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()
    var queue: DisplayQueue? { didSet { started = false } }
    var stats: Stats!
    var onKey: ((String) -> Void)?
    var countEmpty: () -> Bool = { true } // 只有补帧开着时，没帧可显示才算"空拍"
    private var link: CADisplayLink?
    private var formatDesc: CMVideoFormatDescription?
    private var started = false // 第一帧到之前不计空拍
    private var backlogRun = 0
    /// 补出来的帧算完就直接上屏（不进队列、不等下一次刷新回调），然后跳过一次刷新回调，
    /// 真实帧在再下一次刷新显示——补出来的帧正好占一个刷新周期，不会被真实帧顶掉
    private var holdTicks = 0
    var directInterpEnabled = ProcessInfo.processInfo.environment["FI_NODIRECTINTERP"] != "1"

    func showInterpNow(_ pb: CVPixelBuffer, arrivalMs: Double) -> Bool {
        guard directInterpEnabled else { return false }
        directLock.lock(); defer { directLock.unlock() }
        let renderer = displayLayer.sampleBufferRenderer
        normalizeColor(pb, kind: "补帧（直接上屏）")
        guard renderer.status != .failed, let sb = makeSampleBuffer(pb) else { return false }
        renderer.enqueue(sb)
        holdTicks = 1
        CATransaction.begin(); CATransaction.setDisableActions(true)
        markerLayer.isHidden = !markInterpolated
        CATransaction.commit()
        let lat = nowMs() - arrivalMs
        stats.with { $0.displayed += 1; $0.latencySum += lat; $0.latencyN += 1 }
        return true
    }

    // 叠加文字：中间的提示、上方的短暂提示、左上角的统计
    private let messageLayer = CATextLayer()
    private let flashLayer = CATextLayer()   // 旧的短暂提示（不再显示，留着免得改布局）
    // 短暂提示（2026-11-28 重做：原来是固定 300×30 的黑底文字条，用户说粗糙）：毛玻璃胶囊，宽度跟着文字，左边小图标，淡入淡出
    private let toast = NSVisualEffectView()
    private let toastIcon = NSImageView()
    private let toastLabel = NSTextField(labelWithString: "")
    // 左上角浮窗（帧数 / 延迟）：毛玻璃小条，是窗口里的独立视图，
    // 不进视频帧，所以不会被补帧或锐化
    private let hud = NSVisualEffectView()
    private let hudLabel = NSTextField(labelWithString: "")
    private let markerLayer = CALayer() // 补出来的帧：右上角橙点
    var markInterpolated = false
    private var flashToken = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
        displayLayer.frame = bounds
        // 不用 autoresizingMask：它按"大小变化量"去调图层，全屏 / 窗口来回切时误差会累积，画面越来越大。
        // 改为每次布局时直接把图层设成视图大小（见 layoutOverlays）
        layer?.addSublayer(displayLayer)
        contentsLayer.contentsGravity = .resizeAspect
        contentsLayer.frame = bounds
        layer?.addSublayer(contentsLayer)
        for (l, size) in [(messageLayer, 18.0), (flashLayer, 15.0)] {
            l.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            l.fontSize = size
            l.font = NSFont.monospacedSystemFont(ofSize: size, weight: .medium)
            l.foregroundColor = NSColor.white.cgColor
            l.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
            l.cornerRadius = 6
            l.isWrapped = true
            l.isHidden = true
            layer?.addSublayer(l)
        }
        markerLayer.backgroundColor = NSColor.systemOrange.cgColor
        markerLayer.cornerRadius = 9
        markerLayer.isHidden = true
        layer?.addSublayer(markerLayer)
        messageLayer.alignmentMode = .center
        flashLayer.alignmentMode = .center
        flashLayer.cornerRadius = 15
        toast.material = .hudWindow
        toast.blendingMode = .withinWindow
        toast.state = .active
        toast.wantsLayer = true
        toast.layer?.masksToBounds = true
        toast.layer?.borderWidth = 1
        toast.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        toast.alphaValue = 0
        toast.isHidden = true
        toastLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        toastLabel.textColor = .white
        toastLabel.maximumNumberOfLines = 2
        toastLabel.lineBreakMode = .byTruncatingTail
        toastIcon.imageScaling = .scaleProportionallyUpOrDown
        toast.addSubview(toastIcon)
        toast.addSubview(toastLabel)
        addSubview(toast)
        hud.material = .hudWindow
        hud.blendingMode = .withinWindow
        hud.state = .active
        hud.appearance = NSAppearance(named: .darkAqua)
        hud.wantsLayer = true
        hud.layer?.cornerRadius = 9
        hud.layer?.masksToBounds = true
        hud.layer?.borderWidth = 0.5
        hud.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        hud.isHidden = true
        hudLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        hudLabel.textColor = NSColor.white.withAlphaComponent(0.92)
        hudLabel.translatesAutoresizingMaskIntoConstraints = true
        hud.addSubview(hudLabel)
        addSubview(hud)
    }

    override func layout() {
        super.layout()
        layoutOverlays()
    }

    /// 画面实际占用的像素大小（16:9 套进视图里），给画面增强决定放大到多大
    var onPixelSize: ((CGSize) -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutOverlays()
    }

    private func layoutOverlays() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        contentsLayer.frame = bounds
        CATransaction.commit()
        let scale = window?.backingScaleFactor ?? 2
        let px = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let fit = min(px.width / 16, px.height / 9)
        onPixelSize?(CGSize(width: (fit * 16).rounded(), height: (fit * 9).rounded()))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let b = bounds
        let mw = min(b.width - 40, 640)
        messageLayer.frame = CGRect(x: (b.width - mw) / 2, y: b.height / 2 - 50, width: mw, height: 100)
        flashLayer.frame = CGRect(x: (b.width - 300) / 2, y: 24, width: 300, height: 30)
        layoutHud()
        if !toast.isHidden { layoutToast() }
        markerLayer.frame = CGRect(x: b.width - 32, y: b.height - 32, width: 18, height: 18)
        CATransaction.commit()
    }

    /// 中间的常驻提示（nil = 隐藏）。显示提示时清掉旧画面
    func setMessage(_ text: String?) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        messageLayer.string = text.map { "\n\(L($0))\n" }
        messageLayer.isHidden = text == nil
        CATransaction.commit()
        if text != nil { displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil) }
    }

    /// 上方短暂提示，2 秒后消失
    func flash(_ text: String) {
        flashToken += 1
        let tok = flashToken
        // 图标和颜色按内容选：补帧开 = 亮色星星，补帧关 = 灰色，⚠ = 黄色三角，其他 = 信息
        var t = L(text)
        let (sym, color): (String, NSColor)
        if t.hasPrefix("⚠") { t = String(t.dropFirst()).trimmingCharacters(in: .whitespaces); (sym, color) = ("exclamationmark.triangle.fill", .systemYellow) }
        else if text.contains("补帧：开") || text.contains("Interpolation: on") { (sym, color) = ("sparkles", NSColor(red: 120 / 255, green: 132 / 255, blue: 1, alpha: 1)) }
        else if text.contains("补帧：关") || text.contains("Interpolation: off") { (sym, color) = ("sparkles", .secondaryLabelColor) }
        else { (sym, color) = ("info.circle.fill", .secondaryLabelColor) }
        toastIcon.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
        toastIcon.contentTintColor = color
        toastLabel.stringValue = t
        layoutToast()
        toast.isHidden = false
        let shown = toast.alphaValue > 0.5
        if !shown { toast.frame.origin.y += 8 }
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.18
            toast.animator().alphaValue = 1
            if !shown { toast.animator().frame.origin.y -= 8 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.flashToken == tok else { return }
            NSAnimationContext.runAnimationGroup({ c in
                c.duration = 0.25
                self.toast.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated { if let self, self.flashToken == tok { self.toast.isHidden = true } }
            })
        }
    }

    /// 提示的大小和位置：宽度跟着文字（最宽画面的 70%），在画面上方居中
    private func layoutToast() {
        let maxW = max(200, bounds.width * 0.7)
        toastLabel.preferredMaxLayoutWidth = maxW - 60
        let ls = toastLabel.sizeThatFits(NSSize(width: maxW - 60, height: 200))
        let h = max(36, ceil(ls.height) + 16), w = min(maxW, ceil(ls.width) + 58)
        toast.frame = CGRect(x: (bounds.width - w) / 2, y: bounds.height - 22 - h, width: w, height: h)
        toast.layer?.cornerRadius = min(h / 2, 18)
        toastIcon.frame = CGRect(x: 16, y: (h - 18) / 2, width: 18, height: 18)
        toastLabel.frame = CGRect(x: 42, y: (h - ceil(ls.height)) / 2, width: w - 58, height: ceil(ls.height))
    }

    /// 左上角浮窗（nil = 隐藏），一行：帧数 · 延迟
    func setHud(_ text: String?) {
        hud.isHidden = text == nil
        guard let text else { return }
        if hudLabel.stringValue != text {
            hudLabel.stringValue = L(text)
            layoutHud()
        }
    }

    private func layoutHud() {
        hudLabel.sizeToFit()
        let ls = hudLabel.frame.size
        let padX: CGFloat = 12, h: CGFloat = 28
        let w = ceil(ls.width) + padX * 2
        hud.frame = CGRect(x: 14, y: bounds.height - 14 - h, width: w, height: h)
        hudLabel.frame = CGRect(x: padX, y: (h - ls.height) / 2, width: ceil(ls.width), height: ls.height)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if let c = event.charactersIgnoringModifiers { onKey?(c) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, link == nil else { return }
        let l = displayLink(target: self, selector: #selector(vsync(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stop() { link?.invalidate(); link = nil }

    @objc private func vsync(_ l: CADisplayLink) {
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed {
            stats.with { $0.lastError = "显示层失败：\(String(describing: renderer.error))，已重置" }
            renderer.flush()
        }
        directLock.lock()
        let hold = holdTicks > 0
        if hold { holdTicks -= 1 }
        directLock.unlock()
        if hold { return } // 这一个刷新周期留给刚直接上屏的补帧
        guard let queue, let item = queue.pop() else {
            if started && countEmpty() { stats.with { $0.emptyVsync += 1 } }
            backlogRun = 0
            return
        }
        // 削积压：帧进出速度一样时，一旦积了一两帧就一直积着，画面照样流畅但延迟永远多一两帧（实测多 38ms）。
        // 取完这一帧队列里还有剩、而且连续 0.5 秒都这样，就丢一帧（优先丢补出来的）把积压削掉
        if queue.count > 0 { backlogRun += 1 } else { backlogRun = 0 }
        if backlogRun >= 30 {
            backlogRun = 0
            if queue.trimOne() { stats.with { $0.trims += 1 } }
        }
        started = true
        directLock.lock()
        normalizeColor(item.buffer, kind: item.interpolated ? "补帧（队列）" : "真实帧（队列）")
        let sbOpt = makeSampleBuffer(item.buffer)
        if let sbOpt { renderer.enqueue(sbOpt) }
        directLock.unlock()
        guard sbOpt != nil else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        markerLayer.isHidden = !(markInterpolated && item.interpolated)
        CATransaction.commit()
        let lat = nowMs() - item.arrivalMs
        stats.with { $0.displayed += 1; $0.latencySum += lat; $0.latencyN += 1 }
    }

    /// 直通：不排队、不等下一次屏幕刷新，采集线程拿到一帧马上交给显示层（补帧和画面增强都关着时用）
    private let directLock = NSLock()
    /// 直通的显示方式（实验）：FI_RENDER=contents 时把图像直接设成普通图层的内容，不经过视频显示层
    let contentsLayer = CALayer()
    static let renderMode = ProcessInfo.processInfo.environment["FI_RENDER"] ?? "video"

    func enqueueDirect(_ pb: CVPixelBuffer, arrivalMs: Double) {
        directLock.lock(); defer { directLock.unlock() }
        if DisplayView.renderMode == "contents", let surf = CVPixelBufferGetIOSurface(pb) {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            contentsLayer.contents = surf.takeUnretainedValue()
            CATransaction.commit()
            CATransaction.flush()
            let lat = nowMs() - arrivalMs
            stats.with { $0.displayed += 1; $0.latencySum += lat; $0.latencyN += 1 }
            return
        }
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        normalizeColor(pb, kind: "直通 \(fourCC(CVPixelBufferGetPixelFormatType(pb)))")
        guard let sb = makeSampleBuffer(pb) else { return }
        renderer.enqueue(sb)
        let lat = nowMs() - arrivalMs
        stats.with { $0.displayed += 1; $0.latencySum += lat; $0.latencyN += 1 }
    }

    /// 每种帧第一次显示时把它带的附件记进日志（查颜色问题用）
    private var loggedAttach = Set<String>()

    /// 所有要显示的帧统一颜色附件：先清掉全部，再只设 BT.709 三项。
    /// 2026-11-14 实测：采集卡的帧带着系统给的颜色附件（拷贝时会跟过来），补出来的帧没有，
    /// 显示层对两种帧的颜色解释不同，开补帧时画面亮度每帧一高一低（窗口整体亮度 76 ↔ 83），看起来就是一直在闪
    private func normalizeColor(_ pb: CVPixelBuffer, kind: String) {
        if !loggedAttach.contains(kind) {
            loggedAttach.insert(kind)
            let keys = (CVBufferCopyAttachments(pb, .shouldPropagate) as? [String: Any]).map { $0.keys.sorted().joined(separator: ",") } ?? "无"
            let keys2 = (CVBufferCopyAttachments(pb, .shouldNotPropagate) as? [String: Any]).map { $0.keys.sorted().joined(separator: ",") } ?? "无"
            Log.write("显示的帧（\(kind)）原来带的附件：\(keys)；不传递的：\(keys2)")
        }
        CVBufferRemoveAllAttachments(pb)
        tagBT709(pb)
    }

    private var formatKey = ""

    /// 格式描述只按"像素格式 + 尺寸"建，不含每行字节数（CVBytesPerRow）。
    /// 2026-11-14 实测：真实帧和补出来的帧来自不同的缓冲池，每行字节数 2884 / 2904 不一样，
    /// 系统按缓冲生成的描述每帧都"变了格式"（每秒 60 次），显示层每帧重新配置，窗口模式下会闪
    private func makeSampleBuffer(_ pb: CVPixelBuffer) -> CMSampleBuffer? {
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let key = "\(fourCC(fmt)) \(w)x\(h)"
        if formatDesc == nil || key != formatKey {
            stats.with { $0.fmtChanges += 1; $0.lastFmt = key }
            let ext: [String: Any] = [
                kCVImageBufferColorPrimariesKey as String: kCVImageBufferColorPrimaries_ITU_R_709_2,
                kCVImageBufferTransferFunctionKey as String: displayTransferFunction,
                kCVImageBufferYCbCrMatrixKey as String: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            ]
            var fd: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreate(allocator: nil, codecType: fmt, width: Int32(w), height: Int32(h),
                                           extensions: ext as CFDictionary, formatDescriptionOut: &fd)
            if formatDesc != nil { Log.write("显示格式变化：\(formatKey) → \(key)") }
            formatDesc = fd
            formatKey = key
        }
        guard let fd = formatDesc else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: fd,
                                                 sampleTiming: &timing, sampleBufferOut: &sb)
        guard let sb else { return nil }
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(atts) > 0 {
            let d = unsafeBitCast(CFArrayGetValueAtIndex(atts, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(d, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sb
    }
}
