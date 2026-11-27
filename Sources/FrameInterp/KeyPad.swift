#if FI_KEYPAD
import AppKit
import SwiftUI

// MARK: - 键盘当手柄（测试用插件，2026-11-27）
// 只在 ./make-app.sh keypad 编出来的测试版里有（编译开关 FI_KEYPAD），普通版和发布的 DMG 不带。
// 给内嵌 Xbox 网页用：按键变成一个虚拟手柄（W3C 标准布局），经 WebStreamHost.pushRaw 转给网页，网页在画面区、在后面补帧时都能用。
// 设置 → 「键盘当手柄（测试版）」：开关、每个手柄按键改绑（点「改」再按一个键）、恢复默认；绑定存在 UserDefaults keypad.v1。
// 开关键（默认 B）：光标在网页输入框里时照常打字。开着时绑定的键不再传给网页 / FrameInterp 自己，带 ⌘ 的组合键照常。
// 键位按键盘位置（keyCode），不受输入法影响。测试别用系统级模拟按键（会发到最前面的别的 App），用 selfTest()。

/// 手柄上的一个动作
enum PadAction: String, CaseIterable, Identifiable {
    case stickUp, stickDown, stickLeft, stickRight
    case rStickUp, rStickDown, rStickLeft, rStickRight
    case a, b, x, y, lb, rb, lt, rt, view, menu, l3, r3
    case dpadUp, dpadDown, dpadLeft, dpadRight, home
    case toggle
    var id: String { rawValue }

    var name: String {
        switch self {
        case .stickUp: return "左摇杆 上"
        case .stickDown: return "左摇杆 下"
        case .stickLeft: return "左摇杆 左"
        case .stickRight: return "左摇杆 右"
        case .rStickUp: return "右摇杆 上"
        case .rStickDown: return "右摇杆 下"
        case .rStickLeft: return "右摇杆 左"
        case .rStickRight: return "右摇杆 右"
        case .a: return "A"
        case .b: return "B"
        case .x: return "X"
        case .y: return "Y"
        case .lb: return "LB"
        case .rb: return "RB"
        case .lt: return "LT"
        case .rt: return "RT"
        case .view: return "视图（两个方块）"
        case .menu: return "菜单（三条线）"
        case .l3: return "左摇杆按下"
        case .r3: return "右摇杆按下"
        case .dpadUp: return "十字键 上"
        case .dpadDown: return "十字键 下"
        case .dpadLeft: return "十字键 左"
        case .dpadRight: return "十字键 右"
        case .home: return "Xbox 键"
        case .toggle: return "开 / 关键盘手柄"
        }
    }

    /// 标准布局里的按键编号（摇杆和开关键没有）
    var button: Int? {
        switch self {
        case .a: return 0
        case .b: return 1
        case .x: return 2
        case .y: return 3
        case .lb: return 4
        case .rb: return 5
        case .lt: return 6
        case .rt: return 7
        case .view: return 8
        case .menu: return 9
        case .l3: return 10
        case .r3: return 11
        case .dpadUp: return 12
        case .dpadDown: return 13
        case .dpadLeft: return 14
        case .dpadRight: return 15
        case .home: return 16
        default: return nil
        }
    }

    /// 摇杆：轴（0 / 1 = 左摇杆 x / y，2 / 3 = 右摇杆 x / y）和方向
    var stick: (axis: Int, dir: Float)? {
        switch self {
        case .stickUp: return (1, -1)
        case .stickDown: return (1, 1)
        case .stickLeft: return (0, -1)
        case .stickRight: return (0, 1)
        case .rStickUp: return (3, -1)
        case .rStickDown: return (3, 1)
        case .rStickLeft: return (2, -1)
        case .rStickRight: return (2, 1)
        default: return nil
        }
    }

    /// 默认键位（用户 2026-11-27 定的；LB / RB / 视图 / 菜单 / 右摇杆按下 / Xbox 键原来没定，补了顺手的）
    static let defaults: [PadAction: UInt16] = [
        .stickUp: 13, .stickLeft: 0, .stickDown: 1, .stickRight: 2,     // W A S D
        .rStickUp: 34, .rStickLeft: 38, .rStickDown: 40, .rStickRight: 37, // I J K L
        .a: 36, .b: 53, .x: 15, .y: 3,                                  // 回车 Esc R F
        .lt: 41, .rt: 35,                                               // ; P
        .lb: 12, .rb: 14,                                               // Q E
        .view: 48, .menu: 46,                                           // Tab M
        .l3: 56, .r3: 8,                                                // 左 Shift、C
        .dpadUp: 126, .dpadDown: 125, .dpadLeft: 123, .dpadRight: 124,  // 方向键
        .home: 4,                                                       // H
        .toggle: 11,                                                    // B
    ]
}

@MainActor
final class KeyPad: ObservableObject {
    static let shared = KeyPad()
    weak var host: WebStreamHost?
    var onToggle: ((Bool) -> Void)?
    @Published private(set) var enabled = false
    @Published private(set) var binds: [PadAction: UInt16]
    @Published var listening: PadAction?       // 正在等用户按新键（设置里点了「改」）
    private var down = Set<UInt16>()
    private var slot = 0
    private var monitor: Any?
    private var swallowUp = Set<UInt16>()
    private static let defaultsKey = "keypad.v1"
    /// 修饰键（按下 / 松开走 flagsChanged）：左右 Shift、Control、Option、Caps Lock
    private static let modifierKeys: Set<UInt16> = [56, 60, 59, 62, 58, 61, 57]

    private init() {
        var b = PadAction.defaults
        if let saved = UserDefaults.standard.dictionary(forKey: KeyPad.defaultsKey) as? [String: Int] {
            for (k, v) in saved { if let a = PadAction(rawValue: k) { b[a] = v < 0 ? nil : UInt16(v) } }
        }
        binds = b
    }

    // MARK: 绑定
    func key(for a: PadAction) -> UInt16? { binds[a] }
    private func action(for code: UInt16) -> PadAction? { binds.first { $0.value == code }?.key }

    func bind(_ a: PadAction, to code: UInt16) {
        // 一个键只管一个动作：别的动作原来用这个键就清掉
        for (other, c) in binds where c == code && other != a { binds[other] = nil }
        binds[a] = code
        save()
        Log.write("键盘手柄：\(a.name) 改成 \(KeyPad.keyName(code))")
    }
    func unbind(_ a: PadAction) { binds[a] = nil; save() }
    func resetDefaults() { binds = PadAction.defaults; save(); Log.write("键盘手柄：恢复默认键位") }
    private func save() {
        var d: [String: Int] = [:]
        for a in PadAction.allCases { d[a.rawValue] = binds[a].map(Int.init) ?? -1 }
        UserDefaults.standard.set(d, forKey: KeyPad.defaultsKey)
    }

    // MARK: 开关
    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { e in
            nonisolated(unsafe) let ev = e   // 本地事件监听本来就在主线程
            return MainActor.assumeIsolated { KeyPad.shared.handle(ev) } ? nil : e
        }
    }

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        down.removeAll()
        if on { slot = host?.freeSlot() ?? 0; push() } else { host?.removePad(slot) }
        Log.write("键盘当手柄：\(on ? "开（手柄 \(slot + 1)）" : "关")")
        onToggle?(on)
    }
    func toggle() { setEnabled(!enabled) }

    /// 这个按键现在归键盘手柄管吗（FrameInterp 自己的快捷键遇到它要让开）
    func isMapped(_ e: NSEvent) -> Bool {
        if listening != nil { return true }
        guard let h = host, h.loaded, !e.modifierFlags.contains(.command), let a = action(for: e.keyCode) else { return false }
        return a == .toggle ? !h.typing : enabled
    }

    /// 处理一个按键事件；返回 true = 吃掉（不再往下传）
    func handle(_ e: NSEvent) -> Bool {
        // 设置里正在改键：下一个键（含修饰键按下）就是新键位
        if let a = listening {
            if e.type == .keyDown || (e.type == .flagsChanged && KeyPad.modifierKeys.contains(e.keyCode) && isPress(e)) {
                bind(a, to: e.keyCode)
                listening = nil
                swallowUp.insert(e.keyCode)
                return true
            }
            return e.type == .keyUp
        }
        if e.type == .keyUp, swallowUp.remove(e.keyCode) != nil { return true }
        guard let h = host, h.loaded else { return false }
        if e.modifierFlags.contains(.command) && e.type != .flagsChanged { return false }
        guard let a = action(for: e.keyCode) else { return false }

        // 开关键（输入框里照常打字）
        if a == .toggle {
            guard e.type == .keyDown, !h.typing else { return false }
            if !e.isARepeat { toggle() }
            swallowUp.insert(e.keyCode)
            return true
        }
        guard enabled else { return false }
        switch e.type {
        case .flagsChanged:
            if isPress(e) { down.insert(e.keyCode) } else { down.remove(e.keyCode) }
            push()
            return false          // 修饰键不吃掉（吃掉也挡不住系统）
        case .keyDown:
            if !e.isARepeat { down.insert(e.keyCode); push() }
            return true
        default:
            down.remove(e.keyCode); push()
            return true
        }
    }

    /// 修饰键这次是按下还是松开
    private func isPress(_ e: NSEvent) -> Bool {
        switch e.keyCode {
        case 56, 60: return e.modifierFlags.contains(.shift)
        case 59, 62: return e.modifierFlags.contains(.control)
        case 58, 61: return e.modifierFlags.contains(.option)
        case 57: return e.modifierFlags.contains(.capsLock)
        default: return !down.contains(e.keyCode)
        }
    }

    private func push() {
        guard let h = host, h.loaded else { return }
        var b = [Float](repeating: 0, count: 17)
        var a: [Float] = [0, 0, 0, 0]
        for k in down {
            guard let act = action(for: k) else { continue }
            if let i = act.button { b[i] = 1 }
            if let s = act.stick { a[s.axis] += s.dir }
        }
        for i in 0..<4 { a[i] = max(-1, min(1, a[i])) }
        for (x, y) in [(0, 1), (2, 3)] where a[x] != 0 && a[y] != 0 { a[x] *= 0.7071; a[y] *= 0.7071 }   // 斜着推不超过 1
        h.pushRaw(slot, "Keyboard", b, a)
    }

    // MARK: 键名
    static func keyName(_ c: UInt16) -> String {
        let names: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "回车", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
            43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "Tab", 49: "空格", 50: "`", 51: "删除", 53: "Esc",
            56: "左 Shift", 60: "右 Shift", 59: "左 Control", 62: "右 Control", 58: "左 Option", 61: "右 Option", 57: "大写锁定",
            123: "←", 124: "→", 125: "↓", 126: "↑", 117: "向前删除", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
            82: "小键盘 0", 83: "小键盘 1", 84: "小键盘 2", 85: "小键盘 3", 86: "小键盘 4", 87: "小键盘 5", 88: "小键盘 6", 89: "小键盘 7",
            91: "小键盘 8", 92: "小键盘 9", 76: "小键盘回车",
        ]
        return names[c] ?? "键 \(c)"
    }

    // MARK: 自测（FI_KEYPADTEST=1）
    /// 在程序里造按键事件直接交给 handle()，不经过系统（不会发到别的 App）。
    /// 按开关键开 → 按住 W、D、回车、P、; 2.5 秒 → 松开 → 网页里聚焦输入框，按开关键（应该照常打字、不关）→ 改绑 A 到空格再按空格 → 恢复默认 → 关
    func selfTest() {
        guard let w = NSApp.mainWindow ?? NSApp.windows.first, let h = host else { return }
        func key(_ code: UInt16, _ down: Bool) -> Bool {
            guard let e = NSEvent.keyEvent(with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: w.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                                           isARepeat: false, keyCode: code) else { return false }
            return handle(e)
        }
        func tap(_ c: UInt16) -> Bool { let r = key(c, true); _ = key(c, false); return r }
        func after(_ s: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s) { MainActor.assumeIsolated(f) } }
        let t = binds[.toggle] ?? 11
        _ = tap(t)
        Log.write("键盘手柄自测：按开关键 → \(enabled ? "开" : "关")")
        let codes: [UInt16] = [13, 2, 36, 35, 41]
        codes.forEach { _ = key($0, true) }
        Log.write("键盘手柄自测：按住 W D 回车 P ;")
        after(2.5) {
            codes.forEach { _ = key($0, false) }
            Log.write("键盘手柄自测：松开")
            h.webView.evaluateJavaScript("const i = document.createElement('input'); document.body.appendChild(i); i.focus();")
            after(0.8) {
                let eaten = tap(t)
                Log.write("键盘手柄自测：输入框里按开关键 → \(eaten ? "被吃掉（不对）" : "照常打字")，键盘手柄仍\(self.enabled ? "开" : "关")")
                h.webView.evaluateJavaScript("document.activeElement.blur();")
                self.listening = .a
                _ = tap(49)                               // 空格 → A
                Log.write("键盘手柄自测：A 改绑成 \(self.binds[.a].map(KeyPad.keyName) ?? "无")，回车现在是 \(self.action(for: 36)?.name ?? "无")")
                _ = key(49, true)
                after(1.5) {
                    _ = key(49, false)
                    self.resetDefaults()
                    after(0.8) {
                        _ = tap(t)
                        Log.write("键盘手柄自测：输入框外按开关键 → \(self.enabled ? "开" : "关")")
                    }
                }
            }
        }
    }
}

/// 设置里的「键盘当手柄（测试版）」一节
struct KeyPadSection: View {
    @ObservedObject var kp = KeyPad.shared
    @ObservedObject var model: UIModel
    @State private var open = false

    var body: some View {
        SectionBlock(title: "键盘当手柄（测试版）", icon: "keyboard", trailing: {
            Button { open.toggle() } label: {
                Text(open ? "收起键位" : "改键位").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.muted)
                    .padding(.horizontal, 8).frame(height: 20)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.border))
            }
            .buttonStyle(.plain)
        }) {
            SwitchLine(title: "用键盘当手柄", isOn: Binding(get: { kp.enabled }, set: { kp.setEnabled($0) }))
            Hint("给内嵌 Xbox 网页测试用，只在测试版里有。也可以按「\(kp.key(for: .toggle).map(KeyPad.keyName) ?? "（未设置）")」开关；光标在网页输入框里时这个键照常打字。"
                 + (model.webLoaded ? "" : "\n要先打开 Xbox 网页才会生效。"))
            Hint(summary)
            if open {
                VStack(spacing: 2) {
                    ForEach(PadAction.allCases) { a in row(a) }
                }
                .padding(.top, 2)
                HStack {
                    Button("恢复默认键位") { kp.resetDefaults() }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.blue)
                    Spacer()
                }
                .padding(.top, 4)
            }
        }
    }

    private var summary: String {
        let n: (PadAction) -> String = { kp.key(for: $0).map(KeyPad.keyName) ?? "—" }
        return "左摇杆 \(n(.stickUp))\(n(.stickLeft))\(n(.stickDown))\(n(.stickRight)) · 右摇杆 \(n(.rStickUp))\(n(.rStickLeft))\(n(.rStickDown))\(n(.rStickRight)) · A \(n(.a)) · B \(n(.b)) · X \(n(.x)) · Y \(n(.y)) · LT \(n(.lt)) · RT \(n(.rt)) · 十字键 方向键"
    }

    private func row(_ a: PadAction) -> some View {
        let listening = kp.listening == a
        return HStack(spacing: 8) {
            Text(a.name).font(.system(size: 12)).foregroundStyle(Theme.text.opacity(0.9))
            Spacer(minLength: 6)
            Text(listening ? "按一个键…" : (kp.key(for: a).map(KeyPad.keyName) ?? "未设置"))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(listening ? Theme.accent : (kp.key(for: a) == nil ? Theme.faint : Theme.text))
                .padding(.horizontal, 8).frame(minWidth: 70, minHeight: 22)
                .background(listening ? Theme.accent.opacity(0.15) : Theme.bg.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(listening ? Theme.accent.opacity(0.6) : Theme.border))
            Button(listening ? "取消" : "改") { kp.listening = listening ? nil : a }
                .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.blue)
                .frame(width: 30)
            if !listening && kp.key(for: a) != nil && a != .toggle {
                Button("清除") { kp.unbind(a) }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.muted).frame(width: 30)
            } else {
                Color.clear.frame(width: 30, height: 1)
            }
        }
        .padding(.vertical, 2)
    }
}
#endif
