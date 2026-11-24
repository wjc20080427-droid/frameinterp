import AppKit
import SwiftUI

/// 输入菜单里的一项
struct SourceOption: Identifiable, Hashable {
    enum Group: String { case card = "采集卡", window = "窗口", other = "其他" }
    let id: String
    let title: String
    let group: Group
    let source: Source
    var app = ""             // 窗口：所属 App
    var windowTitle = ""     // 窗口：标题
    var streaming = false    // 窗口：是串流 App
    var unsupported = false  // 窗口：暂不支持（浏览器里的 Xbox 网页串流）
    var emulator = ""        // 窗口：是哪个模拟器的（Emulator.name），空 = 不是模拟器
    var size = ""            // 窗口：大小（点）

    static func == (a: SourceOption, b: SourceOption) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

extension Source {
    var optionID: String {
        switch self {
        case .device(let id, _): return "dev:\(id)"
        case .window(let id, _): return "win:\(id)"
        case .iphone: return "iphone"
        case .test: return "test"
        }
    }
}

/// 界面状态（App 写，界面读；界面上的操作通过回调交给 App）
@MainActor
final class UIModel: ObservableObject {
    @Published var sources: [SourceOption] = []
    @Published var selectedID: String?
    @Published var inputName = ""
    @Published var inputDetail = "未选择"
    @Published var interpOn = false
    @Published var ires = 0
    @Published var interpStatus = "—"
    @Published var showFPS = false
    @Published var showSettings = false
    @Published var isFullScreen = false
    /// 全屏时顶栏和工具栏只在鼠标移动后显示一会儿
    @Published var chromeVisible = true
    /// 左上角红绿灯：最左边按钮离窗口左边的距离、按钮中心离窗口顶部的距离（窗口建好后按实际位置更新）
    @Published var trafficInset: CGFloat = 20
    @Published var trafficCenterY: CGFloat = 26
    @Published var snap = StatsSnapshot()
    @Published var hasInput = false
    @Published var opening = false
    @Published var message: String? // 打开失败等提示（显示在待机画面上）

    // 输入
    @Published var captureHeight = 1080      // 想要的采集分辨率：1080 / 1440 / 2160
    @Published var availableHeights: [Int] = [1080, 1440, 2160] // 当前设备支持的档
    @Published var heightMaxFps: [Int: Int] = [:] // 采集卡每档最高帧率（空 = 不知道 / 不是采集卡）
    @Published var sourceW = 0               // 实际采集到的尺寸
    @Published var sourceH = 0
    @Published var audioOn = true            // 声音直通（关 = 静音）
    // 窗口采集
    @Published var inputMode = 0             // 设置里的输入类型：0 采集卡 / 1 串流窗口
    @Published var screenAccess = false      // 有没有录屏权限（读窗口画面要它）
    @Published var showWindowPicker = false
    @Published var windowKind = 0            // 首页窗口卡片 / 窗口选择器的分页：0 串流 / 1 模拟器
    @Published var showEmulatorList = false  // 支持的模拟器列表
    @Published var showWizard = false       // 配置向导
    var onOpenWizard: () -> Void = {}
    var wizard: WizardModel?
    @Published var windowThumbs: [String: NSImage] = [:]
    var windowOptions: [SourceOption] { sources.filter { $0.group == .window } }
    var onOpenWindowPicker: () -> Void = {}
    var onRequestScreenAccess: () -> Void = {}
    var onRelaunch: () -> Void = {}
    var onWindowAutoCrop: (Bool) -> Void = { _ in }
    @Published var screenAsked = false       // 已经请求过录屏权限（之后提示"重新打开程序"）
    @Published var autoHideCursor = true     // 鼠标 2 秒不动就隐藏
    @Published var windowAutoCrop = true     // 串流窗口：自动裁掉标题栏和黑边
    @Published var subtitleGuard = true      // 字幕保护（补帧时字幕不闪）
    @Published var sharpScale = true         // 清晰放大：三次插值缩放到屏幕大小，2K / 4K 自动轻度锐化
    @Published var autoSharpHiRes = true     // 2K / 4K 输入自动轻度锐化
    @Published var antiFlickerDown = true    // 缩小时按比例取样（防闪烁）
    @Published var compressedSoftSharp = true // 压缩传输时锐化减半
    // 声音：输入（哪个设备的声音）、输出（从哪里放出来）；空 = 自动 / 系统默认
    @Published var audioInID = ""
    @Published var audioOutID = ""
    @Published var audioInputs: [AudioOption] = []
    @Published var audioOutputs: [AudioOption] = []
    @Published var audioInActual = ""        // 实际在用的输入设备名
    var isHiResSource: Bool { sourceW > 1920 || sourceH > 1080 }

    // 调节（保存在本机，下次打开还在）
    @Published var dupLevel = 1      // 重复帧判断：0 宽松 / 1 标准 / 2 灵敏
    @Published var cutLevel = 1      // 切镜头不补帧：0 关 / 1 标准 / 2 灵敏
    @Published var smoothLevel = 1   // 0 低延迟 / 1 平衡 / 2 流畅
    @Published var skipLate = true   // 补帧太慢就跳过
    @Published var stillDirect = true // 画面几乎不动时不补帧（直通）
    @Published var interpSharpLevel = 0 // 补帧时的锐化：0 关 / 1 只锐化补出来的帧 / 2 所有帧
    var interpSharpness: Float { [0, 0.25, 0.25][interpSharpLevel] }
    var interpSharpAll: Bool { interpSharpLevel == 2 }
    /// 旧版的补帧档位（界面上已去掉），只用于日志
    static let presets: [(ires: Int, smooth: Int, isharp: Int)] = [(720, 1, 0), (0, 1, 0), (0, 1, 2)]
    var preset: Int {
        UIModel.presets.firstIndex { $0.ires == ires && $0.smooth == smoothLevel && $0.isharp == interpSharpLevel } ?? 3
    }
    @Published var markInterp = false // 标出补出来的帧
    @Published var advancedOpen = false // 高级选项默认收起
    @Published var sharpLevel = 0     // 0 关 / 1 柔和 / 2 标准 / 3 锐利 / 4 最锐
    @Published var captureFps = 60   // 采集帧率 60 / 120
    @Published var captureMJPEG = false  // 压缩传输（MJPEG）
    @Published var mjpegAvailable: Bool? = nil // 当前采集卡有没有 MJPEG 格式（nil = 还没打开设备）
    @Published var upscaleOn = false  // MetalFX 放大：界面已去掉，始终关
    @Published var enhanceStatus = ""
    var sharpness: Float { [0, 0.25, 0.5, 0.75, 1.0][sharpLevel] }
    var onTuning: () -> Void = {}

    static let defaultsKey = "tuning.v3"
    func loadTuning() {
        let d = UserDefaults.standard
        guard let t = d.dictionary(forKey: UIModel.defaultsKey) else { return }
        dupLevel = t["dup"] as? Int ?? dupLevel
        cutLevel = t["cut"] as? Int ?? cutLevel
        smoothLevel = t["smooth"] as? Int ?? smoothLevel
        skipLate = t["skipLate"] as? Bool ?? skipLate
        stillDirect = t["still"] as? Bool ?? stillDirect
        interpSharpLevel = t["isharp"] as? Int ?? interpSharpLevel
        markInterp = t["mark"] as? Bool ?? markInterp
        ires = t["ires"] as? Int ?? ires
        if ires == 540 { ires = 720 } // 540p 已经去掉
        showFPS = (t["fps"] as? Bool ?? showFPS) || (t["perf"] as? Bool ?? false)
        sharpLevel = t["sharp"] as? Int ?? sharpLevel
        upscaleOn = false
        captureFps = t["capfps"] as? Int ?? captureFps
        captureHeight = t["capres"] as? Int ?? captureHeight
        captureMJPEG = t["mjpeg"] as? Bool ?? captureMJPEG
        audioOn = t["audio"] as? Bool ?? audioOn
        autoHideCursor = t["hidecur"] as? Bool ?? autoHideCursor
        windowAutoCrop = t["wincrop"] as? Bool ?? windowAutoCrop
        subtitleGuard = t["subguard"] as? Bool ?? subtitleGuard
        sharpScale = t["sharpscale"] as? Bool ?? sharpScale
        autoSharpHiRes = t["autosharp"] as? Bool ?? autoSharpHiRes
        antiFlickerDown = t["widedown"] as? Bool ?? antiFlickerDown
        compressedSoftSharp = t["mjsharp"] as? Bool ?? compressedSoftSharp
        audioInID = t["audioIn"] as? String ?? audioInID
        audioOutID = t["audioOut"] as? String ?? audioOutID
    }
    func saveTuning() {
        UserDefaults.standard.set(["dup": dupLevel, "cut": cutLevel, "smooth": smoothLevel, "skipLate": skipLate, "still": stillDirect, "isharp": interpSharpLevel,
                                   "mark": markInterp, "ires": ires, "fps": showFPS,
                                   "sharp": sharpLevel, "upscale": upscaleOn, "capfps": captureFps,
                                   "capres": captureHeight, "mjpeg": captureMJPEG, "audio": audioOn, "audioIn": audioInID, "audioOut": audioOutID, "hidecur": autoHideCursor, "wincrop": windowAutoCrop, "subguard": subtitleGuard, "sharpscale": sharpScale, "autosharp": autoSharpHiRes, "widedown": antiFlickerDown, "mjsharp": compressedSoftSharp], forKey: UIModel.defaultsKey)
    }
    func resetTuning() {
        dupLevel = 1; cutLevel = 1; smoothLevel = 1; skipLate = true; stillDirect = true; markInterp = false; sharpLevel = 0; interpSharpLevel = 0
        onTuning()
    }

    /// 档位 → 实际参数
    var dupParams: (thr: Double, pct: Double) { [(1.0, 0.15), (0.5, 0.05), (0.25, 0.02)][dupLevel] }
    var cutThreshold: Double { [Double.infinity, 40, 25][cutLevel] }
    var queueLimit: Int { [3, 4, 5][smoothLevel] } // 实测队列 3 在节奏不均匀时每秒丢 4~5 帧，所以平衡用 4
    var skipLateMs: Double { skipLate ? 30 : 0 }

    var onSelect: (Source?) -> Void = { _ in }
    var onStartStop: () -> Void = {}
    var onWindowButton: (Int) -> Void = { _ in } // 0 关闭 / 1 最小化 / 2 全屏
    var onInterp: (Bool) -> Void = { _ in }
    var onIres: (Int) -> Void = { _ in }
    var onShowFPS: (Bool) -> Void = { _ in }
    var onFullScreen: () -> Void = {}
    var onRefresh: () -> Void = {}
    var onOpenLogs: () -> Void = {}
    var onCaptureFps: (Int) -> Void = { _ in }
    var onCaptureMJPEG: (Bool) -> Void = { _ in }
    var onCaptureHeight: (Int) -> Void = { _ in }
    var onAudioIn: (String) -> Void = { _ in }
    var onAudioOut: (String) -> Void = { _ in }
    var onRefreshAudio: () -> Void = {}
    var onAudio: (Bool) -> Void = { _ in }

    nonisolated static func resName(_ h: Int) -> String { [1080: "1080p", 1440: "2K", 2160: "4K"][h] ?? "\(h)p" }
}

/// 音频设备选项（输入：AVCaptureDevice.uniqueID；输出：CoreAudio 设备 UID）
struct AudioOption: Identifiable, Hashable {
    let id: String
    let name: String
}

// MARK: - 配色（2026-11-21 换成自己的：偏蓝的深色底，鸢尾蓝表示"打开 / 主要操作"，薄荷绿表示"已连接 / 运行中"。
// 原来参考 Genki Arcade 的珊瑚红 + 青绿，准备开源前换掉）

enum Theme {
    static let bg = Color(red: 11 / 255, green: 12 / 255, blue: 17 / 255)
    static let surface = Color(red: 22 / 255, green: 24 / 255, blue: 33 / 255)
    static let panel = Color(red: 17 / 255, green: 19 / 255, blue: 26 / 255)
    static let border = Color.white.opacity(0.08)
    static let borderHover = Color.white.opacity(0.2)
    static let text = Color(red: 245 / 255, green: 245 / 255, blue: 245 / 255)
    static let muted = text.opacity(0.55)
    static let faint = text.opacity(0.35)
    static let ok = Color(red: 96 / 255, green: 220 / 255, blue: 150 / 255)       // 薄荷绿：已连接 / 运行中
    static let accent = Color(red: 120 / 255, green: 132 / 255, blue: 255 / 255)  // 鸢尾蓝：打开 / 主要操作
    static let blue = Color(red: 70 / 255, green: 158 / 255, blue: 246 / 255)
    static let amber = Color(red: 245 / 255, green: 180 / 255, blue: 70 / 255)
    static let violet = Color(red: 160 / 255, green: 140 / 255, blue: 250 / 255)

    /// 小号大写标签（"INPUT" 这种）
    static func label(_ size: CGFloat = 10) -> Font { .system(size: size, weight: .semibold) }
    static let topBarH: CGFloat = 52
    static let toolBarH: CGFloat = 60
}

// MARK: - 根视图：顶栏 / 画面 / 底部工具栏，设置面板从左下角弹出

struct RootView: View {
    @ObservedObject var model: UIModel
    let video: NSView

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                Theme.bg
                VStack(spacing: 0) {
                    if !model.isFullScreen { TopBar(model: model) }
                    Stage(model: model, video: video)
                    if !model.isFullScreen { BottomBar(model: model) }
                }
                // 全屏：顶栏和工具栏浮在画面上，鼠标一动就出来，停 2.5 秒自动收起
                if model.isFullScreen && model.chromeVisible {
                    VStack(spacing: 0) {
                        TopBar(model: model)
                            .background(LinearGradient(colors: [.black.opacity(0.85), .black.opacity(0)], startPoint: .top, endPoint: .bottom))
                        Spacer()
                        BottomBar(model: model)
                            .background(LinearGradient(colors: [.black.opacity(0), .black.opacity(0.85)], startPoint: .top, endPoint: .bottom))
                    }
                    .transition(.opacity)
                }
                if model.showWindowPicker {
                    WindowPicker(model: model)
                        .transition(.opacity)
                }
                if model.showEmulatorList {
                    EmulatorList(model: model)
                        .transition(.opacity)
                }
                if model.showWizard, let w = model.wizard {
                    SetupWizardView(w: w)
                        .transition(.opacity)
                }
                if model.showSettings {
                    // 设置按钮在坞的中间，面板就从坞上方居中弹出（像 Windows 11 的开始菜单）
                    SettingsPanel(model: model)
                        .frame(width: 360)
                        .frame(maxHeight: max(240, geo.size.height - Theme.topBarH - Theme.toolBarH - 28))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, Theme.toolBarH + 4)
                        .frame(maxWidth: .infinity)
                        .transition(.opacity.combined(with: .offset(y: 8)))
                }
            }
        }
        .foregroundStyle(Theme.text)
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.18), value: model.showSettings)
        .animation(.easeOut(duration: 0.18), value: model.showWindowPicker)
        .animation(.easeOut(duration: 0.18), value: model.showWizard)
        .animation(.easeOut(duration: 0.18), value: model.showEmulatorList)
        .animation(.easeOut(duration: 0.25), value: model.chromeVisible)
    }
}

/// 把 AppKit 的显示视图放进 SwiftUI
struct VideoHost: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
    /// 画面没有"自己的大小"：给多大就用多大
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 320, height: proposal.height ?? 180)
    }
}

// MARK: - 顶栏

struct TopBar: View {
    @ObservedObject var model: UIModel

    var body: some View {
        HStack(spacing: 12) {
            if !model.isFullScreen { TrafficLights(model: model).padding(.trailing, 6) }
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 22, height: 22)
                Text("FrameInterp").font(.system(size: 14, weight: .bold)).tracking(0.3)
            }
            StatusPill(model: model)
            Spacer(minLength: 12)
            if model.hasInput {
                Text(model.inputName)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            StartButton(model: model)
        }
        .padding(.horizontal, 16)
        .frame(height: Theme.topBarH)
        .background {
            if !model.isFullScreen {
                Theme.bg.gesture(WindowDragGesture())
                    .overlay(alignment: .bottom) { Theme.border.frame(height: 1) }
            }
        }
    }
}

/// 自己画的红绿灯（和系统的一样：鼠标移上去显示符号）
struct TrafficLights: View {
    @ObservedObject var model: UIModel
    @State private var hover = false
    var body: some View {
        HStack(spacing: 8) {
            light(Color(red: 1, green: 0.37, blue: 0.34), "xmark", 0)
            light(Color(red: 1, green: 0.74, blue: 0.18), "minus", 1)
            light(Color(red: 0.16, green: 0.79, blue: 0.25), "arrow.up.left.and.arrow.down.right", 2)
        }
        .onHover { hover = $0 }
    }
    private func light(_ c: Color, _ icon: String, _ i: Int) -> some View {
        Button { model.onWindowButton(i) } label: {
            ZStack {
                Circle().fill(c)
                Circle().strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5)
                if hover { Image(systemName: icon).font(.system(size: 7, weight: .heavy)).foregroundStyle(.black.opacity(0.55)) }
            }
            .frame(width: 12, height: 12)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

struct StatusPill: View {
    @ObservedObject var model: UIModel

    private var state: (String, Color) {
        let s = model.snap
        if model.opening { return ("连接中", Theme.amber) }
        guard model.hasInput else { return (model.message != nil ? "出错" : "未连接", model.message != nil ? Theme.amber : Theme.faint) }
        let res = model.sourceH > 0 ? UIModel.resName(model.sourceH) : ""
        if model.interpOn && s.interpOn && s.displayed > 0 { return ("补帧 · \(res) · \(s.unique) → \(s.displayed)", Theme.ok) }
        if model.interpOn { return ("补帧 · \(res)", Theme.ok) }
        return ("直通 · \(res)\(model.captureFps == 120 ? "120" : "60")", Theme.ok)
    }

    var body: some View {
        let (t, c) = state
        HStack(spacing: 6) {
            Circle().fill(c).frame(width: 6, height: 6)
                .shadow(color: c.opacity(0.8), radius: c == Theme.faint ? 0 : 3)
            Text(t).font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 10).frame(height: 24)
        .background(Theme.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.border))
    }
}

/// 右上角：连接 / 断开（胶囊按钮：没连接时实心蓝，连接后描边）
struct StartButton: View {
    @ObservedObject var model: UIModel
    var body: some View {
        let running = model.hasInput || model.opening
        PillButton(title: running ? "断开" : "连接", icon: running ? "bolt.slash.fill" : "bolt.fill", filled: !running) { model.onStartStop() }
            .help(running ? "断开：停止采集" : "连接选中的采集卡")
    }
}

// MARK: - 画面区域

struct Stage: View {
    @ObservedObject var model: UIModel
    let video: NSView

    var body: some View {
        ZStack {
            // 画面固定 16:9；显示视图一直在层级里（显示链路不重建），没有输入时被待机页盖住
            VideoHost(view: video)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: model.isFullScreen ? 0 : 8, style: .continuous))
                .overlay {
                    if !model.isFullScreen {
                        RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(model.isFullScreen ? 0 : 16)
            if !model.hasInput && !model.opening {
                IdleView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.bg)
            }
        }
        .background(model.isFullScreen ? Color.black : Theme.bg)
        .contentShape(Rectangle())
        .onTapGesture { if model.showSettings { model.showSettings = false } }
    }
}

/// 没有输入时的首页（2026-11-21 重做：原来的布局、文案和 Genki Arcade 网页太像——居中大标题、01/02/03 三张步骤卡、
/// 带 ◆ 的横条——准备开源前改成自己的：左对齐的标题，两张并排的"来源"卡片（采集卡 / 串流窗口），下面一行主机配置）
struct IdleView: View {
    @ObservedObject var model: UIModel

    private var cards: [SourceOption] { model.sources.filter { $0.group == .card } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // 标题：左对齐，小图标 + 名字 + 一句话
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                    // 名字右边是原来首页大标题的样式（粗体 Build For + 细体 Apple Silicon），缩到和名字一样大
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Text("FrameInterp").font(.system(size: 30, weight: .bold, design: .rounded))
                        (Text("Build For ").font(.system(size: 30, weight: .heavy))
                         + Text("Apple Silicon").font(.system(size: 30, weight: .thin)))
                            .tracking(-0.6)
                            .foregroundStyle(Theme.muted)
                    }
                    .lineLimit(1).minimumScaleFactor(0.6)
                }
                .padding(.bottom, 4)
                Text("选择画面来源").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.faint)
                HStack(alignment: .top, spacing: 14) {
                    CaptureSourceCard(model: model, cards: cards)
                    WindowSourceCard(model: model)
                }
                if let w = model.wizard { WizardBanner(w: w, model: model) }
                if let m = model.message {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.accent)
                        Text(m).font(.system(size: 12)).foregroundStyle(Theme.text.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.accent.opacity(0.5)))
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.vertical, 40)
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
    }
}

/// 首页的来源卡片外框：上面图标 + 标题 + 状态，中间说明，下面按钮
struct SourceCard<Actions: View>: View {
    let icon: String, title: String, status: String, statusOn: Bool, detail: String, tint: Color
    var tabs: [String] = []                 // 有的话标题下面显示分页（串流 / 模拟器）
    var tab = 0
    var onTab: (Int) -> Void = { _ in }
    @ViewBuilder let actions: Actions
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 18, weight: .semibold)).foregroundStyle(tint)
                    .frame(width: 36, height: 36)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                Text(title).font(.system(size: 16, weight: .bold))
                Spacer(minLength: 4)
                HStack(spacing: 5) {
                    Circle().fill(statusOn ? Theme.ok : Theme.faint).frame(width: 6, height: 6)
                    Text(status).font(.system(size: 11, weight: .medium)).foregroundStyle(statusOn ? Theme.ok : Theme.muted).lineLimit(1)
                }
            }
            if !tabs.isEmpty { Segmented(labels: tabs, selection: tab, onSelect: onTab) }
            Text(detail).font(.system(size: 12)).foregroundStyle(Theme.muted).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack(spacing: 8) { actions }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border))
    }
}

/// 采集卡（HDMI）
struct CaptureSourceCard: View {
    @ObservedObject var model: UIModel
    let cards: [SourceOption]
    var body: some View {
        SourceCard(icon: "cable.connector", title: "采集卡（HDMI）",
                   status: cards.first?.title ?? "未检测到", statusOn: !cards.isEmpty,
                   detail: cards.isEmpty
                       ? "主机 HDMI 接采集卡，采集卡用 USB-C 接到 Mac（USB 3 以上）。插上后这里会显示设备名，不用装驱动。"
                       : "画面和声音都从采集卡来，延迟最低。" + (cards.count > 1 ? "共 \(cards.count) 个设备，可在设置里换。" : ""),
                   tint: Theme.ok) {
            if cards.isEmpty {
                PillButton(title: "重新检测", icon: "arrow.clockwise", filled: false) { model.onRefresh() }
            } else {
                PillButton(title: "连接", icon: "bolt.fill", filled: true) { model.onStartStop() }
            }
        }
    }
}

/// 窗口来源：分两页——串流（PS Remote Play、Moonlight、Chiaki…；网页版 Xbox 串流暂不支持）和模拟器（Dolphin、PCSX2…）。
/// 两者都是抓窗口画面补帧，但要做的准备不同，分开说明、分开找窗口
struct WindowSourceCard: View {
    @ObservedObject var model: UIModel
    var body: some View {
        let emu = model.windowKind == 1
        let found = model.windowOptions.filter { emu ? !$0.emulator.isEmpty : $0.streaming }
        let status = !model.screenAccess ? "需要录屏权限"
            : (found.first.map { $0.app } ?? (emu ? "未发现模拟器" : "未发现串流 App"))
        let detail = !model.screenAccess
            ? "要读取别的 App 的窗口，需要在系统设置里打开「录屏与系统录音」权限。"
            : emu
                ? L("从 Dolphin、PCSX2、RetroArch 等模拟器的窗口取画面补帧（2 倍）。手柄要在模拟器里打开后台输入。") + (Lang.english ? " " : "") + Emulator.refreshNote
                : "从 PS Remote Play、Moonlight、Chiaki 等串流 App 的窗口取画面补帧，不用采集卡。暂不支持网页版 Xbox 串流（xbox.com/play）"
        SourceCard(icon: emu ? "gamecontroller" : "macwindow.on.rectangle", title: "窗口",
                   status: status, statusOn: model.screenAccess && !found.isEmpty, detail: detail, tint: Theme.violet,
                   tabs: ["串流", "模拟器"], tab: model.windowKind, onTab: { model.windowKind = $0 }) {
            if !model.screenAccess {
                PillButton(title: "授权录屏", icon: "lock.open", filled: false) { model.onOpenWindowPicker() }
            } else if let first = found.first {
                PillButton(title: "连接", icon: "bolt.fill", filled: true) { model.onSelect(first.source) }
                PillButton(title: "选其他窗口", icon: "rectangle.on.rectangle", filled: false) { model.onOpenWindowPicker() }
            } else {
                PillButton(title: "选择窗口", icon: "rectangle.on.rectangle", filled: false) { model.onOpenWindowPicker() }
            }
            if emu {
                PillButton(title: "支持的模拟器", icon: "list.bullet", filled: false) { model.showEmulatorList = true }
            }
        }
    }
}

/// 支持的模拟器：名字、主机、要在模拟器里改什么
struct EmulatorList: View {
    @ObservedObject var model: UIModel
    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
                .onTapGesture { model.showEmulatorList = false }
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("支持的模拟器").font(.system(size: 16, weight: .bold))
                        Text("这些模拟器的窗口会被自动认出来，排在窗口列表前面。列表外的模拟器也能用，在「选其他窗口」里选它的窗口就行")
                            .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    IconSquare(icon: "xmark", help: "关闭") { model.showEmulatorList = false }
                }
                .padding(18)
                Theme.border.frame(height: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Emulator.all) { e in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(e.name).font(.system(size: 13, weight: .semibold))
                                    Text(e.system).font(.system(size: 11)).foregroundStyle(Theme.faint)
                                }
                                .frame(width: 130, alignment: .leading)
                                Text(e.tip).font(.system(size: 12)).foregroundStyle(Theme.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 9)
                            Theme.border.frame(height: 1)
                        }
                    }
                    .padding(.horizontal, 18)
                }
                .frame(maxHeight: 400)
                VStack(alignment: .leading, spacing: 4) {
                    Hint("· 键盘鼠标操作不了：FrameInterp 在前台显示补帧画面，键盘鼠标会被它收走，请用手柄")
                    Hint("· " + Emulator.refreshNote)
                    Hint("· 补帧会多 30～50ms 延迟。60 帧补到 120 主要是看起来更顺")
                }
                .padding(18)
            }
            .frame(width: 640)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
            .shadow(color: .black.opacity(0.6), radius: 30, y: 10)
        }
    }
}

/// 胶囊按钮：实心 = 主要操作，描边 = 次要
struct PillButton: View {
    let title: String, icon: String, filled: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .bold))
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(filled ? Color.black : Theme.text)
            .padding(.horizontal, 14).frame(height: 30)
            .background(filled ? Theme.accent : Theme.surface.opacity(0.01), in: Capsule())
            .overlay(Capsule().strokeBorder(filled ? Color.clear : Theme.borderHover))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// 待机页上的"配置向导"横条：没配置过时请用户先配置，配置过显示当前配置
struct WizardBanner: View {
    @ObservedObject var w: WizardModel
    @ObservedObject var model: UIModel

    var body: some View {
        let configured = !w.appliedSummary.isEmpty
        HStack(spacing: 12) {
            Image(systemName: "gamecontroller.fill").font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 36, height: 36)
                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(configured ? "主机配置" : "按主机一键设置").font(.system(size: 14, weight: .bold))
                Text(configured ? w.appliedSummary : "PS5 / PS5 Pro / Xbox Series S / X：自动设好采集分辨率、补帧和锐化")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            PillButton(title: configured ? "换主机" : "选主机", icon: "gamecontroller", filled: false) { model.onOpenWizard() }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(configured ? Theme.border : Theme.accent.opacity(0.45)))
    }
}

/// 选择窗口：每个窗口一张预览卡片，串流 App 排前面
struct WindowPicker: View {
    @ObservedObject var model: UIModel
    /// 当前分页要找的窗口排前面（串流页：串流 App；模拟器页：模拟器），其他保持原来的顺序
    private var sortedWindows: [SourceOption] {
        let w = model.windowOptions
        let hit: (SourceOption) -> Bool = model.windowKind == 1 ? { !$0.emulator.isEmpty } : { $0.streaming }
        return w.filter(hit) + w.filter { !hit($0) }
    }
    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
                .onTapGesture { model.showWindowPicker = false }
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("选择要补帧的窗口").font(.system(size: 16, weight: .bold))
                        Text(model.windowKind == 1 ? "模拟器的窗口排在前面。手柄要在模拟器里打开后台输入。" : "串流 App 的窗口排在前面。窗口可以放在任何地方，被挡住也没关系。")
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Segmented(labels: ["串流", "模拟器"], selection: model.windowKind) { model.windowKind = $0 }
                        .frame(width: 160)
                    IconSquare(icon: "arrow.clockwise", help: "刷新") { model.onOpenWindowPicker() }
                    IconSquare(icon: "xmark", help: "关闭") { model.showWindowPicker = false }
                }
                .padding(18)
                Theme.border.frame(height: 1)
                if !model.screenAccess {
                    VStack(spacing: 12) {
                        Image(systemName: "lock.rectangle.on.rectangle").font(.system(size: 30)).foregroundStyle(Theme.violet)
                        Text("需要「录屏与系统录音」权限").font(.system(size: 15, weight: .semibold))
                        Text("FrameInterp 只读取你选中的那一个窗口的画面，用来补帧，不保存、不上传。\n在系统设置里打开 FrameInterp 后，需要重新打开本程序才生效。")
                            .font(.system(size: 12)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                        HStack(spacing: 10) {
                            OutlineButton(title: "授权录屏", icon: "lock.open", color: Theme.violet) { model.onRequestScreenAccess() }
                            OutlineButton(title: "已打开，重新打开 FrameInterp", icon: "arrow.clockwise", color: Theme.ok) { model.onRelaunch() }
                        }
                        Text("已经打开了还是不行：在系统设置的列表里选中 FrameInterp，点「−」删掉，再点「授权录屏」重新加一次（程序每次更新后系统会把它当成新程序）。")
                            .font(.system(size: 11)).foregroundStyle(Theme.faint).multilineTextAlignment(.center)
                            .frame(maxWidth: 520)
                    }
                    .frame(maxWidth: .infinity).padding(40)
                } else if model.windowOptions.isEmpty {
                    Text("没有可用的窗口：先打开串流 App，再点右上角刷新")
                        .font(.system(size: 13)).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity).padding(40)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 12)], spacing: 12) {
                            ForEach(sortedWindows) { o in WindowCard(model: model, option: o) }
                        }
                        .padding(18)
                    }
                    .frame(height: min(480, CGFloat((model.windowOptions.count + 2) / 3) * 252 + 36)) // 按窗口数量定高度，少的时候不留大片空白
                }
            }
            .frame(width: 760)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
            .shadow(color: .black.opacity(0.6), radius: 30, y: 10)
        }
    }
}

struct WindowCard: View {
    @ObservedObject var model: UIModel
    let option: SourceOption
    @State private var hover = false
    var body: some View {
        let selected = model.selectedID == option.id
        Button { model.onSelect(option.source) } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    Color.black
                    if let img = model.windowThumbs[option.id] {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "macwindow").font(.system(size: 22)).foregroundStyle(Theme.faint)
                    }
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    if option.unsupported {
                        Text("暂不支持").font(.system(size: 10, weight: .bold)).foregroundStyle(.black)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.amber, in: RoundedRectangle(cornerRadius: 4)).padding(6)
                    } else if let e = Emulator.all.first(where: { $0.name == option.emulator }) {
                        Text(L("模拟器") + " · " + L(e.system)).font(.system(size: 10, weight: .bold)).foregroundStyle(.black)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.ok, in: RoundedRectangle(cornerRadius: 4)).padding(6)
                    } else if option.streaming {
                        Text("串流").font(.system(size: 10, weight: .bold)).foregroundStyle(.black)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.violet, in: RoundedRectangle(cornerRadius: 4)).padding(6)
                    }
                }
                Text(option.app).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(option.windowTitle.isEmpty ? option.size : "\(option.windowTitle) · \(option.size)")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                if option.unsupported {
                    Text("网页版 Xbox 串流：浏览器失去焦点会暂停画面，暂不支持")
                        .font(.system(size: 10)).foregroundStyle(Theme.amber).lineLimit(2)
                }
            }
            .padding(10)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Theme.violet : (hover ? Theme.borderHover : Theme.border)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct OutlineButton: View {
    let title: String, icon: String, color: Color
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 10, weight: .bold))
                Text(title).font(.system(size: 12, weight: .semibold)).tracking(0.48)
            }
            .foregroundStyle(color)
            .padding(.horizontal, 16).frame(height: 32)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(color))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 底部工具栏

/// 2026-11-21 改：底部工具栏学 Windows 11 任务栏 / macOS 程序坞，按钮居中放在一个半透明的圆角"坞"里，
/// 鼠标移上去轻微放大（程序坞的样子）；左边留着输入和实时数字。原来是左对齐一排方框按钮（和 Genki 网页一样）
struct BottomBar: View {
    @ObservedObject var model: UIModel
    static let dockWidth: CGFloat = 340

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // 左边：输入和实时数字（窗口窄了就收起来，不和中间的坞重叠）
                let room = (geo.size.width - BottomBar.dockWidth) / 2 - 28
                if room > 140 {
                    HStack { Ticker(model: model).frame(maxWidth: min(room, 380), alignment: .leading); Spacer() }
                }
                Dock(model: model)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 16)
        .frame(height: Theme.toolBarH)
        .background {
            if !model.isFullScreen { Theme.bg.overlay(alignment: .top) { Theme.border.frame(height: 1) } }
        }
    }
}

/// 居中的坞
struct Dock: View {
    @ObservedObject var model: UIModel
    var body: some View {
        HStack(spacing: 4) {
            DockItem(icon: "gearshape.fill", active: model.showSettings, help: "设置（⌘,）") { model.showSettings.toggle() }
            DockSeparator()
            DockItem(icon: "square.stack.3d.forward.dottedline", active: model.interpOn,
                     help: model.interpOn ? "补帧：开（空格）" : "补帧：关（空格）") { model.onInterp(!model.interpOn) }
            DockItem(icon: model.audioOn ? "speaker.wave.2.fill" : "speaker.slash.fill", active: model.audioOn,
                     help: model.audioOn ? "声音直通：开（点一下静音）" : "声音直通：关") { model.onAudio(!model.audioOn) }
            DockItem(icon: "sparkles", active: model.sharpLevel > 0,
                     help: model.sharpLevel > 0 ? "锐化：开（强度在设置里调）" : "锐化：关") {
                model.sharpLevel = model.sharpLevel > 0 ? 0 : 2
                model.onTuning()
            }
            DockItem(icon: "gauge.with.needle", active: model.showFPS, help: "帧数和延迟浮窗（⌘I）") { model.onShowFPS(!model.showFPS) }
            DockSeparator()
            DockItem(icon: model.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                     active: false, help: model.isFullScreen ? "退出全屏（Esc）" : "全屏（f）") { model.onFullScreen() }
        }
        .padding(.horizontal, 6)
        .frame(height: 48)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .background(Theme.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.45), radius: 14, y: 4)
        .environment(\.colorScheme, .dark)
    }
}

/// 坞里的一项：图标（主功能带文字）。鼠标移上去像 macOS 程序坞一样轻微放大；
/// 打开的项图标变成蓝色、带浅色底（不用底部横条：用户反馈上下不对称）
struct DockItem: View {
    let icon: String
    var label: String? = nil
    let active: Bool
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 15, weight: .medium))
                if let label { Text(label).font(.system(size: 12, weight: .semibold)) }
            }
            .foregroundStyle(active ? Theme.accent : Theme.text.opacity(hover ? 0.95 : 0.7))
            .padding(.horizontal, label == nil ? 0 : 10)
            .frame(minWidth: 38, minHeight: 34)
            .background(active ? Theme.accent.opacity(0.16) : (hover ? Color.white.opacity(0.06) : .clear),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
            .scaleEffect(hover ? 1.18 : 1, anchor: .center)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: hover)
            .animation(.easeOut(duration: 0.15), value: active)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
        .zIndex(hover ? 1 : 0)
    }
}

struct DockSeparator: View {
    var body: some View { Color.white.opacity(0.12).frame(width: 1, height: 22).padding(.horizontal, 5) }
}

/// 工具栏左边的两行信息：上面是输入，下面是实时数字
struct Ticker: View {
    @ObservedObject var model: UIModel
    var body: some View {
        let s = model.snap
        VStack(alignment: .leading, spacing: 2) {
            if model.hasInput {
                HStack(spacing: 6) {
                    Text(model.inputName).foregroundStyle(Theme.violet).fontWeight(.semibold)
                    Text(model.sourceW > 0 ? "\(String(model.sourceW))×\(String(model.sourceH)) · \(String(model.captureFps)) fps" : "")
                        .foregroundStyle(Theme.text.opacity(0.8))
                }
                .lineLimit(1)
                Text(s.displayed > 0
                     ? "游戏 \(s.unique) FPS → 显示 \(s.displayed) FPS · 延迟 \(Int((s.capDelay + s.latency).rounded())) ms" + (s.interpOn ? " · 补一帧 \(f1(s.interpAvg)) ms" : "")
                     : "等待画面…")
                    .foregroundStyle(Theme.muted).monospacedDigit().lineLimit(1)
            } else {
                Text(model.opening ? "正在打开…" : "没有输入").foregroundStyle(Theme.text.opacity(0.8)).fontWeight(.semibold)
                Text("插上采集卡点「连接」，或选一个串流窗口").foregroundStyle(Theme.muted)
            }
        }
        .font(.system(size: 12))
        .transaction { $0.animation = nil }
    }
}

// MARK: - 设置面板（左下角弹出）

struct SettingsPanel: View {
    @ObservedObject var model: UIModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("设置").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted)
                Spacer()
                Button { model.showSettings = false } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.muted)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Theme.border.frame(height: 1)
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    inputSection
                    interpSection
                    pictureSection.id("picture")
                    displaySection
                    advancedSection
                    statusSection
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
                .transaction { $0.animation = nil }
            }
            .scrollIndicators(.automatic)
            .onAppear {
                // 测试用：FI_SHOWSETTINGS=picture 打开时直接滚到画面设置（截图检查界面）
                if ProcessInfo.processInfo.environment["FI_SHOWSETTINGS"] == "picture" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { proxy.scrollTo("picture", anchor: .top) }
                }
            }
            }
        }
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
        .shadow(color: .black.opacity(0.6), radius: 24, y: 8)
        .onAppear { model.onRefreshAudio() } // 耳机 / 音箱插拔后打开设置能看到最新列表
    }

    // 输入
    private var inputSection: some View {
        SectionBlock(title: "输入来源", icon: "cable.connector") {
            Field("输入类型") {
                Segmented(labels: ["采集卡", "串流窗口"], selection: model.inputMode) { model.inputMode = $0 }
            }
            if model.inputMode == 1 {
                windowInput
            } else {
                cardInput
            }
        }
    }

    // 串流窗口
    @ViewBuilder
    private var windowInput: some View {
        if !model.screenAccess {
            Hint("读取其他 App 的窗口画面需要「录屏与系统录音」权限。")
            Button { model.onRequestScreenAccess() } label: {
                Text("授权录屏").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.violet)
                    .frame(maxWidth: .infinity).frame(height: 32)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.violet))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { model.onRelaunch() } label: {
                Text("已打开，重新打开 FrameInterp").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ok)
                    .frame(maxWidth: .infinity).frame(height: 32)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.ok))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Hint("系统设置里打开 FrameInterp 后，要重新打开本程序才生效。还是不行就在列表里删掉 FrameInterp 再授权一次。")
        } else {
            Field("窗口") {
                HStack(spacing: 6) {
                    SelectField(text: model.windowOptions.first { $0.id == model.selectedID }?.title ?? "选择一个窗口") {
                        let stream = model.windowOptions.filter(\.streaming)
                        let emus = model.windowOptions.filter { !$0.streaming && !$0.emulator.isEmpty }
                        let other = model.windowOptions.filter { !$0.streaming && $0.emulator.isEmpty }
                        if !stream.isEmpty { Section("串流 App") { ForEach(stream) { o in Button(o.title) { model.onSelect(o.source) } } } }
                        if !emus.isEmpty { Section("模拟器") { ForEach(emus) { o in Button(o.title) { model.onSelect(o.source) } } } }
                        if !other.isEmpty { Section("其他窗口") { ForEach(other) { o in Button(o.title) { model.onSelect(o.source) } } } }
                        if model.windowOptions.isEmpty { Text("没有可用的窗口") }
                    }
                    IconSquare(icon: "arrow.clockwise", help: "重新查找窗口") { model.onRefresh() }
                }
            }
            Button { model.onOpenWindowPicker() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.on.rectangle")
                    Text("带预览选择窗口")
                }
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text.opacity(0.85))
                .frame(maxWidth: .infinity).frame(height: 32)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.border))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        if let cur = model.windowOptions.first(where: { $0.id == model.selectedID }),
           let e = Emulator.all.first(where: { $0.name == cur.emulator }) {
            Hint(e.fullTip)
            Hint(Emulator.refreshNote)
        }
        SwitchLine(title: "自动裁掉标题栏和黑边", isOn: Binding(get: { model.windowAutoCrop }, set: { model.onWindowAutoCrop($0) }))
        Hint("游戏画面按 16:9 铺满、居中，不留黑边。开始后 3 秒内识别黑边；窗口大小变了会自动重新铺满。关掉则整个窗口按 16:9 铺满")
        Hint("按窗口画面的原始像素采集（不再先缩到 1080p）；开补帧时补帧器在 1080p 上补。全屏时不会让串流 App 以为自己被挡住而降帧。声音由串流 App 自己播放。")
        Hint("暂不支持网页版 Xbox 串流（Chrome / Edge / Safari 里的 xbox.com/play）：浏览器一失去焦点网页就暂停画面，和 FrameInterp 在前台显示补帧冲突。以后会把网页内嵌进 FrameInterp 来支持")
        Hint("画面糊时先看串流 App 自己的画质：PS Remote Play → 设置 → 视频画质，分辨率选 1080p、帧率选「高」（默认可能是 720p）；串流窗口别拉得太小")
        if model.inputMode == 1, model.hasInput, case .some(let id) = model.selectedID, id.hasPrefix("win:") { Hint(model.inputDetail) }
    }

    // 采集卡
    @ViewBuilder
    private var cardInput: some View {
            Field("视频设备") {
                HStack(spacing: 6) {
                    SelectField(text: model.sources.first { $0.id == model.selectedID && $0.group != .window }?.title ?? "未选择") {
                        Button("不使用（停止）") { model.onSelect(nil) }
                        ForEach([SourceOption.Group.card, .other], id: \.self) { g in
                            let items = model.sources.filter { $0.group == g }
                            if !items.isEmpty {
                                Section(g.rawValue) {
                                    ForEach(items) { o in Button(o.title) { model.onSelect(o.source) } }
                                }
                            }
                        }
                    }
                    IconSquare(icon: "arrow.clockwise", help: "重新查找采集卡和窗口") { model.onRefresh() }
                }
            }
            Field("分辨率") {
                SelectField(text: resTitle(model.captureHeight)) {
                    ForEach([1080, 1440, 2160], id: \.self) { h in
                        Button(resTitle(h) + resNote(h)) { model.onCaptureHeight(h) }
                            .disabled(!model.availableHeights.contains(h))
                    }
                }
            }
            if let mx = model.heightMaxFps[model.captureHeight], mx < model.captureFps {
                Hint("采集卡这一档最高只有 \(mx) 帧，比主机输出的少，画面会掉帧。玩游戏建议选能跑满 \(model.captureFps) 帧的档")
            }
            Field("帧率") {
                SelectField(text: "\(model.captureFps) fps") {
                    Button("60 fps") { model.onCaptureFps(60) }
                    Button("120 fps（主机输出 120Hz 时才有用）") { model.onCaptureFps(120) }
                }
            }
            SwitchLine(title: "压缩传输（MJPEG）", isOn: Binding(get: { model.captureMJPEG }, set: { model.onCaptureMJPEG($0) }))
            Hint(model.mjpegAvailable == false
                 ? "这个采集卡在 macOS 上没有提供压缩格式，开了不起作用"
                 : "USB 带宽不够时用（4K 60 帧、2K 120 帧）。画面经过压缩，细节略差；1080p 60 不需要开")
            SwitchLine(title: "声音直通", isOn: Binding(get: { model.audioOn }, set: { model.onAudio($0) }))
            Field("音频输入") {
                SelectField(text: model.audioInID.isEmpty
                            ? "自动（采集卡自带）" + (model.audioInActual.isEmpty ? "" : " · \(model.audioInActual)")
                            : (model.audioInputs.first { $0.id == model.audioInID }?.name ?? "已拔出的设备")) {
                    Button("自动（采集卡自带的声音）") { model.onAudioIn("") }
                    Divider()
                    ForEach(model.audioInputs) { o in Button(o.name) { model.onAudioIn(o.id) } }
                }
            }
            Field("音频输出") {
                SelectField(text: model.audioOutID.isEmpty
                            ? "系统默认（跟随系统设置）"
                            : (model.audioOutputs.first { $0.id == model.audioOutID }?.name ?? "已断开的设备")) {
                    Button("系统默认（跟随系统设置）") { model.onAudioOut("") }
                    Divider()
                    ForEach(model.audioOutputs) { o in Button(o.name) { model.onAudioOut(o.id) } }
                }
            }
            if !(model.selectedID ?? "").hasPrefix("win:") { Hint(model.inputDetail) }
            if let w = model.wizard, !w.appliedSummary.isEmpty {
                Field("当前配置") { Hint(w.appliedSummary) }
                    .padding(.top, 4)
                OutlineButton(title: "换主机", icon: "wand.and.stars", color: Theme.ok) { model.onOpenWizard() }
                Hint("配置已保存，换主机时再选一次")
            } else {
                OutlineButton(title: "选主机，一键配置", icon: "wand.and.stars", color: Theme.ok) { model.onOpenWizard() }
                    .padding(.top, 4)
            }
    }

    /// 菜单里每档后面的说明：没有这一档 → 不支持；有但跑不满所选帧率 → 标最高帧率
    private func resNote(_ h: Int) -> String {
        if !model.availableHeights.contains(h) { return " · 这个设备不支持" }
        if let mx = model.heightMaxFps[h], mx < model.captureFps { return " · 最高 \(mx) 帧" }
        return ""
    }

    private func resTitle(_ h: Int) -> String {
        switch h {
        case 1440: return "2K · 1440p (2560×1440)"
        case 2160: return "4K UHD (3840×2160)"
        default: return "1080p (1920×1080)"
        }
    }

    // 补帧
    private var interpSection: some View {
        SectionBlock(title: "补帧", icon: "square.stack.3d.forward.dottedline") {
            SwitchLine(title: "开启补帧", isOn: Binding(get: { model.interpOn }, set: { model.onInterp($0) }))
            Hint("30 帧游戏补成 60 帧；本来就是 60 帧的游戏不用开。快捷键：空格")
            SwitchLine(title: "字幕和提示保护", isOn: tuningBinding(\.subtitleGuard))
            Hint("下方字幕、左上状态条、左下地点名、右上金钱 / 提示、右下消息框停住不动时，补出来的帧里用真实画面，不闪、不变形。只管这几块")
            Hint(model.interpStatus)
        }
    }

    // 画面
    private var pictureSection: some View {
        SectionBlock(title: "画质", icon: "sparkles") {
            SwitchLine(title: "清晰放大", isOn: tuningBinding(\.sharpScale))
            Hint(model.sharpScale
                 ? "程序自己把画面缩放到屏幕的实际像素再显示，系统不再二次缩放。\n"
                   + "· 放大（1080p、2K → 全屏）：三次插值，比系统的双线性清楚，字边缘锯齿少\n"
                   + "· 缩小（4K → 全屏）：按比例取样，细线、栅栏、小字不闪\n"
                   + "每帧约 1.5~4ms（GPU），延迟基本不变"
                 : "关：交给系统缩放（双线性，偏软）；下面的锐化在原分辨率上做")
            if model.sharpScale {
                SwitchLine(title: "2K / 4K 自动轻度锐化", isOn: tuningBinding(\.autoSharpHiRes))
                Hint("采集分辨率是 2K / 4K 时（开补帧后也算），锐化至少用「柔和」（0.25）。主机输出 4K，但很多游戏内部只渲染 1440p 左右，画面会偏软")
                SwitchLine(title: "缩小防闪烁", isOn: tuningBinding(\.antiFlickerDown))
                Hint("采集分辨率比显示区域大很多时（4K 采集，或 2K 放进小窗口，缩到 0.85 倍以下）才起作用；开补帧、串流窗口模式时画面是 1080p，不会用到。关掉每帧省约 2ms，但画面移动时细线、栅栏、树叶会闪、出摩尔纹")
                SwitchLine(title: "压缩传输时减弱锐化", isOn: tuningBinding(\.compressedSoftSharp))
                Hint("开了「压缩传输（MJPEG）」时锐化减半，免得把压缩方块和字边的波纹一起放大。不压缩时不起作用")
            }
            Field("锐化") {
                Segmented(labels: ["关", "柔和", "标准", "锐利", "最锐"], selection: model.sharpLevel) {
                    model.sharpLevel = $0; model.onTuning()
                }
            }
            Hint([
                "关（默认）：不额外锐化" + (model.sharpScale && model.autoSharpHiRes ? "；2K / 4K 输入仍会自动轻度锐化" : ""),
                "柔和 0.25：边缘稍微清楚一点，几乎没有副作用。1080p 画面推荐",
                "标准 0.5：明显清楚，适合偏软的画面（游戏内部低分辨率渲染、开了动态模糊）",
                "锐利 0.75：画面偏糊时试试；草地、树叶在动时可能有点闪",
                "最锐 1.0：最强；文字边缘可能出现白边，草地闪烁，不建议一直开",
            ][model.sharpLevel] + "\n锐化只加强亮度（明暗）边缘，不动颜色，所以不会出彩边")
            if !model.enhanceStatus.isEmpty { Hint(model.enhanceStatus) }
        }
    }

    // 显示
    private var displaySection: some View {
        SectionBlock(title: "显示", icon: "display") {
            SwitchLine(title: "帧数和延迟浮窗", isOn: Binding(get: { model.showFPS }, set: { model.onShowFPS($0) }))
            Hint("画面左上角，每秒刷新（⌘I）。帧数 = 游戏本身每秒的新画面；延迟 = 采集卡交给电脑到送上屏幕")
            SwitchLine(title: "全屏时鼠标不动 2 秒隐藏", isOn: Binding(get: { model.autoHideCursor }, set: { model.autoHideCursor = $0; model.onTuning() }))
            Hint("只在全屏时生效，鼠标一动就出来")
        }
    }

    // 高级
    private var advancedSection: some View {
        SectionBlock(title: "高级", icon: "slider.horizontal.3", trailing: {
            Button { model.advancedOpen.toggle() } label: {
                Text(model.advancedOpen ? "收起" : "展开").font(.system(size: 10, weight: .semibold)).tracking(0.4)
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 8).frame(height: 20)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.border))
            }
            .buttonStyle(.plain)
        }) {
            if !model.advancedOpen {
                Hint("一般不用改。画面有问题时再展开调。")
            } else {
                option("重复帧判断", ["宽松", "标准", "灵敏"], \.dupLevel, [
                    "宽松：画面静止时不容易误判成新画面", "标准：一般情况用这个", "灵敏：只有准星、小地图在动时也能认出新画面"])
                option("切镜头时不补帧", ["关闭", "标准", "灵敏"], \.cutLevel, [
                    "关闭：切镜头也补，过渡那一帧可能是两个画面叠在一起", "标准：画面突然整个换掉时跳过补帧", "灵敏：变化更小也跳过，鬼影少但没那么顺"])
                Field("补帧分辨率") {
                    Segmented(labels: ["原分辨率", "720p"], selection: model.ires == 0 ? 0 : 1) { model.onIres($0 == 0 ? 0 : 720) }
                }
                Hint(model.ires == 0 ? "画质最好；1080p 每帧补帧约 20ms（2K / 4K 也按 1080p 补）" : "更快（每帧约 11ms），补出来的帧略软")
                if model.sharpScale {
                    Field("补帧锐化") {
                        Hint("清晰放大开着时这一项不起作用：真实帧和补出来的帧都按「画质 → 锐化」统一处理，前后一致不闪")
                    }
                } else {
                    option("补帧锐化", ["关", "只补帧", "全部"], \.interpSharpLevel, [
                        "关：不锐化", "只锐化补出来的帧（柔和），真实帧不动", "所有帧都锐化（柔和），观感一致"])
                }
                option("延迟和流畅", ["低延迟", "平衡", "流畅"], \.smoothLevel, [
                    "低延迟：排队最短；游戏帧率不稳时每秒会丢几帧", "平衡：一般情况用这个，不丢帧", "流畅：多排一帧，帧率很不稳的游戏更稳；延迟多约 17ms"])
                SwitchLine(title: "补帧太慢就跳过", isOn: tuningBinding(\.skipLate))
                Hint("偶尔有一帧补得特别慢（超过 30ms）时不显示它，避免顿一下")
                SwitchLine(title: "画面几乎不动时不补帧", isOn: tuningBinding(\.stillDirect))
                Hint("加载转圈、跳动的数字：每帧直接显示，不糊也不卡；画面一动就恢复补帧")
                SwitchLine(title: "标出补出来的帧", isOn: tuningBinding(\.markInterp))
                Hint("补出来的帧右上角闪一个橙点，用来确认补帧在工作")
                Button("恢复默认") { model.resetTuning() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.blue)
                    .padding(.top, 4)
            }
        }
    }

    // 状态
    private var statusSection: some View {
        let s = model.snap
        return SectionBlock(title: "状态", icon: "waveform.path.ecg") {
            if !model.hasInput {
                Hint("没有输入")
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                    row("显示帧率", "\(s.displayed) 帧/秒", good: s.displayed >= 58 || !s.interpOn)
                    row("游戏帧率", "\(s.unique) 帧/秒")
                    row("采集帧率", "\(s.capture) 帧/秒")
                    row("补帧耗时", s.interpOn ? "\(f1(s.interpAvg)) ms（最慢 \(f1(s.interpMax))）" : "已关闭", good: !s.interpOn || s.interpMax < 30)
                    row("采集到程序", "\(f1(s.capDelay)) ms")
                    row("程序内延迟", "\(f1(s.latency)) ms")
                    row("丢帧", "\(s.drops + s.failures)", good: s.drops + s.failures == 0)
                    row("切场景 / 太慢跳过", "\(s.cuts) / \(s.lateSkips)")
                }
                .font(.system(size: 11).monospacedDigit())
            }
            Button("打开日志文件夹") { model.onOpenLogs() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.blue)
                .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func row(_ k: String, _ v: String, good: Bool = true) -> some View {
        GridRow {
            Text(k).foregroundStyle(Theme.muted)
            Text(v).foregroundStyle(good ? Theme.text : Theme.amber).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tuningBinding<T>(_ kp: ReferenceWritableKeyPath<UIModel, T>) -> Binding<T> {
        Binding(get: { model[keyPath: kp] }, set: { model[keyPath: kp] = $0; model.onTuning() })
    }

    @ViewBuilder
    private func option(_ title: String, _ labels: [String], _ kp: ReferenceWritableKeyPath<UIModel, Int>, _ hints: [String]) -> some View {
        Field(title) {
            Segmented(labels: labels, selection: model[keyPath: kp]) { model[keyPath: kp] = $0; model.onTuning() }
        }
        Hint(hints[model[keyPath: kp]])
    }
}

// MARK: - 设置面板里的小控件

/// 一节：大写英文小标题 + 内容
struct SectionBlock<Content: View, Trailing: View>: View {
    let title: String
    let icon: String
    let trailing: Trailing
    @ViewBuilder let content: Content
    init(title: String, icon: String = "circle", @ViewBuilder trailing: () -> Trailing = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title; self.icon = icon; self.trailing = trailing(); self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                Text(title).font(.system(size: 14, weight: .bold))
                Spacer()
                trailing
            }
            .padding(.top, 14)
            content
        }
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) { Theme.border.frame(height: 1) }
    }
}

/// 字段：灰色小标签 + 控件
struct Field<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content
    init(_ label: String, @ViewBuilder content: () -> Content) { self.label = label; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 10, weight: .medium)).tracking(1.0).foregroundStyle(Theme.muted)
            content
        }
        .padding(.top, 2)
    }
}

struct Hint: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        if !text.isEmpty {
            Text(text).font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 下拉框：深灰底 + 细边框 + 右边小箭头
struct SelectField<MenuContent: View>: View {
    let text: String
    @ViewBuilder let menu: () -> MenuContent
    @State private var hover = false
    var body: some View {
        Menu { menu() } label: {
            HStack {
                Text(text).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.muted)
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 12).frame(height: 32)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(hover ? Theme.borderHover : Theme.border))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { hover = $0 }
    }
}

/// 分段选择：选中的那段珊瑚红描边
struct Segmented: View {
    let labels: [String]
    let selection: Int
    let onSelect: (Int) -> Void
    var body: some View {
        HStack(spacing: 4) {
            ForEach(labels.indices, id: \.self) { i in
                let sel = i == selection
                Button { onSelect(i) } label: {
                    Text(labels[i]).font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                        .foregroundStyle(sel ? Theme.accent : Theme.muted)
                        .frame(maxWidth: .infinity).frame(height: 26)
                        .background(sel ? Theme.accent.opacity(0.1) : Theme.surface, in: RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(sel ? Theme.accent : Theme.border))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// 文字 + 右边开关
struct SwitchLine: View {
    let title: String
    @Binding var isOn: Bool
    var body: some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer()
            Button { isOn.toggle() } label: {
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule().fill(isOn ? Theme.accent : Color.white.opacity(0.14)).frame(width: 34, height: 20)
                    Circle().fill(Color.white).frame(width: 16, height: 16).padding(.horizontal, 2)
                        .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
                }
                .animation(.easeOut(duration: 0.15), value: isOn)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 2)
    }
}

/// 32×32 小方块按钮（下拉框旁边的刷新）
struct IconSquare: View {
    let icon: String, help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                .frame(width: 32, height: 32)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.border))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
