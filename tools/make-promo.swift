// 生成 FrameInterp 的演示视频（1920×1080，60 帧，H.264）。
// 用法：swiftc -O tools/make-promo.swift -o .build/make-promo && .build/make-promo promo/app-ui.png dist/FrameInterp-演示.mp4
// 对比片段里右边多出来的帧是真的用 Apple 低延迟补帧（和 App 里同一个模型）算出来的，不是画出来的。
import AppKit
import AVFoundation
import CoreImage
import VideoToolbox

let W = 1920, H = 1080, FPS = 60
let args = CommandLine.arguments
guard args.count >= 3 else { print("用法：make-promo 界面截图.png 输出.mp4"); exit(1) }
let uiImage = NSImage(contentsOfFile: args[1])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let outURL = URL(fileURLWithPath: args[2])
try? FileManager.default.removeItem(at: outURL)

// MARK: - 颜色、文字

let bg = CGColor(red: 0.055, green: 0.055, blue: 0.065, alpha: 1)
let accent = NSColor(red: 0.30, green: 0.85, blue: 0.55, alpha: 1)
let dim = NSColor(white: 0.62, alpha: 1)
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func text(_ ctx: CGContext, _ s: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .white,
          x: CGFloat? = nil, y: CGFloat, alpha: CGFloat = 1) {
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                .foregroundColor: color.withAlphaComponent(alpha * color.alphaComponent)]
    let str = NSAttributedString(string: s, attributes: attrs)
    let sz = str.size()
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    str.draw(at: NSPoint(x: x ?? (CGFloat(W) - sz.width) / 2, y: y))
    NSGraphicsContext.restoreGraphicsState()
}

func ease(_ t: Double) -> Double { let c = min(max(t, 0), 1); return c * c * (3 - 2 * c) }

// MARK: - 演示画面（像游戏的横向卷轴：远山、近山、树、路、车）

func drawScene(_ ctx: CGContext, t: Double) {
    let w = CGFloat(W), h = CGFloat(H)
    // 天空
    let sky = CGGradient(colorsSpace: srgb, colors: [CGColor(red: 0.98, green: 0.62, blue: 0.35, alpha: 1),
                                                    CGColor(red: 0.20, green: 0.32, blue: 0.62, alpha: 1)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: h * 0.35), end: CGPoint(x: 0, y: h), options: [])
    ctx.setFillColor(CGColor(red: 1, green: 0.88, blue: 0.55, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: w * 0.72, y: h * 0.62, width: 150, height: 150))
    // 山：两层，滚动速度不同（视差）
    func hills(speed: Double, base: CGFloat, amp: CGFloat, freq: Double, color: CGColor) {
        let off = t * speed
        ctx.beginPath(); ctx.move(to: CGPoint(x: 0, y: 0))
        var x: CGFloat = 0
        while x <= w + 8 {
            let wx = Double(x) + off
            let y = base + amp * CGFloat(sin(wx * freq) * 0.6 + sin(wx * freq * 2.3 + 1.7) * 0.3 + sin(wx * freq * 5.1) * 0.1)
            ctx.addLine(to: CGPoint(x: x, y: y)); x += 8
        }
        ctx.addLine(to: CGPoint(x: w, y: 0)); ctx.closePath()
        ctx.setFillColor(color); ctx.fillPath()
    }
    hills(speed: 120, base: h * 0.52, amp: 110, freq: 0.0030, color: CGColor(red: 0.36, green: 0.30, blue: 0.48, alpha: 1))
    hills(speed: 320, base: h * 0.40, amp: 80, freq: 0.0055, color: CGColor(red: 0.20, green: 0.42, blue: 0.36, alpha: 1))
    // 地面
    ctx.setFillColor(CGColor(red: 0.16, green: 0.32, blue: 0.22, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h * 0.30))
    // 树：每 220 像素一棵，900 像素/秒
    let treeOff = (t * 900).truncatingRemainder(dividingBy: 220)
    var i = -1
    while CGFloat(i) * 220 - CGFloat(treeOff) < w + 220 {
        let x = CGFloat(i) * 220 - CGFloat(treeOff)
        let k = Int((t * 900) / 220) + i
        let sc: CGFloat = 0.8 + CGFloat((k * 37) % 5) * 0.08
        ctx.setFillColor(CGColor(red: 0.35, green: 0.22, blue: 0.14, alpha: 1))
        ctx.fill(CGRect(x: x + 40, y: h * 0.28, width: 18, height: 60 * sc))
        ctx.setFillColor(CGColor(red: 0.12, green: 0.50, blue: 0.28, alpha: 1))
        for (j, yy) in [0.0, 45.0, 85.0].enumerated() {
            let ww = (110 - CGFloat(j) * 25) * sc
            ctx.beginPath()
            ctx.move(to: CGPoint(x: x + 49 - ww / 2, y: h * 0.28 + 50 * sc + CGFloat(yy) * sc))
            ctx.addLine(to: CGPoint(x: x + 49 + ww / 2, y: h * 0.28 + 50 * sc + CGFloat(yy) * sc))
            ctx.addLine(to: CGPoint(x: x + 49, y: h * 0.28 + 50 * sc + CGFloat(yy) * sc + 95 * sc))
            ctx.closePath(); ctx.fillPath()
        }
        i += 1
    }
    // 路 + 移动的虚线（1400 像素/秒）
    ctx.setFillColor(CGColor(red: 0.18, green: 0.18, blue: 0.20, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h * 0.20))
    ctx.setFillColor(CGColor(red: 0.95, green: 0.85, blue: 0.30, alpha: 1))
    let dashOff = CGFloat((t * 1400).truncatingRemainder(dividingBy: 240))
    var dx = -dashOff
    while dx < w { ctx.fill(CGRect(x: dx, y: h * 0.09, width: 130, height: 14)); dx += 240 }
    // 车：轻微上下颠，车轮转
    let bob = CGFloat(sin(t * 18) * 3)
    let cx = w * 0.42, cy = h * 0.13 + bob
    ctx.setFillColor(CGColor(red: 0.85, green: 0.20, blue: 0.22, alpha: 1))
    ctx.fill(CGRect(x: cx, y: cy + 40, width: 300, height: 70))
    ctx.fill(CGRect(x: cx + 60, y: cy + 105, width: 160, height: 55))
    ctx.setFillColor(CGColor(red: 0.65, green: 0.85, blue: 0.95, alpha: 1))
    ctx.fill(CGRect(x: cx + 75, y: cy + 112, width: 60, height: 40)); ctx.fill(CGRect(x: cx + 145, y: cy + 112, width: 60, height: 40))
    for wx in [cx + 60, cx + 240] {
        ctx.setFillColor(CGColor(gray: 0.08, alpha: 1)); ctx.fillEllipse(in: CGRect(x: wx - 38, y: cy + 2, width: 76, height: 76))
        ctx.setStrokeColor(CGColor(gray: 0.75, alpha: 1)); ctx.setLineWidth(5)
        for s in 0..<4 {
            let a = -t * 12 + Double(s) * .pi / 4
            ctx.move(to: CGPoint(x: wx - CGFloat(cos(a)) * 28, y: cy + 40 - CGFloat(sin(a)) * 28))
            ctx.addLine(to: CGPoint(x: wx + CGFloat(cos(a)) * 28, y: cy + 40 + CGFloat(sin(a)) * 28))
        }
        ctx.strokePath()
    }
}

// MARK: - 真实帧（30 帧）和 Apple 补出来的中间帧

var transfer: VTPixelTransferSession?
VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
let ci = CIContext()
let ioAttrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]

func newBuffer(_ fmt: OSType) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, W, H, fmt, ioAttrs as CFDictionary, &pb)
    return pb!
}

/// 第 k 个真实帧（30 帧/秒的内容）
func realFrame(_ k: Int) -> CVPixelBuffer {
    let bgra = newBuffer(kCVPixelFormatType_32BGRA)
    CVPixelBufferLockBaseAddress(bgra, [])
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(bgra), width: W, height: H, bitsPerComponent: 8,
                        bytesPerRow: CVPixelBufferGetBytesPerRow(bgra), space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    drawScene(ctx, t: Double(k) / 30)
    CVPixelBufferUnlockBaseAddress(bgra, [])
    let yuv = newBuffer(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    VTPixelTransferSessionTransferImage(transfer!, from: bgra, to: yuv)
    return yuv
}

let vtConfig = VTLowLatencyFrameInterpolationConfiguration(frameWidth: W, frameHeight: H, numberOfInterpolatedFrames: 2)!
let processor = VTFrameProcessor()
try processor.startSession(configuration: vtConfig)

func interpolate(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> CVPixelBuffer {
    let d = newBuffer(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    let fa = VTFrameProcessorFrame(buffer: a, presentationTimeStamp: CMTime(value: 0, timescale: 60))!
    let fb = VTFrameProcessorFrame(buffer: b, presentationTimeStamp: CMTime(value: 2, timescale: 60))!
    let fd = VTFrameProcessorFrame(buffer: d, presentationTimeStamp: CMTime(value: 1, timescale: 60))!
    let p = VTLowLatencyFrameInterpolationParameters(sourceFrame: fb, previousFrame: fa, interpolationPhase: [0.5], destinationFrames: [fd])!
    let sem = DispatchSemaphore(value: 0)
    processor.process(parameters: p) { _, e in if let e { print("补帧失败：\(e)") }; sem.signal() }
    sem.wait()
    return d
}

var realCache = [Int: CGImage](), interpCache = [Int: CGImage](), yuvCache = [Int: CVPixelBuffer]()
func cg(_ pb: CVPixelBuffer) -> CGImage { ci.createCGImage(CIImage(cvPixelBuffer: pb), from: CGRect(x: 0, y: 0, width: W, height: H))! }
func yuv(_ k: Int) -> CVPixelBuffer {
    if let y = yuvCache[k] { return y }
    let y = realFrame(k); yuvCache[k] = y
    for old in yuvCache.keys where old < k - 2 { yuvCache[old] = nil }
    return y
}
func real(_ k: Int) -> CGImage {
    if let c = realCache[k] { return c }
    let c = cg(yuv(k)); realCache[k] = c
    for old in realCache.keys where old < k - 2 { realCache[old] = nil }
    return c
}
func mid(_ k: Int) -> CGImage {
    if let c = interpCache[k] { return c }
    let c = cg(interpolate(yuv(k), yuv(k + 1))); interpCache[k] = c
    for old in interpCache.keys where old < k - 2 { interpCache[old] = nil }
    return c
}

// MARK: - 各段

func panel(_ ctx: CGContext, _ img: CGImage, x: CGFloat, label: String, sub: String, tag: Bool, highlight: Bool) {
    let pw: CGFloat = 900, ph: CGFloat = 506, y: CGFloat = 230
    ctx.saveGState()
    let r = CGRect(x: x, y: y, width: pw, height: ph)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: 14, cornerHeight: 14, transform: nil)); ctx.clip()
    ctx.interpolationQuality = .high
    ctx.draw(img, in: r)
    ctx.restoreGState()
    if highlight {
        ctx.setStrokeColor(accent.cgColor); ctx.setLineWidth(3)
        ctx.addPath(CGPath(roundedRect: r.insetBy(dx: -4, dy: -4), cornerWidth: 17, cornerHeight: 17, transform: nil)); ctx.strokePath()
    }
    text(ctx, label, size: 40, weight: .semibold, color: highlight ? accent : .white, x: x, y: y + ph + 56)
    text(ctx, sub, size: 24, color: dim, x: x, y: y + ph + 18)
    if tag {
        let tr = CGRect(x: x + pw - 190, y: y + ph - 62, width: 170, height: 44)
        ctx.setFillColor(accent.withAlphaComponent(0.92).cgColor)
        ctx.addPath(CGPath(roundedRect: tr, cornerWidth: 10, cornerHeight: 10, transform: nil)); ctx.fillPath()
        text(ctx, "补出来的帧", size: 24, weight: .semibold, color: .black, x: tr.minX + 25, y: tr.minY + 8)
    }
}

/// 对比：m = 60 帧时间轴上的位置。左边永远显示真实帧（每帧停两拍），右边奇数位是补出来的帧
func compare(_ ctx: CGContext, m: Int, k0: Int, slow: Bool) {
    let k = k0 + m / 2
    panel(ctx, real(k), x: 40, label: "原始 30 帧", sub: "采集卡收到的画面，每帧重复两次", tag: false, highlight: false)
    let isMid = m % 2 == 1
    panel(ctx, isMid ? mid(k) : real(k), x: 980, label: "FrameInterp 补到 60 帧", sub: "每两帧之间实时补一帧", tag: slow && isMid, highlight: true)
}

struct Section { let dur: Double; let draw: (CGContext, Double, Int) -> Void } // (ctx, 段内秒数, 段内帧号)

let sections: [Section] = [
    Section(dur: 3.2) { ctx, t, _ in
        let a = CGFloat(ease(t / 0.8))
        text(ctx, "FrameInterp", size: 120, weight: .bold, y: 560 + CGFloat(1 - a) * 30, alpha: a)
        text(ctx, "采集卡画面 · 30 帧实时补到 60 帧 · 低延迟", size: 44, color: accent, y: 470, alpha: CGFloat(ease((t - 0.4) / 0.8)))
        text(ctx, "Apple 低延迟补帧模型，在 Mac 上实时运行", size: 30, color: dim, y: 400, alpha: CGFloat(ease((t - 0.8) / 0.8)))
    },
    Section(dur: 4.8) { ctx, t, _ in
        let z = 1.0 + 0.05 * ease(t / 4.8)
        let iw = Double(uiImage.width), ih = Double(uiImage.height)
        let fit = min(1500 / iw, 860 / ih) * z
        let dw = iw * fit, dh = ih * fit
        ctx.interpolationQuality = .high
        ctx.draw(uiImage, in: CGRect(x: (Double(W) - dw) / 2, y: 175 + (860 - dh) / 2, width: dw, height: dh))
        text(ctx, "插上采集卡自动识别  ·  一键开启补帧  ·  声音直通", size: 40, weight: .medium, y: 70, alpha: CGFloat(ease((t - 0.3) / 0.6)))
    },
    Section(dur: 8.0) { ctx, t, j in
        text(ctx, "同一段画面，正常速度", size: 46, weight: .semibold, y: 900)
        compare(ctx, m: j, k0: 0, slow: false)
    },
    Section(dur: 6.0) { ctx, t, j in
        text(ctx, "慢放 4 倍：右边每隔一帧，就是实时算出来的新画面", size: 46, weight: .semibold, y: 900)
        compare(ctx, m: j / 4, k0: 300, slow: true)
    },
    Section(dur: 4.2) { ctx, t, _ in
        let items = [("≈18 ms", "补一帧 1080p（M2）"), ("60 帧", "稳定输出，不丢帧"), ("≈0 ms", "不补帧时程序额外延迟")]
        for (i, it) in items.enumerated() {
            let a = CGFloat(ease((t - Double(i) * 0.25) / 0.6))
            let x = 160 + CGFloat(i) * 560
            text(ctx, it.0, size: 96, weight: .bold, color: accent, x: x, y: 520, alpha: a)
            text(ctx, it.1, size: 34, color: dim, x: x, y: 460, alpha: a)
        }
        text(ctx, "原生 4:2:2 采集 · 补帧画面直接上屏 · 帧数和延迟浮窗", size: 34, y: 250, alpha: CGFloat(ease((t - 0.9) / 0.6)))
    },
    Section(dur: 3.0) { ctx, t, _ in
        let a = CGFloat(ease(t / 0.8))
        text(ctx, "FrameInterp 1.0", size: 100, weight: .bold, y: 540, alpha: a)
        text(ctx, "Apple 芯片 Mac  ·  macOS 26 或更新  ·  支持常见 USB 采集卡", size: 36, color: dim, y: 450, alpha: a)
    },
]

// MARK: - 编码

let writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: W, AVVideoHeightKey: H,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 30_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                                      AVVideoExpectedSourceFrameRateKey: FPS, AVVideoMaxKeyFrameIntervalKey: FPS],
])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)

var frameNo = 0
let fade = 0.3
for (si, s) in sections.enumerated() {
    let n = Int(s.dur * Double(FPS))
    for j in 0..<n {
        while !input.isReadyForMoreMediaData { usleep(1000) }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        CVPixelBufferLockBaseAddress(pb!, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb!), width: W, height: H, bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(pb!), space: srgb,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.setFillColor(bg); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        let t = Double(j) / Double(FPS)
        s.draw(ctx, t, j)
        // 段与段之间淡入淡出（第一段不淡入）
        var black = 0.0
        if si > 0, t < fade { black = 1 - t / fade }
        if t > s.dur - fade && si < sections.count - 1 { black = (t - (s.dur - fade)) / fade }
        if black > 0 { ctx.setFillColor(bg.copy(alpha: CGFloat(black))!); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H)) }
        CVPixelBufferUnlockBaseAddress(pb!, [])
        adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(frameNo), timescale: CMTimeScale(FPS)))
        frameNo += 1
    }
    print("第 \(si + 1)/\(sections.count) 段完成")
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
print(writer.status == .completed ? "已生成 \(outURL.path)，\(frameNo) 帧（\(Double(frameNo) / Double(FPS)) 秒）" : "失败：\(String(describing: writer.error))")
