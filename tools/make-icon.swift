// 生成程序图标：swift tools/make-icon.swift 输出.png
// 设计：深色圆角方块（macOS 图标规格），三张斜着错开的画面：
// 后面和前面是真实帧（白），中间发青色光的是补出来的帧。
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// 底板：macOS 图标网格 824×824，留阴影
let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
let platePath = CGPath(roundedRect: plate, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.45).cgColor)
ctx.addPath(platePath); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(platePath); ctx.clip()
let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
    NSColor(srgbRed: 0.16, green: 0.18, blue: 0.24, alpha: 1).cgColor,
    NSColor(srgbRed: 0.05, green: 0.06, blue: 0.09, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
// 右上角一点冷光
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
    NSColor(srgbRed: 0.25, green: 0.75, blue: 1, alpha: 0.28).cgColor,
    NSColor(srgbRed: 0.25, green: 0.75, blue: 1, alpha: 0).cgColor] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 560, y: 520), startRadius: 0, endCenter: CGPoint(x: 560, y: 520), endRadius: 420, options: [])
ctx.restoreGState()

// 三张画面（16:9）
func frame(_ cx: CGFloat, _ cy: CGFloat, fill: NSColor, stroke: NSColor, alpha: CGFloat, glow: Bool = false) {
    let w: CGFloat = 430, h: CGFloat = 242
    let r = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    let p = CGPath(roundedRect: r, cornerWidth: 34, cornerHeight: 34, transform: nil)
    ctx.saveGState()
    if glow { ctx.setShadow(offset: .zero, blur: 60, color: NSColor(srgbRed: 0.3, green: 0.85, blue: 1, alpha: 0.9).cgColor) }
    ctx.addPath(p); ctx.setFillColor(fill.withAlphaComponent(alpha).cgColor); ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(p); ctx.setStrokeColor(stroke.cgColor); ctx.setLineWidth(10); ctx.strokePath()
    // 画面里一条"地平线"和一个太阳，表示是一帧画面
    ctx.saveGState(); ctx.addPath(p); ctx.clip()
    ctx.setFillColor(stroke.withAlphaComponent(0.35).cgColor)
    ctx.fill(CGRect(x: r.minX, y: r.minY, width: w, height: h * 0.32))
    ctx.fillEllipse(in: CGRect(x: r.maxX - 120, y: r.maxY - 105, width: 62, height: 62))
    ctx.restoreGState()
}
let white = NSColor(white: 0.92, alpha: 1)
let cyan = NSColor(srgbRed: 0.35, green: 0.88, blue: 1, alpha: 1)
frame(400, 640, fill: NSColor(white: 0.55, alpha: 1), stroke: NSColor(white: 0.62, alpha: 1), alpha: 0.35)   // 上一帧
frame(624, 384, fill: NSColor(white: 0.8, alpha: 1), stroke: white, alpha: 0.30)                             // 当前帧
frame(512, 512, fill: cyan, stroke: cyan, alpha: 0.30, glow: true)                                           // 补出来的帧

img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("已生成 \(out)")
