import CoreVideo
import Foundation
import Metal
import MetalFX

/// 画面增强：MetalFX 空间放大（1080p → 屏幕实际像素）+ RCAS 锐化（AMD FidelityFX 的对比度自适应锐化）。
/// 输入：420v（补帧器 / 采集出来的格式）；输出：BGRA，交给显示层。
/// 每个要显示的帧（真实帧和补出来的帧）都走一遍，同步等 GPU 做完。
/// M2 实测（同时在补帧）：只锐化（1080p）约 1.8ms；MetalFX 放大到全屏 2940×1654 约 6ms。
/// 多个线程会调用（采集线程、补帧线程），内部加锁串行。
final class Enhancer: @unchecked Sendable {
    /// 锐化强度 0~1（0 = 不锐化）。档位：柔和 0.25 / 标准 0.5 / 锐利 0.75 / 最锐 1.0
    var sharpness: Float = 0.75
    /// 是否用 MetalFX 放大到 targetSize（目标比源大时才放大）
    var upscale = false
    /// 显示区域的实际像素大小（主线程按窗口大小更新）。
    /// 全屏 / 窗口切换的动画里大小每帧都变，MetalFX 放大器每变一次就要重建（日志里一次切换重建 20~30 次）。
    /// 所以大小稳定 0.3 秒后才真正换成新尺寸，动画期间继续用旧尺寸（显示层会自己缩放）
    var targetSize = CGSize.zero {
        didSet { if targetSize != oldValue { targetChangedAt = nowMs() } }
    }
    private var targetChangedAt = 0.0
    private var stableTarget = CGSize.zero

    private(set) var lastMs = 0.0
    private(set) var describe = ""

    private let lock = NSLock()
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let yuvPipeline: MTLComputePipelineState
    private let rcasPipeline: MTLComputePipelineState
    private let rcasYPipeline: MTLComputePipelineState
    private var yuvPool: CVPixelBufferPool?
    private var yuvPoolSize = (0, 0)
    private var cache: CVMetalTextureCache?
    private var scaler: MTLFXSpatialScaler?
    private var scalerKey = ""
    private var rgbTex: MTLTexture?      // YUV → RGB（源尺寸）
    private var upTex: MTLTexture?       // MetalFX 放大后（目标尺寸）
    private var outPool: CVPixelBufferPool?
    private var outPoolSize = (0, 0)

    init?() {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue() else { return nil }
        device = d
        queue = q
        do {
            let lib = try d.makeLibrary(source: Enhancer.shaderSource, options: nil)
            yuvPipeline = try d.makeComputePipelineState(function: lib.makeFunction(name: "yuvToRgb")!)
            rcasPipeline = try d.makeComputePipelineState(function: lib.makeFunction(name: "rcas")!)
            rcasYPipeline = try d.makeComputePipelineState(function: lib.makeFunction(name: "rcasY")!)
        } catch {
            Log.write("⚠ 画面增强着色器编译失败：\(error)")
            return nil
        }
        CVMetalTextureCacheCreate(nil, nil, d, nil, &cache)
    }

    var enabled: Bool { sharpness > 0 || upscale }

    /// 处理一帧。不需要处理 / 出错时原样返回输入
    /// sharpnessOverride：只对这一帧用的锐化强度（"只锐化补出来的帧"时用），nil = 用全局设置
    func process(_ src: CVPixelBuffer, sharpnessOverride: Float? = nil) -> CVPixelBuffer {
        lock.lock(); defer { lock.unlock() }
        let sharp = sharpnessOverride ?? sharpness
        guard sharp > 0 || upscale, let cache else { return src }
        let t0 = nowMs()
        let sw = CVPixelBufferGetWidth(src), sh = CVPixelBufferGetHeight(src)
        guard CVPixelBufferGetPixelFormatType(src) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else { return src }

        // 输出尺寸：放大打开且目标比源大 → 目标尺寸（16:9 内的实际像素，取偶数）；否则源尺寸
        if stableTarget == .zero || nowMs() - targetChangedAt > 300 { stableTarget = targetSize }
        var ow = sw, oh = sh
        if upscale, stableTarget.width > CGFloat(sw) + 8 {
            ow = Int(stableTarget.width) & ~1
            oh = Int(stableTarget.height) & ~1
        }
        let doScale = ow != sw || oh != sh
        if !doScale && sharp <= 0 { return src }

        // 纹理
        guard let yTex = texture(src, plane: 0, format: .r8Unorm, cache: cache),
              let cTex = texture(src, plane: 1, format: .rg8Unorm, cache: cache) else { return src }
        if rgbTex?.width != sw || rgbTex?.height != sh {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: sw, height: sh, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            rgbTex = device.makeTexture(descriptor: d)
        }
        guard let rgbTex, let out = outBuffer(ow, oh), let outTex = texture(out, plane: -1, format: .bgra8Unorm, cache: cache),
              let cb = queue.makeCommandBuffer() else { return src }

        // 1. YUV → RGB
        if let enc = cb.makeComputeCommandEncoder() {
            enc.setComputePipelineState(yuvPipeline)
            enc.setTexture(yTex, index: 0); enc.setTexture(cTex, index: 1); enc.setTexture(rgbTex, index: 2)
            dispatch(enc, yuvPipeline, sw, sh)
            enc.endEncoding()
        }
        // 2. MetalFX 放大
        var rcasInput = rgbTex
        if doScale {
            ensureScaler(sw, sh, ow, oh)
            if let scaler, let upTex {
                scaler.colorTexture = rgbTex
                scaler.outputTexture = upTex
                scaler.inputContentWidth = sw
                scaler.inputContentHeight = sh
                scaler.encode(commandBuffer: cb)
                rcasInput = upTex
            }
        }
        // 3. RCAS 锐化（强度 0 时就是拷贝），写进输出缓冲
        if let enc = cb.makeComputeCommandEncoder() {
            enc.setComputePipelineState(rcasPipeline)
            enc.setTexture(rcasInput, index: 0); enc.setTexture(outTex, index: 1)
            // RCAS 的强度以"档"为单位：0 档最锐，每加 1 档减半。强度 1.0 → 0 档，0.25 → 1.5 档
            var con: Float = sharp > 0 ? exp2(-(1 - sharp) * 2) : 0
            enc.setBytes(&con, length: 4, index: 0)
            dispatch(enc, rcasPipeline, rcasInput.width, rcasInput.height)
            enc.endEncoding()
        }
        cb.commit()
        cb.waitUntilCompleted()
        guard cb.status == .completed else { return src }
        CVBufferSetAttachment(out, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(out, kCVImageBufferTransferFunctionKey, displayTransferFunction, .shouldPropagate)
        lastMs = nowMs() - t0
        describe = doScale ? "MetalFX \(sw)×\(sh) → \(ow)×\(oh)" : "\(sw)×\(sh)（画面没有放大）"
        return out
    }

    /// 只锐化亮度：420v 进、420v 出（色度原样拷贝）。给"只锐化补出来的帧"用
    func sharpenLuma(_ src: CVPixelBuffer, sharpness sharp: Float) -> CVPixelBuffer {
        lock.lock(); defer { lock.unlock() }
        guard sharp > 0, let cache, CVPixelBufferGetPixelFormatType(src) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else { return src }
        let t0 = nowMs()
        let w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src)
        if yuvPool == nil || yuvPoolSize != (w, h) {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 6] as CFDictionary, attrs as CFDictionary, &p)
            yuvPool = p; yuvPoolSize = (w, h)
        }
        var outOpt: CVPixelBuffer?
        guard let yuvPool, CVPixelBufferPoolCreatePixelBuffer(nil, yuvPool, &outOpt) == kCVReturnSuccess, let out = outOpt,
              let iY = texture(src, plane: 0, format: .r8Unorm, cache: cache), let iC = texture(src, plane: 1, format: .rg8Unorm, cache: cache),
              let oY = texture(out, plane: 0, format: .r8Unorm, cache: cache), let oC = texture(out, plane: 1, format: .rg8Unorm, cache: cache),
              let cb = queue.makeCommandBuffer() else { return src }
        if let enc = cb.makeComputeCommandEncoder() {
            enc.setComputePipelineState(rcasYPipeline)
            enc.setTexture(iY, index: 0); enc.setTexture(oY, index: 1)
            var con: Float = exp2(-(1 - sharp) * 2)
            enc.setBytes(&con, length: 4, index: 0)
            dispatch(enc, rcasYPipeline, w, h)
            enc.endEncoding()
        }
        if let bl = cb.makeBlitCommandEncoder() {
            bl.copy(from: iC, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(), sourceSize: MTLSize(width: iC.width, height: iC.height, depth: 1),
                    to: oC, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
            bl.endEncoding()
        }
        cb.commit(); cb.waitUntilCompleted()
        guard cb.status == .completed else { return src }
        lastMs = nowMs() - t0
        return out
    }

    private func dispatch(_ enc: MTLComputeCommandEncoder, _ p: MTLComputePipelineState, _ w: Int, _ h: Int) {
        let tw = p.threadExecutionWidth, th = max(1, p.maxTotalThreadsPerThreadgroup / tw)
        enc.dispatchThreads(MTLSize(width: w, height: h, depth: 1), threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
    }

    private func ensureScaler(_ sw: Int, _ sh: Int, _ ow: Int, _ oh: Int) {
        let key = "\(sw)x\(sh)>\(ow)x\(oh)"
        guard key != scalerKey else { return }
        scalerKey = key
        let d = MTLFXSpatialScalerDescriptor()
        d.inputWidth = sw; d.inputHeight = sh
        d.outputWidth = ow; d.outputHeight = oh
        d.colorTextureFormat = .bgra8Unorm
        d.outputTextureFormat = .bgra8Unorm
        d.colorProcessingMode = .perceptual
        scaler = d.makeSpatialScaler(device: device)
        guard let scaler else { Log.write("⚠ MetalFX 放大器创建失败（\(key)）"); return }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: ow, height: oh, mipmapped: false)
        td.usage = scaler.outputTextureUsage.union(.shaderRead)
        td.storageMode = .private
        upTex = device.makeTexture(descriptor: td)
        Log.write("MetalFX 放大：\(sw)×\(sh) → \(ow)×\(oh)")
    }

    private func outBuffer(_ w: Int, _ h: Int) -> CVPixelBuffer? {
        if outPool == nil || outPoolSize != (w, h) {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 8] as CFDictionary, attrs as CFDictionary, &p)
            outPool = p
            outPoolSize = (w, h)
        }
        guard let outPool else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, outPool, &pb)
        return pb
    }

    /// plane = -1：非平面格式
    private func texture(_ pb: CVPixelBuffer, plane: Int, format: MTLPixelFormat, cache: CVMetalTextureCache) -> MTLTexture? {
        let w = plane >= 0 ? CVPixelBufferGetWidthOfPlane(pb, plane) : CVPixelBufferGetWidth(pb)
        let h = plane >= 0 ? CVPixelBufferGetHeightOfPlane(pb, plane) : CVPixelBufferGetHeight(pb)
        var t: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, format, w, h, max(plane, 0), &t)
        return t.flatMap { CVMetalTextureGetTexture($0) }
    }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    // BT.709 视频范围 YUV → RGB（结果仍是伽马编码的值，直接给 MetalFX 的 perceptual 模式）
    kernel void yuvToRgb(texture2d<float, access::read> yTex [[texture(0)]],
                         texture2d<float, access::read> cTex [[texture(1)]],
                         texture2d<float, access::write> outTex [[texture(2)]],
                         uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;
        float y = (yTex.read(gid).r - 16.0/255.0) * (255.0/219.0);
        float2 c = (cTex.read(gid / 2).rg - 128.0/255.0) * (255.0/224.0);
        float3 rgb = float3(y + 1.5748 * c.y,
                            y - 0.1873 * c.x - 0.4681 * c.y,
                            y + 1.8556 * c.x);
        outTex.write(float4(saturate(rgb), 1.0), gid);
    }

    // RCAS 只做亮度（单通道），给 420v 的亮度平面用
    kernel void rcasY(texture2d<float, access::read> inTex [[texture(0)]],
                      texture2d<float, access::write> outTex [[texture(1)]],
                      constant float &con [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
        uint w = inTex.get_width(), h = inTex.get_height();
        if (gid.x >= w || gid.y >= h) return;
        float e = inTex.read(gid).r;
        float b = inTex.read(uint2(gid.x, gid.y > 0 ? gid.y - 1 : 0)).r;
        float hh = inTex.read(uint2(gid.x, min(gid.y + 1, h - 1))).r;
        float d = inTex.read(uint2(gid.x > 0 ? gid.x - 1 : 0, gid.y)).r;
        float f = inTex.read(uint2(min(gid.x + 1, w - 1), gid.y)).r;
        float mn4 = min(min(b, d), min(f, hh)), mx4 = max(max(b, d), max(f, hh));
        float hitMin = min(mn4, e) / (4.0 * max(mx4, e) + 1e-5);
        float hitMax = (1.0 - max(mx4, e)) / (4.0 * min(mn4, e) - 4.0 - 1e-5);
        float lobe = max(-0.1875, min(max(-hitMin, hitMax), 0.0)) * con;
        float c = (lobe * (b + d + f + hh) + e) / (4.0 * lobe + 1.0);
        outTex.write(float4(saturate(c), 0, 0, 1), gid);
    }

    // AMD FidelityFX RCAS（对比度自适应锐化，FSR 1 的锐化部分），con = exp2(-档数)，0 = 不锐化（等于拷贝）
    kernel void rcas(texture2d<float, access::read> inTex [[texture(0)]],
                     texture2d<float, access::write> outTex [[texture(1)]],
                     constant float &con [[buffer(0)]],
                     uint2 gid [[thread_position_in_grid]]) {
        uint w = inTex.get_width(), h = inTex.get_height();
        if (gid.x >= w || gid.y >= h) return;
        float3 e = inTex.read(gid).rgb;
        if (con <= 0.0) { outTex.write(float4(e, 1.0), gid); return; }
        uint2 up = uint2(gid.x, gid.y > 0 ? gid.y - 1 : 0);
        uint2 dn = uint2(gid.x, min(gid.y + 1, h - 1));
        uint2 lf = uint2(gid.x > 0 ? gid.x - 1 : 0, gid.y);
        uint2 rt = uint2(min(gid.x + 1, w - 1), gid.y);
        float3 b = inTex.read(up).rgb, d = inTex.read(lf).rgb, f = inTex.read(rt).rgb, hh = inTex.read(dn).rgb;
        float3 mn4 = min(min(b, d), min(f, hh));
        float3 mx4 = max(max(b, d), max(f, hh));
        float3 hitMin = min(mn4, e) / (4.0 * max(mx4, e) + 1e-5);
        float3 hitMax = (1.0 - max(mx4, e)) / (4.0 * min(mn4, e) - 4.0 - 1e-5);
        float3 lobeRGB = max(-hitMin, hitMax);
        float lobe = max(-0.1875, min(max(lobeRGB.r, max(lobeRGB.g, lobeRGB.b)), 0.0)) * con;
        float3 c = (lobe * (b + d + f + hh) + e) / (4.0 * lobe + 1.0);
        outTex.write(float4(saturate(c), 1.0), gid);
    }
    """
}
