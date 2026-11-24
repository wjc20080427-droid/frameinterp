import AVFoundation
import CoreMedia
import CoreMediaIO
import CoreAudio
import Foundation

enum Devices {
    /// 允许读取用数据线连着的 iPad / iPhone 屏幕（QuickTime 录 iPad 屏幕用的就是它）。
    /// 只对本程序生效，不改系统设置。打开后设备要过一两秒才出现。
    static func allowScreenDevices() {
        var prop = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var allow: UInt32 = 1
        CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &prop, 0, nil, UInt32(MemoryLayout<UInt32>.size), &allow)
    }

    /// 数据线连着的 iPad / iPhone 屏幕（画面和声音混在一起的设备）
    static func isScreenDevice(_ d: AVCaptureDevice) -> Bool {
        d.hasMediaType(.muxed) && d.modelID.contains("iOS Device")
    }

    static func video() -> [AVCaptureDevice] {
        let cams = AVCaptureDevice.DiscoverySession(deviceTypes: [.external, .builtInWideAngleCamera, .continuityCamera, .deskViewCamera],
                                                    mediaType: .video, position: .unspecified).devices
        let screens = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .muxed, position: .unspecified)
            .devices.filter(isScreenDevice)
        return screens + cams
    }

    static func audio() -> [AVCaptureDevice] {
        var seen = Set<String>()
        return AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                                mediaType: .audio, position: .unspecified).devices
            .filter { seen.insert($0.uniqueID).inserted }
    }

    /// 摄像头（内建 / 连续互通 / 桌上视角）和虚拟摄像头：默认不列出、不选，只在 --device 明确指定时才用
    static func isCamera(_ d: AVCaptureDevice) -> Bool {
        if isScreenDevice(d) { return false } // iPad / iPhone 屏幕不是摄像头
        // iPhone 连续互通相机的 deviceType 也报 .external，所以再看 isContinuityCamera 和厂商
        if d.deviceType != .external || d.isContinuityCamera || d.manufacturer == "Apple Inc." { return true }
        return isVirtual(d)
    }

    /// 虚拟摄像头（OBS、Camo、Zoom 等软件装的），不是真的硬件
    static func isVirtual(_ d: AVCaptureDevice) -> Bool {
        isVirtualName(d.localizedName + " " + d.manufacturer)
    }
    static func isVirtualName(_ name: String) -> Bool {
        let n = name.lowercased()
        return ["virtual", "obs virtual", "obs-camera", "camo", "snap camera", "mmhmm", "manycam", "ndi ", "xsplit", "zoom", "loopback"]
            .contains { n.contains($0) }
    }

    /// 像不像采集卡（分数越高越像）：自动选输入时用。
    /// 名字里有常见采集卡品牌 / 型号 → 很像；能出 1080p60 → 像；名字像普通摄像头（webcam、Logitech C920 之类）→ 不像
    static func captureCardScore(_ d: AVCaptureDevice) -> Int {
        if isScreenDevice(d) { return 50 }
        // 能出 1080p60（摄像头大多只有 1080p30）
        let has1080p60 = d.formats.contains { f in
            let dim = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return dim.width >= 1920 && dim.height >= 1080 && f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 59.9 }
        }
        // modelID 不参与：UVC 设备的 modelID 都是 "UVC Camera VendorID_…"，采集卡也一样
        return captureCardScore(name: d.localizedName + " " + d.manufacturer, has1080p60: has1080p60)
    }

    static func captureCardScore(name: String, has1080p60: Bool) -> Int {
        let n = name.lowercased()
        var s = 0
        let brands = ["shadowcast", "genki", "elgato", "cam link", "game capture", "hd60", "4k60", "4k x", "avermedia", "live gamer",
                      "gc5", "gc3", "gc55", "ugreen", "razer ripsaw", "ripsaw", "magewell", "usb capture", "evga", "xr1", "nzxt",
                      "nexigo", "mirabox", "j5create", "startech", "hdmi", "capture", "usb3 video", "usb video", "macrosilicon",
                      "ms2109", "ms2130", "uvc video", "video capture", "grabber", "streamer"]
        if brands.contains(where: { n.contains($0) }) { s += 100 }
        let webcam = ["webcam", "web cam", "facetime", "logitech", "brio", "c920", "c922", "c930", "streamcam", "kiyo", "insta360",
                      "obsbot", "camera"]
        if webcam.contains(where: { n.contains($0) }) && !n.contains("capture") { s -= 80 }
        if has1080p60 { s += 40 }
        return s
    }

    static func subtype(_ f: AVCaptureDevice.Format) -> FourCharCode {
        CMFormatDescriptionGetMediaSubType(f.formatDescription)
    }

    /// 压缩传输（MJPEG）：开着时优先用采集卡的 MJPEG 格式。2026-11-20 加：Genki Arcade 网页在 Mac 上 4K60 / 2K120 走的就是 MJPEG，
    /// 不压缩的 4K60 要约 6Gb/s，5Gb/s 的 USB 跑不动。系统负责解码成 420v，后面流程不变
    nonisolated(unsafe) static var preferCompressed = false

    static func isMJPEG(_ f: AVCaptureDevice.Format) -> Bool {
        let s = subtype(f)
        return s == kCMVideoCodecType_JPEG || s == kCMVideoCodecType_JPEG_OpenDML || fourCC(s) == "mjpg" || fourCC(s) == "MJPG"
    }

    static func describe(_ f: AVCaptureDevice.Format) -> String {
        let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        let rates = f.videoSupportedFrameRateRanges.map { r in
            r.minFrameRate == r.maxFrameRate ? String(format: "%.2f", r.maxFrameRate)
                : String(format: "%.2f-%.2f", r.minFrameRate, r.maxFrameRate)
        }.joined(separator: ",")
        return "\(d.width)x\(d.height) \(fourCC(subtype(f)))\(isMJPEG(f) ? "(MJPEG)" : "") @ \(rates) fps"
    }

    static func printList() {
        print("== 视频设备 ==")
        for d in video() {
            print("• \(d.localizedName)  [\(isCamera(d) ? "摄像头，默认跳过" : "外接/采集卡")]  id=\(d.uniqueID)")
            for f in d.formats { print("    \(describe(f))") }
        }
        print("== 音频设备 ==")
        for d in audio() { print("• \(d.localizedName)  id=\(d.uniqueID)") }
    }

    static func pickVideo(_ name: String?) -> AVCaptureDevice? {
        let all = video()
        if let name {
            return all.first { $0.localizedName.localizedCaseInsensitiveContains(name) }
        }
        // 不只认 Genki：按"像不像采集卡"打分选最高的；只有一个外接设备时直接用它
        let ext = all.filter { !isCamera($0) }
        if ext.count == 1 { return ext[0] }
        let ranked = ext.map { ($0, captureCardScore($0)) }.sorted { $0.1 > $1.1 }
        guard let top = ranked.first, top.1 >= 50 else { return nil } // 都不像采集卡（比如只有网络摄像头）就不自动选
        return top.0
    }

    /// 音频：--audio 指定，否则找和视频设备同名（或互相包含）的音频设备。找不到不回退到麦克风。
    static func pickAudio(_ name: String?, video: AVCaptureDevice?) -> AVCaptureDevice? {
        let all = audio()
        if let name { return all.first { $0.localizedName.localizedCaseInsensitiveContains(name) } }
        guard let v = video else { return nil }
        let vn = v.localizedName.lowercased()
        let candidates = all.filter { $0.uniqueID != "BuiltInMicrophoneDevice" && !$0.isContinuityCamera && $0.manufacturer != "Apple Inc." }
        // 1. 名字一样或互相包含（ShadowCast 3 / ShadowCast 3、Elgato HD60 X / Game Capture HD60 X）
        if let a = candidates.first(where: {
            let an = $0.localizedName.lowercased()
            return an == vn || an.contains(vn) || vn.contains(an)
        }) { return a }
        // 2. USB 声卡的 ID 是 "AppleUSBAudioEngine:厂商:产品名:序列号:接口"。
        //    便宜采集卡视频叫 "USB Video"，声音叫 "USB Digital Audio"，但声音 ID 里的产品名就是 "USB Video"
        if let a = candidates.first(where: {
            let parts = $0.uniqueID.split(separator: ":", omittingEmptySubsequences: false).map { $0.lowercased() }
            guard parts.count >= 3, parts[0].contains("usbaudio") else { return false }
            return parts[2] == vn || (!v.manufacturer.isEmpty && parts[1] == v.manufacturer.lowercased() && parts[2].contains(vn))
        }) { return a }
        return nil
    }

    /// 按顺序可以试的格式：先是按 fps / height 选的那个，然后同分辨率的其他格式、同分辨率降到 30 帧、再降分辨率。
    /// 2026-11-19 实测 ShadowCast 3 接在 5 Gb/s 的 USB 上：4K 60 帧、2K 的"120 帧"格式开了但一帧都不送（带宽不够，也不报错），
    /// 4K 30 帧、2K 60 帧正常。所以打开后几秒没有帧就按这个顺序往下换
    static func candidates(_ d: AVCaptureDevice, fps: Double, height: Int) -> [(AVCaptureDevice.Format, AVFrameRateRange)] {
        var out: [(AVCaptureDevice.Format, AVFrameRateRange)] = []
        func add(_ f: AVCaptureDevice.Format, _ r: AVFrameRateRange) {
            if !out.contains(where: { $0.0 === f && abs($0.1.maxFrameRate - r.maxFrameRate) < 0.5 }) { out.append((f, r)) }
        }
        if let p = pickFormat(d, fps: fps, height: height) { add(p.0, p.1) }
        let heights = [2160, 1440, 1080].filter { $0 <= height }
        // 压缩模式：同一档先试 MJPEG，再试不压缩的；不压缩模式不用 MJPEG
        let kinds: [Bool] = preferCompressed ? [true, false] : [false]
        for h in heights {
            for rate in [fps, 60, 30] where rate <= fps {
                for mj in kinds {
                for f in d.formats where isMJPEG(f) == mj {
                    let dim = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
                    guard Int(dim.height) == h, Int(dim.width) == h * 16 / 9,
                          let r = f.videoSupportedFrameRateRanges.first(where: { abs($0.maxFrameRate - rate) < 0.5 }) else { continue }
                    add(f, r)
                }
                }
            }
        }
        return out
    }

    /// 这台设备有的 16:9 分辨率档（1080 / 1440 / 2160）和每档最高帧率。
    /// 2026-11-24 改：以前只算能跑到 60 帧的档，有张"USB3 Video"卡 2K 只有 10/20/30 帧（不压缩 NV12），
    /// 被标成"不支持"，而 OBS 能选。现在有就列出来，菜单里标最高帧率，让用户自己决定
    static func heightMaxFps(_ d: AVCaptureDevice) -> [Int: Int] {
        if isScreenDevice(d) { return [1080: 60] }
        var out: [Int: Int] = [:]
        for f in d.formats {
            let dim = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let h = Int(dim.height)
            guard [1080, 1440, 2160].contains(h), Int(dim.width) == h * 16 / 9 else { continue }
            let mx = Int((f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0).rounded())
            if mx > 0 { out[h] = max(out[h] ?? 0, mx) }
        }
        return out
    }

    /// 选 1080p、≥59.9fps，非 MJPEG 优先
    /// 选 1080p、正好 60 帧的档位；同等条件下优先原生 420v（补帧要的就是它，省掉一次格式转换），不用 MJPEG。
    /// 注意：有的采集卡 1080p 同时有 120 档，Xbox 只输出 60，所以要选"最接近 60"的档，不能选最高的。
    /// fps：想要的采集帧率（60 或 120）。卡支持就选它，不支持就退回最接近的
    /// height：想要的分辨率（1080 / 1440 / 2160）。卡没有这一档就用比它低的最高一档
    static func pickFormat(_ d: AVCaptureDevice, fps: Double = 60, height: Int = 1080) -> (AVCaptureDevice.Format, AVFrameRateRange)? {
        var best: (AVCaptureDevice.Format, AVFrameRateRange, Int)?
        for f in d.formats {
            let dim = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let ranges = f.videoSupportedFrameRateRanges
            guard !ranges.isEmpty else { continue }
            // 能跑 60 的档里选最接近 60 的；都跑不到 60 就选最高的
            let r = ranges.filter { $0.maxFrameRate >= fps - 0.1 }.min(by: { abs($0.maxFrameRate - fps) < abs($1.maxFrameRate - fps) })
                ?? ranges.filter { $0.maxFrameRate >= 59.9 }.min(by: { abs($0.maxFrameRate - 60) < abs($1.maxFrameRate - 60) })
                ?? ranges.max(by: { $0.maxFrameRate < $1.maxFrameRate })!
            var score = 0
            let wantW = height * 16 / 9
            if Int(dim.height) == height && Int(dim.width) == wantW { score += 1000 }
            else if Int(dim.height) < height && Int(dim.width) * 9 == Int(dim.height) * 16 { score += 400 + Int(dim.height) / 10 } // 低一档里取最高的
            else if Int(dim.height) > height { continue } // 不选比要求高的
            if r.maxFrameRate >= 59.9 { score += 500 }
            if r.maxFrameRate >= fps - 0.1 { score += 300 } // 能跑到想要的帧率（比如 120）
            if isMJPEG(f) == preferCompressed { score += 100 }
            // 优先原生 4:2:2（颜色细节是 4:2:0 的两倍，文字和界面边缘更清楚）；补帧要的 4:2:0 由程序自己拷贝时转换
            let st = subtype(f)
            if st == kCVPixelFormatType_422YpCbCr8_yuvs || st == kCVPixelFormatType_422YpCbCr8 { score += 60 }
            else if st == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange { score += 50 }
            score += Int(min(r.maxFrameRate, fps))
            if best == nil || score > best!.2 { best = (f, r, score) }
        }
        return best.map { ($0.0, $0.1) }
    }
}

/// 视频采集：采集回调在 queue 上，交出 AVFoundation 的缓冲（回调返回后可能被回收，调用方需要立即拷贝）
final class VideoCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "capture.video", qos: .userInteractive)
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    private(set) var width = 1920, height = 1080
    private(set) var formatText = ""
    private(set) var droppedByAVF = 0
    var onDrop: (() -> Void)?
    private var device: AVCaptureDevice?
    private var chosenFormat: AVCaptureDevice.Format?
    private var frameDuration = CMTime(value: 1, timescale: 60)

    /// 把格式和帧率设到设备上（配置时和开始采集后各调一次）
    func applyFrameRate() {
        guard let device, let fmt = chosenFormat, (try? device.lockForConfiguration()) != nil else { return }
        if device.activeFormat != fmt { device.activeFormat = fmt }
        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration
        device.unlockForConfiguration()
    }

    /// 设备实际生效的帧率（日志用）
    var actualFrameRate: String {
        guard let d = device else { return "?" }
        let mn = d.activeVideoMinFrameDuration.seconds, mx = d.activeVideoMaxFrameDuration.seconds
        return String(format: "%.0f~%.0f 帧/秒，格式 %@", mx > 0 ? 1 / mx : 0, mn > 0 ? 1 / mn : 0, Devices.describe(d.activeFormat))
    }

    /// choice：指定用哪个格式（自动降档时用）；nil = 按 fps / height 自动选
    func configure(device: AVCaptureDevice, pixelFormat: OSType?, fps: Double = 60, height: Int = 1080,
                   choice: (AVCaptureDevice.Format, AVFrameRateRange)? = nil) throws {
        if Devices.isScreenDevice(device) { return try configureScreen(device: device, pixelFormat: pixelFormat) }
        guard let (fmt, range) = choice ?? Devices.pickFormat(device, fps: fps, height: height) else { throw err("设备没有可用格式") }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw err("不能添加视频输入") }
        session.addInput(input)
        self.device = device
        chosenFormat = fmt
        // 60 帧档：min 和 max 都设成 1/60（不让它自己降帧）。开始采集后再设一次（会话启动时可能被改回默认）
        frameDuration = range.minFrameDuration.seconds > 0 ? range.minFrameDuration : CMTime(value: 1, timescale: 60)
        applyFrameRate()
        let dim = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
        self.width = Int(dim.width); self.height = Int(dim.height)
        formatText = Devices.describe(fmt)
        isCompressed = Devices.isMJPEG(fmt)

        let out = AVCaptureVideoDataOutput()
        out.alwaysDiscardsLateVideoFrames = true
        // 用采集卡原生的格式输出，不让系统转换（4:2:2 时直接拿 4:2:2 显示，颜色细节不丢）
        let native = Devices.subtype(fmt)
        if out.availableVideoPixelFormatTypes.contains(native) {
            out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: native]
        } else if let pf = pixelFormat, out.availableVideoPixelFormatTypes.contains(pf) {
            out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pf]
        } else if Devices.isMJPEG(fmt) {
            // MJPEG：让系统解码成 420v
            out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        }
        outputFormat = (out.videoSettings?[kCVPixelBufferPixelFormatTypeKey as String] as? NSNumber).map { fourCC($0.uint32Value) } ?? "?"
        out.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(out) else { throw err("不能添加视频输出") }
        session.addOutput(out)
    }
    private(set) var outputFormat = ""
    /// 选的是 MJPEG（压缩传输）格式
    private(set) var isCompressed = false


    /// iPad / iPhone 屏幕：没有固定格式（转屏时尺寸会变），画面统一按比例缩放到 1920×1080（留黑边）。
    /// 声音也从这个设备出来，直接在同一个会话里放到扬声器。
    private func configureScreen(device: AVCaptureDevice, pixelFormat: OSType?) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw err("不能添加 iPad 输入") }
        session.addInput(input)
        width = 1920; height = 1080
        formatText = "\(device.localizedName) 屏幕（有线），按比例缩放到 1920×1080"
        let out = AVCaptureVideoDataOutput()
        out.alwaysDiscardsLateVideoFrames = true
        if let pf = pixelFormat, out.availableVideoPixelFormatTypes.contains(pf) {
            out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pf]
        }
        out.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(out) else { throw err("不能添加视频输出") }
        session.addOutput(out)
        let audio = AVCaptureAudioPreviewOutput()
        audio.volume = 1
        if session.canAddOutput(audio) { session.addOutput(audio) }
    }

    /// 只在已知尺寸前用来预读格式（为了先建补帧器）
    static func probeSize(_ device: AVCaptureDevice, fps: Double = 60, height: Int = 1080) -> (Int, Int) {
        if Devices.isScreenDevice(device) { return (1920, 1080) }
        guard let (f, _) = Devices.pickFormat(device, fps: fps, height: height) else { return (1920, 1080) }
        let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        return (Int(d.width), Int(d.height))
    }

    var onFirstFrame: ((String) -> Void)?
    private var sawFirst = false

    var onColorInfo: ((String) -> Void)?
    /// 收到的帧数（主线程读，用来判断"开了但一帧都没有"）
    private(set) var frameCount = 0

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        frameCount += 1
        // 亮度诊断：开始后第 30 帧、之后每 5 秒记一次（采集卡给的颜色标签 + 亮度分布）
        if frameCount == 30 || frameCount % 300 == 0, let cb = onColorInfo { cb(ColorProbe.describe(pb)) }
        if !sawFirst {
            // 记下实际收到的格式（读回设置不可靠，读回来的字典里可能没有格式这一项）
            sawFirst = true
            onFirstFrame?("\(fourCC(CVPixelBufferGetPixelFormatType(pb))) \(CVPixelBufferGetWidth(pb))×\(CVPixelBufferGetHeight(pb))")
        }
        onFrame?(pb, CMSampleBufferGetPresentationTimeStamp(sb))
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        droppedByAVF += 1
        onDrop?()
    }

    private func err(_ s: String) -> NSError { NSError(domain: "capture", code: 1, userInfo: [NSLocalizedDescriptionKey: s]) }
}

/// 音频直通：独立会话，AVCaptureAudioPreviewOutput 放到选定的输出设备（nil = 系统默认）
final class AudioPassthrough {
    let session = AVCaptureSession()
    private let out = AVCaptureAudioPreviewOutput()
    /// 输出设备的 CoreAudio UID；nil = 跟随系统默认输出。运行中改也立即生效
    var outputUID: String? { didSet { out.outputDeviceUniqueID = outputUID } }
    /// 静音（工具栏的"声音直通"按钮）：会话照常跑，只是音量为 0，重新打开没有延迟
    var muted = false { didSet { out.volume = muted ? 0 : 1 } }
    func start(device: AVCaptureDevice) throws {
        session.beginConfiguration()
        let input = try AVCaptureDeviceInput(device: device)
        if session.canAddInput(input) { session.addInput(input) }
        out.volume = muted ? 0 : 1
        out.outputDeviceUniqueID = outputUID
        if session.canAddOutput(out) { session.addOutput(out) }
        session.commitConfiguration()
        session.startRunning()
    }
    func stop() { session.stopRunning() }
}


/// 诊断：逐个试采集卡的格式（1080p / 2K / 4K × 60 / 30 帧），每个跑 3 秒，记下实际收到几帧。
/// 用法：open -n FrameInterp.app --args --probe（要用打包的 App，才有摄像头权限）
enum FormatProbe {
    final class Counter: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
        var frames = 0, drops = 0, first = ""
        func captureOutput(_ o: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
            if frames == 0, let pb = CMSampleBufferGetImageBuffer(sb) {
                first = "\(fourCC(CVPixelBufferGetPixelFormatType(pb))) \(CVPixelBufferGetWidth(pb))×\(CVPixelBufferGetHeight(pb))"
            }
            frames += 1
        }
        func captureOutput(_ o: AVCaptureOutput, didDrop sb: CMSampleBuffer, from c: AVCaptureConnection) { drops += 1 }
    }

    static func run() async {
        guard await AVCaptureDevice.requestAccess(for: .video) else { Log.write("探测：没有摄像头权限"); return }
        guard let d = Devices.pickVideo(nil) else { Log.write("探测：没找到采集卡"); return }
        Log.write("探测：\(d.localizedName)")
        for f in d.formats {
            let dim = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            guard [1080, 1440, 2160].contains(Int(dim.height)), Int(dim.width) * 9 == Int(dim.height) * 16 else { continue }
            for fps in [60.0, 30.0] {
                guard let r = f.videoSupportedFrameRateRanges.first(where: { abs($0.maxFrameRate - fps) < 0.5 }) else { continue }
                let s = AVCaptureSession()
                guard let input = try? AVCaptureDeviceInput(device: d), s.canAddInput(input) else { continue }
                s.beginConfiguration()
                s.addInput(input)
                let out = AVCaptureVideoDataOutput()
                let native = Devices.subtype(f)
                if out.availableVideoPixelFormatTypes.contains(native) { out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: native] }
                let c = Counter()
                let q = DispatchQueue(label: "probe")
                out.setSampleBufferDelegate(c, queue: q)
                if s.canAddOutput(out) { s.addOutput(out) }
                if (try? d.lockForConfiguration()) != nil {
                    d.activeFormat = f
                    d.activeVideoMinFrameDuration = r.minFrameDuration
                    d.activeVideoMaxFrameDuration = r.minFrameDuration
                    d.unlockForConfiguration()
                }
                s.commitConfiguration()
                s.startRunning()
                if (try? d.lockForConfiguration()) != nil {
                    if d.activeFormat != f { d.activeFormat = f }
                    d.activeVideoMinFrameDuration = r.minFrameDuration
                    d.activeVideoMaxFrameDuration = r.minFrameDuration
                    d.unlockForConfiguration()
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                s.stopRunning()
                let n = q.sync { (c.frames, c.drops, c.first) }
                Log.write(String(format: "探测 %dx%d %@ @%.0f：3 秒收到 %d 帧（约 %.0f 帧/秒），系统丢 %d，帧格式 %@",
                                 dim.width, dim.height, fourCC(native), fps, n.0, Double(n.0) / 3, n.1, n.2.isEmpty ? "—" : n.2))
            }
        }
        Log.write("探测结束")
    }
}


/// 系统的音频输出设备（扬声器、耳机、HDMI、蓝牙…），给"音频输出"选择用
enum AudioOutputs {
    static func list() -> [AudioOption] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard outputChannels(id) > 0, let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return AudioOption(id: uid, name: name)
        }
    }

    private static func string(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    private static func outputChannels(_ id: AudioObjectID) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { buf.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buf) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(buf.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}


/// 亮度诊断：帧上的颜色标签 + 亮度（Y）分布。视频范围的 Y 应该在 16~235；大量 < 16 或 > 235 说明其实是全范围数据
enum ColorProbe {
    static func describe(_ pb: CVPixelBuffer) -> String {
        func att(_ k: CFString) -> String {
            (CVBufferCopyAttachment(pb, k, nil) as? String)?.replacingOccurrences(of: "ITU_R_", with: "") ?? "无"
        }
        var cs = "无"
        if let c = CVBufferCopyAttachment(pb, kCVImageBufferCGColorSpaceKey, nil) {
            cs = (CGColorSpace.self == type(of: c as AnyObject) || CFGetTypeID(c) == CGColorSpace.typeID)
                ? ((c as! CGColorSpace).name as String? ?? "未命名") : "?"
        }
        let fmt = fourCC(CVPixelBufferGetPixelFormatType(pb))
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        var hist = [Int](repeating: 0, count: 256)
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        if CVPixelBufferIsPlanar(pb), let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0)?.assumingMemoryBound(to: UInt8.self) {
            let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            for r in stride(from: 0, to: h, by: 4) { for c in stride(from: 0, to: w, by: 4) { hist[Int(y[r * bpr + c])] += 1 } }
        } else if let b = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) {
            let bpr = CVPixelBufferGetBytesPerRow(pb)
            let yOff = fmt == "yuvs" ? 0 : 1 // yuvs = Y0 U Y1 V；2vuy = U Y0 V Y1
            for r in stride(from: 0, to: h, by: 4) { for c in stride(from: 0, to: w, by: 4) { hist[Int(b[r * bpr + c * 2 + yOff])] += 1 } }
        }
        let n = max(1, hist.reduce(0, +))
        func pct(_ q: Double) -> Int { var acc = 0; for i in 0..<256 { acc += hist[i]; if Double(acc) >= q * Double(n) { return i } }; return 255 }
        let low = Double(hist[0..<16].reduce(0, +)) / Double(n) * 100, high = Double(hist[236...].reduce(0, +)) / Double(n) * 100
        let mean = Double(hist.enumerated().reduce(0) { $0 + $1.offset * $1.element }) / Double(n)
        return String(format: "亮度诊断：%@ 原色 %@ 曲线 %@ 矩阵 %@ 色彩空间 %@ | Y 最暗1%% %d 中位 %d 最亮1%% %d 平均 %.0f | <16 的 %.1f%% >235 的 %.1f%%",
                      fmt, att(kCVImageBufferColorPrimariesKey), att(kCVImageBufferTransferFunctionKey), att(kCVImageBufferYCbCrMatrixKey), cs,
                      pct(0.01), pct(0.5), pct(0.99), mean, low, high)
    }
}
