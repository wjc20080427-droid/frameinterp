import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// 一个唯一帧：已经拷进我们自己的缓冲池（不是 AVFoundation 的采集缓冲）
struct UniqueFrame {
    let buffer: CVPixelBuffer   // 原分辨率（显示用）
    let proc: CVPixelBuffer     // 补帧分辨率（--ires 时是缩小的拷贝，否则和 buffer 是同一个）
    let pts: CMTime
    let arrivalMs: Double
}

func fourCC(_ v: OSType) -> String {
    let b = [24, 16, 8, 0].map { UInt8((v >> UInt32($0)) & 0xFF) }
    if b.allSatisfy({ $0 >= 32 && $0 < 127 }) { return String(bytes: b, encoding: .ascii) ?? "\(v)" }
    return "\(v)"
}

/// 给缓冲补上 BT.709 颜色附件
/// 所有显示的帧统一的颜色标签：BT.709 原色和矩阵，亮度曲线用 sRGB。
/// 2026-11-19 实测：曲线标成 BT.709 时 macOS 显示偏暗（Y=40 的暗部显示成 15，正常应为 28），
/// 标 sRGB（或采集卡自己标的 SMPTE 240M）和浏览器 / Genki 网页直接解码一样（28 / 75 / 128 / 191）
let displayTransferFunction = kCVImageBufferTransferFunction_sRGB
func tagBT709(_ pb: CVPixelBuffer) {
    CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, displayTransferFunction, .shouldPropagate)
    CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
}

/// Apple 低延迟补帧（VTLowLatencyFrameInterpolation）。
/// - 会话在后台队列启动（模型加载可能很慢），启动后用合成画面预热，直到第一次 process 成功才算就绪。
/// - 所有 process 调用在一个串行队列上排队，同一时间只有一个在算；传进去的缓冲在回调前不会被改。
final class VTInterpolator: @unchecked Sendable {
    let width: Int, height: Int          // 补帧分辨率
    let srcWidth: Int, srcHeight: Int    // 采集分辨率
    /// 补帧时显示的分辨率：一般就是采集分辨率；2K / 4K 选"一致"时和补帧分辨率一样（1080p），
    /// 真实帧和补出来的帧清晰度相同，不会一帧清楚一帧软
    let dispWidth: Int, dispHeight: Int
    private(set) var pixelFormat: OSType = 0
    private(set) var supportedFormats: [OSType] = []
    private(set) var ready = false
    private(set) var startError: String?
    private(set) var startMs = 0.0, warmupMs = 0.0, warmupTries = 0

    private let processor = VTFrameProcessor()
    private var config: VTLowLatencyFrameInterpolationConfiguration!
    private var srcPool: CVPixelBufferPool!
    private var dispPool: CVPixelBufferPool! // 原分辨率拷贝（--ires 时才和 srcPool 不同）
    private var dstPool: CVPixelBufferPool!
    private var transfer: VTPixelTransferSession?
    private let workQ = DispatchQueue(label: "interp.work", qos: .userInteractive)

    /// procHeight > 0 且小于源高度时，补帧在缩小的画面上做（宽按比例，取偶数）。
    /// 2026-11-18 实测：Apple 低延迟补帧只接受 1920×1080 和 1280×720（2560×1440、3840×2160、1600×900 都报 -19730），
    /// 所以 2K / 4K 输入一律缩到 1080p（选了 720p 就 720p）补帧。
    /// unifiedHiRes：2K / 4K 补帧时真实帧也按补帧分辨率显示（推荐，观感一致）；false 时真实帧保持原生分辨率
    static let hiResLimit = (w: 1920, h: 1080)
    static func isHiRes(_ w: Int, _ h: Int) -> Bool { w > hiResLimit.w || h > hiResLimit.h }

    init?(width: Int, height: Int, procHeight: Int = 0, unifiedHiRes: Bool = true, forceFormat: String? = nil) {
        srcWidth = width
        srcHeight = height
        let hiRes = VTInterpolator.isHiRes(width, height)
        if hiRes {
            (self.width, self.height) = procHeight == 720 ? (1280, 720) : (1920, 1080)
        } else if procHeight > 0 && procHeight < height {
            self.height = procHeight & ~1
            self.width = Int((Double(width) * Double(procHeight) / Double(height)).rounded()) & ~1
        } else {
            self.width = width
            self.height = height
        }
        (dispWidth, dispHeight) = hiRes && unifiedHiRes ? (self.width, self.height) : (width, height)
        let width = self.width, height = self.height
        guard VTLowLatencyFrameInterpolationConfiguration.isSupported else {
            startError = "这台机器不支持 VTLowLatencyFrameInterpolation"
            return nil
        }
        guard let c = VTLowLatencyFrameInterpolationConfiguration(frameWidth: width, frameHeight: height,
                                                                  numberOfInterpolatedFrames: 2)
        else { return nil }
        config = c
        supportedFormats = c.supportedPixelFormats // ObjC 的 frameSupportedPixelFormats 在 Swift 里叫这个
        // 优先 420v，其次 BGRA，再其次第一个
        let pref: [OSType] = [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_32BGRA]
        pixelFormat = pref.first(where: supportedFormats.contains) ?? supportedFormats.first ?? kCVPixelFormatType_32BGRA
        switch forceFormat {
        case "420v": pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case "x420": pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case "bgra": pixelFormat = kCVPixelFormatType_32BGRA
        default: break
        }
        srcPool = makePool(c.sourcePixelBufferAttributes, width, height)
        dstPool = makePool(c.destinationPixelBufferAttributes, width, height)
        dispPool = (dispWidth == width && dispHeight == height) ? srcPool
            : makePool(c.sourcePixelBufferAttributes, dispWidth, dispHeight)
        if srcPool == nil || dstPool == nil || dispPool == nil { return nil }
        var t: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &t)
        transfer = t
        if let t {
            // 拷贝 / 缩放（--ires）/ 必要时转格式
            // 按比例缩放、留黑边：尺寸一样时就是普通拷贝；iPad 这种尺寸会变的输入也不会变形
            VTSessionSetProperty(t, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Letterbox)
            VTSessionSetProperty(t, key: kVTPixelTransferPropertyKey_DownsamplingMode, value: kVTDownsamplingMode_Average)
        }
    }

    var describe: String {
        "VT 低延迟补帧 \(width)x\(height)\(width != srcWidth ? "（源 \(srcWidth)x\(srcHeight)，补帧时显示 \(dispWidth)x\(dispHeight)）" : "")，像素格式 \(fourCC(pixelFormat))（支持：\(supportedFormats.map(fourCC).joined(separator: ",")))"
    }

    private func makePool(_ base: [String: Any], _ width: Int, _ height: Int) -> CVPixelBufferPool? {
        var attrs = base
        attrs[kCVPixelBufferPixelFormatTypeKey as String] = pixelFormat
        attrs[kCVPixelBufferWidthKey as String] = width
        attrs[kCVPixelBufferHeightKey as String] = height
        if attrs[kCVPixelBufferIOSurfacePropertiesKey as String] == nil {
            attrs[kCVPixelBufferIOSurfacePropertiesKey as String] = [String: Any]()
        }
        attrs[kCVPixelBufferMetalCompatibilityKey as String] = true
        var pool: CVPixelBufferPool?
        // 最少保留 8 个，防止显示队列 + 处理中的缓冲把池子用空后反复分配
        let poolAttrs: [String: Any] = [kCVPixelBufferPoolMinimumBufferCountKey as String: 8]
        CVPixelBufferPoolCreate(nil, poolAttrs as CFDictionary, attrs as CFDictionary, &pool)
        return pool
    }

    private func newBuffer(_ pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        // 池子超过 24 个就报错而不是无限分配（说明有泄漏或队列堆积）
        let aux: [String: Any] = [kCVPixelBufferPoolAllocationThresholdKey as String: 24]
        CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, aux as CFDictionary, &pb)
        return pb
    }

    /// 把采集缓冲拷进自己的池子（同步，调用方线程）。失败返回 nil。
    /// 补帧分辨率和原分辨率不同（--ires / 720p）时为 true：这时可以先只拷补帧要用的小图，马上开始补帧
    var separateProc: Bool { dispPool !== srcPool }

    /// 只拷补帧分辨率的那份（直接从采集缓冲缩小 + 转 420v）
    func copyProc(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        guard let transfer, let proc = newBuffer(srcPool),
              VTPixelTransferSessionTransferImage(transfer, from: src, to: proc) == noErr else { return nil }
        tagBT709(proc)
        return proc
    }

    /// 补出来的帧（补帧分辨率）放大回原分辨率，和真实帧同样大小、同样格式，显示层就不用每帧切换尺寸。
    /// 在补帧回调里调用（补帧队列），所以单独用一个转换会话，不和采集线程抢
    private lazy var upTransfer: VTPixelTransferSession? = {
        var t: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &t)
        if let t { VTSessionSetProperty(t, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Normal) }
        return t
    }()
    func upscaleToDisp(_ pb: CVPixelBuffer) -> CVPixelBuffer {
        guard CVPixelBufferGetWidth(pb) != dispWidth || CVPixelBufferGetHeight(pb) != dispHeight,
              let t = upTransfer, let out = newBuffer(dispPool),
              VTPixelTransferSessionTransferImage(t, from: pb, to: out) == noErr else { return pb }
        tagBT709(out)
        return out
    }

    /// 只拷原分辨率的那份（显示真实帧用）
    func copyDisp(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        guard let transfer, let disp = newBuffer(dispPool),
              VTPixelTransferSessionTransferImage(transfer, from: src, to: disp) == noErr else { return nil }
        tagBT709(disp)
        return disp
    }

    /// 返回 (原分辨率拷贝, 补帧分辨率拷贝)；不缩放时两者是同一个缓冲
    func copyIn(_ src: CVPixelBuffer) -> (CVPixelBuffer, CVPixelBuffer)? {
        guard let transfer, let disp = newBuffer(dispPool) else { return nil }
        guard VTPixelTransferSessionTransferImage(transfer, from: src, to: disp) == noErr else { return nil }
        tagBT709(disp)
        if dispPool === srcPool { return (disp, disp) }
        guard let proc = newBuffer(srcPool),
              VTPixelTransferSessionTransferImage(transfer, from: disp, to: proc) == noErr else { return nil }
        tagBT709(proc)
        return (disp, proc)
    }

    /// 后台启动会话 + 预热；完成后在 main 上回调
    func start(_ done: @escaping (VTInterpolator) -> Void) {
        workQ.async { [self] in
            let t0 = nowMs()
            do {
                try processor.startSession(configuration: config)
            } catch {
                startError = "startSession 失败：\(error)"
                DispatchQueue.main.async { done(self) }
                return
            }
            startMs = nowMs() - t0
            warmup()
            DispatchQueue.main.async { done(self) }
        }
    }

    /// 用两张合成画面反复试 process，直到成功（最多约 10 秒）。
    /// 旧实验遇到过刚 startSession 就 process 报 -19730 的情况，这里把"就绪"定义为第一次成功的 process。
    private func warmup() {
        guard let a = newBuffer(srcPool), let b = newBuffer(srcPool) else {
            startError = "预热：分配缓冲失败"
            return
        }
        fill(a, value: 60)
        fill(b, value: 70)
        tagBT709(a); tagBT709(b)
        let t0 = nowMs()
        var lastErr: Error?
        // 测试用：FI_FAIL1080=1 模拟"这台 Mac 上 1080p 补帧启动失败"（检查自动改 720p 的流程）
        if ProcessInfo.processInfo.environment["FI_FAIL1080"] == "1", height > 720 {
            startError = "预热 10 秒仍失败：（模拟）-19730 Processor is not initialized"
            return
        }
        while nowMs() - t0 < 10_000 {
            warmupTries += 1
            let (out, err) = runSync(prev: UniqueFrame(buffer: a, proc: a, pts: CMTime(value: 0, timescale: 600), arrivalMs: 0),
                                     curr: UniqueFrame(buffer: b, proc: b, pts: CMTime(value: 20, timescale: 600), arrivalMs: 0),
                                     phases: [0.5])
            if out != nil {
                ready = true
                warmupMs = nowMs() - t0
                return
            }
            lastErr = err
            Thread.sleep(forTimeInterval: 0.1)
        }
        startError = "预热 10 秒仍失败：\(String(describing: lastErr))"
    }

    private func fill(_ pb: CVPixelBuffer, value: UInt8) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        if CVPixelBufferIsPlanar(pb) {
            for p in 0..<CVPixelBufferGetPlaneCount(pb) {
                let v: UInt8 = p == 0 ? value : 128
                memset(CVPixelBufferGetBaseAddressOfPlane(pb, p), Int32(v),
                       CVPixelBufferGetBytesPerRowOfPlane(pb, p) * CVPixelBufferGetHeightOfPlane(pb, p))
            }
        } else {
            memset(CVPixelBufferGetBaseAddress(pb), Int32(value), CVPixelBufferGetBytesPerRow(pb) * CVPixelBufferGetHeight(pb))
        }
    }

    /// 在当前线程同步等待一次补帧（只在 workQ 上调用）
    /// 一段间隔里最多补几帧。实测补 2 帧（1/3、2/3）在 720p 要 33ms、1080p 要 91ms，
    /// 比一个刷新周期还长：画面先空一拍再一下涌来两帧，反而更卡（M2 上每秒丢 5 帧 + 空 5 拍）。
    /// 所以固定补 1 帧，补不够的由管线的"欠账"在下一次短间隔时补上。会话仍按 2 帧配置，以后机器够快可以打开。
    var maxFramesPerGap: Int { 1 }

    /// 在当前线程同步补帧（只在 workQ 上调用）。phases：0~1 之间的位置，比如 [0.5] 或 [1/3, 2/3]
    private func runSync(prev: UniqueFrame, curr: UniqueFrame, phases: [Float]) -> ([CVPixelBuffer]?, Error?) {
        var dsts: [CVPixelBuffer] = []
        for _ in phases {
            guard let d = newBuffer(dstPool) else { return (nil, NSError(domain: "interp", code: 1, userInfo: [NSLocalizedDescriptionKey: "输出缓冲池用空"])) }
            dsts.append(d)
        }
        let span = CMTimeSubtract(curr.pts, prev.pts)
        guard let fp = VTFrameProcessorFrame(buffer: prev.proc, presentationTimeStamp: prev.pts),
              let fc = VTFrameProcessorFrame(buffer: curr.proc, presentationTimeStamp: curr.pts)
        else { return (nil, NSError(domain: "interp", code: 2, userInfo: [NSLocalizedDescriptionKey: "创建帧失败"])) }
        var fds: [VTFrameProcessorFrame] = []
        for (d, ph) in zip(dsts, phases) {
            let t = CMTimeAdd(prev.pts, CMTimeMultiplyByFloat64(span, multiplier: Float64(ph)))
            guard let f = VTFrameProcessorFrame(buffer: d, presentationTimeStamp: t) else {
                return (nil, NSError(domain: "interp", code: 2, userInfo: [NSLocalizedDescriptionKey: "创建输出帧失败"]))
            }
            fds.append(f)
        }
        guard let params = VTLowLatencyFrameInterpolationParameters(sourceFrame: fc, previousFrame: fp,
                                                                    interpolationPhase: phases, destinationFrames: fds)
        else { return (nil, NSError(domain: "interp", code: 2, userInfo: [NSLocalizedDescriptionKey: "创建参数失败"])) }
        let sem = DispatchSemaphore(value: 0)
        var err: Error?
        processor.process(parameters: params) { _, e in
            err = e
            sem.signal()
        }
        if sem.wait(timeout: .now() + 1.0) == .timedOut {
            return (nil, NSError(domain: "interp", code: 3, userInfo: [NSLocalizedDescriptionKey: "process 超时 1 秒"]))
        }
        if let err { return (nil, err) }
        for d in dsts where CVBufferCopyAttachment(d, kCVImageBufferColorPrimariesKey, nil) == nil { tagBT709(d) }
        return (dsts, nil)
    }

    /// 异步补帧（prev → curr 之间按 phases 补）。completion 在 workQ 上调用：(中间帧们, 耗时 ms, 错误)
    var onQueueWait: ((Double) -> Void)?
    func interpolate(prev: UniqueFrame, curr: UniqueFrame, phases: [Float],
                     completion: @escaping ([CVPixelBuffer]?, Double, Error?) -> Void) {
        let tq = nowMs()
        workQ.async { [self] in
            let t0 = nowMs()
            onQueueWait?(t0 - tq)
            let (out, err) = runSync(prev: prev, curr: curr, phases: phases)
            completion(out, nowMs() - t0, err)
        }
    }

    /// 在补帧串行队列上排一个任务（保证显示顺序）
    func enqueue(_ block: @escaping () -> Void) { workQ.async(execute: block) }

    func stop() {
        workQ.sync { processor.endSession() }
    }
}
