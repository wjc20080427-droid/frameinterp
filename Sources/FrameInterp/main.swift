import AVFoundation
import AppKit
import Foundation
import ScreenCaptureKit
import SwiftUI

setvbuf(stdout, nil, _IOLBF, 0)
Devices.allowScreenDevices()
let options = Options.parse(CommandLine.arguments)

if options.list {
    Devices.printList()
    exit(0)
}
if options.listWindows {
    let sem = DispatchSemaphore(value: 0)
    Task { await WindowCapture.printList(); sem.signal() }
    sem.wait()
    exit(0)
}

/// 画面来源
enum Source: Equatable {
    case device(id: String, name: String)   // 采集卡
    case window(id: CGWindowID, title: String)
    case iphone                             // 命令行 --window NAME 指定的窗口（界面里不再出现）
    case test                               // 内置测试图案
    case xbox(serverId: String, name: String)  // 原生 Xbox 串流（开发中，只在测试版能用）

    var label: String {
        switch self {
        case .device(_, let n): return n
        case .window(_, let t): return t
        case .xbox(_, let n): return "\(n)（原生串流）"
        case .iphone: return "指定窗口"
        case .test: return "测试图案"
        }
    }
}

@MainActor
final class App: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    var opts: Options
    let stats = Stats()
    let model = UIModel()
    let enhancer = Enhancer()
    let scaler = SharpScaler()
    var cursorHideWork: DispatchWorkItem?
    var keyMonitor: Any?
    var mouseMonitor: Any?
    var chromeHideWork: DispatchWorkItem?
    var lastSource: Source?        // 「停止」后再按「开始」时用
    var formatChoice: (AVCaptureDevice.Format, AVFrameRateRange)?
    var formatChoices = 0
    var screenVerified = false     // 真的读到过窗口列表（有录屏权限）
    var audioVideoDevice: AVCaptureDevice? // 声音跟着哪个采集设备（换音频输入时重开用）
    var interp: VTInterpolator?
    var pipeline: Pipeline? { didSet { livePipeline = pipeline } }
    var capture: VideoCapture?
    var windowCapture: WindowCapture?
    #if FI_XNATIVE
    var xboxSession: XboxStreamSession?
    #endif
    /// 内嵌网页串流（xbox.com/play，实验）
    var webHost: WebStreamHost?
    var testSource: TestSource?
    var audio: AudioPassthrough?
    var window: NSWindow?
    var view: DisplayView?
    var statsTimer: Timer?
    var headlessTimer: DispatchSourceTimer?

    var source: Source?
    var interpOn: Bool
    var ires: Int                  // 补帧分辨率（0 = 原分辨率）
    /// 1080p 补帧在这台 Mac 上预热失败时自动改用 720p（2026-11-21：别人的 Mac 上报 -19730 "Processor is not initialized"）
    /// 网上多个项目实测：macOS 26.x 上 Apple 低延迟补帧最多处理 1280×720 的像素量（超了 startSession 不报错，process 报 -19730），
    /// 27 才放宽到 1080p。用户反馈的两台（M2 26.6、M4 26.5.2）都是 26.x。所以 26.x 上一开始就用 720p 补帧，不用先等 10 秒失败
    /// 2026-11-23 B 站用户反馈：M1 Pro + macOS 27，1080p 补帧打开后只有 10 帧。Apple 论坛也有人实测 M1 Pro 低延迟补帧最大 720p，
    /// Console Link 等软件在 M1 Pro 上也只支持 720p。所以 M1 系列芯片一开始就用 720p 补帧；其他芯片补帧太慢时也会自动降到 720p（见 checkInterpSpeed）
    var autoProc720 = ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27 || App.isM1Family || SlowMemory.slow30
    /// 为什么用 720p 补帧（状态里说明）
    var proc720Reason: String {
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27 { return "（macOS 26 只支持 720p 补帧，升级到 macOS 27 可用 1080p）" }
        if App.isM1Family && !slowSwitched { return "（M1 系列芯片 1080p 补帧太慢，自动用 720p）" }
        if SlowMemory.slow30 && !slowSwitched { return "（上次测到这台 Mac 1080p 补帧太慢，直接用 720p）" }
        if slowSwitched { return "（1080p 补帧在这台 Mac 上太慢，自动改用 720p）" }
        return "（这台 Mac 上 1080p 补帧不可用，自动用 720p）"
    }
    var slowSwitched = false
    private var slowSeconds = 0
    static var isM1Family: Bool {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        let b = String(cString: buf)
        return b.hasPrefix("Apple M1")
    }

    /// 补帧跟不上（每帧太慢，或者开着补帧显示帧率掉得很低）连续 3 秒：自动改用 720p 补帧
    func checkInterpSpeed(_ snap: StatsSnapshot) {
        guard pipeline?.interpActive == true, !autoProc720, let vt = interp, vt.height > 720, snap.unique >= 15 else { slowSeconds = 0; return }
        // 30 帧左右的游戏补帧后应接近翻倍；60 帧的游戏在 60Hz 屏幕上不用补，不按显示帧率判断。FI_FAKE_SLOW=1 测试用
        // 2026-11-24 加：120Hz 屏幕上 60 帧的游戏（模拟器、串流）要补到 120，每帧要在 16ms 内补完；
        // M2 上 1080p 补一帧约 18～20ms 跟不上，补完显示不到 1.6 倍就改用 720p
        let hiRefresh = (pipeline?.refreshMs ?? 16.7) < 10
        let slow30 = ProcessInfo.processInfo.environment["FI_FAKE_SLOW"] == "1"
            || (snap.interpDone > 0 && snap.interpAvg > 28)
            // 2026-11-27 加 interpDone > 0：补帧根本没跑起来（比如时间戳不对）不算"慢"，降 720p 也没用（原生串流因此被误判、断开重连）
            || (snap.interpDone > 0 && snap.unique <= 40 && snap.displayed < Int(Double(snap.unique) * 1.3))
        // 60 → 120：画面稳定 60 帧左右时，每帧平均超过 16.5ms 就一定跟不上（一秒要补 60 次）。
        // 2026-11-25 改：不用等 3 秒，1 秒就降；上次在这台 Mac 上已经测到过，看到 60 帧画面马上降
        let hiCase = hiRefresh && snap.unique >= 45 && snap.interpDone > 0 && snap.stillDirect == 0
        let slowHi = hiCase && (SlowMemory.slowHi || snap.interpAvg > 16.5 || snap.displayed < Int(Double(snap.unique) * 1.6))
        slowSeconds = slow30 || slowHi ? slowSeconds + 1 : 0
        guard slowSeconds >= (slow30 ? 3 : 1), let cur = source else { return }
        // 原生 Xbox 串流：重开输入会断开重连主机，先不自动降 720p（以后改成只重建补帧、不断开串流）
        if case .xbox = cur {
            if !slowSwitched { slowSwitched = true; Log.write("补帧偏慢（每帧 \(f1(snap.interpAvg))ms），原生串流不自动改 720p（会断开重连），可在高级里手动改") }
            slowSeconds = 0
            return
        }
        slowSeconds = 0
        autoProc720 = true
        slowSwitched = true
        // 记下来：下次同一台 Mac、同一个系统版本直接用 720p（60 → 120 的情况只在看到 60 帧画面时才降，30 帧游戏照样用 1080p）
        if slow30 { SlowMemory.slow30 = true } else { SlowMemory.slowHi = true }
        Log.write("补帧太慢（每帧 \(f1(snap.interpAvg))ms，游戏 \(snap.unique) → 显示 \(snap.displayed)\(slow30 ? "" : "，屏幕高刷新率")），自动改用 720p 补帧并记住（\(App.machineInfo)）")
        view?.flash("1080p 补帧太慢，自动改用 720p 补帧…")
        Task { await switchTo(cur, force: true) }
    }

    /// 芯片、型号、系统版本（写日志、报错时显示）
    static var machineInfo: String {
        func sysctl(_ name: String) -> String {
            var size = 0
            sysctlbyname(name, nil, &size, nil, 0)
            var buf = [CChar](repeating: 0, count: max(size, 1))
            sysctlbyname(name, &buf, &size, nil, 0)
            return String(cString: buf)
        }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(sysctl("machdep.cpu.brand_string")) · \(sysctl("hw.model")) · macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
    var cachedWindows: [SCWindow] = []
    var switching = false
    var generation = 0             // 每次切换来源 +1，旧回调看到不一致就忽略

    let inputMenu = NSMenu(title: L("输入"))
    let windowsMenu = NSMenu(title: L("窗口"))
    var interpItem: NSMenuItem!
    var iresItems: [Int: NSMenuItem] = [:]
    var statsItem: NSMenuItem!

    init(_ o: Options) {
        opts = o
        // 双击打开时默认不补帧（按空格打开）；命令行测试（--test / --selftest / --interp）照旧默认打开
        interpOn = (o.test || o.selftest || o.forceInterp) ? o.interpOn : false
        ires = o.interpHeight
    }

    // MARK: - 启动

    func applicationDidFinishLaunching(_ n: Notification) {
        // 用自己的全屏（盖住菜单栏那种），不要系统自动往"显示"菜单里加的"进入全屏幕"
        UserDefaults.standard.set(false, forKey: "NSFullScreenMenuItemEverywhere")
        if opts.probe {
            Log.open()
            Task { await FormatProbe.run(); exit(0) }
            return
        }
        if opts.selftest {
            Task { await switchTo(.test) }
            startHeadlessConsumer()
        } else {
            NSApp.setActivationPolicy(.regular)
            Log.open()
            Log.write("FrameInterp 启动，日志：\(Log.path ?? "-")")
            Log.write("这台 Mac：\(App.machineInfo)")
            buildMenus()
            makeWindow()
            bindModel()
            refreshSources()
            for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        let d = n.object as? AVCaptureDevice
                        Log.write("\(name == AVCaptureDevice.wasConnectedNotification ? "设备接入" : "设备拔出")：\(d?.localizedName ?? "?")")
                        self.refreshSources()
                        // 还没选输入时，接上采集卡 / iPad 就自动用它
                        if self.source == nil, name == AVCaptureDevice.wasConnectedNotification, let d, !Devices.isCamera(d),
                           d.hasMediaType(.video) || Devices.isScreenDevice(d) {
                            Task { await self.switchTo(.device(id: d.uniqueID, name: d.localizedName)) }
                        }
                    }
                }
            }
            Task { await switchTo(initialSource()) }
        }
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            MainActor.assumeIsolated { self.tickStats() }
        }
        // 测试用：FI_WIZARD=1 启动后打开配置向导；FI_WIZARD_CONSOLE=主机序号 预先选中（截图检查界面）
        if ProcessInfo.processInfo.environment["FI_WIZARD"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MainActor.assumeIsolated {
                self.openWizard()
                if let c = ProcessInfo.processInfo.environment["FI_WIZARD_CONSOLE"].flatMap(Int.init).flatMap(Console.init(rawValue:)) { self.wizard.console = c }
            } }
        }
        // 测试用：FI_TOGGLEFS=秒数 启动后过这么久切换一次全屏
        if let v = ProcessInfo.processInfo.environment["FI_TOGGLEFS"], let sec = Double(v) {
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { MainActor.assumeIsolated { self.toggleFullScreen() } }
        }
        // 测试用：FI_WINKIND=1 首页窗口卡片打开在"模拟器"页；FI_EMULIST=1 启动后打开支持的模拟器列表
        if let k = ProcessInfo.processInfo.environment["FI_WINKIND"].flatMap(Int.init) { model.streamTab = k; model.windowKind = k == 2 ? 1 : 0 }
        if ProcessInfo.processInfo.environment["FI_EMULIST"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MainActor.assumeIsolated { self.model.showEmulatorList = true } }
        }
        #if FI_XNATIVE
        XboxAccount.shared.restore()   // 原生 Xbox 串流（开发中）：钥匙串里有登录就自动登录
        if ProcessInfo.processInfo.environment["FI_XLOGIN"] == "1" { XboxAccount.shared.signIn() }   // 测试：启动就申请登录码（截图看界面）
        if ProcessInfo.processInfo.environment["FI_XRTCTEST"] == "1" { XboxRTC.selfTest() }   // 测试：WebRTC 能不能用
        if ProcessInfo.processInfo.environment["FI_XRUMBLETEST"] == "1" { XboxRumbleTest.run() }   // 测试：震动包解析 + 手柄震一下
        if ProcessInfo.processInfo.environment["FI_SRTEST"] == "1" { SuperResTest.run() }   // 测试：AI 超分
        // 测试：Teredo 地址解析（RFC 4380 的例子：2001:0:4136:e378:8000:63bf:3fff:fdd2 → 192.0.2.45 端口 40000）
        if ProcessInfo.processInfo.environment["FI_TEREDOTEST"] == "1" {
            for c in ["candidate:1 1 UDP 2122260223 2001:0000:4136:e378:8000:63bf:3fff:fdd2 9002 typ host",
                      "candidate:2 1 UDP 2122260223 2001:0:4136:e378:8000:63bf:3fff:fdd2 40000 typ host",
                      "candidate:3 1 UDP 2122260223 192.168.1.20 9002 typ host",
                      "candidate:4 1 UDP 2122260223 fe80::1 9002 typ host"] {
                Log.write("Teredo 自测：\(c.split(separator: " ")[4]) → \(XboxStreamSession.teredoCandidates(c))")
            }
        }
        // 测试：FI_XCONNECT=主机名，自动登录后直接连这台主机（最多等 20 秒拿主机列表）
        if let name = ProcessInfo.processInfo.environment["FI_XCONNECT"] {
            Task { @MainActor in
                for _ in 0..<40 {
                    if let c = XboxAccount.shared.consoles.first(where: { $0.name == name }) {
                        await self.switchTo(.xbox(serverId: c.id, name: c.name)); return
                    }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                Log.write("FI_XCONNECT：没找到主机 \(name)")
            }
        }
        #endif
        // FI_WEBRESET=1：先清掉内嵌网页存的 Xbox 数据（区域 / 语言记错时）
        if ProcessInfo.processInfo.environment["FI_WEBRESET"] == "1" { WebStreamHost.resetXboxData {} }
        // 测试用：FI_DUMPMENU=1 把菜单结构写进日志（核对菜单，不用去点）
        if ProcessInfo.processInfo.environment["FI_DUMPMENU"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                MainActor.assumeIsolated {
                    self.rebuildInputMenu(); self.updateMenuState()
                    func dump(_ m: NSMenu, _ depth: Int) -> [String] {
                        m.items.flatMap { it -> [String] in
                            let pad = String(repeating: "  ", count: depth)
                            if it.isSeparatorItem { return [pad + "──"] }
                            let k = it.keyEquivalent.isEmpty ? "" : " [" + (it.keyEquivalentModifierMask.contains(.control) ? "⌃" : "") + (it.keyEquivalentModifierMask.contains(.option) ? "⌥" : "") + "⌘" + it.keyEquivalent.uppercased() + "]"
                            let line = pad + (it.state == .on ? "✓ " : "") + (it.image != nil ? "◇ " : "") + it.title + k
                            return [line] + (it.submenu.map { dump($0, depth + 1) } ?? [])
                        }
                    }
                    Log.write("菜单结构：\n" + dump(NSApp.mainMenu!, 0).joined(separator: "\n"))
                }
            }
        }
        // 测试用：FI_XFAKECONNECT=1 用测试图案时盖上"正在连接主机"的加载画面（截图看样子，不连真主机）
        if ProcessInfo.processInfo.environment["FI_XFAKECONNECT"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { MainActor.assumeIsolated { self.model.nativeConnecting = (title: "正在连接 卧室 Xbox", step: "等主机准备好…") } }
        }
        // 测试用：FI_WEBXBOX=1 打开内嵌 Xbox 网页；=test 用本地测试页，3 秒后自动「开始补帧」
        if let v = ProcessInfo.processInfo.environment["FI_WEBXBOX"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                MainActor.assumeIsolated {
                    self.openWebXbox()
                    if v.hasPrefix("test") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { MainActor.assumeIsolated { self.startWebXbox() } }
                    }
                    #if FI_KEYPAD
                    if ProcessInfo.processInfo.environment["FI_KEYPADTEST"] == "1" {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { MainActor.assumeIsolated { KeyPad.shared.selfTest() } }
                    }
                    #endif
                    if v.hasSuffix("back") {   // 补帧 6 秒后回到网页，再过 4 秒再开始补帧
                        DispatchQueue.main.asyncAfter(deadline: .now() + 9) { MainActor.assumeIsolated { self.openWebXbox() } }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 13) { MainActor.assumeIsolated { self.startWebXbox() } }
                    }
                }
            }
        }
        // 测试用：FI_WEBSPIKE=1 / occl 内嵌网页自测（网页窗口放主窗口后面，看还在不在渲染、能不能抓到）
        if ProcessInfo.processInfo.environment["FI_WEBSPIKE"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MainActor.assumeIsolated { WebSpike.run(mainWindow: self.window) } }
        }
        // 测试用：FI_SHOWSETTINGS=1 启动后打开设置栏（截图检查界面）
        if ["1", "picture", "advanced"].contains(ProcessInfo.processInfo.environment["FI_SHOWSETTINGS"] ?? "") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MainActor.assumeIsolated { self.model.showSettings = true } }
        }
        // 测试用：环境变量 FI_PANELTEST=1 时每秒展开 / 收起设置栏一次，记录窗口和画面大小
        if ProcessInfo.processInfo.environment["FI_PANELTEST"] == "1" {
            var n = 0
            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { t in
                MainActor.assumeIsolated {
                    n += 1
                    self.model.showSettings.toggle()
                    let f = self.window?.frame ?? .zero, v = self.view?.bounds ?? .zero
                    Log.write("设置栏测试 \(n)：窗口 \(Int(f.width))×\(Int(f.height))，画面 \(Int(v.width))×\(Int(v.height))，图层 \(self.view.map { "\(Int($0.displayLayer.frame.width))×\(Int($0.displayLayer.frame.height))" } ?? "-")")
                    if n >= 10 { t.invalidate() }
                }
            }
        }
        // 测试用：FI_PICKER=1 时 3 秒后打开窗口选择器
        if ProcessInfo.processInfo.environment["FI_PICKER"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { MainActor.assumeIsolated { self.openWindowPicker() } }
        }
        // 测试用：FI_FSTEST=1 时每 1.5 秒进出全屏一次，记录窗口和画面大小
        if ProcessInfo.processInfo.environment["FI_FSTEST"] == "1" {
            var n = 0
            Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { t in
                MainActor.assumeIsolated {
                    let f = self.window?.frame ?? .zero, v = self.view?.bounds ?? .zero
                    Log.write("全屏测试 \(n)（\(self.model.isFullScreen ? "全屏" : "窗口")）：窗口 \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))×\(Int(f.height))，画面 \(Int(v.width))×\(Int(v.height))，图层 \(self.view.map { "\(Int($0.displayLayer.frame.width))×\(Int($0.displayLayer.frame.height))" } ?? "-")")
                    n += 1
                    if n > 8 { t.invalidate(); return }
                    self.toggleFullScreen()
                }
            }
        }
        // 测试用：FI_LATTEST=1 时测显示延迟（配合 --test --nointerp）：3 秒后开始录自己的画面区域，10 秒后出结果
        if ProcessInfo.processInfo.environment["FI_LATTEST"] == "1" {
            FrameStamp.enabled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                MainActor.assumeIsolated {
                    guard let win = self.window, let v = self.view, let content = win.contentView else { return }
                    let r = v.convert(v.bounds, to: content)
                    let top = content.isFlipped ? r.minY : content.bounds.height - r.maxY
                    let probe = LatencyProbe(label: "\(DisplayView.renderMode)，\(self.model.isFullScreen ? "全屏" : "窗口")")
                    Task {
                        await probe.start(windowID: CGWindowID(win.windowNumber),
                                          rect: CGRect(x: r.minX, y: top, width: r.width, height: r.height),
                                          scale: win.backingScaleFactor)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { probe.stopAndReport() }
                }
            }
        }
        if opts.seconds > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + opts.seconds) { MainActor.assumeIsolated { self.quit() } }
        }
    }

    /// 命令行指定的来源；都没指定时自动找采集卡，找不到就等用户在菜单里选
    func initialSource() -> Source? {
        if opts.test { return .test }
        if opts.window != nil { return .iphone } // --window NAME：switchTo 里按名字找
        if let d = Devices.pickVideo(opts.device) { return .device(id: d.uniqueID, name: d.localizedName) }
        return nil
    }

    func makeWindow() {
        let rect = NSRect(x: 0, y: 0, width: 1440, height: 820)
        let win = FIWindow(contentRect: rect,
                           styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.title = "FrameInterp"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.appearance = NSAppearance(named: .darkAqua)
        win.backgroundColor = NSColor(red: 10 / 255, green: 10 / 255, blue: 10 / 255, alpha: 1)
        win.collectionBehavior = [.fullScreenPrimary]
        win.minSize = NSSize(width: 960, height: 600)
        win.titlebarSeparatorStyle = .none
        win.acceptsMouseMovedEvents = true
        win.delegate = self
        let v = DisplayView(frame: .zero)
        v.stats = stats
        v.countEmpty = { [weak self] in MainActor.assumeIsolated { self?.pipeline?.countsEmpty ?? false } }
        model.interpOn = interpOn
        model.ires = ires
        if !opts.selftest {
            model.loadTuning()
            if opts.interpHeight == 0 { ires = model.ires } else { model.ires = ires }
        }
        v.markInterpolated = model.markInterp
        v.onPixelSize = { [weak self] size in self?.enhancer?.targetSize = size; self?.scaler?.targetSize = size }
        let host = NSHostingView(rootView: RootView(model: model, video: v))
        host.sizingOptions = [] // 窗口大小由用户决定，不让界面内容（展开 / 收起设置栏）去撑大窗口
        win.contentView = host
        win.setContentSize(rect.size)
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate()
        window = win
        view = v
        // 量出红绿灯的实际位置，让右上角的全屏键和它对称
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.placeTrafficLights()
                guard let self, let close = win.standardWindowButton(.closeButton), let sup = close.superview,
                      let content = win.contentView else { return }
                let r = content.convert(close.convert(close.bounds, to: nil), from: nil)
                _ = sup
                self.model.trafficInset = r.minX
                self.model.trafficCenterY = content.isFlipped ? r.midY : content.bounds.height - r.midY
                Log.write("红绿灯位置：左边距 \(Int(r.minX))，中心离顶 \(Int(self.model.trafficCenterY))")
            }
        }
        v.setMessage("正在查找画面来源…")
        // 空格 / f：不管焦点在哪个控件上都能用（文字输入框除外）
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            #if FI_KEYPAD
            if MainActor.assumeIsolated({ KeyPad.shared.isMapped(e) }) { return e }   // 键盘当手柄开着：让给它
            #endif
            guard let self, e.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  !(NSApp.keyWindow?.firstResponder is NSText),
                  MainActor.assumeIsolated({ !self.model.webMode }) else { return e }
            switch e.charactersIgnoringModifiers?.lowercased() {
            case " ": MainActor.assumeIsolated { self.setInterp(!self.interpOn) }; return nil
            case "f": MainActor.assumeIsolated { self.toggleFullScreen() }; return nil
            default:
                // Esc：先关配置向导 / 设置面板，再退出全屏
                if e.keyCode == 53, MainActor.assumeIsolated({ self.model.showWizard }) {
                    MainActor.assumeIsolated { self.wizard.onClose() }
                    return nil
                }
                if e.keyCode == 53, MainActor.assumeIsolated({ self.model.showSettings }) {
                    MainActor.assumeIsolated { self.model.showSettings = false }
                    return nil
                }
                if e.keyCode == 53, MainActor.assumeIsolated({ self.model.isFullScreen }) {
                    MainActor.assumeIsolated { self.toggleFullScreen() }
                    return nil
                }
                return e
            }
        }
        // 全屏时鼠标一动，顶栏和工具栏出来 2.5 秒
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { [weak self] e in
            MainActor.assumeIsolated { self?.pokeChrome(); self?.pokeCursor() }
            return e
        }
        // 只有命令行明确用采集卡且没写 --windowed 时才自动全屏；双击打开的程序默认窗口化
        if opts.fullscreen || (opts.device != nil && !opts.windowed) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { MainActor.assumeIsolated { self.toggleFullScreen() } }
        }
    }

    /// 界面操作 → App
    func bindModel() {
        model.onSelect = { [weak self] s in Task { await self?.switchTo(s) } }
        model.onInterp = { [weak self] on in self?.setInterp(on) }
        setupWizard()
        model.onIres = { [weak self] h in self?.applyIres(h) }
        model.onShowFPS = { [weak self] on in
            guard let self else { return }
            model.showFPS = on
            model.saveTuning()
            if !on { view?.setHud(nil) }
            updateMenuState()
        }
        model.onFullScreen = { [weak self] in self?.toggleFullScreen() }
        model.onRefresh = { [weak self] in self?.refreshSources() }
        model.onTuning = { [weak self] in self?.applyTuning() }
        model.onStartStop = { [weak self] in self?.startStop() }
        model.onRefreshAudio = { [weak self] in self?.refreshAudioDevices() }
        model.onAudioIn = { [weak self] id in
            guard let self, id != model.audioInID else { return }
            model.audioInID = id
            model.saveTuning()
            Log.write("音频输入：\(id.isEmpty ? "自动" : (model.audioInputs.first { $0.id == id }?.name ?? id))")
            restartAudio()
        }
        model.onAudioOut = { [weak self] id in
            guard let self, id != model.audioOutID else { return }
            model.audioOutID = id
            model.saveTuning()
            audio?.outputUID = id.isEmpty ? nil : id
            Log.write("音频输出：\(id.isEmpty ? "系统默认" : (model.audioOutputs.first { $0.id == id }?.name ?? id))")
            view?.flash("声音输出：\(id.isEmpty ? "系统默认" : (model.audioOutputs.first { $0.id == id }?.name ?? "已选设备"))")
        }
        model.onOpenWindowPicker = { [weak self] in self?.openWindowPicker() }
        model.onWebXbox = { [weak self] in self?.openWebXbox() }
        model.onWebStart = { [weak self] in self?.startWebXbox() }
        model.onWebClose = { [weak self] in self?.closeWebXbox() }
        model.onWebReload = { [weak self] in self?.webHost?.retry() }
        model.onRequestScreenAccess = { [weak self] in self?.requestScreenAccess() }
        model.onRelaunch = { [weak self] in self?.relaunch() }
        model.onWindowAutoCrop = { [weak self] on in
            guard let self, on != model.windowAutoCrop else { return }
            model.windowAutoCrop = on
            model.saveTuning()
            Log.write("自动裁标题栏和黑边：\(on ? "开" : "关")")
            if let s = source, sourceIsWindow { Task { await self.switchTo(s, force: true) } }
        }
        model.onWindowButton = { [weak self] i in
            guard let w = self?.window else { return }
            switch i {
            case 0: w.performClose(nil)
            case 1: w.miniaturize(nil)
            default: self?.toggleFullScreen()
            }
        }
        model.onAudio = { [weak self] on in
            guard let self else { return }
            model.audioOn = on
            model.saveTuning()
            audio?.muted = !on
            view?.flash(on ? "声音直通：开" : "声音直通：关")
            Log.write("声音直通：\(on ? "开" : "关")")
        }
        model.onCaptureHeight = { [weak self] h in
            guard let self, h != model.captureHeight else { return }
            model.captureHeight = h
            model.saveTuning()
            Log.write("采集分辨率：\(UIModel.resName(h))")
            if let s = source, case .device = s { Task { await self.switchTo(s, force: true) } }
        }
        model.onCaptureMJPEG = { [weak self] on in
            guard let self, on != model.captureMJPEG else { return }
            model.captureMJPEG = on
            model.saveTuning()
            Log.write("压缩传输（MJPEG）：\(on ? "开" : "关")")
            if let s = source, case .device = s { Task { await self.switchTo(s, force: true) } }
        }
        model.onCaptureFps = { [weak self] fps in
            guard let self, fps != model.captureFps else { return }
            model.captureFps = fps
            model.saveTuning()
            Log.write("采集帧率：\(fps)")
            if let s = source, case .device = s { Task { await self.switchTo(s, force: true) } }
        }
        model.onOpenLogs = {
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/FrameInterp")
            NSWorkspace.shared.open(dir)
        }
    }

    /// 重新列出可选的输入（采集卡同步列，窗口异步列）
    func refreshSources() {
        Task {
            // 没授权时不扫窗口：一扫就会弹录屏权限
            if CGPreflightScreenCaptureAccess() || screenVerified, let w = try? await WindowCapture.windows() { cachedWindows = w }
            var list: [SourceOption] = []
            for d in Devices.video() where !Devices.isCamera(d) {
                let src = Source.device(id: d.uniqueID, name: d.localizedName)
                list.append(SourceOption(id: src.optionID, title: d.localizedName, group: .card, source: src))
            }
            model.screenAccess = CGPreflightScreenCaptureAccess() || screenVerified
            let mine = ProcessInfo.processInfo.processIdentifier
            // 串流 App 的窗口排在前面，模拟器其次
            let wins = cachedWindows.filter { $0.owningApplication?.processID != mine }
                .sorted { (WindowCapture.rank($0), Emulator.match($0) == nil ? 1 : 0) < (WindowCapture.rank($1), Emulator.match($1) == nil ? 1 : 0) }
            for w in wins {
                let app = w.owningApplication?.applicationName ?? "?"
                let t = ((w.title ?? "").isEmpty ? app : "\(app) — \(w.title!)") + (!w.isOnScreen && WindowCapture.isNativeFullScreen(w) ? "（系统全屏）" : "")
                let src = Source.window(id: w.windowID, title: t)
                list.append(SourceOption(id: src.optionID, title: t, group: .window, source: src,
                                         app: app, windowTitle: w.title ?? "", streaming: WindowCapture.isStreaming(w) && !WindowCapture.isWebXbox(w),
                                         unsupported: WindowCapture.isWebXbox(w),
                                         emulator: Emulator.match(w)?.name ?? "",
                                         size: "\(Int(w.frame.width))×\(Int(w.frame.height))",
                                         platform: WindowCapture.platform(w)))
            }
            // 测试图案只在开发测试（--test / --selftest）时出现
            if opts.test || opts.selftest {
                list.append(SourceOption(id: Source.test.optionID, title: "测试图案", group: .other, source: .test))
            }
            // 当前选中的窗口如果不在列表里（比如被遮住），也保留它
            if let cur = source, !list.contains(where: { $0.id == cur.optionID }) {
                list.append(SourceOption(id: cur.optionID, title: cur.label, group: .window, source: cur))
            }
            model.sources = list
        }
    }

    // MARK: - 菜单

    // 2026-11-28 重做：按 macOS 习惯——「设置…」放进应用菜单，加「窗口」「帮助」菜单，菜单项配 SF Symbols 小图标、分组标题，
    // 补帧 / 显示里的开关都带勾选状态（打开菜单时刷新）
    let interpMenu = NSMenu(title: L("补帧"))
    let viewMenu = NSMenu(title: L("显示"))
    var guardItem: NSMenuItem?, sharpScaleItem: NSMenuItem?
    var sharpItems: [Int: NSMenuItem] = [:]

    /// 加一个带图标的菜单项
    @discardableResult
    private func item(_ m: NSMenu, _ title: String, _ icon: String?, _ action: Selector?, key: String = "", mods: NSEvent.ModifierFlags = [.command], tag: Int = 0) -> NSMenuItem {
        let it = m.addItem(withTitle: L(title), action: action, keyEquivalent: key)
        if !key.isEmpty { it.keyEquivalentModifierMask = mods }
        if let icon { it.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil) }
        it.tag = tag
        return it
    }

    func buildMenus() {
        let main = NSMenu()

        // 应用菜单
        let appMenu = NSMenu()
        item(appMenu, "关于 FrameInterp", nil, #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        appMenu.addItem(.separator())
        item(appMenu, "设置…", "gearshape", #selector(togglePanel), key: ",")
        appMenu.addItem(.separator())
        item(appMenu, "隐藏 FrameInterp", nil, #selector(NSApplication.hide(_:)), key: "h")
        item(appMenu, "隐藏其他", nil, #selector(NSApplication.hideOtherApplications(_:)), key: "h", mods: [.command, .option])
        item(appMenu, "全部显示", nil, #selector(NSApplication.unhideAllApplications(_:)))
        appMenu.addItem(.separator())
        item(appMenu, "退出 FrameInterp", nil, #selector(quitAction), key: "q")
        let appItem = NSMenuItem(); appItem.submenu = appMenu; main.addItem(appItem)

        // 输入（打开时按当前设备重建）
        inputMenu.delegate = self
        let inItem = NSMenuItem(); inItem.submenu = inputMenu; main.addItem(inItem)

        // 补帧
        interpMenu.delegate = self
        interpItem = item(interpMenu, "开启补帧", "sparkles", #selector(toggleInterp), key: "e")
        guardItem = item(interpMenu, "字幕和提示保护", "captions.bubble", #selector(toggleGuard))
        interpMenu.addItem(.separator())
        let resMenu = NSMenu()
        for (h, title) in [(0, "原分辨率（画质好）"), (720, "720p（更快，中间帧略软）")] {
            iresItems[h] = item(resMenu, title, nil, #selector(setIres(_:)), tag: h)
        }
        let resItem = item(interpMenu, "补帧分辨率", "square.resize", nil)
        resItem.submenu = resMenu
        let fgItem = NSMenuItem(); fgItem.submenu = interpMenu; main.addItem(fgItem)

        // 显示
        viewMenu.delegate = self
        item(viewMenu, "进入全屏幕", "arrow.up.left.and.arrow.down.right", #selector(toggleFullScreen), key: "f", mods: [.command, .control])   // macOS 27 显示成 🌐F，⌃⌘F 留作隐藏备用
        statsItem = item(viewMenu, "帧数和延迟", "speedometer", #selector(toggleStats), key: "i")
        viewMenu.addItem(.separator())
        sharpScaleItem = item(viewMenu, "清晰放大", "arrow.up.backward.and.arrow.down.forward", #selector(toggleSharpScale))
        let sharpMenu = NSMenu()
        for (i, t) in ["关", "柔和", "标准", "锐利", "最锐"].enumerated() {
            sharpItems[i] = item(sharpMenu, t, nil, #selector(setSharp(_:)), tag: i)
        }
        let sharpItem = item(viewMenu, "锐化", "wand.and.rays", nil)
        sharpItem.submenu = sharpMenu
        #if FI_KEYPAD
        viewMenu.addItem(.separator())
        keyPadItem = item(viewMenu, "键盘当手柄（测试版）", "keyboard", #selector(toggleKeyPad))
        KeyPad.shared.install()
        KeyPad.shared.onToggle = { [weak self] on in
            self?.keyPadItem?.state = on ? .on : .off
            let n: (PadAction) -> String = { KeyPad.shared.key(for: $0).map(KeyPad.keyName) ?? "—" }
            self?.view?.flash(on ? "键盘当手柄：开 · 摇杆 \(n(.stickUp))\(n(.stickLeft))\(n(.stickDown))\(n(.stickRight)) · A \(n(.a)) · B \(n(.b)) · X \(n(.x)) · Y \(n(.y)) · 键位在设置里改（\(n(.toggle)) 关）"
                                 : "键盘当手柄：关")
        }
        #endif
        let dispItem = NSMenuItem(); dispItem.submenu = viewMenu; main.addItem(dispItem)

        // 窗口（系统标准）
        let winMenu = NSMenu(title: L("窗口"))
        item(winMenu, "最小化", nil, #selector(NSWindow.performMiniaturize(_:)), key: "m")
        item(winMenu, "缩放", nil, #selector(NSWindow.performZoom(_:)))
        winMenu.addItem(.separator())
        item(winMenu, "前置全部窗口", nil, #selector(NSApplication.arrangeInFront(_:)))
        let winItem = NSMenuItem(); winItem.submenu = winMenu; main.addItem(winItem)
        NSApp.windowsMenu = winMenu

        // 帮助
        let helpMenu = NSMenu(title: L("帮助"))
        item(helpMenu, "FrameInterp 使用说明", "questionmark.circle", #selector(openHelp))
        item(helpMenu, "打开日志文件夹", "folder", #selector(openLogsAction))
        let helpItem = NSMenuItem(); helpItem.submenu = helpMenu; main.addItem(helpItem)
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = main
        updateMenuState()
    }

    @objc func toggleGuard() { model.subtitleGuard.toggle(); model.onTuning(); updateMenuState() }
    @objc func toggleSharpScale() { model.sharpScale.toggle(); model.onTuning(); updateMenuState() }
    @objc func setSharp(_ sender: NSMenuItem) {
        if sender.tag == 0 { model.autoSharpHiRes = false }
        model.sharpLevel = sender.tag; model.onTuning(); updateMenuState()
    }
    @objc func openHelp() { if let u = URL(string: "https://github.com/wjc20080427-droid/frameinterp#readme") { NSWorkspace.shared.open(u) } }
    @objc func openLogsAction() { model.onOpenLogs() }
    @objc func openWizardAction() { model.onOpenWizard() }

    func updateMenuState() {
        interpItem?.state = interpOn ? .on : .off
        for (h, it) in iresItems { it.state = h == ires ? .on : .off }
        statsItem?.state = model.showFPS ? .on : .off
        guardItem?.state = model.subtitleGuard ? .on : .off
        sharpScaleItem?.state = model.sharpScale ? .on : .off
        for (i, it) in sharpItems { it.state = i == model.sharpLevel ? .on : .off }
    }

    /// 打开"输入"菜单时按当前设备重建
    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated { if menu === inputMenu { rebuildInputMenu() } else { updateMenuState() } }
    }

    func rebuildInputMenu() {
        let m = inputMenu
        m.removeAllItems()
        m.addItem(NSMenuItem.sectionHeader(title: L("采集卡")))
        let cards = Devices.video().filter { !Devices.isCamera($0) }
        if cards.isEmpty { item(m, "没有检测到采集卡", nil, nil).isEnabled = false }
        for d in cards {
            addSourceItem(m, .device(id: d.uniqueID, name: d.localizedName), title: d.localizedName)
            m.items.last?.image = NSImage(systemSymbolName: "cable.connector", accessibilityDescription: nil)
        }
        m.addItem(.separator())
        m.addItem(NSMenuItem.sectionHeader(title: L("串流")))
        #if FI_XNATIVE
        // Xbox：原生串流，直接列主机
        let acc = XboxAccount.shared
        if case .signedIn = acc.state {
            for c in acc.consoles {
                addSourceItem(m, .xbox(serverId: c.id, name: c.name), title: "\(c.name)（\(c.typeName)）")
                m.items.last?.image = NSImage(systemSymbolName: "gamecontroller", accessibilityDescription: nil)
            }
            if acc.consoles.isEmpty { item(m, "没找到 Xbox 主机", nil, nil).isEnabled = false }
        } else {
            item(m, "登录 Xbox 账号…", "person.crop.circle", #selector(xboxSignInAction))
        }
        #else
        item(m, "Xbox 网页串流…", "globe", #selector(openWebXboxAction))
        if webHost?.loaded == true { item(m, "回到 Xbox 网页", "arrow.uturn.backward", #selector(openWebXboxAction), key: "j") }
        #endif
        // 串流 App、模拟器的窗口
        windowsMenu.removeAllItems()
        let mine = ProcessInfo.processInfo.processIdentifier
        let list = cachedWindows.filter {
            $0.owningApplication?.processID != mine
                && !($0.owningApplication?.bundleIdentifier ?? "").lowercased().contains("screencontinuity")
                && (WindowCapture.isStreaming($0) || Emulator.match($0) != nil)
        }
        if list.isEmpty { windowsMenu.addItem(withTitle: L("没有发现串流 App 或模拟器的窗口"), action: nil, keyEquivalent: "").isEnabled = false }
        for w in list {
            let app = w.owningApplication?.applicationName ?? "?"
            let t = (w.title ?? "").isEmpty ? app : "\(app) — \(w.title!)"
            addSourceItem(windowsMenu, .window(id: w.windowID, title: t), title: t)
        }
        item(m, "PlayStation / 模拟器窗口", "macwindow", nil).submenu = windowsMenu
        item(m, "从所有窗口里选…", "rectangle.on.rectangle", #selector(openPickerAction))
        if opts.test || opts.selftest {
            m.addItem(.separator())
            addSourceItem(m, .test, title: "测试图案（30 帧 + 不规则重复）")
        }
        m.addItem(.separator())
        item(m, "选主机，一键配置…", "wand.and.stars", #selector(openWizardAction))
        item(m, "停止", "stop.circle", #selector(stopSourceAction), key: ".")
        // 后台刷新窗口列表，下次打开菜单时用
        refreshWindowList()
    }

    @objc func openPickerAction() { openWindowPicker() }
    #if FI_XNATIVE
    @objc func xboxSignInAction() { model.streamTab = 0; XboxAccount.shared.signIn() }
    #endif

    private func addSourceItem(_ m: NSMenu, _ s: Source, title: String) {
        let it = m.addItem(withTitle: L(title), action: #selector(pickSource(_:)), keyEquivalent: "")
        it.representedObject = SourceBox(s)
        it.state = source == s ? .on : .off
    }

    func refreshWindowList() {
        Task {
            if CGPreflightScreenCaptureAccess() || screenVerified, let w = try? await WindowCapture.windows() { cachedWindows = w }
        }
    }

    @objc func pickSource(_ sender: NSMenuItem) {
        guard let b = sender.representedObject as? SourceBox else { return }
        Task { await switchTo(b.source) }
    }

    @objc func stopSourceAction() {
        Task { await switchTo(nil) }
    }

    @objc func toggleInterp() { setInterp(!interpOn) }

    // MARK: 配置向导（只选主机）
    let wizard = WizardModel()
    func setupWizard() {
        model.wizard = wizard
        wizard.load()
        model.onOpenWizard = { [weak self] in self?.openWizard() }
        wizard.onClose = { [weak self] in
            guard let self else { return }
            wizard.save(done: true) // 关掉也算看过，不再自动弹
            model.showWizard = false
        }
        wizard.onApply = { [weak self] c in self?.applyConsole(c) }
    }
    func openWizard() {
        model.showSettings = false
        wizard.availableHeights = model.availableHeights
        wizard.heightMaxFps = model.heightMaxFps
        wizard.captureHeight = model.availableHeights.contains(model.captureHeight) ? model.captureHeight : 1080
        wizard.captureFps = model.captureFps
        model.showWizard = true
        Log.write("打开配置向导")
    }
    /// 套用这台主机的默认配置：采集 1080p 60 不压缩、补帧开、按主机定锐化
    func applyConsole(_ c: Console) {
        let date = Date().formatted(.dateTime.month().day())
        wizard.console = c
        wizard.appliedSummary = "\(c.name) · 主机输出 \(c.output) · 采集 \(UIModel.resName(wizard.captureHeight)) \(wizard.captureFps) 帧 · 补帧开 · 锐化 \(c.sharpName)（\(date) 应用）"
        wizard.save(done: true)
        model.showWizard = false
        model.captureHeight = wizard.captureHeight
        model.captureFps = wizard.captureFps
        model.captureMJPEG = false
        model.sharpLevel = c.sharpLevel
        model.sharpScale = true
        model.autoSharpHiRes = true
        model.antiFlickerDown = true
        model.compressedSoftSharp = true
        applyTuning()
        setInterp(true)
        Log.write("应用主机配置：\(wizard.appliedSummary)")
        if let s = source, case .device = s { Task { await self.switchTo(s, force: true) } }
        view?.flash("已应用 \(c.name) 配置")
    }

    func setInterp(_ on: Bool) {
        // 第一次用采集卡开补帧：弹配置向导
        if on, !wizard.done, !model.showWizard, case .device = source, !opts.test, !opts.selftest {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.openWizard() }
        }
        interpOn = on
        model.interpOn = on
        pipeline?.interpEnabled = on
        updateMenuState()
        view?.flash(on ? "补帧：开" : "补帧：关")
        Log.write("补帧：\(on ? "开" : "关")")
    }

    @objc func setIres(_ sender: NSMenuItem) { applyIres(sender.tag) }

    /// 调节卡片的设置 → 管线（立即生效，不用重开输入）
    func applyTuning() {
        model.saveTuning()
        view?.markInterpolated = model.markInterp
        // 清晰放大开着时锐化由它来做（缩放后的画面上做），旧的画面增强关掉
        let useScaler = model.sharpScale && scaler != nil && !opts.selftest
        if let s = scaler {
            s.enabled = useScaler
            s.sharpness = model.sharpness
            s.autoSharpHiRes = model.autoSharpHiRes
            s.wideDown = model.antiFlickerDown
            s.compressedSharpFactor = model.compressedSoftSharp ? 0.5 : 1
        }
        if let e = enhancer, !opts.selftest {
            e.sharpness = useScaler ? 0 : model.sharpness
            e.upscale = model.upscaleOn
        }
        guard let p = pipeline, !opts.selftest else { return }
        p.enhancer = enhancer
        p.scaler = useScaler ? scaler : nil
        let d = model.dupParams
        p.dup.threshold = d.thr
        p.dup.changedPct = d.pct
        p.cutThreshold = model.cutThreshold
        p.queue.limit = model.queueLimit
        p.skipLateMs = model.skipLateMs
        p.interpSharpness = model.interpSharpness
        p.interpSharpAll = model.interpSharpAll
        p.stillPassthrough = model.stillDirect
        for g in p.textGuards { g.enabled = model.subtitleGuard }
        Log.write("调节：重复帧 \(["宽松","标准","灵敏"][model.dupLevel])(thr \(d.thr), pct \(d.pct))，切镜头 \(["关闭","标准","灵敏"][model.cutLevel])，\(["低延迟","平衡","流畅"][model.smoothLevel])(队列 \(model.queueLimit))，太慢跳过 \(model.skipLate ? "开" : "关")，锐化 \(["关","柔和","标准","锐利","最锐"][model.sharpLevel])，补帧锐化 \(["关","只补帧","全部"][model.interpSharpLevel])，档位 \(["低延迟","平衡","质量","自定义"][model.preset])，MetalFX 放大 \(model.upscaleOn ? "开" : "关")")
    }

    func applyIres(_ h: Int) {
        guard h != ires else { return }
        ires = h
        model.ires = h
        model.saveTuning()
        updateMenuState()
        Log.write("补帧分辨率：\(h == 0 ? "原分辨率" : "\(h)p")")
        if let s = source { Task { await switchTo(s, force: true) } }
    }


    @objc func toggleStats() { model.onShowFPS(!model.showFPS) }
    @objc func openWebXboxAction() { openWebXbox() }
    #if FI_KEYPAD
    var keyPadItem: NSMenuItem?
    /// 测试版：键盘当手柄开 / 关（要先打开 Xbox 网页）
    @objc func toggleKeyPad() { KeyPad.shared.toggle() }
    #endif

    /// 打开内嵌的 xbox.com/play：网页直接显示在主窗口画面区，登录、选主机 / 游戏，开始串流后点顶栏「开始补帧」
    func openWebXbox() {
        let h = webHost ?? {
            let h = WebStreamHost()
            h.onLog = { Log.write("Xbox 网页：" + $0) }
            h.onLoadState = { [weak self] loading, p, err in
                guard let self else { return }
                if model.webLoading != loading { model.webLoading = loading }
                model.webProgress = p
                if model.webError != err { model.webError = err }
            }
            webHost = h
            model.webSlot = h.slot
            #if FI_KEYPAD
            KeyPad.shared.host = h
            #endif
            Log.write("Xbox 网页：打开（关遮挡检测 \(h.occlusionOff ? "成功" : "失败：没有这个私有接口，被挡住时网页可能停止渲染")）")
            return h
        }()
        model.showSettings = false
        model.showWindowPicker = false
        // 正在用别的输入（采集卡、其他窗口）就先停掉；正在补这个网页的话停掉采集，网页挪回来
        if source != nil { Task { await switchTo(nil) } }
        if ProcessInfo.processInfo.environment["FI_WEBXBOX"]?.hasPrefix("test") == true { h.openTestPage() } else { h.openXbox() }
        h.startGamepads()
        h.showInApp()
        model.webMode = true
        model.webLoaded = true
        window?.makeFirstResponder(h.webView)
    }

    /// 开始补帧：网页挪进主窗口后面的采集窗口，抓它的画面补帧
    func startWebXbox() {
        guard let h = webHost, let w = window else { return }
        h.moveToCapture(behind: w)
        model.webMode = false
        Task {
            await switchTo(.window(id: h.windowID, title: L("Xbox 网页串流（内嵌）")), force: true)
            view?.flash(L("补帧中 · ⌘J 回到网页（选游戏、退出游戏）"))
        }
    }

    /// 关掉网页：停掉串流，回首页
    func closeWebXbox() {
        guard let h = webHost else { return }
        if h.capturing { Task { await switchTo(nil) } }
        h.close()
        model.webMode = false
        model.webLoaded = false
    }

    @objc func quitAction() { quit() }

    /// 全屏时鼠标 2 秒不动就隐藏（2026-11-21 用户要求从 5 秒改成 2 秒）（一动系统自动显示）。窗口模式不藏
    func pokeCursor() {
        cursorHideWork?.cancel()
        guard model.autoHideCursor, model.isFullScreen else { return }
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.model.autoHideCursor, self.model.isFullScreen, NSApp.isActive else {
                    Log.write("鼠标隐藏跳过：开关 \(self.model.autoHideCursor) 全屏 \(self.model.isFullScreen) 前台 \(NSApp.isActive)")
                    return
                }
                NSCursor.setHiddenUntilMouseMoves(true)
                Log.write("鼠标 2 秒没动，已隐藏")
            }
        }
        cursorHideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: w)
    }

    @objc func togglePanel() {
        model.showSettings.toggle()
        if model.showSettings { pokeChrome() }
    }

    /// 等串流 App 开出新窗口（断线重连），找到就接着采集它；每 2 秒看一次，最多等 10 分钟
    var followBundle: String?
    var followAppName = "串流 App"
    func followStreamingApp(bundle: String, gen: Int, tries: Int = 0) {
        guard tries < 300 else { view?.setMessage("⚠ 串流窗口一直没回来，请重新选择窗口"); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == gen else { return } // 用户已经换了输入
                Task {
                    let wins = (try? await WindowCapture.windows()) ?? []
                    let key: (SCWindow) -> String = { w in
                        let b = w.owningApplication?.bundleIdentifier ?? ""
                        return b.isEmpty ? "name:" + (w.owningApplication?.applicationName ?? "") : b
                    }
                    if let w = wins.filter({ key($0) == bundle && $0.frame.width >= 320 })
                        .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
                        let app = w.owningApplication?.applicationName ?? "串流 App"
                        let t = (w.title ?? "").isEmpty ? app : "\(app) — \(w.title!)"
                        Log.write("串流窗口回来了：\(t)，接着采集")
                        await self.switchTo(.window(id: w.windowID, title: t), force: true)
                        self.view?.flash("已重新接上 \(app)")
                    } else {
                        self.followStreamingApp(bundle: bundle, gen: gen, tries: tries + 1)
                    }
                }
            }
        }
    }

    /// 窗口选择器：刷新窗口列表 + 每个窗口拍一张小预览图
    func openWindowPicker() {
        model.showSettings = false
        model.showWindowPicker = true
        Task {
            // 不只看 CGPreflightScreenCaptureAccess：在系统设置里刚打开权限时它在程序重开前一直说"没有"，
            // 直接试着读一次窗口列表，读得到就是有权限
            let wins: [SCWindow]
            do {
                wins = try await WindowCapture.windows()
                screenVerified = true
                model.screenAccess = true
            } catch {
                model.screenAccess = false
                Log.write("打开窗口选择器：读不到窗口列表（录屏权限没生效）：\(error.localizedDescription)")
                return
            }
            Log.write("打开窗口选择器：\(wins.count) 个窗口")
            cachedWindows = wins
            refreshSources()
            let mine = ProcessInfo.processInfo.processIdentifier
            for w in wins.filter({ $0.owningApplication?.processID != mine }).prefix(24) {
                let cfg = SCStreamConfiguration()
                cfg.width = 480
                cfg.height = max(2, Int(480 * w.frame.height / max(w.frame.width, 1)))
                cfg.showsCursor = false
                if let img = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: cfg) {
                    model.windowThumbs["win:\(w.windowID)"] = NSImage(cgImage: img, size: .zero)
                }
            }
        }
    }

    /// 录屏权限：第一次会弹系统询问；拒绝过的话只能去系统设置里打开（打开后要重新启动本程序）
    func requestScreenAccess() {
        if CGPreflightScreenCaptureAccess() || screenVerified { model.screenAccess = true; openWindowPicker(); return }
        let ok = CGRequestScreenCaptureAccess()
        model.screenAccess = ok
        model.screenAsked = true
        Log.write("请求录屏权限：\(ok ? "已允许" : "未允许（打开系统设置；打开后要重新打开本程序）")")
        if !ok, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 重新打开本程序（录屏权限要重开才生效）
    func relaunch() {
        Log.write("重新打开程序（让录屏权限生效）")
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self.quit() } }
        }
    }

    /// 右上角「开始 / 停止」
    func startStop() {
        if pipeline != nil || model.opening {
            Log.write("停止（用户点了停止）")
            Task { await switchTo(nil) }
            return
        }
        let s = lastSource.flatMap { last in model.sources.contains { $0.id == last.optionID } ? last : nil } ?? initialSource()
        guard let s else {
            refreshSources()
            model.message = "没有找到采集卡：确认采集卡已经接到 Mac（建议 USB 3 接口），再点「连接」"
            return
        }
        Task { await switchTo(s) }
    }

    /// 系统红绿灯藏起来，由顶栏自己画（系统标题栏只有 ~28 点高，挪不进 52 点的顶栏里居中）
    func placeTrafficLights() {
        guard let win = window else { return }
        for t in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            win.standardWindowButton(t)?.isHidden = true
        }
    }

    nonisolated func windowDidResize(_ n: Notification) {
        MainActor.assumeIsolated { placeTrafficLights() }
    }

    /// 全屏时显示顶栏和工具栏，2.5 秒没动就收起（设置面板开着时不收）
    func pokeChrome() {
        guard model.isFullScreen else { return }
        if !model.chromeVisible { model.chromeVisible = true }
        chromeHideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.model.isFullScreen, !self.model.showSettings else { return }
                self.model.chromeVisible = false
            }
        }
        chromeHideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: w)
    }

    func key(_ k: String) {
        switch k.lowercased() {
        case " ": toggleInterp()
        case "f": toggleFullScreen()
        case "q": quit()
        default: break
        }
    }

    // MARK: - 切换来源

    func stopCurrent() {
        generation += 1
        testSource?.stop(); testSource = nil
        capture?.session.stopRunning(); capture = nil
        windowCapture?.stop(); windowCapture = nil
        #if FI_XNATIVE
        xboxSession?.stop(); xboxSession = nil
        #endif
        model.nativeConnecting = nil
        audio?.stop(); audio = nil
        audioVideoDevice = nil
        view?.queue = nil
        pipeline = nil
        if let old = interp {
            interp = nil
            DispatchQueue.global().async { old.stop() } // endSession 可能要等正在算的一帧
        }
    }

    /// attempt：采集卡格式的第几个候选（打开后没有帧时自动往下换，见 Devices.candidates）
    func switchTo(_ s: Source?, force: Bool = false, attempt: Int = 0) async {
        if switching { return }
        if s == source && !force && pipeline != nil { return }
        switching = true
        defer { switching = false }
        stopCurrent()
        source = s
        model.selectedID = s?.optionID
        model.hasInput = false
        model.interpStatus = "—"
        model.message = nil
        model.sourceW = 0; model.sourceH = 0
        scaler?.compressed = false
        // 同一个串流窗口重新打开（比如窗口大小变了）时保持覆盖全屏，不闪一下退出再进
        leaveStreamSpace()
        guard let s else {
            applyWindowAlpha()
            model.opening = false
            model.inputName = ""
            view?.setMessage(nil)
            model.inputDetail = "未选择"
            window?.title = "FrameInterp"
            return
        }
        lastSource = s
        applyWindowAlpha()
        model.inputMode = sourceIsWindow ? 1 : { if case .xbox = s { return 1 }; return 0 }()
        model.showWindowPicker = false
        model.opening = true
        defer { model.opening = false }
        model.inputName = s.label
        model.inputDetail = "正在打开…"
        Log.write("切换输入：\(s.label)")
        view?.setMessage("正在打开：\(s.label)…")
        let gen = generation

        // 1. 确定尺寸、准备采集对象
        var w = 1920, h = 1080
        var device: AVCaptureDevice?
        var wc: WindowCapture?
        var test: TestSource?
        switch s {
        case .xbox:
            // 原生 Xbox 串流：解码出来的画面统一转成 1920×1080 给补帧
            (w, h) = (1920, 1080)
            model.availableHeights = [1080]
            model.heightMaxFps = [:]
        case .test:
            let t = TestSource()
            test = t
            (w, h) = (t.width, t.height)
            model.availableHeights = [1080, 1440, 2160]
            model.heightMaxFps = [:]
            // 测试钩子：FI_FAKECAPS=1080:60,1440:30 假装采集卡只有这些档（看分辨率菜单的样子）
            if let fake = ProcessInfo.processInfo.environment["FI_FAKECAPS"] {
                var caps: [Int: Int] = [:]
                for p in fake.split(separator: ",") {
                    let kv = p.split(separator: ":").compactMap { Int($0) }
                    if kv.count == 2 { caps[kv[0]] = kv[1] }
                }
                model.heightMaxFps = caps
                model.availableHeights = caps.keys.sorted()
            }
        case .device(let id, _):
            guard let d = Devices.video().first(where: { $0.uniqueID == id }) else {
                return fail("找不到设备：\(s.label)（已拔出？）")
            }
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                return fail("没有摄像头权限：系统设置 → 隐私与安全性 → 摄像头，打开 FrameInterp（或终端）")
            }
            device = d
            // 这张卡支持哪些分辨率；选的档不支持就用它支持的最高一档（不超过所选）
            Devices.preferCompressed = model.captureMJPEG
            model.mjpegAvailable = d.formats.contains(where: Devices.isMJPEG)
            if attempt == 0 { Log.write("设备格式（\(d.formats.count) 个）：" + d.formats.map(Devices.describe).joined(separator: "；")) }
            let caps = Devices.heightMaxFps(d)
            model.heightMaxFps = caps
            model.availableHeights = caps.isEmpty ? [1080] : caps.keys.sorted()
            if !Devices.isScreenDevice(d) {
                let cands = Devices.candidates(d, fps: Double(model.captureFps), height: model.captureHeight)
                if !cands.isEmpty {
                    let c = cands[min(attempt, cands.count - 1)]
                    formatChoice = c
                    formatChoices = cands.count
                    let dim = CMVideoFormatDescriptionGetDimensions(c.0.formatDescription)
                    (w, h) = (Int(dim.width), Int(dim.height))
                } else {
                    formatChoice = nil
                    (w, h) = VideoCapture.probeSize(d, fps: Double(model.captureFps), height: model.captureHeight)
                }
            } else {
                formatChoice = nil
                (w, h) = VideoCapture.probeSize(d, fps: Double(model.captureFps), height: model.captureHeight)
            }
        case .iphone, .window:
            let found: SCWindow?
            do {
                switch s {
                case .window(let id, _):
                    if let wid = webHost?.windowID, wid == id {
                        found = try await WindowCapture.ownWindow(id)
                    } else {
                        found = try await WindowCapture.windows().first { $0.windowID == id }
                    }
                default:
                    found = try await WindowCapture.pick(opts.window.flatMap { $0.isEmpty ? nil : $0 })
                }
            } catch {
                return fail("读不到窗口：需要录屏权限\n系统设置 → 隐私与安全性 → 录屏与系统录音，打开 FrameInterp（或终端），然后重新打开程序")
            }
            followBundle = nil
            guard let win = found else {
                return fail(s == .iphone ? "没找到 iPhone 镜像窗口：先打开「iPhone 镜像」App，再在「输入」菜单里选它"
                                         : "窗口已关闭：\(s.label)")
            }
            // 串流 App（PS Remote Play、Chiaki…）断线重连时会关掉旧窗口、开新窗口：记下 App，窗口没了就自动找它的新窗口
            let ownWeb = webHost.map { $0.windowID == win.windowID } ?? false
            if WindowCapture.isStreaming(win) && !ownWeb {
                let bid = win.owningApplication?.bundleIdentifier ?? ""
                followBundle = bid.isEmpty ? "name:" + (win.owningApplication?.applicationName ?? "") : bid
                followAppName = win.owningApplication?.applicationName ?? "串流 App"
            }
            let c = WindowCapture()
            c.autoCrop = model.windowAutoCrop
            if ownWeb, let h = webHost { c.contentOverride = h.captureRect }
            c.onLog = { msg in DispatchQueue.main.async { Log.write(msg) } }
            c.onNeedRestart = { [weak self] in
                DispatchQueue.main.async {
                    guard let self, let cur = self.source, cur == s else { return }
                    Task { await self.switchTo(cur, force: true) }
                }
            }
            // 用串流窗口所在屏幕的缩放倍数（Retina 是 2）
            let winCenter = CGPoint(x: win.frame.midX, y: win.frame.midY)
            let scr = NSScreen.screens.first { s in
                let h = NSScreen.screens.first?.frame.height ?? 0 // SCWindow 坐标原点在左上，NSScreen 在左下
                return s.frame.contains(CGPoint(x: winCenter.x, y: h - winCenter.y))
            } ?? NSScreen.main
            c.configure(window: win, scale: scr?.backingScaleFactor ?? 2)
            wc = c
            fullScreenStream = !win.isOnScreen && WindowCapture.isNativeFullScreen(win) ? win : nil
            if let e = Emulator.match(win) {
                Log.write("模拟器窗口：\(e.name)（\(e.system)），屏幕 \(Emulator.screenHz)Hz")
                view?.flash(e.shortTip)
            }
            if WindowCapture.isWebXbox(win) {
                Log.write("⚠ 选的是浏览器里的网页版 Xbox 串流（失去焦点会暂停画面，建议改用内嵌的「Xbox 网页」）")
                view?.flash("⚠ 浏览器里的网页版 Xbox 会因失去焦点暂停：请改用「Xbox 网页」（内嵌）")
            }
            (w, h) = (c.width, c.height)
            model.availableHeights = [1080]
            model.heightMaxFps = [:]
        }
        guard gen == generation else { return }

        // 2. 补帧器 + 管线
        guard let vt = VTInterpolator(width: w, height: h, procHeight: autoProc720 ? 720 : ires, unifiedHiRes: true, forceFormat: opts.pixfmt) else {
            return fail("创建补帧器失败（\(w)x\(h) 不支持？）")
        }
        var o = opts
        o.interpOn = interpOn
        let p = Pipeline(options: o, interp: vt, stats: stats)
        interp = vt
        pipeline = p
        p.refreshMs = 1000.0 / Double(max(30, window?.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 60))
        applyTuning()
        view?.queue = p.queue
        if let v = view { p.directOut = { [weak v] pb, t in v?.enqueueDirect(pb, arrivalMs: t) } }
        if let v = view { p.directInterp = { [weak v] pb, t in v?.showInterpNow(pb, arrivalMs: t) ?? false } }
        window?.title = "FrameInterp — \(s.label)"
        model.hasInput = true
        model.sourceW = w; model.sourceH = h
        scaler?.sourceHeight = h
        model.inputDetail = "\(w)×\(h)" + (vt.width != w ? "，补帧在 \(vt.width)×\(vt.height) 上做" : "")
        model.interpStatus = "正在启动补帧…"
        Log.write("输入：\(s.label)  \(w)x\(h)\n\(vt.describe)")
        view?.setMessage(nil)
        view?.flash("正在启动补帧（几秒内）…")
        vt.start { [weak self] vt in
            MainActor.assumeIsolated {
                guard let self, self.interp === vt else { return }
                if let e = vt.startError {
                    Log.write("⚠ 补帧不可用（补帧尺寸 \(vt.width)×\(vt.height)，\(App.machineInfo)）：\(e)")
                    // 1080p 补帧不行：自动换 720p 再试一次（有的 Mac 只支持其中一种尺寸）
                    if vt.height > 720, !self.autoProc720, let cur = self.source {
                        self.autoProc720 = true
                        Log.write("自动改用 720p 补帧再试")
                        self.view?.flash("1080p 补帧不可用，自动改用 720p 补帧…")
                        Task { await self.switchTo(cur, force: true) }
                        return
                    }
                    self.view?.flash("⚠ 补帧不可用，只显示原画面")
                    self.model.interpStatus = "⚠ 补帧不可用（\(vt.width)×\(vt.height) 补帧在这台 Mac 上启动失败）\n\(App.machineInfo)\n"
                        + "画面照常显示，只是不补帧。请把 设置 → 状态 →「打开日志文件夹」里最新的日志发给作者\n\(e)"
                } else {
                    Log.write("补帧就绪：startSession \(Int(vt.startMs))ms，预热 \(Int(vt.warmupMs))ms" + (self.autoProc720 ? "，用 720p 补帧" + self.proc720Reason : ""))
                    self.view?.flash(self.autoProc720 ? "补帧就绪（这台 Mac 用 720p 补帧）" : "补帧就绪")
                    self.model.interpStatus = "Apple 低延迟补帧 · 已就绪" + (self.autoProc720 ? self.proc720Reason : "")
                }
            }
        }

        // 3. 开始采集（不等补帧就绪：先显示原画面）
        switch s {
        case .xbox(let sid, _):
            #if FI_XNATIVE
            guard let con = XboxAccount.shared.consoles.first(where: { $0.id == sid }),
                  let sess = XboxStreamSession(console: con, width: w, height: h, pixelFormat: vt.pixelFormat) else {
                return fail("原生串流：还没登录 Xbox 账号，或者找不到这台主机")
            }
            sess.onFrame = { pb, pts in p.handle(pb, pts: pts) }
            // 界面上的分辨率按主机实际发来的显示（局域网 1440p、公网常是 720p）
            sess.onSize = { [weak self, weak sess] w, h in
                guard let self else { return }
                if model.nativeConnecting != nil { withAnimation(.easeOut(duration: 0.35)) { self.model.nativeConnecting = nil } }
                model.sourceW = w; model.sourceH = h
                let sr = w == SuperRes720.inW && h == SuperRes720.inH && SuperRes720.enabled && sess?.superRes != nil
                scaler?.sourceHeight = sr ? SuperRes720.outH : h
                model.inputDetail = "\(w)×\(h)（主机发来的）" + (h > 1080 ? "，补帧在 1920×1080 上做" : sr ? "，AI 超分到 1920×1080" : "")
                if sr { Log.write("原生串流：主机发 720p，AI 超分到 1080p") }
            }
            // 连接过程盖绿色光球加载画面，第一帧画面到了再收起
            model.nativeConnecting = (title: "正在连接 \(con.name)", step: "正在请求主机串流…")
            sess.onStatus = { [weak self] st in
                guard let self, model.nativeConnecting != nil else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    self.model.nativeConnecting = (title: "正在连接 \(con.name)", step: st == "已连接" ? "已连上，正在接收画面…" : st)
                }
            }
            sess.onEnded = { [weak self, weak sess] why in
                guard let self, let sess, self.xboxSession === sess else { return }
                model.nativeConnecting = nil
                self.view?.setMessage("⚠ 原生串流：\(why)")
            }
            xboxSession = sess
            Task { [weak self] in
                do { try await sess.start() } catch {
                    guard let self, self.xboxSession === sess else { return }
                    self.fail("原生串流：\(error.localizedDescription)")
                }
            }
            #else
            return fail("这个版本没有原生 Xbox 串流")
            #endif
        case .test:
            let t = test!
            t.onFrame = { pb, pts in p.handle(pb, pts: pts) }
            testSource = t
            t.start()
        case .device:
            let c = VideoCapture()
            do { try c.configure(device: device!, pixelFormat: vt.pixelFormat, fps: Double(model.captureFps), height: model.captureHeight, choice: formatChoice) } catch {
                return fail("采集配置失败：\(error.localizedDescription)")
            }
            Log.write("采集格式：\(c.formatText)")
            scaler?.compressed = c.isCompressed
            c.onFirstFrame = { f in DispatchQueue.main.async { Log.write("实际收到的帧：\(f)") } }
            c.onColorInfo = { msg in DispatchQueue.main.async { Log.write(msg) } }
            model.inputDetail = c.formatText + (vt.width != c.width ? "\n补帧在 \(vt.width)×\(vt.height) 上做（Apple 补帧最高 1080p）" : "")
                + (attempt > 0 ? "\n⚠ 所选格式没有画面（多半是 USB 带宽不够），已自动改用这个格式" : "")
            model.sourceW = c.width; model.sourceH = c.height
            scaler?.sourceHeight = c.height
            c.onFrame = { pb, pts in p.handle(pb, pts: pts) }
            let st = stats
            c.onDrop = { st.with { $0.avfDrops += 1 } }
            capture = c
            DispatchQueue.global(qos: .userInitiated).async {
                c.session.startRunning()
                c.applyFrameRate()
                let rate = c.actualFrameRate
                DispatchQueue.main.async { Log.write("采集设备实际设置：\(rate)") }
            }
            // 开了 2.5 秒几乎没有帧（< 10 帧）：这个格式走不通（4K 60 帧在 5 Gb/s 的 USB 上就是这样，
            // 有时会先漏出 1 帧再停），换下一个候选
            if formatChoice != nil {
                let tried = c.formatText
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self, weak c] in
                    MainActor.assumeIsolated {
                        guard let self, let c, self.capture === c, gen == self.generation, c.frameCount < 10 else { return }
                        guard attempt + 1 < self.formatChoices else {
                            self.fail("采集卡开了但没有画面：检查主机是否开机、HDMI 是否插好")
                            return
                        }
                        Log.write("⚠ \(tried) 2.5 秒只收到 \(c.frameCount) 帧，自动换下一个格式（第 \(attempt + 2) 个）")
                        self.view?.flash("这个格式没有画面（可能是 USB 带宽不够），正在换一个…")
                        Task { await self.switchTo(s, force: true, attempt: attempt + 1) }
                    }
                }
            }
            // iPad 屏幕的声音已经在采集会话里放出来了
            if !opts.noAudio && !Devices.isScreenDevice(device!) { await startAudio(for: device!) }
        case .iphone, .window:
            let c = wc!
            c.onFrame = { pb, pts in p.handle(pb, pts: pts) }
            c.onStop = { [weak self] msg in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.windowCapture === c else { return }
                        Log.write("窗口采集停止：\(msg)")
                        if let b = self.followBundle {
                            self.view?.setMessage("串流窗口关闭了，正在等 \(self.followAppName) 的新窗口…")
                            self.followStreamingApp(bundle: b, gen: self.generation)
                        } else {
                            self.view?.setMessage("⚠ \(msg)")
                        }
                    }
                }
            }
            windowCapture = c
            do { try await c.start() } catch {
                return fail("窗口采集启动失败：\(error.localizedDescription)\n（可能需要录屏权限）")
            }
            if let fs = fullScreenStream { joinStreamSpace(fs) }
        }
    }

    private func fail(_ msg: String) {
        Log.write("⚠ \(msg)")
        stopCurrent()
        model.hasInput = false
        model.opening = false
        model.inputDetail = "⚠ 打开失败"
        model.message = msg
        view?.setMessage(nil)
    }

    /// 音频输入 / 输出设备列表（打开设置面板时、设备插拔时刷新）
    func refreshAudioDevices() {
        model.audioInputs = Devices.audio().map { AudioOption(id: $0.uniqueID, name: $0.localizedName) }
        model.audioOutputs = AudioOutputs.list()
    }

    /// 换了音频输入：只重开声音，不动画面
    func restartAudio() {
        audio?.stop(); audio = nil
        model.audioInActual = ""
        guard let d = audioVideoDevice, !opts.noAudio, !Devices.isScreenDevice(d) else { return }
        Task { await startAudio(for: d) }
    }

    func startAudio(for video: AVCaptureDevice) async {
        audioVideoDevice = video
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            view?.flash("⚠ 没有麦克风权限，声音不直通")
            return
        }
        refreshAudioDevices()
        // 选了输入设备就用它（拔掉了就退回自动）；自动 = 和采集卡配对的那个，找不到不会用麦克风代替
        let chosen = model.audioInID.isEmpty ? nil : Devices.audio().first { $0.uniqueID == model.audioInID }
        guard let a = chosen ?? Devices.pickAudio(opts.audioDevice, video: video) else {
            Log.write("⚠ 没找到和采集卡配对的音频设备（不会用麦克风代替）")
            view?.flash("⚠ 没找到采集卡的音频设备，可在设置里手动选音频输入")
            return
        }
        let p = AudioPassthrough()
        do {
            p.muted = !model.audioOn
            let out = model.audioOutID
            p.outputUID = out.isEmpty || !model.audioOutputs.contains(where: { $0.id == out }) ? nil : out
            try p.start(device: a)
            audio = p
            model.audioInActual = a.localizedName
            Log.write("音频直通：\(a.localizedName) → \(p.outputUID.flatMap { u in model.audioOutputs.first { $0.id == u }?.name } ?? "系统默认输出")")
            model.inputDetail += "\n声音：\(a.localizedName)"
        } catch { Log.write("⚠ 音频直通失败：\(error)") }
    }

    // MARK: - 统计

    func tickStats() {
        let snap = stats.snapshot(interpOn: pipeline?.interpActive ?? false,
                                  queueDepth: pipeline?.queue.count ?? 0, backend: "vt")
        if pipeline != nil {
            Log.write(snap.line)
            checkInterpSpeed(snap)
            if let gs = pipeline?.textGuards, pipeline?.interpActive == true {
                let on = gs.filter { $0.enabled && $0.maskCount > 0 }
                if !on.isEmpty { Log.write("  字幕 / 提示保护：" + on.map { "\($0.name) \($0.maskCount)" }.joined(separator: "，") + " 像素") }
            }
            if let s = pipeline?.scaler, s.enabled, snap.displayed > 0, !s.describe.isEmpty {
                model.enhanceStatus = "\(s.describe) · 每帧 \(f1(snap.enhanceAvg)) ms"
            } else if let e = enhancer, e.enabled, snap.displayed > 0, !e.describe.isEmpty {
                model.enhanceStatus = "\(e.describe) · 每帧 \(f1(snap.enhanceAvg)) ms"
            } else {
                model.enhanceStatus = ""
            }
        }
        model.snap = snap
        // 左上角浮窗：帧数 + 延迟（采集卡交给电脑 → 送上屏幕，不含采集卡本身和屏幕刷新）
        if model.showFPS {
            if pipeline != nil, snap.displayed > 0 {
                // 帧数 = 游戏本身的帧数（每秒真正的新画面，重复帧不算）；开补帧时再显示补完后屏幕上的帧数
                let lat = String(format: "延迟 %.0f ms", snap.capDelay + snap.latency)
                let fps = snap.interpOn ? "游戏 \(snap.unique) → \(snap.displayed) FPS" : "游戏 \(snap.unique) FPS"
                view?.setHud("\(fps)   \(lat)")
            } else {
                view?.setHud("— FPS   延迟 —")
            }
        } else {
            view?.setHud(nil)
        }
    }

    /// 没有窗口时（--selftest）用 60Hz 定时器代替显示刷新去取帧
    nonisolated(unsafe) var livePipeline: Pipeline? // 给后台线程读的镜像（只做 --selftest 用）

    func startHeadlessConsumer() {
        let q = DispatchQueue(label: "headless.vsync", qos: .userInteractive)
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: q)
        t.schedule(deadline: .now(), repeating: .nanoseconds(16_666_667), leeway: .microseconds(200))
        var started = false
        let stats = self.stats
        t.setEventHandler { [unowned self] in
            guard let p = self.livePipeline else { return }
            if let item = p.queue.pop() {
                started = true
                let lat = nowMs() - item.arrivalMs
                stats.with { $0.displayed += 1; $0.latencySum += lat; $0.latencyN += 1 }
            } else if started && p.interpActive {
                stats.with { $0.emptyVsync += 1 }
            }
        }
        headlessTimer = t
        t.resume()
    }

    func quit() {
        statsTimer?.invalidate()
        Log.write(stats.snapshotAndReset(interpOn: pipeline?.interpActive ?? false, queueDepth: pipeline?.queue.count ?? 0, backend: "vt"))
        Log.write(stats.summary())
        testSource?.stop()
        headlessTimer?.cancel()
        capture?.session.stopRunning()
        windowCapture?.stop()
        audio?.stop()
        view?.stop()
        exit(0)
    }

    // MARK: - 全屏（系统真全屏：独占整个屏幕，菜单栏和程序坞都藏起来，鼠标移到最上面才出菜单栏）
    /// 输入是屏幕上的窗口（串流 / 镜像）吗
    var sourceIsWindow: Bool {
        switch source { case .window, .iphone: return true; default: return false }
    }

    /// 全屏：采集卡用系统全屏（独占一个桌面）。
    /// 输入是串流窗口时不能这样：系统全屏把我们放到另一个桌面，串流窗口被系统判为"看不见"，
    /// 串流软件就省电降帧，画面一卡一卡（小窗时串流窗口露着一点，所以稳）。
    /// 改为在当前桌面铺满屏幕、自动隐藏菜单栏和程序坞，并且窗口不透明度 0.995（肉眼看不出）：
    /// 2026-11-19 实测，被完全不透明的窗口盖住时系统判"不可见"，盖它的窗口不透明度 < 1 时仍判"可见"
    @objc func toggleFullScreen() {
        guard let win = window else { return }
        if coverFullScreen { exitCoverFullScreen(); return }
        if model.isFullScreen { win.toggleFullScreen(nil); return }
        if sourceIsWindow { enterCoverFullScreen() } else { win.toggleFullScreen(nil) }
    }

    var coverFullScreen = false
    var frameBeforeCover: NSRect?

    // MARK: 串流窗口是系统全屏（单独一个桌面）—— 2.4 的做法
    // 2026-11-20 用户实测：Chrome 里的 xbox.com/play 系统全屏后，切回 FrameInterp（在另一个桌面），
    // Chrome 发现自己的画面看不见就停止绘制，采集一直 0 帧。
    // 做法：让我们的窗口能出现在任何桌面、也能盖在别的程序的全屏窗口上，先切到串流 App 的全屏桌面，
    // 再把我们的窗口放到最前面铺满（不透明度 0.995，和普通窗口时一样：串流窗口仍算"看得见"，不会停）。
    // （2026-11-22 试过"覆盖模式"：串流 App 留在前台、FrameInterp 只盖一层不接收点击的画面 / 返回游戏 / 自动点继续，
    //   用户实测补帧不稳定，要求回到 2.3 / 2.4 的窗口补帧逻辑，只保留新界面）
    var fullScreenStream: SCWindow?
    private var joinedStreamSpace = false
    func joinStreamSpace(_ sw: SCWindow) {
        guard let win = window, let pid = sw.owningApplication?.processID,
              let app = NSRunningApplication(processIdentifier: pid) else { return }
        joinedStreamSpace = true
        // 实测（2026-11-20）：普通程序的窗口进不了别的程序的全屏桌面，切成"辅助程序"才行（这期间程序坞里没有图标）
        NSApp.setActivationPolicy(.accessory)
        win.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
        win.level = .floating
        win.orderOut(nil) // 先收起来，切到全屏桌面后再显示：能出现在所有桌面的窗口，显示时出现在当前桌面
        app.activate() // 系统切到串流 App 的全屏桌面
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.joinedStreamSpace, let win = self.window else { return }
            NSApp.activate()
            win.orderFrontRegardless()
            win.makeKey()
            if !self.coverFullScreen { self.enterCoverFullScreen() }
            Log.write("串流窗口是系统全屏：FrameInterp 移到它的全屏桌面上盖住它（它仍算看得见，不会停）")
        }
    }
    func leaveStreamSpace() {
        fullScreenStream = nil
        guard joinedStreamSpace, let win = window else { return }
        joinedStreamSpace = false
        win.collectionBehavior.remove([.canJoinAllSpaces, .fullScreenAuxiliary])
        win.level = .normal
        if coverFullScreen { exitCoverFullScreen() }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        win.makeKeyAndOrderFront(nil)
    }

    func enterCoverFullScreen() {
        guard let win = window, let scr = win.screen ?? NSScreen.main else { return }
        frameBeforeCover = win.frame
        coverFullScreen = true
        (win as? FIWindow)?.allowOverMenuBar = true
        NSApp.presentationOptions = [.autoHideDock, .autoHideMenuBar]
        win.setFrame(scr.frame, display: true, animate: false)
        applyWindowAlpha()
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) {
            model.showSettings = false
            model.isFullScreen = true
            model.chromeVisible = false
        }
        Log.write("进入全屏（当前桌面铺满，串流窗口仍算可见）")
        pokeCursor()
    }

    func exitCoverFullScreen() {
        guard let win = window else { return }
        coverFullScreen = false
        (win as? FIWindow)?.allowOverMenuBar = false
        NSApp.presentationOptions = []
        if let f = frameBeforeCover { win.setFrame(f, display: true, animate: false) }
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { model.isFullScreen = false; model.chromeVisible = true }
        cursorHideWork?.cancel()
        Log.write("退出全屏")
    }

    /// 输入是串流窗口时，窗口始终 0.995 不透明（窗口模式下盖住串流窗口也一样会让它降帧）；其他输入 1。
    /// 内嵌 Xbox 网页除外：它已经关掉遮挡检测，0.995 反而会让后面的采集窗口隐约透出来
    func applyWindowAlpha() {
        window?.alphaValue = sourceIsWindow && webHost?.capturing != true ? 0.995 : 1
    }

    nonisolated func windowWillEnterFullScreen(_ n: Notification) {
        MainActor.assumeIsolated {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) {
                model.showSettings = false
                model.isFullScreen = true
                model.chromeVisible = false
            }
            Log.write("进入全屏")
            pokeCursor() // 进全屏后鼠标一直不动，5 秒后也藏起来
        }
    }

    nonisolated func windowWillExitFullScreen(_ n: Notification) {
        MainActor.assumeIsolated {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { model.isFullScreen = false; model.chromeVisible = true }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.placeTrafficLights() } }
        }
    }


    nonisolated func windowWillClose(_ n: Notification) {
        MainActor.assumeIsolated { quit() }
    }
}

/// 串流窗口全屏（铺满当前桌面）时允许窗口盖到菜单栏的位置（系统默认会把带标题栏的窗口限制在菜单栏下面）
final class FIWindow: NSWindow {
    var allowOverMenuBar = false
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        allowOverMenuBar ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
}

final class SourceBox: NSObject {
    let source: Source
    init(_ s: Source) { source = s }
}


let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { App(options) }
app.delegate = delegate
app.run()


/// 记住"这台 Mac 上 1080p 补帧太慢"（2026-11-25 加）。按芯片 + 型号 + 系统版本记，换了系统版本就重新测。
/// slow30：普通补帧（30 → 60）就跟不上 → 下次一开始就用 720p；
/// slowHi：只是高刷新率屏幕上 60 → 120 跟不上 → 下次看到 60 帧画面马上降，30 帧游戏还是 1080p
@MainActor
enum SlowMemory {
    static let key = "slow1080.v1"
    private static var dict: [String: Any] {
        guard let d = UserDefaults.standard.dictionary(forKey: key), d["machine"] as? String == App.machineInfo else { return [:] }
        return d
    }
    private static func set(_ k: String) {
        var d = dict
        d["machine"] = App.machineInfo
        d[k] = true
        UserDefaults.standard.set(d, forKey: key)
    }
    static var slow30: Bool {
        get { dict["slow30"] as? Bool ?? false }
        set { if newValue { set("slow30") } }
    }
    static var slowHi: Bool {
        get { dict["slowHi"] as? Bool ?? false }
        set { if newValue { set("slowHi") } }
    }
}
