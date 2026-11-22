// 宣传图第二版：4:3 和 16:9 两张，GTA 风格的原创画面（霓虹日落、棕榈、跑车、小地图雷达），全部用代码画。
// 不使用任何游戏官方的图、logo、字体；GTA / PS5 / Xbox 只以文字出现。
// 用法：swiftc -O tools/make-poster2.swift -o .build/make-poster2 && .build/make-poster2 dist
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a) }
func grad(_ c: [CGColor], _ l: [CGFloat]) -> CGGradient { CGGradient(colorsSpace: cs, colors: c as CFArray, locations: l)! }
let neon = NSColor(red: 0.30, green: 0.95, blue: 0.62, alpha: 1)
let pink = NSColor(red: 1.0, green: 0.36, blue: 0.62, alpha: 1)
var rng: UInt64 = 7
func rnd() -> CGFloat { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(rng >> 33) / CGFloat(1 << 31) }

final class Canvas {
    let W: CGFloat, H: CGFloat, S: CGFloat
    let ctx: CGContext
    init(_ w: CGFloat, _ h: CGFloat, scale: CGFloat = 2) {
        W = w; H = h; S = scale
        ctx = CGContext(data: nil, width: Int(w * scale), height: Int(h * scale), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: scale, y: scale)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    }
    @discardableResult
    func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight = .regular, _ color: NSColor = .white,
              x: CGFloat? = nil, y: CGFloat, glow: NSColor? = nil, align: Int = 0) -> CGSize {
        var attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
        if let glow { let sh = NSShadow(); sh.shadowColor = glow; sh.shadowBlurRadius = size * 0.35; sh.shadowOffset = .zero; attrs[.shadow] = sh }
        let a = NSAttributedString(string: s, attributes: attrs)
        let sz = a.size()
        var px = x ?? (W - sz.width) / 2
        if align == 1, let x { px = x - sz.width / 2 }
        a.draw(at: NSPoint(x: px, y: y))
        return sz
    }
    func width(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight) -> CGFloat {
        NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).size().width
    }
    func rrect(_ r: CGRect, _ rad: CGFloat, fill: CGColor? = nil, stroke: CGColor? = nil, lw: CGFloat = 2) {
        let p = CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil)
        if let fill { ctx.setFillColor(fill); ctx.addPath(p); ctx.fillPath() }
        if let stroke { ctx.setStrokeColor(stroke); ctx.setLineWidth(lw); ctx.addPath(p); ctx.strokePath() }
    }

    // MARK: 背景元素

    func sky(horizon: CGFloat) {
        ctx.drawLinearGradient(grad([rgb(255, 150, 90), rgb(240, 70, 120), rgb(110, 40, 140), rgb(22, 14, 48)], [0, 0.25, 0.55, 1]),
                               start: CGPoint(x: 0, y: horizon), end: CGPoint(x: 0, y: H), options: [.drawsBeforeStartLocation])
    }
    func sun(center: CGPoint, r: CGFloat, horizon: CGFloat) {
        let rect = CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)
        ctx.saveGState(); ctx.addEllipse(in: rect); ctx.clip()
        ctx.drawLinearGradient(grad([rgb(255, 90, 140), rgb(255, 200, 90)], [0, 1]), start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: [])
        var stripes: [CGRect] = []
        var sy = rect.minY + r * 0.07, gap = r * 0.11
        while sy < rect.midY + r * 0.1 { stripes.append(CGRect(x: rect.minX, y: sy, width: rect.width, height: gap * 0.42)); sy += gap; gap *= 0.9 }
        ctx.clip(to: stripes); sky(horizon: horizon)
        ctx.restoreGState()
    }
    func city(horizon: CGFloat, maxH: CGFloat, from: CGFloat = -10, to: CGFloat? = nil) {
        var bx = from; let end = to ?? W
        while bx < end {
            let bw = 36 + rnd() * 60, bh = maxH * (0.25 + rnd() * 0.75)
            ctx.setFillColor(rgb(40, 18, 70)); ctx.fill(CGRect(x: bx, y: horizon, width: bw, height: bh))
            ctx.setFillColor(rgb(255, 210, 140, 0.55))
            var wy = horizon + 12
            while wy < horizon + bh - 12 {
                var wx = bx + 7
                while wx < bx + bw - 9 { if rnd() > 0.55 { ctx.fill(CGRect(x: wx, y: wy, width: 4, height: 6)) }; wx += 11 }
                wy += 14
            }
            bx += bw + 3
        }
    }
    func ground(horizon: CGFloat) {
        ctx.drawLinearGradient(grad([rgb(18, 8, 38), rgb(48, 16, 72)], [0, 1]), start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: horizon), options: [])
        ctx.setStrokeColor(pink.withAlphaComponent(0.5).cgColor); ctx.setLineWidth(1.4)
        let vp = CGPoint(x: W / 2, y: horizon)
        for i in -16...16 { ctx.move(to: vp); ctx.addLine(to: CGPoint(x: W / 2 + CGFloat(i) * (W / 9), y: 0)) }
        var gy = horizon - 5, step: CGFloat = 6
        while gy > 0 { ctx.move(to: CGPoint(x: 0, y: gy)); ctx.addLine(to: CGPoint(x: W, y: gy)); step *= 1.28; gy -= step }
        ctx.strokePath()
    }
    func palm(_ x: CGFloat, _ base: CGFloat, _ h: CGFloat, _ lean: CGFloat) {
        ctx.setFillColor(rgb(16, 6, 30))
        let top = CGPoint(x: x + lean, y: base + h)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: x - h * 0.014, y: base)); ctx.addQuadCurve(to: CGPoint(x: top.x - h * 0.006, y: top.y), control: CGPoint(x: x + lean * 0.2 - h * 0.01, y: base + h * 0.6))
        ctx.addLine(to: CGPoint(x: top.x + h * 0.006, y: top.y)); ctx.addQuadCurve(to: CGPoint(x: x + h * 0.014, y: base), control: CGPoint(x: x + lean * 0.2 + h * 0.01, y: base + h * 0.6))
        ctx.closePath(); ctx.fillPath()
        for k in 0..<7 {
            let a = CGFloat(k) / 6 * .pi * 1.15 - 0.08, len = h * 0.42
            let end = CGPoint(x: top.x + cos(a) * len, y: top.y + sin(a) * len * 0.55 - len * 0.18)
            let mid = CGPoint(x: top.x + cos(a) * len * 0.5, y: top.y + sin(a) * len * 0.5 + h * 0.028)
            ctx.beginPath(); ctx.move(to: top)
            ctx.addQuadCurve(to: end, control: CGPoint(x: mid.x, y: mid.y + h * 0.02))
            ctx.addQuadCurve(to: top, control: CGPoint(x: mid.x, y: mid.y - h * 0.006))
            ctx.fillPath()
        }
    }

    // MARK: 跑车（侧视，敞篷，原创造型）

    func car(origin: CGPoint, scale s: CGFloat, color: CGColor = rgb(255, 60, 120)) {
        ctx.saveGState(); ctx.translateBy(x: origin.x, y: origin.y); ctx.scaleBy(x: s, y: s)
        // 影子
        ctx.setFillColor(rgb(0, 0, 0, 0.45)); ctx.fillEllipse(in: CGRect(x: 10, y: -14, width: 560, height: 30))
        // 车身
        ctx.setFillColor(color)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: 10, y: 48)); ctx.addCurve(to: CGPoint(x: 80, y: 78), control1: CGPoint(x: 10, y: 66), control2: CGPoint(x: 40, y: 74))
        ctx.addLine(to: CGPoint(x: 205, y: 82)); ctx.addCurve(to: CGPoint(x: 290, y: 128), control1: CGPoint(x: 232, y: 84), control2: CGPoint(x: 262, y: 118))
        ctx.addCurve(to: CGPoint(x: 360, y: 124), control1: CGPoint(x: 310, y: 134), control2: CGPoint(x: 340, y: 132))
        ctx.addCurve(to: CGPoint(x: 430, y: 84), control1: CGPoint(x: 385, y: 112), control2: CGPoint(x: 405, y: 90))
        ctx.addLine(to: CGPoint(x: 540, y: 74)); ctx.addCurve(to: CGPoint(x: 572, y: 44), control1: CGPoint(x: 560, y: 72), control2: CGPoint(x: 572, y: 62))
        ctx.addLine(to: CGPoint(x: 570, y: 28)); ctx.addLine(to: CGPoint(x: 14, y: 26)); ctx.closePath(); ctx.fillPath()
        // 挡风玻璃 + 车内
        ctx.setFillColor(rgb(255, 210, 240, 0.85))
        ctx.beginPath(); ctx.move(to: CGPoint(x: 222, y: 88)); ctx.addLine(to: CGPoint(x: 286, y: 122)); ctx.addLine(to: CGPoint(x: 300, y: 90)); ctx.closePath(); ctx.fillPath()
        ctx.setFillColor(rgb(30, 10, 50)); ctx.fill(CGRect(x: 300, y: 82, width: 120, height: 36))
        // 高光线
        ctx.setStrokeColor(rgb(255, 255, 255, 0.55)); ctx.setLineWidth(3)
        ctx.move(to: CGPoint(x: 40, y: 60)); ctx.addLine(to: CGPoint(x: 200, y: 66)); ctx.strokePath()
        // 头灯 / 尾灯
        ctx.setShadow(offset: .zero, blur: 26, color: rgb(255, 240, 180))
        ctx.setFillColor(rgb(255, 245, 200)); ctx.fill(CGRect(x: 545, y: 46, width: 26, height: 12))
        ctx.setShadow(offset: .zero, blur: 20, color: rgb(255, 40, 60))
        ctx.setFillColor(rgb(255, 60, 70)); ctx.fill(CGRect(x: 8, y: 46, width: 20, height: 9))
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        // 车轮
        for wx in [120.0, 470.0] as [CGFloat] {
            ctx.setFillColor(rgb(14, 8, 24)); ctx.fillEllipse(in: CGRect(x: wx - 46, y: -2, width: 92, height: 92))
            ctx.setFillColor(rgb(200, 200, 215)); ctx.fillEllipse(in: CGRect(x: wx - 26, y: 18, width: 52, height: 52))
            ctx.setFillColor(rgb(14, 8, 24)); ctx.fillEllipse(in: CGRect(x: wx - 8, y: 36, width: 16, height: 16))
        }
        ctx.restoreGState()
    }

    // MARK: 小地图雷达（GTA 式的圆形小地图，原创画法）

    func radar(center: CGPoint, r: CGFloat) {
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)); ctx.clip()
        ctx.setFillColor(rgb(20, 14, 40, 0.88)); ctx.fill(CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
        ctx.setStrokeColor(rgb(255, 255, 255, 0.28)); ctx.setLineWidth(r * 0.05)
        for i in -3...3 { let o = CGFloat(i) * r * 0.5
            ctx.move(to: CGPoint(x: center.x - r, y: center.y + o + 0.3 * r)); ctx.addLine(to: CGPoint(x: center.x + r, y: center.y + o - 0.2 * r)) }
        for i in -3...3 { let o = CGFloat(i) * r * 0.5
            ctx.move(to: CGPoint(x: center.x + o, y: center.y - r)); ctx.addLine(to: CGPoint(x: center.x + o + 0.15 * r, y: center.y + r)) }
        ctx.strokePath()
        ctx.setStrokeColor(pink.cgColor); ctx.setLineWidth(r * 0.09)
        ctx.move(to: CGPoint(x: center.x - r, y: center.y - 0.2 * r)); ctx.addCurve(to: CGPoint(x: center.x + 0.1 * r, y: center.y + 0.1 * r), control1: CGPoint(x: center.x - 0.4 * r, y: center.y - 0.3 * r), control2: CGPoint(x: center.x - 0.2 * r, y: center.y + 0.3 * r))
        ctx.addLine(to: CGPoint(x: center.x + 0.55 * r, y: center.y + r)); ctx.strokePath()
        ctx.restoreGState()
        // 自己：小三角
        ctx.setFillColor(neon.cgColor); ctx.beginPath()
        ctx.move(to: CGPoint(x: center.x, y: center.y + r * 0.16)); ctx.addLine(to: CGPoint(x: center.x - r * 0.11, y: center.y - r * 0.1)); ctx.addLine(to: CGPoint(x: center.x + r * 0.11, y: center.y - r * 0.1)); ctx.closePath(); ctx.fillPath()
        ctx.setStrokeColor(rgb(255, 255, 255, 0.9)); ctx.setLineWidth(r * 0.06)
        ctx.strokeEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
    }

    // MARK: 屏幕里放着补帧画面的 Mac（设计尺寸 740×462，用 scale 缩放）

    func mac(origin: CGPoint, scale s: CGFloat) {
        ctx.saveGState(); ctx.translateBy(x: origin.x, y: origin.y); ctx.scaleBy(x: s, y: s)
        let lap = CGRect(x: 0, y: 0, width: 740, height: 462)
        ctx.setShadow(offset: CGSize(width: 0, height: -20), blur: 60, color: rgb(0, 0, 0, 0.6))
        rrect(lap, 26, fill: rgb(24, 24, 28)); ctx.setShadow(offset: .zero, blur: 0, color: nil)
        let scr = lap.insetBy(dx: 18, dy: 18)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: scr, cornerWidth: 10, cornerHeight: 10, transform: nil)); ctx.clip()
        ctx.drawLinearGradient(grad([rgb(255, 120, 110), rgb(120, 50, 160), rgb(30, 20, 70)], [0, 0.4, 1]),
                               start: CGPoint(x: 0, y: scr.minY + scr.height * 0.45), end: CGPoint(x: 0, y: scr.maxY), options: [.drawsBeforeStartLocation])
        ctx.setFillColor(rgb(255, 210, 120)); ctx.fillEllipse(in: CGRect(x: scr.midX - 70, y: scr.minY + scr.height * 0.42, width: 140, height: 140))
        ctx.setFillColor(rgb(50, 20, 80))
        var sx = scr.minX
        while sx < scr.maxX { let bw = 24 + rnd() * 40, bh = 30 + rnd() * 110; ctx.fill(CGRect(x: sx, y: scr.minY + scr.height * 0.45, width: bw, height: bh)); sx += bw + 3 }
        ctx.setFillColor(rgb(28, 22, 40)); ctx.fill(CGRect(x: scr.minX, y: scr.minY, width: scr.width, height: scr.height * 0.45))
        ctx.setFillColor(rgb(45, 40, 58))
        ctx.beginPath(); ctx.move(to: CGPoint(x: scr.midX - 30, y: scr.minY + scr.height * 0.45)); ctx.addLine(to: CGPoint(x: scr.midX + 30, y: scr.minY + scr.height * 0.45))
        ctx.addLine(to: CGPoint(x: scr.maxX - 40, y: scr.minY)); ctx.addLine(to: CGPoint(x: scr.minX + 40, y: scr.minY)); ctx.closePath(); ctx.fillPath()
        ctx.setFillColor(rgb(255, 220, 110))
        for i in 0..<6 {
            let t0 = CGFloat(i) / 6, t1 = t0 + 0.07
            func p(_ t: CGFloat) -> CGFloat { scr.minY + scr.height * 0.45 * (1 - t) }
            func hw(_ t: CGFloat) -> CGFloat { 3 + t * 9 }
            ctx.beginPath(); ctx.move(to: CGPoint(x: scr.midX - hw(t0), y: p(t0))); ctx.addLine(to: CGPoint(x: scr.midX + hw(t0), y: p(t0)))
            ctx.addLine(to: CGPoint(x: scr.midX + hw(t1), y: p(t1))); ctx.addLine(to: CGPoint(x: scr.midX - hw(t1), y: p(t1))); ctx.closePath(); ctx.fillPath()
        }
        let c = CGRect(x: scr.midX - 85, y: scr.minY + 34, width: 170, height: 62)
        rrect(c, 18, fill: rgb(250, 250, 255))
        rrect(CGRect(x: c.minX + 30, y: c.maxY - 8, width: 110, height: 38), 12, fill: rgb(40, 40, 60))
        for lx in [c.minX + 12, c.maxX - 42] {
            ctx.setShadow(offset: .zero, blur: 18, color: rgb(255, 40, 60)); ctx.setFillColor(rgb(255, 50, 70)); ctx.fill(CGRect(x: lx, y: c.minY + 34, width: 30, height: 9))
        }
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        let pill = CGRect(x: scr.minX + 16, y: scr.maxY - 52, width: 196, height: 36)
        rrect(pill, 11, fill: rgb(40, 40, 46, 0.78), stroke: rgb(255, 255, 255, 0.2), lw: 1)
        text("60 FPS   延迟 42 ms", 17, .semibold, .white, x: pill.minX + 16, y: pill.minY + 8)
        ctx.restoreGState()
        ctx.setFillColor(rgb(190, 192, 200))
        ctx.beginPath(); ctx.move(to: CGPoint(x: -70, y: -4)); ctx.addLine(to: CGPoint(x: 810, y: -4)); ctx.addLine(to: CGPoint(x: 790, y: -30)); ctx.addLine(to: CGPoint(x: -50, y: -30)); ctx.closePath(); ctx.fillPath()
        ctx.restoreGState()
    }

    func chips(_ items: [String], centerX: CGFloat, y: CGFloat, size: CGFloat) {
        let widths = items.map { width($0, size, .semibold) + size * 1.6 }
        var cx = centerX - (widths.reduce(0, +) + CGFloat(items.count - 1) * size * 0.65) / 2
        for (c, w) in zip(items, widths) {
            let r = CGRect(x: cx, y: y, width: w, height: size * 2.05)
            rrect(r, r.height / 2, fill: rgb(255, 255, 255, 0.12), stroke: rgb(255, 255, 255, 0.35), lw: 1.5)
            text(c, size, .semibold, .white, x: r.minX + size * 0.8, y: r.minY + size * 0.45)
            cx += w + size * 0.65
        }
    }

    func disclaimer(size: CGFloat, y: CGFloat) {
        text("GTA 是 Rockstar Games 的商标；PlayStation、PS5 属于 Sony，Xbox 属于 Microsoft。FrameInterp 是独立软件，与以上公司无关。", size, .regular, NSColor(white: 1, alpha: 0.5), y: y + size * 1.5)
        text("PS5 需在系统设置中关闭 HDCP 才能被采集卡读取。补帧效果和延迟以实际游戏与设备为准。", size, .regular, NSColor(white: 1, alpha: 0.5), y: y)
    }

    func save(_ name: String) {
        let img = ctx.makeImage()!
        let path = "\(outDir)/\(name)"
        try! NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
        print("已生成 \(path)（\(img.width)×\(img.height)）")
    }
}

// MARK: - 4:3（1200×900 @2x = 2400×1800）

do {
    rng = 7
    let c = Canvas(1200, 900)
    let hz: CGFloat = 330
    c.sky(horizon: hz)
    c.sun(center: CGPoint(x: 600, y: 520), r: 210, horizon: hz)
    c.city(horizon: hz, maxH: 190)
    c.ground(horizon: hz)
    c.palm(80, 0, 560, 50); c.palm(180, 0, 400, 25); c.palm(1130, 0, 580, -55); c.palm(1030, 0, 390, -20)
    c.car(origin: CGPoint(x: 30, y: 176), scale: 0.6)
    // 标题
    c.text("在 Mac 上", 46, .bold, .white, y: 810, glow: pink.withAlphaComponent(0.8))
    c.text("补帧畅玩 GTA 6", 92, .heavy, .white, y: 714, glow: pink)
    c.text("PS5 / Xbox  30 帧  →  实时补到  60 帧", 34, .semibold, neon, y: 656, glow: NSColor(red: 0.1, green: 0.02, blue: 0.2, alpha: 0.9))
    // Mac
    c.mac(origin: CGPoint(x: 390, y: 295), scale: 0.62)
    // 小地图雷达
    c.radar(center: CGPoint(x: 150, y: 330 + 70), r: 80)
    c.text("雷达", 16, .semibold, NSColor(white: 1, alpha: 0.75), x: 150, y: 492, align: 1)
    // 底部
    c.ctx.drawLinearGradient(grad([rgb(10, 4, 22, 0.92), rgb(10, 4, 22, 0)], [0, 1]), start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 150), options: [])
    c.chips(["Apple 低延迟补帧", "插上采集卡就能用", "声音直通"], centerX: 600, y: 118, size: 22)
    c.text("FrameInterp  ·  Apple 芯片 Mac · macOS 26 或更新", 26, .bold, .white, y: 70)
    c.disclaimer(size: 12, y: 18)
    c.save("FrameInterp-宣传图-4比3.png")
}

// MARK: - 16:9（1280×720 @2x = 2560×1440）

do {
    rng = 11
    let c = Canvas(1280, 720)
    let hz: CGFloat = 250
    c.sky(horizon: hz)
    c.sun(center: CGPoint(x: 930, y: 400), r: 190, horizon: hz)
    c.city(horizon: hz, maxH: 170)
    c.ground(horizon: hz)
    c.palm(1235, 0, 560, -60); c.palm(1130, 0, 360, -25); c.palm(40, 0, 430, 40)
    // 左边文字
    c.ctx.drawLinearGradient(grad([rgb(14, 6, 30, 0.82), rgb(14, 6, 30, 0)], [0, 1]), start: CGPoint(x: 0, y: 0), end: CGPoint(x: 700, y: 0), options: [])
    c.text("在 Mac 上", 40, .bold, .white, x: 70, y: 580, glow: pink.withAlphaComponent(0.8))
    c.text("补帧畅玩", 92, .heavy, .white, x: 70, y: 478, glow: pink)
    c.text("GTA 6", 130, .heavy, NSColor(red: 1, green: 0.85, blue: 0.4, alpha: 1), x: 70, y: 346, glow: pink)
    c.text("PS5 / Xbox  30 帧 → 实时补到 60 帧", 30, .semibold, neon, x: 70, y: 290, glow: NSColor(red: 0.1, green: 0.02, blue: 0.2, alpha: 0.9))
    c.chips(["Apple 低延迟补帧", "插上采集卡就能用", "声音直通"], centerX: 330, y: 214, size: 20)
    c.text("FrameInterp", 46, .bold, .white, x: 70, y: 130)
    c.text("Apple 芯片 Mac · macOS 26 或更新", 22, .medium, NSColor(white: 1, alpha: 0.78), x: 70, y: 96)
    // 右边：Mac + 跑车 + 雷达
    c.mac(origin: CGPoint(x: 640, y: 310), scale: 0.74)
    c.car(origin: CGPoint(x: 650, y: 82), scale: 0.6, color: rgb(255, 60, 120))
    c.radar(center: CGPoint(x: 1160, y: 190), r: 62)
    // 底部小字
    c.text("GTA 是 Rockstar Games 的商标；PlayStation、PS5 属于 Sony，Xbox 属于 Microsoft。FrameInterp 是独立软件，与以上公司无关。", 12, .regular, NSColor(white: 1, alpha: 0.5), x: 70, y: 40)
    c.text("PS5 需在系统设置中关闭 HDCP 才能被采集卡读取。补帧效果和延迟以实际游戏与设备为准。", 12, .regular, NSColor(white: 1, alpha: 0.5), x: 70, y: 20)
    c.save("FrameInterp-宣传图-16比9.png")
}
