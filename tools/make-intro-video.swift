// 生成 FrameInterp 的介绍视频（1920×1080，60 帧，H.264）：作用 → 能用的设备 → 体积和占用 → 原理 → 效果。
// 用法：swiftc -O tools/make-intro-video.swift -o .build/make-intro-video && .build/make-intro-video dist/FrameInterp-介绍.mp4
// 对比片段里右边多出来的帧是真的用 Apple 低延迟补帧（和 App 里同一个模型）算出来的，不是画出来的。
import AppKit
import AVFoundation
import CoreImage
import VideoToolbox

let W = 1920, H = 1080, FPS = 60
let args = CommandLine.arguments
guard args.count >= 2 else { print("用法：make-intro-video 输出.mp4"); exit(1) }
let outURL = URL(fileURLWithPath: args[1])
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

// MARK: - 小工具

func rrect(_ ctx: CGContext, _ r: CGRect, _ rad: CGFloat, fill: CGColor? = nil, stroke: CGColor? = nil, lw: CGFloat = 2) {
    let p = CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil)
    if let fill { ctx.setFillColor(fill); ctx.addPath(p); ctx.fillPath() }
    if let stroke { ctx.setStrokeColor(stroke); ctx.setLineWidth(lw); ctx.addPath(p); ctx.strokePath() }
}
func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }
let card = CGColor(red: 1, green: 1, blue: 1, alpha: 0.06)
let line = CGColor(red: 1, green: 1, blue: 1, alpha: 0.14)

/// 小画面缩略图（带圆角、可选边框和角标）
func thumb(_ ctx: CGContext, _ img: CGImage, _ r: CGRect, alpha: CGFloat = 1, border: NSColor? = nil, tag: String? = nil) {
    guard alpha > 0.01 else { return }
    ctx.saveGState()
    ctx.setAlpha(alpha)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: 10, cornerHeight: 10, transform: nil)); ctx.clip()
    ctx.interpolationQuality = .high
    ctx.draw(img, in: r)
    ctx.restoreGState()
    if let border { rrect(ctx, r.insetBy(dx: -3, dy: -3), 12, stroke: border.cgColor, lw: 4) }
    if let tag {
        let tr = CGRect(x: r.minX + 8, y: r.maxY - 38, width: 92, height: 30)
        rrect(ctx, tr, 8, fill: accent.cgColor)
        text(ctx, tag, size: 18, weight: .bold, color: .black, x: tr.minX + 12, y: tr.minY + 5)
    }
    ctx.restoreGState()
}

func stepTitle(_ ctx: CGContext, _ n: String, _ title: String, _ sub: String, t: Double) {
    let a = CGFloat(ease(t / 0.5))
    text(ctx, "原理 \(n)", size: 30, weight: .semibold, color: accent, y: 930, alpha: a)
    text(ctx, title, size: 58, weight: .bold, y: 850, alpha: a)
    text(ctx, sub, size: 30, color: dim, y: 160, alpha: CGFloat(ease((t - 0.6) / 0.6)))
}

/// 对比：m = 60 帧时间轴上的位置。左边永远显示真实帧（每帧停两拍），右边奇数位是补出来的帧
func panel(_ ctx: CGContext, _ img: CGImage, x: CGFloat, label: String, sub: String, highlight: Bool) {
    let pw: CGFloat = 900, ph: CGFloat = 506, y: CGFloat = 230
    let r = CGRect(x: x, y: y, width: pw, height: ph)
    thumb(ctx, img, r, border: highlight ? accent : nil)
    text(ctx, label, size: 40, weight: .semibold, color: highlight ? accent : .white, x: x, y: y + ph + 56)
    text(ctx, sub, size: 24, color: dim, x: x, y: y + ph + 18)
}

// MARK: - 各段

struct Section { let dur: Double; let draw: (CGContext, Double, Int) -> Void } // (ctx, 段内秒数, 段内帧号)

let K0 = 120 // 原理演示用的画面从第几帧开始
let tw: CGFloat = 256, th: CGFloat = 144

let sections: [Section] = [
    // 1. 软件是做什么的
    Section(dur: 4.5) { ctx, t, _ in
        let a = CGFloat(ease(t / 0.8))
        text(ctx, "FrameInterp", size: 120, weight: .bold, y: 600 + CGFloat(1 - a) * 30, alpha: a)
        text(ctx, "把主机 30 帧的游戏画面，实时补到 60 帧", size: 52, weight: .semibold, color: accent, y: 500, alpha: CGFloat(ease((t - 0.5) / 0.8)))
        text(ctx, "PS5 / Xbox  →  采集卡  →  Mac，插上就能玩，画面更顺", size: 34, color: dim, y: 420, alpha: CGFloat(ease((t - 1.0) / 0.8)))
    },
    // 2. 能运行的机型 / 条件
    Section(dur: 6.0) { ctx, t, _ in
        text(ctx, "能用的设备", size: 64, weight: .bold, y: 860, alpha: CGFloat(ease(t / 0.5)))
        let rows: [(String, String)] = [
            ("Apple 芯片的 Mac", "M1 及以后的芯片；不支持 Intel Mac"),
            ("macOS 26 或更新", "用到系统内置的 Apple 低延迟补帧"),
            ("一张 USB 采集卡", "常见品牌都能自动识别，建议插 USB 3 接口"),
            ("HDMI 输出的游戏主机", "PS5 / Xbox 等；PS5 需在设置里关闭 HDCP"),
        ]
        for (i, r) in rows.enumerated() {
            let a = ease((t - 0.4 - Double(i) * 0.35) / 0.5)
            guard a > 0 else { continue }
            let y = 670 - CGFloat(i) * 135
            let box = CGRect(x: 360 + CGFloat(1 - a) * 40, y: y, width: 1200, height: 110)
            ctx.saveGState(); ctx.setAlpha(CGFloat(a))
            rrect(ctx, box, 18, fill: card, stroke: line, lw: 1.5)
            // 勾
            ctx.setStrokeColor(accent.cgColor); ctx.setLineWidth(7); ctx.setLineCap(.round); ctx.setLineJoin(.round)
            ctx.move(to: CGPoint(x: box.minX + 42, y: box.midY + 2)); ctx.addLine(to: CGPoint(x: box.minX + 58, y: box.midY - 14))
            ctx.addLine(to: CGPoint(x: box.minX + 86, y: box.midY + 18)); ctx.strokePath()
            text(ctx, r.0, size: 40, weight: .semibold, x: box.minX + 120, y: box.minY + 52)
            text(ctx, r.1, size: 26, color: dim, x: box.minX + 120, y: box.minY + 16)
            ctx.restoreGState()
        }
    },
    // 3. 体积小、占用小
    Section(dur: 5.5) { ctx, t, _ in
        text(ctx, "小，而且轻", size: 64, weight: .bold, y: 860, alpha: CGFloat(ease(t / 0.5)))
        let items: [(String, String, String)] = [
            ("1.2 MB", "安装包大小", "比一张手机照片还小"),
            ("≈ 1/3 核", "CPU 占用", "M2 一共 8 核，补帧开着也一样"),
            ("≈ 270 MB", "内存占用", "8GB 内存的 Mac 也够用"),
        ]
        for (i, it) in items.enumerated() {
            let a = CGFloat(ease((t - 0.4 - Double(i) * 0.3) / 0.6))
            let cx = 360 + CGFloat(i) * 600
            let box = CGRect(x: cx - 260, y: 330, width: 520, height: 380)
            ctx.saveGState(); ctx.setAlpha(a)
            rrect(ctx, box, 24, fill: card, stroke: line, lw: 1.5)
            let f = NSAttributedString(string: it.0, attributes: [.font: NSFont.systemFont(ofSize: 92, weight: .bold)]).size().width
            text(ctx, it.0, size: 92, weight: .bold, color: accent, x: cx - f / 2, y: 540)
            let f2 = NSAttributedString(string: it.1, attributes: [.font: NSFont.systemFont(ofSize: 38, weight: .semibold)]).size().width
            text(ctx, it.1, size: 38, weight: .semibold, x: cx - f2 / 2, y: 460)
            let f3 = NSAttributedString(string: it.2, attributes: [.font: NSFont.systemFont(ofSize: 26)]).size().width
            text(ctx, it.2, size: 26, color: dim, x: cx - f3 / 2, y: 390)
            ctx.restoreGState()
        }
        text(ctx, "补帧由系统内置模型完成，几乎不占显卡（M2 MacBook Air 实测）", size: 30, color: dim, y: 200, alpha: CGFloat(ease((t - 1.4) / 0.6)))
    },
    // 4. 原理 ①：去掉重复帧
    Section(dur: 5.0) { ctx, t, _ in
        stepTitle(ctx, "①", "先找出真正的新画面", "采集卡每秒送来 60 帧，30 帧的游戏里每张画面重复了两次；程序逐帧比较，把重复的拿掉", t: t)
        text(ctx, "采集卡送来的 60 帧（每张画面出现两次）", size: 30, weight: .semibold, y: 680,
             alpha: CGFloat(ease((t - 0.3) / 0.4) * (1 - ease((t - 2.0) / 0.4))))
        let imgs = [real(K0), real(K0 + 1), real(K0 + 2)]
        let gap: CGFloat = 26
        let x6 = (CGFloat(W) - (6 * tw + 5 * gap)) / 2
        let x3gap: CGFloat = 120
        let x3 = (CGFloat(W) - (3 * tw + 2 * x3gap)) / 2
        let move = ease((t - 2.4) / 0.9)
        for i in 0..<6 {
            let dup = i % 2 == 1
            let r6 = CGRect(x: x6 + CGFloat(i) * (tw + gap), y: 470, width: tw, height: th)
            let appear = CGFloat(ease((t - 0.3 - Double(i) * 0.1) / 0.4))
            if dup {
                let fadeOut = CGFloat(1 - ease((t - 2.0) / 0.5))
                thumb(ctx, imgs[i / 2], r6, alpha: appear * fadeOut)
                let xa = CGFloat(ease((t - 1.3) / 0.4)) * fadeOut * appear
                if xa > 0 {
                    rrect(ctx, r6, 10, fill: CGColor(red: 0, green: 0, blue: 0, alpha: 0.45 * xa))
                    text(ctx, "重复", size: 30, weight: .bold, color: NSColor.systemRed, x: r6.midX - 30, y: r6.midY - 18, alpha: xa)
                }
            } else {
                let r3 = CGRect(x: x3 + CGFloat(i / 2) * (tw + x3gap), y: 470, width: tw, height: th)
                let r = CGRect(x: lerp(r6.minX, r3.minX, move), y: r6.minY, width: tw, height: th)
                thumb(ctx, imgs[i / 2], r, alpha: appear)
            }
        }
        if move > 0.5 { text(ctx, "真正的新画面：每秒 30 张", size: 30, weight: .semibold, color: .white, y: 380, alpha: CGFloat(ease((t - 3.2) / 0.5))) }
    },
    // 5. 原理 ②：两帧之间补一帧
    Section(dur: 5.0) { ctx, t, _ in
        stepTitle(ctx, "②", "两张画面之间，补出一张", "用 Apple 低延迟补帧模型（macOS 内置）根据前后两张画面的运动，算出中间那一刻", t: t)
        let gap: CGFloat = 40
        let x0 = (CGFloat(W) - (5 * tw + 4 * gap)) / 2
        for i in 0..<5 {
            let r = CGRect(x: x0 + CGFloat(i) * (tw + gap), y: 470, width: tw, height: th)
            if i % 2 == 0 {
                thumb(ctx, real(K0 + i / 2), r)
            } else {
                let a = ease((t - 0.9 - Double(i / 2) * 0.5) / 0.5)
                let s = CGFloat(0.85 + 0.15 * a)
                let rr = CGRect(x: r.midX - tw * s / 2, y: r.midY - th * s / 2, width: tw * s, height: th * s)
                if a < 0.05 { rrect(ctx, r, 10, stroke: CGColor(red: 1, green: 1, blue: 1, alpha: 0.25), lw: 2) }
                thumb(ctx, mid(K0 + i / 2), rr, alpha: CGFloat(a), border: accent, tag: "补出")
            }
        }
        text(ctx, "真实", size: 26, color: dim, x: x0 + tw / 2 - 26, y: 420)
        text(ctx, "真实", size: 26, color: dim, x: x0 + 2 * (tw + gap) + tw / 2 - 26, y: 420)
        text(ctx, "真实", size: 26, color: dim, x: x0 + 4 * (tw + gap) + tw / 2 - 26, y: 420)
        text(ctx, "M2 上补一张 1080p 约 18 ms", size: 30, weight: .semibold, y: 340, alpha: CGFloat(ease((t - 2.2) / 0.5)))
    },
    // 6. 原理 ③：算完立刻上屏，均匀 60 帧
    Section(dur: 5.5) { ctx, t, j in
        stepTitle(ctx, "③", "算完马上显示，节奏均匀", "补出的画面一算完就送上屏幕，真实画面在下一次刷新显示；每 16.7 ms 一张，正好 60 帧", t: t)
        let gap: CGFloat = 40
        let x0 = (CGFloat(W) - (5 * tw + 4 * gap)) / 2
        // 时间轴
        let axisY: CGFloat = 420
        ctx.setStrokeColor(line); ctx.setLineWidth(2)
        ctx.move(to: CGPoint(x: x0 - 20, y: axisY)); ctx.addLine(to: CGPoint(x: x0 + 5 * tw + 4 * gap + 20, y: axisY)); ctx.strokePath()
        let play = ease((t - 0.6) / 3.6) * 5
        for i in 0..<5 {
            let r = CGRect(x: x0 + CGFloat(i) * (tw + gap), y: 470, width: tw, height: th)
            let on = play >= Double(i)
            let img = i % 2 == 0 ? real(K0 + i / 2) : mid(K0 + i / 2)
            thumb(ctx, img, r, alpha: on ? 1 : 0.35, border: (i % 2 == 1) ? accent : nil)
            ctx.setFillColor(on ? accent.cgColor : line)
            ctx.fillEllipse(in: CGRect(x: r.midX - 9, y: axisY - 9, width: 18, height: 18))
            if i < 4 { text(ctx, "16.7 ms", size: 22, color: dim, x: r.maxX + gap / 2 - 38, y: axisY - 40) }
        }
        text(ctx, "开补帧额外延迟约 30–40 ms；不需要时一键关掉，回到直通", size: 30, weight: .semibold, y: 300, alpha: CGFloat(ease((t - 3.4) / 0.6)))
    },
    // 7. 效果：正常速度对比
    Section(dur: 7.0) { ctx, t, j in
        text(ctx, "效果", size: 50, weight: .bold, y: 900)
        let k = 300 + j / 2
        panel(ctx, real(k), x: 40, label: "原始 30 帧", sub: "采集卡收到的画面", highlight: false)
        panel(ctx, j % 2 == 1 ? mid(k) : real(k), x: 980, label: "FrameInterp 60 帧", sub: "右边的中间帧由 Apple 补帧模型实时算出", highlight: true)
    },
    // 8. 结尾
    Section(dur: 3.5) { ctx, t, _ in
        let a = CGFloat(ease(t / 0.8))
        text(ctx, "FrameInterp", size: 110, weight: .bold, y: 560, alpha: a)
        text(ctx, "1.2 MB · Apple 芯片 Mac · macOS 26+", size: 40, color: accent, y: 470, alpha: a)
        text(ctx, "演示画面为程序绘制的示例场景；数据为 M2 MacBook Air 实测", size: 24, color: dim, y: 120, alpha: a)
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
