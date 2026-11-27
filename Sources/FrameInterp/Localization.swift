import Foundation
import SwiftUI

// MARK: - 界面英文化（2026-11-22，准备开源）
// 跟随系统：系统首选语言是中文时显示中文（源码里写的就是中文），其他语言显示英文。环境变量 FI_LANG=en / zh 可强制。
// 做法：界面上所有文字显示前都过 L()——整句查表；带数字的句子按模板换；拼起来的句子按词组替换（长的先换）。
// 日志保持中文。

enum Lang {
    static let english: Bool = {
        if let f = ProcessInfo.processInfo.environment["FI_LANG"] { return f.hasPrefix("en") }
        return !(Locale.preferredLanguages.first ?? "zh").hasPrefix("zh")
    }()
}

func L(_ s: String) -> String {
    guard Lang.english, s.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) || (0x3000...0x303F).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) }) else { return s }
    if let t = EN.exact[s] { return t }
    for (re, out) in EN.templates {
        let r = NSRange(s.startIndex..., in: s)
        if let m = re.firstMatch(in: s, range: r), m.range == r {
            var o = out
            for i in 1..<m.numberOfRanges {
                let g = Range(m.range(at: i), in: s).map { L(String(s[$0])) } ?? ""
                o = o.replacingOccurrences(of: "{\(i)}", with: g)
            }
            return o
        }
    }
    var o = s
    for (zh, en) in EN.fragments { o = o.replacingOccurrences(of: zh, with: en) }
    return o
}

// 让 SwiftUI 的文字控件都经过 L()：同名的 String 版本优先于系统的 LocalizedStringKey 版本
extension Text {
    init(_ s: String) { self.init(verbatim: L(s)) }
}
extension Button where Label == Text {
    init(_ s: String, action: @escaping () -> Void) { self.init(action: action) { Text(verbatim: L(s)) } }
}
extension Section where Parent == Text, Footer == EmptyView, Content: View {
    init(_ s: String, @ViewBuilder content: () -> Content) { self.init(content: content, header: { Text(verbatim: L(s)) }) }
}
extension View {
    func help(_ s: String) -> some View { help(Text(verbatim: L(s))) }
}

enum EN {
    static let exact: [String: String] = [
        // 通用 / 状态
        "采集卡": "Capture card", "窗口": "Window", "其他": "Other", "未选择": "None selected",
        "连接中": "Connecting", "出错": "Error", "未连接": "Not connected", "断开": "Disconnect",
        "断开：停止采集": "Disconnect: stop capturing", "连接选中的采集卡": "Connect the selected capture card",
        "选择画面来源": "Choose a video source", "采集卡（HDMI）": "Capture card (HDMI)", "未检测到": "Not detected",
        "主机 HDMI 接采集卡，采集卡用 USB-C 接到 Mac（USB 3 以上）。插上后这里会显示设备名，不用装驱动。":
            "Connect the console's HDMI to the capture card and the card to your Mac over USB-C (USB 3 or faster). The device name appears here once it's plugged in — no drivers needed.",
        "画面和声音都从采集卡来，延迟最低。": "Picture and sound both come from the capture card — lowest latency.",
        "重新检测": "Rescan", "串流窗口": "Streaming window", "需要录屏权限": "Needs screen recording",
        "未发现串流 App": "No streaming app found",
        "从 PS Remote Play、Moonlight、Chiaki 等串流 App 的窗口取画面补帧，不用采集卡。暂不支持网页版 Xbox 串流（xbox.com/play）":
            "Interpolates the window of a streaming app such as PS Remote Play, Moonlight or Chiaki — no capture card needed. Web-based Xbox streaming (xbox.com/play) is not supported yet.",
        "要读取别的 App 的窗口，需要在系统设置里打开「录屏与系统录音」权限。":
            "To read another app's window, allow \"Screen & System Audio Recording\" in System Settings.",
        "授权录屏": "Allow recording", "选其他窗口": "Other window", "选择窗口": "Choose window",
        "主机配置": "Console preset", "按主机一键设置": "Set up for your console",
        "PS5 / PS5 Pro / Xbox Series S / X：自动设好采集分辨率、补帧和锐化":
            "PS5 / PS5 Pro / Xbox Series S / X: sets capture resolution, interpolation and sharpening for you",
        "换主机": "Change console", "选主机": "Choose console",
        "选择要补帧的窗口": "Choose a window to interpolate",
        "串流 App 的窗口排在前面。窗口可以放在任何地方，被挡住也没关系。":
            "Streaming apps are listed first. The window can be anywhere, even covered by other windows.",
        "刷新": "Refresh", "关闭": "Close",
        "需要「录屏与系统录音」权限": "\"Screen & System Audio Recording\" permission needed",
        "FrameInterp 只读取你选中的那一个窗口的画面，用来补帧，不保存、不上传。\n在系统设置里打开 FrameInterp 后，需要重新打开本程序才生效。":
            "FrameInterp only reads the one window you choose, to interpolate it. Nothing is saved or uploaded.\nAfter enabling FrameInterp in System Settings, reopen the app for it to take effect.",
        "已打开，重新打开 FrameInterp": "Enabled — reopen FrameInterp",
        "已经打开了还是不行：在系统设置的列表里选中 FrameInterp，点「−」删掉，再点「授权录屏」重新加一次（程序每次更新后系统会把它当成新程序）。":
            "Still not working after enabling it? Select FrameInterp in the System Settings list, click \"−\" to remove it, then click \"Allow recording\" again (macOS treats every update as a new app).",
        "没有可用的窗口：先打开串流 App，再点右上角刷新": "No windows available: open the streaming app first, then click Refresh at the top right",
        "暂不支持": "Not supported", "串流": "Streaming",
        "网页版 Xbox 串流：浏览器失去焦点会暂停画面，暂不支持": "Web Xbox streaming: the page pauses when the browser loses focus — not supported yet",
        // 底部坞
        "设置（⌘,）": "Settings (⌘,)", "补帧：开（空格）": "Interpolation: on (Space)", "补帧：关（空格）": "Interpolation: off (Space)",
        "声音直通：开（点一下静音）": "Audio pass-through: on (click to mute)", "声音直通：关": "Audio pass-through: off",
        "锐化：开（强度在设置里调）": "Sharpening: on (strength in Settings)", "锐化：关": "Sharpening: off",
        "帧数和延迟浮窗（⌘I）": "FPS & latency overlay (⌘I)", "退出全屏（Esc）": "Exit full screen (Esc)", "全屏（f）": "Full screen (F)",
        "等待画面…": "Waiting for video…", "正在打开…": "Opening…", "没有输入": "No input",
        "插上采集卡点「连接」，或选一个串流窗口": "Plug in a capture card and click Connect, or choose a streaming window",
        // 设置：输入来源
        "设置": "Settings", "输入来源": "Source", "输入类型": "Source type",
        "读取其他 App 的窗口画面需要「录屏与系统录音」权限。": "Reading another app's window needs the \"Screen & System Audio Recording\" permission.",
        "系统设置里打开 FrameInterp 后，要重新打开本程序才生效。还是不行就在列表里删掉 FrameInterp 再授权一次。":
            "After enabling FrameInterp in System Settings, reopen the app. If it still doesn't work, remove FrameInterp from the list and allow it again.",
        "选择一个窗口": "Choose a window", "串流 App": "Streaming apps", "其他窗口": "Other windows", "没有可用的窗口": "No windows available",
        "重新查找窗口": "Rescan windows", "带预览选择窗口": "Choose with previews",
        "自动裁掉标题栏和黑边": "Crop title bar and black bars",
        "游戏画面按 16:9 铺满、居中，不留黑边。开始后 3 秒内识别黑边；窗口大小变了会自动重新铺满。关掉则整个窗口按 16:9 铺满":
            "Fills the screen with the 16:9 game picture, centered, without black bars. Black bars are detected in the first 3 seconds and the picture re-fits when the window is resized. When off, the whole window is fitted as 16:9.",
        "按窗口画面的原始像素采集（不再先缩到 1080p）；开补帧时补帧器在 1080p 上补。全屏时不会让串流 App 以为自己被挡住而降帧。声音由串流 App 自己播放。":
            "Captures the window at its native pixels (no longer scaled to 1080p first); interpolation runs at 1080p. In full screen the streaming app still counts as visible, so it won't throttle. Audio is played by the streaming app itself.",
        "暂不支持网页版 Xbox 串流（Chrome / Edge / Safari 里的 xbox.com/play）：浏览器一失去焦点网页就暂停画面，和 FrameInterp 在前台显示补帧冲突。以后会把网页内嵌进 FrameInterp 来支持":
            "Web-based Xbox streaming (xbox.com/play in Chrome / Edge / Safari) is not supported yet: the page pauses as soon as the browser loses focus, which conflicts with FrameInterp showing the interpolated picture in front. Embedding the page inside FrameInterp is planned.",
        "画面糊时先看串流 App 自己的画质：PS Remote Play → 设置 → 视频画质，分辨率选 1080p、帧率选「高」（默认可能是 720p）；串流窗口别拉得太小":
            "Blurry picture? Check the streaming app's own quality first: PS Remote Play → Settings → Video Quality, choose 1080p and High frame rate (the default may be 720p). Don't make the streaming window too small.",
        "视频设备": "Video device", "不使用（停止）": "None (stop)", "重新查找采集卡和窗口": "Rescan capture cards and windows",
        "分辨率": "Resolution", " · 这个设备不支持": " · not supported by this device", "帧率": "Frame rate",
        "120 fps（主机输出 120Hz 时才有用）": "120 fps (only useful when the console outputs 120 Hz)",
        "压缩传输（MJPEG）": "Compressed transfer (MJPEG)",
        "这个采集卡在 macOS 上没有提供压缩格式，开了不起作用": "This capture card offers no compressed format on macOS, so this has no effect",
        "USB 带宽不够时用（4K 60 帧、2K 120 帧）。画面经过压缩，细节略差；1080p 60 不需要开":
            "Use when USB bandwidth is not enough (4K 60 fps, 2K 120 fps). The picture is compressed and slightly less detailed; not needed for 1080p 60.",
        "声音直通": "Audio pass-through", "音频输入": "Audio input", "自动（采集卡自带）": "Automatic (capture card)",
        "已拔出的设备": "Unplugged device", "自动（采集卡自带的声音）": "Automatic (capture card audio)", "音频输出": "Audio output",
        "系统默认（跟随系统设置）": "System default", "已断开的设备": "Disconnected device", "当前配置": "Current preset",
        "配置已保存，换主机时再选一次": "Preset saved. Choose again when you switch consoles.", "选主机，一键配置": "Choose console preset",
        // 设置：补帧
        "补帧": "Interpolation", "开启补帧": "Frame interpolation",
        "30 帧游戏补成 60 帧；本来就是 60 帧的游戏不用开。快捷键：空格": "Turns 30 fps games into 60 fps; not needed for games that already run at 60. Shortcut: Space",
        "字幕和提示保护": "Subtitle & HUD guard",
        "下方字幕、左上状态条、左下地点名、右上金钱 / 提示、右下消息框停住不动时，补出来的帧里用真实画面，不闪、不变形。只管这几块":
            "When subtitles, the status bars at the top left, place names at the bottom left, money / notices at the top right or messages at the bottom right stay still, interpolated frames use the real picture there — no shimmer or warping. Only these areas are affected.",
        // 设置：画质
        "画质": "Image", "清晰放大": "Sharp scaling",
        "程序自己把画面缩放到屏幕的实际像素再显示，系统不再二次缩放。\n· 放大（1080p、2K → 全屏）：三次插值，比系统的双线性清楚，字边缘锯齿少\n· 缩小（4K → 全屏）：按比例取样，细线、栅栏、小字不闪\n每帧约 1.5~4ms（GPU），延迟基本不变":
            "FrameInterp scales the picture to the screen's physical pixels itself, so macOS doesn't scale it again.\n· Upscaling (1080p, 2K → full screen): cubic interpolation, sharper than the system's bilinear, fewer jagged text edges\n· Downscaling (4K → full screen): area sampling, so thin lines, fences and small text don't flicker\nAbout 1.5–4 ms per frame on the GPU; latency is basically unchanged",
        "关：交给系统缩放（双线性，偏软）；下面的锐化在原分辨率上做": "Off: macOS scales the picture (bilinear, softer); sharpening below runs at the source resolution",
        "2K / 4K 自动轻度锐化": "Light auto-sharpening for 2K / 4K",
        "采集分辨率是 2K / 4K 时（开补帧后也算），锐化至少用「柔和」（0.25）。主机输出 4K，但很多游戏内部只渲染 1440p 左右，画面会偏软":
            "When capturing at 2K / 4K (also with interpolation on), sharpening is at least Soft (0.25). Consoles output 4K, but many games render internally at about 1440p, so the picture looks soft.",
        "缩小防闪烁": "Anti-flicker downscaling",
        "隐藏其他": "Hide Others",
        "全部显示": "Show All",
        "原分辨率（画质好）": "Native resolution (best quality)",
        "720p（更快，中间帧略软）": "720p (faster, softer in-between frames)",
        "进入全屏幕": "Enter Full Screen",
        "最小化": "Minimize",
        "缩放": "Zoom",
        "前置全部窗口": "Bring All to Front",
        "帮助": "Help",
        "FrameInterp 使用说明": "FrameInterp Guide",
        "没找到 Xbox 主机": "No Xbox console found",
        "登录 Xbox 账号…": "Sign in to Xbox…",
        "Xbox 网页串流…": "Xbox web streaming…",
        "没有发现串流 App 或模拟器的窗口": "No streaming app or emulator windows found",
        "PlayStation / 模拟器窗口": "PlayStation / emulator windows",
        "从所有窗口里选…": "Choose from all windows…",
        "选主机，一键配置…": "Set up for your console…",
        "停止": "Stop",
        "画质（下次连接生效）": "Quality (applies next connection)",
        "换主机：首页「串流 → Xbox」。Wi-Fi 下画面每隔约 0.5 秒顿一下，多半是隔空投送 / 接力（AWDL）在切频道，用网线或串流时关掉它最稳": "Switch consoles on the home page (Streaming → Xbox). On Wi-Fi, a hitch every ~0.5 s is usually AirDrop / Handoff (AWDL) hopping channels — Ethernet, or turning it off while streaming, is the most stable.",
        "游戏画面按 16:9 铺满、不留黑边；窗口大小变了自动重新铺满": "Fills the game picture at 16:9 with no black bars; refits automatically when the window is resized",
        "画面糊时先看串流 App 自己的画质：PS Remote Play → 设置 → 视频画质，分辨率选 1080p、帧率选「高」；串流窗口别拉得太小": "If it looks blurry, check the streaming app's own quality first: PS Remote Play → Settings → Video Quality, 1080p resolution and High frame rate; don't make the window too small",
        "锐化（2K / 4K 输入，自动用柔和）": "Sharpening (2K / 4K input: Soft applied automatically)",
        "2K / 4K 输入自动轻度锐化": "Light auto-sharpening for 2K / 4K input",
        "串流 App 与模拟器窗口": "Streaming app & emulator windows",
        "已连接 · Xbox": "Connected · Xbox",
        "Xbox 远程游玩还没打开": "Xbox Remote Play hasn't opened yet",
        "Xbox 远程游玩没打开": "Xbox Remote Play didn't open",
       
        "正在加载 Xbox 远程游玩": "Loading Xbox Remote Play",
        "第一次打开会慢一点，网络慢时可能要十几秒": "The first launch is a bit slower — up to 10–20 seconds on a slow network",
        "在 FrameInterp 里打开 Xbox 远程游玩：玩自己的主机，或玩云游戏。被挡住也照常播放，手柄由 FrameInterp 转过去。（实验）": "Opens Xbox Remote Play inside FrameInterp: play your own console or cloud games. It keeps playing while covered, and FrameInterp passes your controller through. (Experimental)",
        "远程游玩 / 云游戏 · 登录、选游戏后点「开始补帧」": "Remote play / cloud gaming · sign in, pick a game, then click Start interpolation",
        "加载太久了：网络可能比较慢，或者连不上 Xbox 服务器。可以再等等，或者重试": "This is taking a while: the network may be slow, or Xbox servers can't be reached. Keep waiting or retry.",
        "连不上 Xbox 服务器（可能被网络拦了，或者 DNS 有问题）": "Can't reach Xbox servers (blocked by the network, or a DNS problem)",
        "没有网络连接，检查 Wi-Fi 后重试": "No network connection — check Wi-Fi and retry",
        "连接超时，网络可能比较慢，稍后重试": "Connection timed out — the network may be slow; retry in a moment",
        "Xbox 网页": "Xbox web",
        "在网页里登录、开始串流，然后点右上角「开始补帧」。手柄由 FrameInterp 转给网页": "Sign in and start streaming in the page, then click Start interpolation (top right). FrameInterp passes your controller to the page.",
        "Xbox 网页 · 串流开始后点「开始补帧」": "Xbox web · click Start interpolation once streaming",
        "关闭网页": "Close page",
        "回到网页": "Back to page",
        "HDMI · 延迟最低": "HDMI · lowest latency",
        "已连接": "Connected",
        "没有检测到采集卡": "No capture card detected",
        "不用采集卡 · 抓窗口画面": "Window capture · no card needed",
        "Xbox 网页可用": "Xbox web ready",
        "未发现": "Not found",
        "网页串流 · 内嵌": "Web streaming · built in",
        "串流要读取窗口画面，需要在系统设置里打开「录屏与系统录音」权限。": "Streaming captures a window, so FrameInterp needs Screen & System Audio Recording permission in System Settings.",
        "在 FrameInterp 里打开 xbox.com/play：远程游玩自己的主机，或玩云游戏。网页被挡住也照常播放，手柄由 FrameInterp 转过去。（实验）": "Opens xbox.com/play inside FrameInterp: remote play your own console or play cloud games. The page keeps playing while covered, and FrameInterp passes your controller through. (Experimental)",
        "打开 PS Remote Play 或 chiaki-ng，连上主机后点「连接」。PS Remote Play 里画质选 1080p、帧率选「高」。": "Open PS Remote Play or chiaki-ng, connect to your console, then click Connect. In PS Remote Play, set resolution to 1080p and frame rate to High.",
        "没发现 PS Remote Play / chiaki-ng 的窗口": "No PS Remote Play / chiaki-ng window found",
        "没发现模拟器的窗口": "No emulator window found",
        "Xbox 网页（内嵌）": "Xbox web (built in)",
        "xbox.com/play · 远程游玩 / 云游戏 · 登录、选游戏后点「开始补帧」": "xbox.com/play · remote play / cloud gaming · sign in, pick a game, then click Start interpolation",
        "打开 Xbox 网页": "Open Xbox web",
        "其他窗口…": "Other windows…",
        "Xbox 网页串流（FrameInterp 内嵌）": "Xbox web streaming (in FrameInterp)",
        "开始补帧": "Start interpolation",
        "登录、选主机或游戏，开始串流后点右上角「开始补帧」 · 补帧时 ⌘J 回到这里": "Sign in and pick a console or game; once streaming, click Start interpolation (top right) · ⌘J brings you back here",
        "Xbox 网页串流（内嵌，实验）…": "Xbox web streaming (built in, experimental)…",
        "回到 Xbox 网页": "Back to Xbox web",
        "Xbox 网页已关闭": "Xbox web closed",
        "Xbox 网页串流（内嵌）": "Xbox web streaming (built in)",
        "补帧中 · ⌘J 回到网页（选游戏、退出游戏）": "Interpolating · ⌘J returns to the web page (pick or quit a game)",
        "⚠ 浏览器里的网页版 Xbox 会因失去焦点暂停：请改用「Xbox 网页」（内嵌）": "⚠ Xbox in a browser pauses when it loses focus — use the built-in Xbox web instead",
        "浏览器里的网页版 Xbox 失去焦点会暂停：请改用「Xbox 网页」（内嵌）": "Xbox in a browser pauses when it loses focus — use the built-in Xbox web instead",
        "网页版 Xbox 串流（xbox.com/play）请用首页窗口卡片里的「Xbox 网页」（实验）：网页在 FrameInterp 里打开，被挡住也照常播放。浏览器里的网页一失去焦点就暂停，仍不支持": "For Xbox web streaming (xbox.com/play), use Xbox web on the home page (experimental): the page opens inside FrameInterp and keeps playing while covered. Xbox in a regular browser pauses when it loses focus and is still unsupported.",
        "清晰放大关着时这一项和「压缩传输时减弱锐化」都不起作用": "Has no effect while Sharp scaling is off (neither does Less sharpening for compressed video)",
        "采集分辨率比显示区域大很多时（4K 采集，或 2K 放进小窗口，缩到 0.85 倍以下）才起作用；开补帧、串流窗口模式时画面是 1080p，不会用到。关掉每帧省约 2ms，但画面移动时细线、栅栏、树叶会闪、出摩尔纹":
            "Only applies when the capture is much larger than the display area (4K capture, or 2K in a small window — below 0.85×). Not used with interpolation or streaming windows (1080p). Turning it off saves about 2 ms per frame, but thin lines, fences and leaves flicker and show moiré when the picture moves.",
        "压缩传输时减弱锐化": "Less sharpening for compressed video",
        "开了「压缩传输（MJPEG）」时锐化减半，免得把压缩方块和字边的波纹一起放大。不压缩时不起作用":
            "Halves sharpening when Compressed transfer (MJPEG) is on, so compression blocks and ringing around text aren't amplified. No effect for uncompressed video.",
        "锐化": "Sharpening", "关": "Off", "柔和": "Soft", "标准": "Standard", "锐利": "Sharp", "最锐": "Max",
        "柔和 0.25：边缘稍微清楚一点，几乎没有副作用。1080p 画面推荐": "Soft 0.25: slightly crisper edges, almost no side effects. Recommended for 1080p.",
        "标准 0.5：明显清楚，适合偏软的画面（游戏内部低分辨率渲染、开了动态模糊）": "Standard 0.5: noticeably crisper; good for soft pictures (low internal resolution, motion blur).",
        "锐利 0.75：画面偏糊时试试；草地、树叶在动时可能有点闪": "Sharp 0.75: try it if the picture looks blurry; grass and leaves may shimmer a little when moving.",
        "最锐 1.0：最强；文字边缘可能出现白边，草地闪烁，不建议一直开": "Max 1.0: strongest; may cause white halos around text and shimmering grass. Not recommended all the time.",
        // 设置：显示 / 高级
        "显示": "Display", "帧数和延迟浮窗": "FPS & latency overlay",
        "画面左上角，每秒刷新（⌘I）。帧数 = 游戏本身每秒的新画面；延迟 = 采集卡交给电脑到送上屏幕":
            "Top left of the picture, updated every second (⌘I). FPS = new frames per second from the game; latency = from the capture card to the screen.",
        "全屏时鼠标不动 2 秒隐藏": "Hide the pointer after 2 s in full screen", "只在全屏时生效，鼠标一动就出来": "Full screen only; moving the mouse shows it again",
        "高级": "Advanced", "收起": "Collapse", "展开": "Expand", "一般不用改。画面有问题时再展开调。": "Usually no need to change these. Expand only if something looks wrong.",
        "重复帧判断": "Duplicate detection", "宽松": "Loose", "灵敏": "Sensitive",
        "宽松：画面静止时不容易误判成新画面": "Loose: still pictures are less likely to be mistaken for new frames",
        "标准：一般情况用这个": "Standard: use this normally",
        "灵敏：只有准星、小地图在动时也能认出新画面": "Sensitive: detects new frames even when only the crosshair or minimap moves",
        "切镜头时不补帧": "Skip interpolation on scene cuts",
        "关闭：切镜头也补，过渡那一帧可能是两个画面叠在一起": "Off: interpolates across cuts; the transition frame may blend two scenes",
        "标准：画面突然整个换掉时跳过补帧": "Standard: skips interpolation when the whole picture changes suddenly",
        "灵敏：变化更小也跳过，鬼影少但没那么顺": "Sensitive: skips on smaller changes too — less ghosting, slightly less smooth",
        "补帧分辨率": "Interpolation resolution", "原分辨率": "Native",
        "画质最好；1080p 每帧补帧约 20ms（2K / 4K 也按 1080p 补）": "Best quality; about 20 ms per frame at 1080p (2K / 4K are interpolated at 1080p)",
        "更快（每帧约 11ms），补出来的帧略软": "Faster (about 11 ms per frame); interpolated frames are slightly softer",
        "补帧锐化": "Interpolation sharpening",
        "清晰放大开着时这一项不起作用：真实帧和补出来的帧都按「画质 → 锐化」统一处理，前后一致不闪":
            "Has no effect while Sharp scaling is on: real and interpolated frames are both sharpened by Image → Sharpening, so they match and don't flicker.",
        "只补帧": "Interpolated only", "全部": "All", "关：不锐化": "Off: no sharpening",
        "只锐化补出来的帧（柔和），真实帧不动": "Sharpen interpolated frames only (soft); real frames untouched",
        "所有帧都锐化（柔和），观感一致": "Sharpen all frames (soft) for a consistent look",
        "延迟和流畅": "Latency vs smoothness", "低延迟": "Low latency", "平衡": "Balanced", "流畅": "Smooth",
        "低延迟：排队最短；游戏帧率不稳时每秒会丢几帧": "Low latency: shortest queue; drops a few frames per second when the game's frame rate is unstable",
        "平衡：一般情况用这个，不丢帧": "Balanced: use this normally, no dropped frames",
        "流畅：多排一帧，帧率很不稳的游戏更稳；延迟多约 17ms": "Smooth: queues one more frame, steadier for very unstable games; about 17 ms more latency",
        "补帧太慢就跳过": "Skip slow interpolations",
        "偶尔有一帧补得特别慢（超过 30ms）时不显示它，避免顿一下": "If a frame occasionally takes too long (over 30 ms), it isn't shown, to avoid a hitch",
        "画面几乎不动时不补帧": "Don't interpolate near-still pictures",
        "加载转圈、跳动的数字：每帧直接显示，不糊也不卡；画面一动就恢复补帧": "Loading spinners, ticking numbers: shown directly, no blur or stutter; interpolation resumes as soon as the picture moves",
        "标出补出来的帧": "Mark interpolated frames", "补出来的帧右上角闪一个橙点，用来确认补帧在工作": "An orange dot flashes at the top right of interpolated frames, to confirm interpolation is working",
        "恢复默认": "Reset to defaults",
        // 状态
        "状态": "Status", "显示帧率": "Display FPS", "游戏帧率": "Game FPS", "采集帧率": "Capture FPS", "补帧耗时": "Interpolation time",
        "已关闭": "Off", "采集到程序": "Capture → app", "程序内延迟": "In-app latency", "丢帧": "Dropped frames",
        "切场景 / 太慢跳过": "Scene cuts / slow skips", "打开日志文件夹": "Open log folder",
        // 选主机
        "GTA 6 内部 1440p，PSSR 放大到接近 4K（四台里最清楚），稳定 30 帧": "GTA 6: 1440p internal, PSSR upscaled to near 4K (sharpest of the four), steady 30 fps",
        "GTA 6 内部 1440p（TAA 放大），30 帧，激烈场景掉到 20 多": "GTA 6: 1440p internal (TAA upscaling), 30 fps, mid-20s in heavy scenes",
        "GTA 6 内部 1440p（TAA 放大），30 帧，偶尔掉到 20 出头": "GTA 6: 1440p internal (TAA upscaling), 30 fps, occasionally low 20s",
        "GTA 6 内部 720p，FSR 放大到约 1080p，二十多到 30 帧": "GTA 6: 720p internal, FSR upscaled to about 1080p, 20s to 30 fps",
        "1440p（菜单里没有就选 4K）": "1440p (4K if 1440p isn't in the menu)",
        "PSSR 重建出来的细节只有输出 2160p 才拿得到": "PSSR-reconstructed detail is only available with 2160p output",
        "游戏内部就是 1440p，输出 4K 会先被主机放大、再被采集卡缩回来，多两次缩放": "The game renders at 1440p; 4K output is upscaled by the console and scaled back down by the capture card — two extra resamples",
        "游戏按输出分辨率重建画面，输出 2160p 细节最多；采集 1080p 时正好缩小 2 倍，画面最干净": "The game reconstructs the image at the output resolution, so 2160p output has the most detail; capturing at 1080p is then an exact 2× downscale — the cleanest picture",
        "内部只有 720p、放大到约 1080p，输出更高没有更多细节": "Only 720p internally, upscaled to about 1080p; higher output adds no detail",
        "PSSR 本来就很锐，再锐化容易出白边": "PSSR is already sharp; more sharpening causes halos",
        "TAA 放大的画面偏软一点": "TAA upscaling looks a little soft", "内部只有 720p，画面最软": "Only 720p internally — the softest picture",
        "选你的主机": "Choose your console",
        "按主机套用推荐配置（按 GTA 6 这类 30 帧游戏定的），以后可以在设置里改": "Applies recommended settings for your console (tuned for 30 fps games like GTA 6). You can change them later in Settings.",
        "关闭（以后可在首页或 设置 → 输入来源 里重新打开）": "Close (reopen it later from the home page or Settings → Source)",
        "采集分辨率": "Capture resolution", "（不支持）": " (not supported)", "60 帧": "60 fps", "120 帧": "120 fps",
        "1080p 60 帧最稳，补帧最高也是 1080p。": "1080p 60 fps is the most stable, and interpolation is 1080p at most.",
        "120 帧只有主机输出 120Hz 时才有用": "120 fps only helps when the console outputs 120 Hz",
        "主机上要改的": "Change on the console", "· HDR 一定要关：采集卡不支持 HDR，开着画面发灰、偏暗": "· Turn HDR off: capture cards don't support HDR; the picture looks grey and dark",
        "点一台主机看推荐配置": "Click a console to see its recommended settings", "应用": "Apply", "主机输出": "Console output", "开": "On",
        "30 帧补到 60 帧": "30 → 60 fps",
        // main / 提示
        "指定窗口": "Window", "测试图案": "Test pattern", "输入": "Input", "正在查找画面来源…": "Looking for a video source…",
        "声音直通：开": "Audio pass-through: on", "（系统全屏）": " (full screen)",
        "关于 FrameInterp": "About FrameInterp", "隐藏 FrameInterp": "Hide FrameInterp", "退出 FrameInterp": "Quit FrameInterp",
        "开启补帧（空格）": "Frame interpolation (Space)", "原分辨率（画质好，1080p 约 20ms）": "Native (best quality, about 20 ms at 1080p)",
        "720p（更快，约 11ms，中间帧略软）": "720p (faster, about 11 ms, slightly softer in-between frames)", "设置…": "Settings…",
        "全屏 / 退出全屏（f，Esc 退出）": "Full screen on/off (F, Esc to exit)", "帧数和延迟": "FPS & latency",
        "（没有检测到采集卡）": "(No capture card detected)", "屏幕上的窗口": "Windows on screen", "（没有窗口，或没有录屏权限）": "(No windows, or no screen recording permission)",
        "测试图案（30 帧 + 不规则重复）": "Test pattern (30 fps + irregular duplicates)", "停止采集": "Stop capturing",
        "补帧：开": "Interpolation: on", "补帧：关": "Interpolation: off",
        "⚠ 串流窗口一直没回来，请重新选择窗口": "⚠ The streaming window didn't come back. Please choose the window again.",
        "没有找到采集卡：确认采集卡已经接到 Mac（建议 USB 3 接口），再点「连接」": "No capture card found: make sure it's connected to the Mac (USB 3 recommended), then click Connect",
        "没有摄像头权限：系统设置 → 隐私与安全性 → 摄像头，打开 FrameInterp（或终端）": "No camera permission: System Settings → Privacy & Security → Camera, enable FrameInterp (or Terminal)",
        "读不到窗口：需要录屏权限\n系统设置 → 隐私与安全性 → 录屏与系统录音，打开 FrameInterp（或终端），然后重新打开程序":
            "Can't read windows: screen recording permission needed\nSystem Settings → Privacy & Security → Screen & System Audio Recording, enable FrameInterp (or Terminal), then reopen the app",
        "没找到 iPhone 镜像窗口：先打开「iPhone 镜像」App，再在「输入」菜单里选它": "iPhone Mirroring window not found: open the iPhone Mirroring app first, then choose it in the Input menu",
        "⚠ 网页版 Xbox 串流暂不支持：浏览器失去焦点会暂停画面": "⚠ Web Xbox streaming is not supported yet: the page pauses when the browser loses focus",
        "正在启动补帧…": "Starting interpolation…", "正在启动补帧（几秒内）…": "Starting interpolation (a few seconds)…",
        "1080p 补帧不可用，自动改用 720p 补帧…": "1080p interpolation unavailable, switching to 720p…",
        "1080p 补帧太慢，自动改用 720p 补帧…": "1080p interpolation is too slow, switching to 720p…",
        "⚠ 补帧不可用，只显示原画面": "⚠ Interpolation unavailable, showing the original picture",
        "补帧就绪（这台 Mac 用 720p 补帧）": "Interpolation ready (720p on this Mac)", "补帧就绪": "Interpolation ready",
        "Apple 低延迟补帧 · 已就绪": "Apple low-latency interpolation · ready",
        "采集卡开了但没有画面：检查主机是否开机、HDMI 是否插好": "The capture card is open but there's no picture: check that the console is on and HDMI is connected",
        "这个格式没有画面（可能是 USB 带宽不够），正在换一个…": "No picture with this format (probably not enough USB bandwidth), trying another…",
        "⚠ 打开失败": "⚠ Failed to open", "⚠ 没有麦克风权限，声音不直通": "⚠ No microphone permission, audio is not passed through",
        "⚠ 没找到采集卡的音频设备，可在设置里手动选音频输入": "⚠ Capture card audio device not found; choose an audio input in Settings",
        "— FPS   延迟 —": "— FPS   Latency —", "无": "None", "不缩放": "no scaling", "三次插值": "cubic", "按比例取样（防闪烁）": "area sampling (anti-flicker)",
        "不锐化": "no sharpening", "这台机器不支持 VTLowLatencyFrameInterpolation": "This Mac doesn't support VTLowLatencyFrameInterpolation",
        "远程游玩": "Remote Play", "未知": "Unknown",
        // 模拟器（2026-11-24）
        "模拟器": "Emulator", "未发现模拟器": "No emulator found", "支持的模拟器": "Supported emulators", "多平台": "Multi-system",
        "从 Dolphin、PCSX2、RetroArch 等模拟器的窗口取画面补帧（2 倍）。手柄要在模拟器里打开后台输入。":
            "Interpolates (2×) the window of an emulator such as Dolphin, PCSX2 or RetroArch. Turn on background input in the emulator so the controller works.",
        "这些模拟器的窗口会被自动认出来，排在窗口列表前面。列表外的模拟器也能用，在「选其他窗口」里选它的窗口就行":
            "Windows of these emulators are recognized automatically and listed first. Other emulators work too — pick their window under \"Choose another window\".",
        "· 键盘鼠标操作不了：FrameInterp 在前台显示补帧画面，键盘鼠标会被它收走，请用手柄":
            "· Keyboard and mouse won't reach the emulator: FrameInterp is in front showing the interpolated picture. Use a controller.",
        "· 补帧会多 30～50ms 延迟。60 帧补到 120 主要是看起来更顺":
            "· Interpolation adds 30–50 ms of latency. Going from 60 to 120 fps mainly makes motion look smoother.",
        "模拟器的窗口排在前面。手柄要在模拟器里打开后台输入。": "Emulator windows are listed first. Turn on background input in the emulator for the controller.",
        "在模拟器设置里打开「后台输入（Background Input）」，关掉「失去焦点时暂停（Pause on focus loss）」":
            "In the emulator's settings, turn on Background Input and turn off Pause on focus loss",
        "控制器设置（Controllers）里勾选「Background Input」，不然 FrameInterp 在前台时手柄没反应":
            "In Controllers, tick Background Input — otherwise the controller does nothing while FrameInterp is in front",
        "设置 → Interface 里关掉「Pause On Focus Loss」": "Settings → Interface: turn off Pause On Focus Loss",
        "设置 → System 里关掉「Pause when not focused」": "Settings → System: turn off Pause when not focused",
        "设置 → User Interface 里关掉「Pause Content When Not Active」": "Settings → User Interface: turn off Pause Content When Not Active",
        // 原生 Xbox 串流
        "微软没给登录码": "Microsoft didn't return a sign-in code", "在网页上拒绝了登录": "Sign-in was declined on the web page",
        "登录码过期了，重新点登录": "The sign-in code expired — sign in again", "没有登录信息，重新登录": "Not signed in — sign in again",
        "拿不到转移令牌": "Couldn't get a transfer token", "刷新登录失败": "Couldn't refresh sign-in", "Xbox Live 登录失败": "Xbox Live sign-in failed",
        "串流授权失败": "Streaming authorization failed", "串流服务登录失败": "Couldn't sign in to the streaming service",
        "串流服务没给服务器地址": "The streaming service returned no server address",
        "还没登录 Xbox 账号": "Not signed in to Xbox", "登录后列出你的主机，点一下就能连": "Sign in to list your consoles — one click to connect",
        "复制并打开": "Copy & Open", "取消": "Cancel", "重试": "Retry",
        "登录你的微软账号后，这里会自动继续（15 分钟内有效）": "After you sign in to your Microsoft account this continues automatically (valid for 15 min)",
        "登录没成功": "Sign-in failed", "正在读取主机…": "Loading consoles…", "没找到主机": "No consoles found",
        "主机要打开远程功能：设置 → 设备和连接 → 远程功能": "Turn on remote features on the console: Settings → Devices & connections → Remote features",
        "Xbox 串流设置": "Xbox Streaming",
        "1440p：局域网、网速好时用，Series X / S 都支持": "1440p: for LAN or fast networks; Series X / S",
        "720p：网络差时更稳": "720p: steadier on poor networks", "1080p：一般用这个": "1080p: recommended",
        "下次连接生效。走公网时主机会按网速自己降分辨率": "Applies next connection. Over the internet the console lowers resolution to fit your bandwidth",
        "刷新主机列表": "Refresh Consoles", "退出登录": "Sign Out", "登录 Xbox 账号": "Sign In to Xbox", "连接": "Connect",
        "正在请求主机串流…": "Requesting a stream…", "等主机准备好…": "Waiting for the console…", "正在验证…": "Authorizing…",
        "等了 90 秒主机还没准备好（主机要开机或待机可唤醒）": "The console wasn't ready after 90 s (it must be on, or in standby with wake enabled)",
        "正在建立连接…": "Connecting…", "建 WebRTC 连接失败": "Couldn't create the WebRTC connection",
        "生成 offer 失败": "Couldn't create an offer", "主机没给 answer": "The console sent no answer", "正在连接主机…": "Connecting to the console…",
        "不用采集卡": "No capture card needed",
    ]

    /// 带数字 / 名字的句子：{} 是会变的部分
    static let templates: [(NSRegularExpression, String)] = [
        ("共 {} 个设备，可在设置里换", "{1} devices; switch in Settings"),
        ("用手机或电脑打开 {}，输入登录码", "On your phone or computer open {1} and enter the code"), ("正在连接 {}", "Connecting to {1}"),
        ("补帧 · {} · {} → {}", "Interp · {1} · {2} → {3}"), ("补帧 · {}", "Interp · {1}"), ("直通 · {}", "Direct · {1}"),
        ("画面和声音都从采集卡来，延迟最低。共 {} 个设备，可在设置里换。", "Picture and sound both come from the capture card — lowest latency. {1} devices; switch in Settings."),
        ("应用 {} 配置", "Apply {1} preset"), ("已应用 {} 配置", "{1} preset applied"), ("已重新接上 {}", "Reconnected to {1}"),
        ("正在打开：{}…", "Opening {1}…"), ("找不到设备：{}（已拔出？）", "Device not found: {1} (unplugged?)"), ("窗口已关闭：{}", "Window closed: {1}"),
        ("串流窗口关闭了，正在等 {} 的新窗口…", "The streaming window closed; waiting for a new {1} window…"),
        ("创建补帧器失败（{}x{} 不支持？）", "Couldn't create the interpolator ({1}x{2} not supported?)"),
        ("采集配置失败：{}", "Capture setup failed: {1}"), ("窗口采集启动失败：{}\n（可能需要录屏权限）", "Window capture failed to start: {1}\n(screen recording permission may be needed)"),
        ("{} · 主机输出 {} · 采集 {} {} 帧 · 补帧开 · 锐化 {}（{} 应用）", "{1} · console output {2} · capture {3} {4} fps · interpolation on · sharpening {5} (applied {6})"),
        ("{} 帧/秒", "{1} fps"), ("{} ms（最慢 {}）", "{1} ms (slowest {2})"),
        ("补帧最高按 1080p 做：开补帧时采 {} 也会先降到 1080p；不补帧时更清楚。采集卡带宽不够时会自动退到能跑的档",
         "Interpolation runs at 1080p at most: with interpolation on, {1} capture is scaled down to 1080p first; it's sharper with interpolation off. If USB bandwidth is not enough, a lower format is used automatically."),
        ("设置 → 屏幕和视频 → 视频输出：分辨率 {}，HDR 关，VRR 关，120Hz 输出 关", "Settings → Screen and Video → Video Output: resolution {1}, HDR off, VRR off, 120 Hz output off"),
        ("设置 → 常规 → 电视和显示选项：分辨率 {}，刷新率 60Hz；视频模式里关掉 HDR10、自动 HDR、VRR", "Settings → General → TV & display options: resolution {1}, refresh rate 60 Hz; in Video modes turn off HDR10, Auto HDR and VRR"),
        ("· 设置 → 屏幕和视频 → 视频输出：分辨率 {}，HDR 关，VRR 关，120Hz 输出 关", "· Settings → Screen and Video → Video Output: resolution {1}, HDR off, VRR off, 120 Hz output off"),
        ("· 设置 → 常规 → 电视和显示选项：分辨率 {}，刷新率 60Hz；视频模式里关掉 HDR10、自动 HDR、VRR", "· Settings → General → TV & display options: resolution {1}, refresh rate 60 Hz; in Video modes turn off HDR10, Auto HDR and VRR"),
        ("{} · 最高 {} 帧", "{1} · max {2} fps"), ("{}（{} 帧）", "{1} ({2} fps)"),
        ("采集卡这一档最高只有 {} 帧，比主机输出的少，画面会掉帧。玩游戏建议选能跑满 {} 帧的档",
         "The capture card only does up to {1} fps at this resolution — less than the console outputs, so frames will drop. For gaming, pick a resolution that reaches {2} fps."),
    ].map { pair -> (NSRegularExpression, String) in
        let pattern = "^" + NSRegularExpression.escapedPattern(for: pair.0).replacingOccurrences(of: "\\{\\}", with: "(.+?)") + "$"
        return (try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]), pair.1)
    }

    /// 拼出来的句子：按词组替换（长的先换）。整句表里的条目也参与（拼接的提示由几句整句组成）
    static let fragments: [(String, String)] = {
        let extra: [String: String] = [
            "现在是 2K / 4K 输入，自动用「柔和」。点「关」会连自动一起关": "2K / 4K input: Soft is applied automatically. Choosing Off turns the automatic sharpening off too",
            "关：不额外锐化": "Off: no extra sharpening",
            "（2K / 4K 输入时自动用柔和）": " (Soft is applied automatically for 2K / 4K input)",
            "。只加强明暗边缘，不出彩边": ". Only sharpens brightness edges, so no color fringing",
            "原生串流": "Native streaming",
            "游戏 ": "Game ", " FPS → 显示 ": " FPS → Display ", " · 延迟 ": " · Latency ", " · 补一帧 ": " · Interp ",
            "延迟 ": "Latency ", "游戏": "Game", " · 这个设备不支持": " · not supported by this device",
            "；2K / 4K 输入仍会自动轻度锐化": "; 2K / 4K input still gets light auto-sharpening",
            "\n锐化只加强亮度（明暗）边缘，不动颜色，所以不会出彩边": "\nSharpening only enhances brightness edges, not color, so there are no color fringes",
            "关（默认）：不额外锐化": "Off (default): no extra sharpening",
            "120 帧只有主机输出 120Hz 时才有用": "120 fps only helps when the console outputs 120 Hz",
            "当前：": "Now: ", "放大 ": "upscale ", " 倍 · 三次插值": "× · cubic", "缩小到 ": "downscale to ", " 倍 · ": "× · ",
            "（画面没有放大）": " (not upscaled)", "锐化 ": "sharpening ", "（2K/4K 自动）": " (2K/4K auto)", "（压缩画面减半）": " (halved for compressed)",
            "2K/4K 自动": "2K/4K auto", "压缩画面减半": "halved for compressed", "压缩画面，锐化减半": "compressed, sharpening halved",
            " · 每帧 ": " · per frame ", "，补帧在 ": ", interpolated at ", " 上做": "", "补帧在 ": "Interpolated at ",
            "（Apple 补帧最高 1080p）": " (Apple interpolation is 1080p at most)",
            "⚠ 所选格式没有画面（多半是 USB 带宽不够），已自动改用这个格式": "⚠ The chosen format had no picture (probably not enough USB bandwidth); switched to this format automatically",
            "声音：": "Audio: ", "清晰放大 ": "Sharp scaling ", "画面增强 ": "Enhancer ",
            "⚠ 补帧不可用（": "⚠ Interpolation unavailable (", " 补帧在这台 Mac 上启动失败）": " interpolation failed to start on this Mac)",
            "画面照常显示，只是不补帧。请把 设置 → 状态 →「打开日志文件夹」里最新的日志发给作者": "The picture is shown normally, just not interpolated. Please send the latest log from Settings → Status → Open log folder to the author",
            "（macOS 26 只支持 720p 补帧，升级到 macOS 27 可用 1080p）": " (macOS 26 supports 720p interpolation only; macOS 27 supports 1080p)",
            "（这台 Mac 上 1080p 补帧不可用，自动用 720p）": " (1080p interpolation unavailable on this Mac, using 720p)",
            "（M1 系列芯片 1080p 补帧太慢，自动用 720p）": " (1080p interpolation is too slow on M1-series chips, using 720p)",
            "（1080p 补帧在这台 Mac 上太慢，自动改用 720p）": " (1080p interpolation is too slow on this Mac, switched to 720p)",
            "预热 10 秒仍失败：": "Warm-up still failing after 10 s: ", "startSession 失败：": "startSession failed: ",
            " 屏幕（有线），按比例缩放到 1920×1080": " screen (wired), scaled to 1920×1080",
            "帧/秒，格式 ": " fps, format ", "采集 ": "capture ", " 帧": " fps", "补帧开": "interpolation on",
            "主机输出 ": "console output ", " 应用）": " applied)", "（": " (", "）": ")", "，": ", ", "：": ": ", "；": "; ", "、": ", ", "。": ". ",
        ]
        var all = extra
        for (k, v) in exact where all[k] == nil { all[k] = v }
        return all.sorted { $0.key.count > $1.key.count }
    }()
}
