import CoreVideo
import Foundation
import Metal
import VideoToolbox

/// 清晰放大：把画面用锐利的三次插值（Catmull-Rom）直接缩放到屏幕上实际显示的像素大小（全屏 2940×1654 这种），
/// 再按需要对亮度做一点 RCAS 锐化。输出仍是 420v，显示层不用再缩放，也不用在两种格式之间来回切（不会闪）。
/// 系统显示层自己放大时用的是比较软的插值，字边缘会糊一点（2026-11-19 用户反馈"2K 和 1080 差不多，字边缘有点糊"）。
/// 所有要显示的帧都走这里：直通、静止直通、真实帧、补出来的帧，尺寸和格式始终一致。
/// 多个线程会调用（采集线程、补帧线程、输出队列），内部加锁串行。
/// 2026-11-20：第一版用两遍 Lanczos-3（每个像素现算三角函数权重），M2 上 GPU 实际要算 7~9ms、延迟多 12ms，太慢；
/// 改成单遍 Catmull-Rom（借 GPU 的双线性采样，每像素只采 5 次），清晰度接近 Lanczos。
/// 同日试过 AMD FSR 1 的 EASU（边缘自适应）：GPU 多 2.6ms，GTA 截图上和 Catmull-Rom 几乎看不出差别（放大倍数只有 1.5 倍），没用。
/// Apple 的 VTLowLatencySuperResolutionScaler 输入最大 1280×1280，1080p 进不去，也用不上。
final class SharpScaler: @unchecked Sendable {
    var enabled = true
    /// 设置里的锐化强度（0 = 关）；2K / 4K 输入时至少用柔和（0.25）
    var sharpness: Float = 0
    var autoSharpHiRes = true
    /// 缩小（4K 采集 → 屏幕）时用按比例放宽的三次核（两遍），不然细线、小字会闪
    var wideDown = true
    /// 压缩传输（MJPEG）：锐化打几折。锐化会把压缩带来的方块和字周围的波纹一起放大
    /// （2026-11-20 用 JPEG 模拟：标准锐化比不锐化多 2~3.6dB 的压缩损伤，减半能挽回约一半）。
    /// 同时试过 8×8 去方块滤波：各种压缩质量下都更差（方块本来就很轻，滤波抹掉的是真细节），没用。
    /// 补帧时也照样打折：补帧前的画面就带着压缩损伤
    var compressed = false
    var compressedSharpFactor: Float = 0.5
    /// 显示区域的实际像素大小（主线程按窗口大小更新）。大小稳定 0.3 秒才换（窗口动画期间不重建）
    var targetSize = CGSize.zero {
        didSet { if targetSize != oldValue { lock.lock(); targetChangedAt = nowMs(); lock.unlock() } }
    }
    private var targetChangedAt = 0.0
    private var sourceHeightSeen = 0    // 最近一帧真实帧的高度
    private var lastRealOut = (0, 0)    // 最近一帧真实帧输出的尺寸
    private var stable = CGSize.zero
    private(set) var lastMs = 0.0
    private(set) var describe = ""

    private let lock = NSLock()
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let yPS: MTLComputePipelineState, cPS: MTLComputePipelineState
    private let rcasPS: MTLComputePipelineState
    private let bYPS: MTLComputePipelineState, bCPS: MTLComputePipelineState
    private let nearest: MTLSamplerState
    private let dH1: MTLComputePipelineState, dV1: MTLComputePipelineState, dH2: MTLComputePipelineState, dV2: MTLComputePipelineState
    private let sampler: MTLSamplerState
    private(set) var lastGpuMs = 0.0
    private var cache: CVMetalTextureCache?
    private var pool: CVPixelBufferPool?
    private var poolSize = (0, 0)
    private var tmpY2: MTLTexture?
    /// 缩小用的中间纹理，按"输出宽 × 源高"分开存：720p 补帧时真实帧（1080p）和补出来的帧（720p）交替进来，不能每帧重建
    private var tmpHs: [String: MTLTexture] = [:], tmpHCs: [String: MTLTexture] = [:]
    /// 缩小用的采样表（每个输出坐标 5 组：采样位置 + 权重），尺寸变了才重算。
    /// 相邻两个同号权重的像素合成一次双线性采样（GPU 一次读两个像素），读取次数减半
    private var lut: [String: MTLBuffer] = [:]
    private func weights(_ n: Int, _ m: Int) -> MTLBuffer? {
        let key = "\(n)>\(m)"
        if let b = lut[key] { return b }
        let ratio = Double(n) / Double(m), sup = 2 * ratio
        let slots = 5
        var a = [Float](repeating: 0, count: m * slots * 2)
        func cr(_ x: Double) -> Double {
            let x = abs(x)
            return x < 1 ? (1.5 * x - 2.5) * x * x + 1 : x < 2 ? ((-0.5 * x + 2.5) * x - 4) * x + 2 : 0
        }
        for o in 0..<m {
            let c = (Double(o) + 0.5) * ratio - 0.5
            let i0 = Int(floor(c - sup)) + 1, i1 = Int(floor(c + sup))
            // 边缘外的像素并到边上（和 clamp 一样）
            var taps: [(Int, Double)] = []
            for i in i0...i1 {
                let w = cr((Double(i) - c) / ratio), ii = min(max(i, 0), n - 1)
                if let l = taps.last, l.0 == ii { taps[taps.count - 1].1 += w } else { taps.append((ii, w)) }
            }
            let sum = taps.reduce(0) { $0 + $1.1 }
            // 两两合并：相邻、同号才合并
            var samples: [(Double, Double)] = [] // (像素中心坐标, 权重)
            var k = 0
            while k < taps.count {
                let (ia, wa) = taps[k]
                if k + 1 < taps.count, taps[k + 1].0 == ia + 1, wa * taps[k + 1].1 > 0 {
                    let wb = taps[k + 1].1
                    samples.append((Double(ia) + 0.5 + wb / (wa + wb), (wa + wb) / sum)); k += 2
                } else {
                    samples.append((Double(ia) + 0.5, wa / sum)); k += 1
                }
            }
            precondition(samples.count <= slots, "缩小比例太大")
            for (j, sm) in samples.enumerated() {
                a[(o * slots + j) * 2] = Float(sm.0 / Double(n)); a[(o * slots + j) * 2 + 1] = Float(sm.1)
            }
        }
        let b = device.makeBuffer(bytes: a, length: a.count * 4, options: .storageModeShared)
        if lut.count > 16 { lut.removeAll() }
        lut[key] = b
        return b
    }
    private var transfer: VTPixelTransferSession?
    private var inPool: CVPixelBufferPool?
    private var inPoolSize = (0, 0)

    init?() {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue() else { return nil }
        device = d; queue = q
        do {
            let lib = try d.makeLibrary(source: SharpScaler.shader, options: nil)
            func p(_ n: String) throws -> MTLComputePipelineState { try d.makeComputePipelineState(function: lib.makeFunction(name: n)!) }
            yPS = try p("cubicY"); cPS = try p("cubicC"); rcasPS = try p("rcasY")
            bYPS = try p("blendY"); bCPS = try p("blendC")
            dH1 = try p("downH1"); dV1 = try p("downV1"); dH2 = try p("downH2"); dV2 = try p("downV2")
        } catch {
            Log.write("⚠ 清晰放大着色器编译失败：\(error)")
            return nil
        }
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear; sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge
        sd.normalizedCoordinates = true
        sampler = d.makeSamplerState(descriptor: sd)!
        let nd = MTLSamplerDescriptor()
        nd.minFilter = .nearest; nd.magFilter = .nearest
        nd.sAddressMode = .clampToEdge; nd.tAddressMode = .clampToEdge
        nd.normalizedCoordinates = true
        nearest = d.makeSamplerState(descriptor: nd)!
        CVMetalTextureCacheCreate(nil, nil, d, nil, &cache)
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
    }

    /// 采集到的画面高度（开补帧时送来的帧已经降到 1080p，2K / 4K 自动锐化要按采集分辨率判断，不然一开补帧就没了）
    var sourceHeight = 0
    /// 这一帧要用的锐化强度
    private func sharpFor(_ srcH: Int) -> Float {
        autoSharpHiRes && max(srcH, sourceHeight) >= 1440 ? max(sharpness, 0.25) : sharpness
    }

    /// 处理一帧：缩放到显示大小（+ 锐化）。不需要处理 / 出错时原样返回
    /// interpolated：补出来的帧（720p 补帧时尺寸比真实帧小）。设置里显示的"当前：…"只按真实帧更新，不然两种尺寸来回跳
    /// overlay：(真实帧, 字幕保护位置图)。720p 补帧时字幕保护在这里合成：位置图里标了的像素用真实帧放大的结果
    func process(_ src: CVPixelBuffer, interpolated: Bool = false, overlay: (CVPixelBuffer, CVPixelBuffer)? = nil) -> CVPixelBuffer {
        guard enabled else { return src }
        lock.lock(); defer { lock.unlock() }
        guard let cache else { return src }
        if stable == .zero || nowMs() - targetChangedAt > 300 { stable = targetSize }
        let sw = CVPixelBufferGetWidth(src), sh = CVPixelBufferGetHeight(src)
        guard stable.width > 0 else { return src }
        let ow = Int(stable.width) & ~1, oh = Int(stable.height) & ~1
        let isCompressed = compressed
        let sharp = sharpFor(sh) * (isCompressed ? compressedSharpFactor : 1)
        // 720p 补出来的帧：放大到真实帧最后输出的尺寸（哪怕真实帧没缩放），两种帧尺寸始终一样，显示层不会闪
        let matchReal = interpolated && sh != sourceHeightSeen && lastRealOut.0 > 0
        let scale = matchReal || abs(ow - sw) > 8 || abs(oh - sh) > 8
        guard scale || sharp > 0 else { if !interpolated { lastRealOut = (sw, sh); sourceHeightSeen = sh }; return src }
        let t0 = nowMs()
        composed = false
        // 采集卡的 4:2:2（yuvs）先转成 420v（和补帧的帧同一种格式）
        var input = src
        if CVPixelBufferGetPixelFormatType(src) != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
            guard let conv = convert(src, sw, sh) else { return src }
            input = conv
        }
        let (dw, dh) = matchReal ? lastRealOut : scale ? (ow, oh) : (sw, sh)
        guard let out = outBuffer(dw, dh),
              let iY = tex(input, 0, .r8Unorm, cache), let iC = tex(input, 1, .rg8Unorm, cache),
              let oY = tex(out, 0, .r8Unorm, cache), let oC = tex(out, 1, .rg8Unorm, cache),
              let cb = queue.makeCommandBuffer() else { return src }
        // 只缩一点（如 2K 放进 2404 宽的窗口，0.94 倍）几乎不闪，不值得多花时间；缩到 0.85 倍以下才用
        let down = scale && wideDown && dw < sw * 85 / 100 && dh < sh * 85 / 100
        guard let e = cb.makeComputeCommandEncoder() else { return src }
        e.setSamplerState(sampler, index: 0)
        e.setSamplerState(nearest, index: 1)
        guard encodeScale(e, iY: iY, iC: iC, oY: oY, oC: oC, sw: sw, sh: sh, dw: dw, dh: dh, sharp: sharp, down: down) else {
            e.endEncoding(); return src
        }
        // 字幕保护（720p 补帧）：真实帧按它自己显示时完全一样的方式放大到同样大小，位置图里标了的像素换成真实帧的
        if let (real, mask) = overlay, CVPixelBufferGetPixelFormatType(real) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
           let rY = tex(real, 0, .r8Unorm, cache), let rC = tex(real, 1, .rg8Unorm, cache), let mT = tex(mask, 0, .r8Unorm, cache) {
            let rw = CVPixelBufferGetWidth(real), rh = CVPixelBufferGetHeight(real)
            let rsharp = sharpFor(rh) * (isCompressed ? compressedSharpFactor : 1)
            let rdown = wideDown && dw < rw * 85 / 100 && dh < rh * 85 / 100
            ensureOverlay(dw, dh)
            if let ovY, let ovC,
               encodeScale(e, iY: rY, iC: rC, oY: ovY, oC: ovC, sw: rw, sh: rh, dw: dw, dh: dh, sharp: rsharp, down: rdown) {
                e.setComputePipelineState(bYPS); e.setTextures([ovY, mT, oY], range: 0..<3); dispatch(e, bYPS, dw, dh)
                e.setComputePipelineState(bCPS); e.setTextures([ovC, mT, oC], range: 0..<3); dispatch(e, bCPS, dw / 2, dh / 2)
                composed = true
            }
        }
        e.endEncoding()
        cb.commit(); cb.waitUntilCompleted()
        lastGpuMs = (cb.gpuEndTime - cb.gpuStartTime) * 1000
        guard cb.status == .completed else { return src }
        tagBT709(out)
        lastMs = nowMs() - t0
        if interpolated && sh != sourceHeightSeen { return out }
        if !interpolated { sourceHeightSeen = sh; lastRealOut = (dw, dh) }
        let ratio = Double(dw) / Double(sw)
        let how = !scale ? "不缩放" : ratio > 1 ? String(format: "放大 %.2f 倍 · 三次插值", ratio)
            : String(format: "缩小到 %.2f 倍 · ", ratio) + (down ? "按比例取样（防闪烁）" : "三次插值")
        var why: [String] = []
        if autoSharpHiRes && max(sh, sourceHeight) >= 1440 && sharpness < 0.25 { why.append("2K/4K 自动") }
        if isCompressed && compressedSharpFactor < 1 && sharp > 0 { why.append("压缩画面减半") }
        describe = "当前：\(sw)×\(sh) → \(dw)×\(dh)，\(how) · "
            + (sharp > 0 ? "锐化 \(String(format: "%.2f", sharp))" + (why.isEmpty ? "" : "（\(why.joined(separator: "，"))）") : "不锐化")
        return out
    }

    /// 一帧的缩放（+ 锐化）编进 encoder：亮度一遍缩放（锐化时先写临时纹理，再 RCAS 写到输出），色度半分辨率
    private func encodeScale(_ e: MTLComputeCommandEncoder, iY: MTLTexture, iC: MTLTexture, oY: MTLTexture, oC: MTLTexture,
                             sw: Int, sh: Int, dw: Int, dh: Int, sharp: Float, down: Bool) -> Bool {
        ensureTemps(sw, sh, dw, dh, down: down)
        guard let tmpY2 else { return false }
        let tmpH = down ? tmpHs["\(dw)x\(sh)"] : nil, tmpHC = down ? tmpHCs["\(dw)x\(sh)"] : nil
        let wx = down ? weights(sw, dw) : nil, wy = down ? weights(sh, dh) : nil
        let wcx = down ? weights(sw / 2, dw / 2) : nil, wcy = down ? weights(sh / 2, dh / 2) : nil
        if down, let tmpH, let wx, let wy {
            e.setComputePipelineState(dH1); e.setTextures([iY, tmpH], range: 0..<2); e.setBuffer(wx, offset: 0, index: 0)
            dispatch(e, dH1, dw, sh)
            e.setComputePipelineState(dV1); e.setTextures([tmpH, sharp > 0 ? tmpY2 : oY], range: 0..<2); e.setBuffer(wy, offset: 0, index: 0)
            dispatch(e, dV1, dw, dh)
        } else {
            e.setComputePipelineState(yPS); e.setTextures([iY, sharp > 0 ? tmpY2 : oY], range: 0..<2)
            dispatch(e, yPS, dw, dh)
        }
        if sharp > 0 {
            var con: Float = exp2(-(1 - sharp) * 2)
            e.setComputePipelineState(rcasPS); e.setTextures([tmpY2, oY], range: 0..<2); e.setBytes(&con, length: 4, index: 0)
            dispatch(e, rcasPS, dw, dh)
        }
        if down, let tmpHC, let wcx, let wcy {
            e.setComputePipelineState(dH2); e.setTextures([iC, tmpHC], range: 0..<2); e.setBuffer(wcx, offset: 0, index: 0)
            dispatch(e, dH2, dw / 2, sh / 2)
            e.setComputePipelineState(dV2); e.setTextures([tmpHC, oC], range: 0..<2); e.setBuffer(wcy, offset: 0, index: 0)
            dispatch(e, dV2, dw / 2, dh / 2)
        } else {
            e.setComputePipelineState(cPS); e.setTextures([iC, oC], range: 0..<2)
            dispatch(e, cPS, dw / 2, dh / 2)
        }
        return true
    }

    /// 字幕保护用：真实帧放大后的亮度 / 色度（和输出一样大）
    private var ovY: MTLTexture?, ovC: MTLTexture?
    private func ensureOverlay(_ dw: Int, _ dh: Int) {
        func make(_ f: MTLPixelFormat, _ w: Int, _ h: Int) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: w, height: h, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        if ovY?.width != dw || ovY?.height != dh { ovY = make(.r8Unorm, dw, dh); ovC = make(.rg8Unorm, dw / 2, dh / 2) }
    }
    /// 最近一帧有没有在显卡上合成字幕（统计用）
    private(set) var composed = false

    private func convert(_ src: CVPixelBuffer, _ w: Int, _ h: Int) -> CVPixelBuffer? {
        if inPool == nil || inPoolSize != (w, h) {
            inPool = makePool(w, h); inPoolSize = (w, h)
        }
        var pb: CVPixelBuffer?
        guard let inPool, let transfer, CVPixelBufferPoolCreatePixelBuffer(nil, inPool, &pb) == kCVReturnSuccess, let pb,
              VTPixelTransferSessionTransferImage(transfer, from: src, to: pb) == noErr else { return nil }
        return pb
    }

    private func ensureTemps(_ sw: Int, _ sh: Int, _ dw: Int, _ dh: Int, down: Bool) {
        func make(_ f: MTLPixelFormat, _ w: Int, _ h: Int) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: w, height: h, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        if tmpY2?.width != dw || tmpY2?.height != dh { tmpY2 = make(.r16Float, dw, dh) }
        guard down else { return }
        let key = "\(dw)x\(sh)"
        if tmpHs[key] == nil {
            if tmpHs.count > 4 { tmpHs.removeAll(); tmpHCs.removeAll() } // 窗口大小变过几次：旧的扔掉
            tmpHs[key] = make(.r16Float, dw, sh); tmpHCs[key] = make(.rg16Float, dw / 2, sh / 2)
        }
    }

    private func makePool(_ w: Int, _ h: Int) -> CVPixelBufferPool? {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var p: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 8] as CFDictionary, attrs as CFDictionary, &p)
        return p
    }

    private func outBuffer(_ w: Int, _ h: Int) -> CVPixelBuffer? {
        if pool == nil || poolSize != (w, h) { pool = makePool(w, h); poolSize = (w, h) }
        var pb: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess else { return nil }
        return pb
    }

    private func tex(_ pb: CVPixelBuffer, _ plane: Int, _ f: MTLPixelFormat, _ cache: CVMetalTextureCache) -> MTLTexture? {
        var t: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, f, CVPixelBufferGetWidthOfPlane(pb, plane),
                                                  CVPixelBufferGetHeightOfPlane(pb, plane), plane, &t)
        return t.flatMap { CVMetalTextureGetTexture($0) }
    }

    private func dispatch(_ e: MTLComputeCommandEncoder, _ p: MTLComputePipelineState, _ w: Int, _ h: Int) {
        let tw = p.threadExecutionWidth, th = max(1, p.maxTotalThreadsPerThreadgroup / tw)
        e.dispatchThreads(MTLSize(width: w, height: h, depth: 1), threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
    }

    static let shader = """
    #include <metal_stdlib>
    using namespace metal;

    // Catmull-Rom 三次插值，借双线性采样只取 5 个样本（去掉四个角，权重很小）
    static float4 catmullRom(texture2d<float, access::sample> tex, sampler s, float2 uv) {
        float2 size = float2(tex.get_width(), tex.get_height());
        float2 sp = uv * size;
        float2 t1 = floor(sp - 0.5) + 0.5;
        float2 f = sp - t1;
        float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
        float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
        float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
        float2 w3 = f * f * (-0.5 + 0.5 * f);
        float2 w12 = w1 + w2;
        float2 t0 = (t1 - 1.0) / size, t3 = (t1 + 2.0) / size, t12 = (t1 + w2 / w12) / size;
        float4 r = tex.sample(s, float2(t12.x, t0.y)) * (w12.x * w0.y)
                 + tex.sample(s, float2(t0.x, t12.y)) * (w0.x * w12.y)
                 + tex.sample(s, float2(t12.x, t12.y)) * (w12.x * w12.y)
                 + tex.sample(s, float2(t3.x, t12.y)) * (w3.x * w12.y)
                 + tex.sample(s, float2(t12.x, t3.y)) * (w12.x * w3.y);
        float ws = w12.x * w0.y + w0.x * w12.y + w12.x * w12.y + w3.x * w12.y + w12.x * w3.y;
        return r / ws;
    }

    kernel void cubicY(texture2d<float, access::sample> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                       sampler s [[sampler(0)]], uint2 g [[thread_position_in_grid]]) {
        if (g.x >= dst.get_width() || g.y >= dst.get_height()) return;
        float2 uv = (float2(g) + 0.5) / float2(dst.get_width(), dst.get_height());
        dst.write(float4(saturate(catmullRom(src, s, uv).r), 0, 0, 1), g);
    }
    kernel void cubicC(texture2d<float, access::sample> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                       sampler s [[sampler(0)]], uint2 g [[thread_position_in_grid]]) {
        if (g.x >= dst.get_width() || g.y >= dst.get_height()) return;
        float2 uv = (float2(g) + 0.5) / float2(dst.get_width(), dst.get_height());
        dst.write(float4(saturate(catmullRom(src, s, uv).rg), 0, 1), g);
    }

    // 缩小用：Catmull-Rom 核按缩小比例放宽（覆盖 ±2×比例 个源像素），横竖各一遍。
    // 每个输出像素把它覆盖到的源像素都算进去，细线、小字、栅栏不会忽有忽无（不闪、没有摩尔纹）。
    // 采样位置和权重在 CPU 上按输出坐标预先算好（见 weights）
    static inline float2 downAt(texture2d<float, access::sample> src, sampler s, uint2 g, device const float2 *wt, bool horiz) {
        float2 sz = float2(src.get_width(), src.get_height());
        device const float2 *t = wt + (horiz ? g.x : g.y) * 5;
        float other = (float(horiz ? g.y : g.x) + 0.5) / (horiz ? sz.y : sz.x);
        float2 acc = 0;
        for (int k = 0; k < 5; k++) {
            float2 pw = t[k];
            if (pw.y != 0) acc += pw.y * src.sample(s, horiz ? float2(pw.x, other) : float2(other, pw.x)).rg;
        }
        return acc;
    }
    kernel void downH1(texture2d<float, access::sample> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                       device const float2 *wt [[buffer(0)]], sampler s [[sampler(0)]], uint2 g [[thread_position_in_grid]]) {
        if (g.x >= dst.get_width() || g.y >= dst.get_height()) return;
        dst.write(float4(downAt(src, s, g, wt, true).r, 0, 0, 1), g);
    }
    kernel void downV1(texture2d<float, access::sample> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                       device const float2 *wt [[buffer(0)]], sampler s [[sampler(0)]], uint2 g [[thread_position_in_grid]]) {
        if (g.x >= dst.get_width() || g.y >= dst.get_height()) return;
        dst.write(float4(saturate(downAt(src, s, g, wt, false).r), 0, 0, 1), g);
    }
    kernel void downH2(texture2d<float, access::sample> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                       device const float2 *wt [[buffer(0)]], sampler s [[sampler(0)]], uint2 g [[thread_position_in_grid]]) {
        if (g.x >= dst.get_width() || g.y >= dst.get_height()) return;
        dst.write(float4(downAt(src, s, g, wt, true), 0, 1), g);
    }
    kernel void downV2(texture2d<float, access::sample> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                       device const float2 *wt [[buffer(0)]], sampler s [[sampler(0)]], uint2 g [[thread_position_in_grid]]) {
        if (g.x >= dst.get_width() || g.y >= dst.get_height()) return;
        dst.write(float4(saturate(downAt(src, s, g, wt, false)), 0, 1), g);
    }

    // 字幕保护合成：位置图（真实帧大小，最近邻取样）里标了的像素，换成真实帧放大后的结果
    kernel void blendY(texture2d<float, access::read> ov [[texture(0)]], texture2d<float, access::sample> mask [[texture(1)]],
                       texture2d<float, access::write> dst [[texture(2)]], sampler ns [[sampler(1)]], uint2 g [[thread_position_in_grid]]) {
        if (g.x >= dst.get_width() || g.y >= dst.get_height()) return;
        float2 uv = (float2(g) + 0.5) / float2(dst.get_width(), dst.get_height());
        if (mask.sample(ns, uv).r > 0.5) dst.write(ov.read(g), g);
    }
    kernel void blendC(texture2d<float, access::read> ov [[texture(0)]], texture2d<float, access::sample> mask [[texture(1)]],
                       texture2d<float, access::write> dst [[texture(2)]], sampler ns [[sampler(1)]], uint2 g [[thread_position_in_grid]]) {
        if (g.x >= dst.get_width() || g.y >= dst.get_height()) return;
        // 色度一个像素对应亮度 2×2：四个里有一个要保护就换（和 CPU 版一样）
        float2 c = (float2(g) + 0.5) / float2(dst.get_width(), dst.get_height());
        float2 o = 0.25 / float2(dst.get_width(), dst.get_height());
        float m = max(max(mask.sample(ns, c + float2(-o.x, -o.y)).r, mask.sample(ns, c + float2(o.x, -o.y)).r),
                      max(mask.sample(ns, c + float2(-o.x, o.y)).r, mask.sample(ns, c + float2(o.x, o.y)).r));
        if (m > 0.5) dst.write(ov.read(g), g);
    }

    // RCAS 只做亮度（AMD FidelityFX，FSR 1 的锐化部分）
    kernel void rcasY(texture2d<float, access::read> inTex [[texture(0)]], texture2d<float, access::write> outTex [[texture(1)]],
                      constant float &con [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
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
    """
}
