import Foundation

/// 命令行参数
struct Options {
    var list = false
    var device: String?          // --device NAME（子串匹配，不区分大小写）
    var audioDevice: String?     // --audio NAME（默认按视频设备名找同名音频设备）
    var noAudio = false          // --noaudio
    var dupThreshold = 0.5       // --thr：抽样亮度平均绝对差低于它 → 可能是重复帧
    var changedPercent = 0.05    // --pct：差值 > pixelDelta 的抽样点占比超过它也算新帧（混合判定）
    var pixelDelta = 12          // --pxd：单点亮度差超过它才算"这个点变了"
    var cutThreshold = 40.0      // --cut：平均差超过它 → 场景切换，不补帧
    var step = 8                 // --step：抽样间隔（像素）
    var queueLimit = 4           // --queue：显示队列上限
    var test = false             // --test：内置测试图案（不需要采集卡）
    var selftest = false         // --selftest：只测 VTFrameProcessor（合成画面），不开窗口
    var seconds: Double = 0      // --seconds N：运行 N 秒后自动退出（0 = 不退出）
    var fullscreen = false       // --fullscreen：启动时全屏
    var windowed = false         // --windowed：启动时不全屏
    var interpOn = true          // --nointerp：启动时关闭补帧
    var probe = false            // --probe：逐个试采集卡的 1080p / 2K / 4K 格式，每个 3 秒，记下收到几帧（诊断用）
    var forceInterp = false      // --interp：双击打开默认不补帧，加这个参数则打开
    var interpHeight = 0         // --ires H：补帧在 H 高度上做（0 = 原分辨率）
    var window: String?          // --window [NAME]：抓窗口（默认找 iPhone 镜像）
    var listWindows = false      // --windows：列出可抓的窗口
    var pixfmt: String?          // --pixfmt 420v|x420|bgra：强制补帧用的像素格式（实验）

    static func parse(_ args: [String]) -> Options {
        var o = Options()
        var i = 1
        func next() -> String {
            i += 1
            guard i < args.count else { die("参数 \(args[i - 1]) 缺少值") }
            return args[i]
        }
        func num(_ s: String) -> Double {
            guard let v = Double(s) else { die("不是数字：\(s)") }
            return v
        }
        while i < args.count {
            switch args[i] {
            case "--list": o.list = true
            case "--device": o.device = next()
            case "--audio": o.audioDevice = next()
            case "--noaudio": o.noAudio = true
            case "--thr": o.dupThreshold = num(next())
            case "--pct": o.changedPercent = num(next())
            case "--pxd": o.pixelDelta = Int(num(next()))
            case "--cut": o.cutThreshold = num(next())
            case "--step": o.step = max(1, Int(num(next())))
            case "--queue": o.queueLimit = max(2, Int(num(next())))
            case "--test": o.test = true
            case "--selftest": o.selftest = true
            case "--seconds": o.seconds = num(next())
            case "--windowed": o.windowed = true
            case "--fullscreen": o.fullscreen = true
            case "--nointerp": o.interpOn = false
            case "--probe": o.probe = true
            case "--interp": o.forceInterp = true
            case "--pixfmt": o.pixfmt = next()
            case "--windows": o.listWindows = true
            case "--window":
                // 值可选：后面不是 -- 开头的参数就当窗口名
                if i + 1 < args.count, !args[i + 1].hasPrefix("--") { o.window = next() } else { o.window = "" }
            case "--ires": o.interpHeight = Int(num(next()))
            case "-h", "--help":
                print(usage)
                exit(0)
            case let a where a.hasPrefix("-psn_") || a.hasPrefix("-NS") || a.hasPrefix("-Apple"):
                // 从 Finder / 系统启动时可能带的参数
                if a.hasPrefix("-NS") || a.hasPrefix("-Apple"), i + 1 < args.count, !args[i + 1].hasPrefix("-") { i += 1 }
            default: die("未知参数：\(args[i])\n\(usage)")
            }
            i += 1
        }
        if o.dupThreshold <= 0 { die("--thr 必须大于 0（采集链路有噪声）") }
        return o
    }

    static let usage = """
    用法：FrameInterp [选项]
      --list              列出视频/音频设备和格式
      --device NAME       选采集设备（名字子串）
      --audio NAME        选音频设备（默认找和视频设备同名的）  --noaudio 不开声音
      --thr X             重复帧阈值：抽样亮度平均差（默认 0.5）
      --pct X             混合判定：变化点占比 %（默认 0.05）  --pxd N 单点变化阈值（默认 12）
      --cut X             场景切换阈值：平均差（默认 40）
      --step N            抽样间隔像素（默认 8）  --queue N 显示队列上限（默认 4）
      --window NAME       抓指定窗口；--windows 列窗口
      --test              内置测试图案（开发测试用；只有带这个参数时输入列表里才有测试图案）
      --selftest          只测 Apple 补帧耗时（不开窗口）
      --ires H            补帧在 H 高度上做（如 720，更快；中间帧会略软），默认原分辨率
      --seconds N         N 秒后自动退出   --windowed 不全屏   --nointerp 启动时关闭补帧
    快捷键：空格 开关补帧   f 全屏   q 退出
    """
}

func die(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

@inline(__always) func nowMs() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }
