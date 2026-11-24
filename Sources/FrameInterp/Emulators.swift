import AppKit
import ScreenCaptureKit

// MARK: - 模拟器（2026-11-24 加）
// 和串流窗口一样是抓窗口画面补帧，单独列出来：识别常见的 Mac 模拟器，窗口列表里标"模拟器"，
// 并告诉用户要在模拟器里改什么——FrameInterp 在前台时模拟器失去焦点，键盘鼠标到不了它，
// 手柄要模拟器支持"后台输入"，有的模拟器失去焦点还会自动暂停。
// 补帧本身不变：最多两帧之间插一帧（2 倍）。60 帧的游戏要 120Hz 屏幕才补得出来（60 → 120），30 帧的补到 60。
// 各模拟器的设置项名称按它们的英文界面写；没把握的只给通用提示。只有 Dolphin 有人实际用过，其他未实测。

struct Emulator: Identifiable {
    let name: String
    let system: String        // 模拟的主机
    let keys: [String]        // 匹配 App 名字 / bundle id（小写）
    let tip: String           // 要在模拟器里改什么
    var id: String { name }

    static let genericTip = "在模拟器设置里打开「后台输入（Background Input）」，关掉「失去焦点时暂停（Pause on focus loss）」"

    static let all: [Emulator] = [
        Emulator(name: "Dolphin", system: "GameCube / Wii", keys: ["dolphin"],
                 tip: "控制器设置（Controllers）里勾选「Background Input」，不然 FrameInterp 在前台时手柄没反应"),
        Emulator(name: "PCSX2", system: "PS2", keys: ["pcsx2"],
                 tip: "设置 → Interface 里关掉「Pause On Focus Loss」"),
        Emulator(name: "DuckStation", system: "PS1", keys: ["duckstation"],
                 tip: "设置 → Interface 里关掉「Pause On Focus Loss」"),
        Emulator(name: "PPSSPP", system: "PSP", keys: ["ppsspp"],
                 tip: "设置 → System 里关掉「Pause when not focused」"),
        Emulator(name: "RetroArch", system: "多平台", keys: ["retroarch"],
                 tip: "设置 → User Interface 里关掉「Pause Content When Not Active」"),
        Emulator(name: "RPCS3", system: "PS3", keys: ["rpcs3"], tip: genericTip),
        Emulator(name: "Cemu", system: "Wii U", keys: ["cemu"], tip: genericTip),
        Emulator(name: "Ryujinx", system: "Switch", keys: ["ryujinx", "ryubing"], tip: genericTip),
        Emulator(name: "Azahar / Citra", system: "3DS", keys: ["azahar", "citra", "lime3ds"], tip: genericTip),
        Emulator(name: "melonDS", system: "DS", keys: ["melonds"], tip: genericTip),
        Emulator(name: "shadPS4", system: "PS4", keys: ["shadps4"], tip: genericTip),
        Emulator(name: "Vita3K", system: "PS Vita", keys: ["vita3k"], tip: genericTip),
        Emulator(name: "xemu", system: "Xbox", keys: ["xemu"], tip: genericTip),
        Emulator(name: "mGBA", system: "GBA", keys: ["mgba"], tip: genericTip),
        Emulator(name: "OpenEmu", system: "多平台", keys: ["openemu"], tip: genericTip),
    ]

    /// 这个窗口是哪个模拟器的（按 App 名字和 bundle id 认，不看窗口标题：标题里常有游戏名）
    static func match(_ w: SCWindow) -> Emulator? {
        match(app: w.owningApplication?.applicationName ?? "", bundle: w.owningApplication?.bundleIdentifier ?? "")
    }
    static func match(app: String, bundle: String) -> Emulator? {
        let s = (app + " " + bundle).lowercased()
        return all.first { e in e.keys.contains { s.contains($0) } }
    }

    /// 当前屏幕最高刷新率
    @MainActor static var screenHz: Int { NSScreen.main?.maximumFramesPerSecond ?? 60 }

    /// 刷新率说明：60Hz 屏幕上 60 帧的游戏不用补（已按界面语言翻好）
    @MainActor static var refreshNote: String {
        let hz = screenHz
        if Lang.english {
            return hz >= 100 ? "This screen is \(hz) Hz: 60 fps games are interpolated to \(min(hz, 120)) fps, 30 fps games to 60 fps."
                : "This screen is only \(hz) Hz: 60 fps games aren't interpolated (a 120 Hz screen is needed for 120 fps); 30 fps games go to 60 fps."
        }
        return hz >= 100
            ? "这块屏幕 \(hz)Hz：60 帧的游戏补到 \(min(hz, 120)) 帧，30 帧的补到 60 帧"
            : "这块屏幕只有 \(hz)Hz：60 帧的游戏不会补帧（要 120Hz 屏幕才能补到 120），30 帧的游戏补到 60 帧"
    }

    /// "Dolphin（GameCube / Wii）：要改什么"（已按界面语言翻好）
    var fullTip: String {
        Lang.english ? "\(name) (\(L(system))): \(L(tip))" : "\(name)（\(system)）：\(tip)"
    }
    /// "Dolphin：要改什么"
    var shortTip: String { Lang.english ? "\(name): \(L(tip))" : "\(name)：\(tip)" }
}
