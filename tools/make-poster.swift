// 宣传图（3:4 竖图，1080×1440 的 2 倍）。全部用代码画，不用任何游戏 / 主机厂商的图标、字体和美术。
// 用法：swiftc -O tools/make-poster.swift -o .build/make-poster && .build/make-poster dist/FrameInterp-宣传图.png
import AppKit

let S: CGFloat = 2
let W: CGFloat = 1080, H: CGFloat = 1440
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "poster.png"
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(W * S), height: Int(H * S), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.scaleBy(x: S, y: S)
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a) }
func grad(_ colors: [CGColor], _ locs: [CGFloat]) -> CGGradient { CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: locs)! }
let neon = NSColor(red: 0.30, green: 0.95, blue: 0.62, alpha: 1)
let pink = NSColor(red: 1.0, green: 0.36, blue: 0.62, alpha: 1)

@discardableResult
func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight = .regular, _ color: NSColor = .white,
          x: CGFloat? = nil, y: CGFloat, glow: NSColor? = nil, kern: CGFloat = 0) -> CGSize {
    var attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .kern: kern]
    if let glow {
        let sh = NSShadow(); sh.shadowColor = glow; sh.shadowBlurRadius = size * 0.35; sh.shadowOffset = .zero
        attrs[.shadow] = sh
    }
    let a = NSAttributedString(string: s, attributes: attrs)
    let sz = a.size()
    a.draw(at: NSPoint(x: x ?? (W - sz.width) / 2, y: y))
    return sz
}

// MARK: 背景：霓虹日落

func drawSky() {
    ctx.drawLinearGradient(grad([rgb(255, 150, 90), rgb(240, 70, 120), rgb(110, 40, 140), rgb(22, 14, 48)], [0, 0.25, 0.55, 1]),
                           start: CGPoint(x: 0, y: H * 0.42), end: CGPoint(x: 0, y: H), options: [.drawsBeforeStartLocation])
}
drawSky()
// 太阳（横条纹）
let sun = CGRect(x: W / 2 - 230, y: H * 0.47, width: 460, height: 460)
ctx.saveGState()
ctx.addEllipse(in: sun); ctx.clip()
ctx.drawLinearGradient(grad([rgb(255, 90, 140), rgb(255, 200, 90)], [0, 1]), start: CGPoint(x: 0, y: sun.minY), end: CGPoint(x: 0, y: sun.maxY), options: [])
// 条纹处露出后面的天空
var stripes: [CGRect] = []
var sy = sun.minY + 30, gap: CGFloat = 26
while sy < sun.midY + 40 { stripes.append(CGRect(x: sun.minX, y: sy, width: sun.width, height: gap * 0.42)); sy += gap; gap *= 0.9 }
ctx.clip(to: stripes)
drawSky()
ctx.restoreGState()
// 城市剪影
var rng: UInt64 = 7
func rnd() -> CGFloat { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(rng >> 33) / CGFloat(1 << 31) }
ctx.setFillColor(rgb(40, 18, 70))
var bx: CGFloat = -10
while bx < W {
    let bw = 40 + rnd() * 70, bh = 60 + rnd() * 230
    ctx.fill(CGRect(x: bx, y: H * 0.42, width: bw, height: bh))
    // 窗户
    ctx.setFillColor(rgb(255, 210, 140, 0.55))
    var wy = H * 0.42 + 14
    while wy < H * 0.42 + bh - 14 {
        var wx = bx + 8
        while wx < bx + bw - 10 { if rnd() > 0.55 { ctx.fill(CGRect(x: wx, y: wy, width: 5, height: 7)) }; wx += 12 }
        wy += 16
    }
    ctx.setFillColor(rgb(40, 18, 70))
    bx += bw + 4
}
// 地面 + 透视网格
ctx.drawLinearGradient(grad([rgb(18, 8, 38), rgb(48, 16, 72)], [0, 1]), start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: H * 0.42), options: [])
ctx.setStrokeColor(pink.withAlphaComponent(0.55).cgColor); ctx.setLineWidth(1.5)
let horizon = H * 0.42, vp = CGPoint(x: W / 2, y: horizon)
for i in -14...14 { ctx.move(to: vp); ctx.addLine(to: CGPoint(x: W / 2 + CGFloat(i) * 120, y: 0)) }
var gy = horizon - 6, step: CGFloat = 8
while gy > 0 { ctx.move(to: CGPoint(x: 0, y: gy)); ctx.addLine(to: CGPoint(x: W, y: gy)); step *= 1.28; gy -= step }
ctx.strokePath()
// 棕榈树剪影
func palm(_ x: CGFloat, _ base: CGFloat, _ h: CGFloat, _ lean: CGFloat) {
    ctx.setFillColor(rgb(16, 6, 30))
    let top = CGPoint(x: x + lean, y: base + h)
    ctx.beginPath()
    ctx.move(to: CGPoint(x: x - 9, y: base)); ctx.addQuadCurve(to: CGPoint(x: top.x - 4, y: top.y), control: CGPoint(x: x + lean * 0.2 - 6, y: base + h * 0.6))
    ctx.addLine(to: CGPoint(x: top.x + 4, y: top.y)); ctx.addQuadCurve(to: CGPoint(x: x + 9, y: base), control: CGPoint(x: x + lean * 0.2 + 6, y: base + h * 0.6))
    ctx.closePath(); ctx.fillPath()
    for k in 0..<7 {
        let a = CGFloat(k) / 6 * .pi * 1.15 - 0.08
        let len: CGFloat = h * 0.42
        let end = CGPoint(x: top.x + cos(a) * len, y: top.y + sin(a) * len * 0.55 - len * 0.18)
        let mid = CGPoint(x: top.x + cos(a) * len * 0.5, y: top.y + sin(a) * len * 0.5 + 18)
        ctx.beginPath(); ctx.move(to: top)
        ctx.addQuadCurve(to: end, control: CGPoint(x: mid.x, y: mid.y + 14))
        ctx.addQuadCurve(to: top, control: CGPoint(x: mid.x, y: mid.y - 4))
        ctx.fillPath()
    }
}
palm(70, 0, 640, 60); palm(170, 0, 470, 30); palm(W - 80, 0, 690, -70); palm(W - 190, 0, 430, -20)

// MARK: 中间的 Mac（屏幕里是补帧后的画面 + 帧数浮窗）

let lap = CGRect(x: 170, y: 340, width: 740, height: 462)
// 屏幕外框
ctx.setShadow(offset: CGSize(width: 0, height: -20), blur: 60, color: rgb(0, 0, 0, 0.6))
ctx.setFillColor(rgb(24, 24, 28))
ctx.addPath(CGPath(roundedRect: lap, cornerWidth: 26, cornerHeight: 26, transform: nil)); ctx.fillPath()
ctx.setShadow(offset: .zero, blur: 0, color: nil)
let scr = lap.insetBy(dx: 18, dy: 18)
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: scr, cornerWidth: 10, cornerHeight: 10, transform: nil)); ctx.clip()
// 屏幕里的游戏画面：夜晚公路飞驰（运动线条表示 60 帧的顺滑）
ctx.drawLinearGradient(grad([rgb(255, 120, 110), rgb(120, 50, 160), rgb(30, 20, 70)], [0, 0.4, 1]),
                       start: CGPoint(x: 0, y: scr.minY + scr.height * 0.45), end: CGPoint(x: 0, y: scr.maxY), options: [.drawsBeforeStartLocation])
ctx.setFillColor(rgb(255, 210, 120)); ctx.fillEllipse(in: CGRect(x: scr.midX - 70, y: scr.minY + scr.height * 0.42, width: 140, height: 140))
ctx.setFillColor(rgb(50, 20, 80))
var sx = scr.minX
while sx < scr.maxX { let bw = 24 + rnd() * 40, bh = 30 + rnd() * 110; ctx.fill(CGRect(x: sx, y: scr.minY + scr.height * 0.45, width: bw, height: bh)); sx += bw + 3 }
ctx.setFillColor(rgb(28, 22, 40)); ctx.fill(CGRect(x: scr.minX, y: scr.minY, width: scr.width, height: scr.height * 0.45))
// 透视公路
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
// 跑车（后视）+ 尾灯拖影
let car = CGRect(x: scr.midX - 85, y: scr.minY + 34, width: 170, height: 62)
ctx.setFillColor(rgb(250, 250, 255)); ctx.addPath(CGPath(roundedRect: car, cornerWidth: 18, cornerHeight: 18, transform: nil)); ctx.fillPath()
ctx.setFillColor(rgb(40, 40, 60)); ctx.addPath(CGPath(roundedRect: CGRect(x: car.minX + 30, y: car.maxY - 8, width: 110, height: 38), cornerWidth: 12, cornerHeight: 12, transform: nil)); ctx.fillPath()
for lx in [car.minX + 12, car.maxX - 42] {
    ctx.setShadow(offset: .zero, blur: 18, color: rgb(255, 40, 60))
    ctx.setFillColor(rgb(255, 50, 70)); ctx.fill(CGRect(x: lx, y: car.minY + 34, width: 30, height: 9))
}
ctx.setShadow(offset: .zero, blur: 0, color: nil)
ctx.setStrokeColor(rgb(255, 255, 255, 0.35)); ctx.setLineWidth(2)
for i in 0..<10 {
    let a = CGFloat(i) / 9
    let x0 = scr.minX + 20 + a * (scr.width - 40)
    ctx.move(to: CGPoint(x: x0, y: scr.minY + 10)); ctx.addLine(to: CGPoint(x: scr.midX + (x0 - scr.midX) * 0.55, y: scr.minY + scr.height * 0.25))
}
ctx.strokePath()
// 帧数浮窗（和 App 一样）
let pill = CGRect(x: scr.minX + 16, y: scr.maxY - 52, width: 196, height: 36)
ctx.setFillColor(rgb(40, 40, 46, 0.78)); ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 11, cornerHeight: 11, transform: nil)); ctx.fillPath()
ctx.setStrokeColor(rgb(255, 255, 255, 0.2)); ctx.setLineWidth(1); ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 11, cornerHeight: 11, transform: nil)); ctx.strokePath()
text("60 FPS   延迟 42 ms", 17, .semibold, .white, x: pill.minX + 16, y: pill.minY + 8)
ctx.restoreGState()
// 底座
ctx.setFillColor(rgb(190, 192, 200))
ctx.beginPath(); ctx.move(to: CGPoint(x: lap.minX - 70, y: lap.minY - 4)); ctx.addLine(to: CGPoint(x: lap.maxX + 70, y: lap.minY - 4))
ctx.addLine(to: CGPoint(x: lap.maxX + 50, y: lap.minY - 30)); ctx.addLine(to: CGPoint(x: lap.minX - 50, y: lap.minY - 30)); ctx.closePath(); ctx.fillPath()
ctx.setFillColor(rgb(150, 152, 160)); ctx.fill(CGRect(x: W / 2 - 70, y: lap.minY - 8, width: 140, height: 4))

// MARK: 文字

text("在 Mac 上", 64, .bold, .white, y: 1268, glow: pink.withAlphaComponent(0.8))
text("补帧畅玩 GTA 6", 104, .heavy, .white, y: 1130, glow: pink)
let sub = "PS5 / Xbox  30 帧  →  实时补到  60 帧"
text(sub, 40, .semibold, neon, y: 1050, glow: NSColor(red: 0.1, green: 0.02, blue: 0.2, alpha: 0.9))

// 底部压暗，让小字看得清
ctx.drawLinearGradient(grad([rgb(10, 4, 22, 0.92), rgb(10, 4, 22, 0)], [0, 1]), start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 330), options: [])

// 三个卖点
let chips = ["Apple 低延迟补帧", "插上采集卡就能用", "声音直通"]
let chipFont = NSFont.systemFont(ofSize: 28, weight: .semibold)
let widths = chips.map { NSAttributedString(string: $0, attributes: [.font: chipFont]).size().width + 44 }
var cx = (W - widths.reduce(0, +) - CGFloat(chips.count - 1) * 18) / 2
for (c, w) in zip(chips, widths) {
    let r = CGRect(x: cx, y: 228, width: w, height: 58)
    ctx.setFillColor(rgb(255, 255, 255, 0.12)); ctx.addPath(CGPath(roundedRect: r, cornerWidth: 29, cornerHeight: 29, transform: nil)); ctx.fillPath()
    ctx.setStrokeColor(rgb(255, 255, 255, 0.35)); ctx.setLineWidth(1.5); ctx.addPath(CGPath(roundedRect: r, cornerWidth: 29, cornerHeight: 29, transform: nil)); ctx.strokePath()
    text(c, 28, .semibold, .white, x: r.minX + 22, y: r.minY + 12)
    cx += w + 18
}
text("FrameInterp", 56, .bold, .white, y: 128)
text("Apple 芯片 Mac · macOS 26 或更新", 26, .medium, NSColor(white: 1, alpha: 0.75), y: 88)
text("GTA 是 Rockstar Games 的商标；PlayStation、PS5 属于 Sony，Xbox 属于 Microsoft。FrameInterp 是独立软件，与以上公司无关。", 15, .regular,
     NSColor(white: 1, alpha: 0.5), y: 44)
text("PS5 需在系统设置中关闭 HDCP 才能被采集卡读取。补帧效果和延迟以实际游戏与设备为准。", 15, .regular, NSColor(white: 1, alpha: 0.5), y: 22)

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("已生成 \(out)（\(img.width)×\(img.height)）")
