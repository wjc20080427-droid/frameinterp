import CoreMedia
import CoreVideo
import Foundation

/// 一秒的统计快照（界面和日志用）
struct StatsSnapshot {
    var capture = 0, unique = 0, displayed = 0, interpDone = 0
    var interpAvg = 0.0, interpMax = 0.0
    var failures = 0, cuts = 0, drops = 0, empty = 0, depth = 0, lateSkips = 0, noNeed = 0, doubleInterp = 0
    var dupThr = 0.0, dupPct = 0.0
    var enhanceAvg = 0.0, enhanceMax = 0.0
    var avfDrops = 0
    var trims = 0
    var fmtChanges = 0
    var lastFmt = ""
    var copyMs = 0.0, obsMs = 0.0, waitMs = 0.0
    var capDelay = 0.0, capDelayMax = 0.0
    var stillDirect = 0
    var dupMean = 0.0, dupMeanMax = 0.0, dupPctMax = 0.0, uniqMean = 0.0, latency = 0.0
    var interpOn = false
    var backend = ""
    var error: String?

    var line: String {
        var s = "采集 \(capture)（系统丢 \(avfDrops)，采集到程序 \(f1(capDelay))/\(f1(capDelayMax))ms） | 唯一 \(unique) | 显示 \(displayed) | 补帧[\(interpOn ? backend : "关")] \(interpDone) 平均 \(f1(interpAvg))ms 最大 \(f1(interpMax))ms"
            + " | 拷贝小图 \(f1(copyMs)) 拷原图 \(f1(obsMs)) 排队 \(f1(waitMs))ms | 格式变化 \(fmtChanges)(\(lastFmt)) | 失败 \(failures) | 削积压 \(trims) | 静止直通 \(stillDirect) | 补2帧 \(doubleInterp) | 无需补 \(noNeed) | 太慢跳过 \(lateSkips) | 切场景 \(cuts) | 队列丢 \(drops) 空拍 \(empty) 深度 \(depth)"
            + " | 差值 重复 \(f2(dupMean))(最大 \(f2(dupMeanMax))/\(String(format: "%.3f", dupPctMax))%) 唯一 \(f1(uniqMean)) 阈值 \(f2(dupThr))/\(String(format: "%.3f", dupPct))% | 增强 \(f1(enhanceAvg))/\(f1(enhanceMax))ms | 延迟 \(f1(latency))ms"
        if let error { s += "\n  最近错误：\(error)" }
        return s
    }
}

func f1(_ v: Double) -> String { String(format: "%.1f", v) }
func f2(_ v: Double) -> String { String(format: "%.2f", v) }

/// 每秒统计（多线程写，主线程读并清零）
final class Stats {
    private let lock = NSLock()
    var capture = 0, unique = 0, displayed = 0, interpDone = 0
    var interpMsSum = 0.0, interpMsMax = 0.0
    var failures = 0, cuts = 0, queueDrops = 0, emptyVsync = 0, copyFails = 0, rendererBusy = 0, lateSkips = 0, noNeed = 0, doubleInterp = 0
    var dupThr = 0.0, dupPct = 0.0
    var enhanceMsSum = 0.0, enhanceN = 0, enhanceMsMax = 0.0
    var avfDrops = 0
    var trims = 0
    var fmtChanges = 0
    var lastFmt = ""
    var copyMsSum = 0.0, obsMsSum = 0.0, prepN = 0, waitMsSum = 0.0, waitN = 0
    var capDelaySum = 0.0, capDelayN = 0, capDelayMax = 0.0
    var stillDirect = 0
    var dupDiffSum = 0.0, dupN = 0, uniqDiffSum = 0.0, uniqN = 0
    var dupPctMax = 0.0, dupMeanMax = 0.0
    var latencySum = 0.0, latencyN = 0
    var lastError: String?
    // 累计
    var totalFailures = 0, totalDrops = 0, totalCuts = 0, totalEmpty = 0, totalInterp = 0
    var allInterpMs: [Double] = []

    func with(_ f: (Stats) -> Void) { lock.lock(); f(self); lock.unlock() }

    func snapshotAndReset(interpOn: Bool, queueDepth: Int, backend: String) -> String {
        snapshot(interpOn: interpOn, queueDepth: queueDepth, backend: backend).line
    }

    /// 取这一秒的统计并清零
    func snapshot(interpOn: Bool, queueDepth: Int, backend: String) -> StatsSnapshot {
        lock.lock(); defer { lock.unlock() }
        var r = StatsSnapshot()
        r.capture = capture; r.unique = unique; r.displayed = displayed; r.interpDone = interpDone
        r.interpAvg = interpDone > 0 ? interpMsSum / Double(interpDone) : 0
        r.interpMax = interpMsMax
        r.enhanceAvg = enhanceN > 0 ? enhanceMsSum / Double(enhanceN) : 0; r.enhanceMax = enhanceMsMax
        enhanceMsSum = 0; enhanceN = 0; enhanceMsMax = 0
        r.avfDrops = avfDrops; avfDrops = 0
        r.trims = trims; trims = 0
        r.fmtChanges = fmtChanges; fmtChanges = 0; r.lastFmt = lastFmt
        r.copyMs = prepN > 0 ? copyMsSum / Double(prepN) : 0; r.obsMs = prepN > 0 ? obsMsSum / Double(prepN) : 0
        r.waitMs = waitN > 0 ? waitMsSum / Double(waitN) : 0
        copyMsSum = 0; obsMsSum = 0; prepN = 0; waitMsSum = 0; waitN = 0
        r.capDelay = capDelayN > 0 ? capDelaySum / Double(capDelayN) : 0; r.capDelayMax = capDelayMax
        capDelaySum = 0; capDelayN = 0; capDelayMax = 0
        r.stillDirect = stillDirect; stillDirect = 0
        r.lateSkips = lateSkips; r.noNeed = noNeed; r.doubleInterp = doubleInterp; r.dupThr = dupThr; r.dupPct = dupPct
        r.failures = failures; r.cuts = cuts; r.drops = queueDrops; r.empty = emptyVsync; r.depth = queueDepth
        r.dupMean = dupN > 0 ? dupDiffSum / Double(dupN) : 0
        r.dupMeanMax = dupMeanMax; r.dupPctMax = dupPctMax
        r.uniqMean = uniqN > 0 ? uniqDiffSum / Double(uniqN) : 0
        r.latency = latencyN > 0 ? latencySum / Double(latencyN) : 0
        r.interpOn = interpOn; r.backend = backend
        r.error = lastError
        totalFailures += failures; totalDrops += queueDrops; totalCuts += cuts; totalEmpty += emptyVsync; totalInterp += interpDone
        capture = 0; unique = 0; displayed = 0; interpDone = 0; interpMsSum = 0; interpMsMax = 0
        failures = 0; cuts = 0; queueDrops = 0; emptyVsync = 0; copyFails = 0; rendererBusy = 0; lateSkips = 0; noNeed = 0; doubleInterp = 0
        dupDiffSum = 0; dupN = 0; uniqDiffSum = 0; uniqN = 0; dupPctMax = 0; dupMeanMax = 0
        latencySum = 0; latencyN = 0
        lastError = nil
        return r
    }

    func summary() -> String {
        lock.lock(); defer { lock.unlock() }
        let v = allInterpMs.sorted()
        func p(_ q: Double) -> Double { v.isEmpty ? 0 : v[min(v.count - 1, Int(Double(v.count) * q))] }
        let avg = v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count)
        return "汇总：补帧 \(v.count) 次，平均 \(f2(avg))ms，中位 \(f2(p(0.5)))ms，95% \(f2(p(0.95)))ms，99% \(f2(p(0.99)))ms，最大 \(f2(v.last ?? 0))ms；失败 \(totalFailures)，切场景 \(totalCuts)，队列丢帧 \(totalDrops)，空拍 \(totalEmpty)"
    }
}

/// 显示队列：限长，超了丢最旧的
final class DisplayQueue {
    struct Item {
        let buffer: CVPixelBuffer
        let interpolated: Bool
        let arrivalMs: Double // 对应唯一帧到达的时间（算延迟用）
    }
    private let lock = NSLock()
    private var items: [Item] = []
    var limit: Int
    let stats: Stats
    init(limit: Int, stats: Stats) { self.limit = limit; self.stats = stats }

    func push(_ item: Item) {
        lock.lock()
        items.append(item)
        var dropped = 0
        while items.count > limit { items.removeFirst(); dropped += 1 }
        lock.unlock()
        if dropped > 0 { stats.with { $0.queueDrops += dropped } }
    }

    func pop() -> Item? {
        lock.lock(); defer { lock.unlock() }
        return items.isEmpty ? nil : items.removeFirst()
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }

    /// 丢掉一帧来缩短积压（优先丢补出来的帧，丢真实帧会让画面跳一下）。返回是否丢了
    func trimOne() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !items.isEmpty else { return false }
        if let i = items.firstIndex(where: { $0.interpolated }) { items.remove(at: i) } else { items.removeFirst() }
        return true
    }
    func clear() { lock.lock(); items.removeAll(); lock.unlock() }
}

/// 后端无关的主管线：重复帧检测 → 拷贝唯一帧 → 补帧 → 显示队列
final class Pipeline {
    let dup: DupDetector
    let interp: VTInterpolator
    let queue: DisplayQueue
    let stats: Stats
    var cutThreshold: Double
    private var recentDiff = 0.0 // 最近几个新画面平均差的滑动平均（判断切场景用）
    /// 屏幕刷新周期（ms）
    var refreshMs = 1000.0 / 60.0
    /// 按两个新画面之间的实际间隔决定补几帧：间隔跨了几个刷新周期，就一共显示几帧
    /// （17ms → 不补，33ms → 补 1 帧，50ms → 补 2 帧，2 帧只在 720p 下来得及）。
    /// 补不够的帧记成"欠账"，下一次间隔短的时候多补一帧还上，保证平均每个刷新周期正好一帧：
    /// 队列不会被挤爆（不丢帧），也不会空着（不空拍）。
    private var frameDebt = 0
    /// 画面几乎不动时临时直通（见 handle 里的说明），高级选项里可以关
    var stillPassthrough = true
    private var smallRun = 0
    private var inStillMode = false
    var interpSharpness: Float = 0 // > 0：补帧时锐化
    var interpSharpAll = false     // true：真实帧也锐化（否则只锐化补出来的帧）
    var skipLateMs = 0.0 // > 0：补一帧超过这么久就不显示它（直接显示真实帧），避免偶尔的大卡顿
    var interpEnabled = true // 主线程写，采集线程读（Bool 读写在 arm64 上是原子的，这里不加锁）

    private var prev: UniqueFrame?
    private var lastCaptureMs = 0.0

    init(options: Options, interp: VTInterpolator, stats: Stats) {
        dup = DupDetector(step: options.step, threshold: options.dupThreshold,
                          changedPct: options.changedPercent, pixelDelta: options.pixelDelta)
        self.interp = interp
        self.stats = stats
        queue = DisplayQueue(limit: options.queueLimit, stats: stats)
        interp.onQueueWait = { [stats] ms in stats.with { $0.waitMsSum += ms; $0.waitN += 1 } }
        cutThreshold = options.cutThreshold
        interpEnabled = options.interpOn
    }

    /// 采集线程调用。pb 是 AVFoundation 的缓冲，只在本函数内使用。
    /// 直通出口（显示视图设置）；补帧和画面增强都关着时，每个采集帧直接交给显示层，延迟最低
    var directOut: ((CVPixelBuffer, Double) -> Void)?
    var passthrough: Bool { !interpEnabled && !(enhancer?.enabled ?? false) && directOut != nil }

    func handle(_ pb: CVPixelBuffer, pts: CMTime) {
        let t = nowMs()
        // 系统给每帧打的采集时间（主机时钟）→ 程序收到这一帧，中间隔了多久（采集卡驱动 + 系统采集框架）
        let ptsMs = CMTimeGetSeconds(pts) * 1000
        if ptsMs.isFinite, t - ptsMs > 0, t - ptsMs < 500 {
            let d = t - ptsMs
            stats.with { $0.capDelaySum += d; $0.capDelayN += 1; $0.capDelayMax = max($0.capDelayMax, d) }
        }
        if passthrough, let out = directOut {
            if queue.count > 0 { queue.clear() } // 刚从处理模式切过来：队列里剩下的旧帧不要再显示
            // 清晰放大开着时直通也先放大到屏幕大小（和其他帧尺寸、格式一致）
            if let s = scaler, s.enabled {
                let o = s.process(pb)
                stats.with { $0.enhanceMsSum += s.lastMs; $0.enhanceN += 1; $0.enhanceMsMax = max($0.enhanceMsMax, s.lastMs) }
                out(o, t)
            } else {
                out(pb, t)
            }
            let r = dup.check(pb) // 只为统计"新画面"；显示已经在上一行做完了
            prev = nil            // 之后打开补帧时，从下一个新画面重新开始，不和很久以前的帧补
            stats.with {
                $0.capture += 1
                if r.isNew { $0.unique += 1 }
            }
            return
        }
        let r = dup.check(pb)
        stats.with { $0.dupThr = dup.effectiveThreshold; $0.dupPct = dup.effectivePct }

        // 画面几乎不动（变化点 < 1%、平均差 < 1.5），比如加载画面的转圈、跳动的数字：
        // 连续 6 帧（0.1 秒）都这样就临时改成直通——每帧都显示、不补帧。否则小图标的帧容易被判成重复帧丢掉（只剩个位数帧），
        // 补出来的中间帧也会把转圈糊掉。画面一有明显变化马上回到补帧
        let small = r.changedPct < 1.0 && r.meanDiff < 1.5
        smallRun = small ? smallRun + 1 : 0
        if stillPassthrough, smallRun >= 6, let out = directOut, setInFlight(0) == 0 {
            if !inStillMode { inStillMode = true; queue.clear() }
            // 用和补帧时一样的 420v 拷贝显示，不直接显示采集卡的 4:2:2：来回切换时格式和颜色细节都不跳
            let still = interp.copyDisp(pb) ?? pb
            out(scaler.map { $0.process(still) } ?? still, t)
            prev = nil // 回到补帧时从下一个新画面重新开始
            stats.with {
                $0.capture += 1; $0.stillDirect += 1
                if r.isNew { $0.unique += 1 }
            }
            return
        }
        inStillMode = false

        if !r.isNew {
            stats.with {
                $0.capture += 1
                $0.dupDiffSum += r.meanDiff; $0.dupN += 1
                $0.dupMeanMax = max($0.dupMeanMax, r.meanDiff)
                $0.dupPctMax = max($0.dupPctMax, r.changedPct)
            }
            return
        }
        // 关键路径：补帧开始之前要做的事越少越好。
        // 720p 补帧时只先拷补帧要用的小图，马上开始补帧；原分辨率那份（显示真实帧用）等补帧开始后再拷，
        // 界面识别放到另一条队列和补帧同时跑（实测这两样在关键路径上要 5~10ms）
        let tCopy0 = nowMs()
        let split = interp.separateProc
        var copy: CVPixelBuffer? = nil
        let proc: CVPixelBuffer
        if split {
            guard let pr = interp.copyProc(pb) else {
                stats.with { $0.capture += 1; $0.copyFails += 1; $0.lastError = "拷贝采集缓冲失败" }
                return
            }
            proc = pr
        } else {
            guard let (c, pr) = interp.copyIn(pb) else {
                stats.with { $0.capture += 1; $0.copyFails += 1; $0.lastError = "拷贝采集缓冲失败" }
                return
            }
            copy = c; proc = pr
        }
        let tCopy1 = nowMs()
        lastUniqueMs = t
        // 切场景：这一帧的变化超过阈值，而且明显比前几帧大（≥ 2.5 倍）。
        // 2026-11-14 实测：快速转镜头时连续好几帧平均差都超过 40（一秒里 12 次），被当成切场景不补帧，
        // 那一秒只剩 48~50 帧。真正的切场景是突然一下，前几帧变化都不大，所以和最近的平均比
        let cut = r.meanDiff > cutThreshold && r.meanDiff > 2.5 * recentDiff
        recentDiff = recentDiff == 0 ? r.meanDiff : recentDiff * 0.7 + r.meanDiff * 0.3
        stats.with {
            $0.capture += 1; $0.unique += 1
            $0.uniqDiffSum += r.meanDiff; $0.uniqN += 1
            if cut { $0.cuts += 1 }
        }
        let p = prev
        let gapMs = p.map { CMTimeGetSeconds(CMTimeSubtract(pts, $0.pts)) * 1000 } ?? 0
        let active = interpEnabled && interp.ready && p != nil && gapMs > 0 && gapMs < 250
        var count = 0
        if active {
            // 这段间隔该显示几帧（含真实帧）
            let slots = max(0, Int((gapMs / refreshMs).rounded()))
            if cut {
                frameDebt = 0
            } else {
                count = min(max(slots - 1 + frameDebt, 0), interp.maxFramesPerGap)
                frameDebt = min(max(frameDebt + slots - (count + 1), -2), 2)
                if count == 0 { stats.with { $0.noNeed += 1 } }
            }
        } else {
            frameDebt = 0
        }
        // 真实帧（原分辨率）：补帧开始后才拷，补帧完成的回调里再取
        let realBox = BufferBox()
        if count > 0, let p {
            let phases: [Float] = count == 1 ? [0.5] : [1.0 / 3.0, 2.0 / 3.0]
            // 太慢就跳过：一般 30ms；补 2 帧时间隔更长，按间隔的 80% 算
            let lateLimit = skipLateMs > 0 ? max(skipLateMs, gapMs * 0.8) : 0
            setInFlight(+1)
            let curForInterp = UniqueFrame(buffer: proc, proc: proc, pts: pts, arrivalMs: t)
            interp.interpolate(prev: p, curr: curForInterp, phases: phases) { [self] outs, ms, err in
                defer { setInFlight(-1) }
                guard let real = realBox.wait() else { return }
                if outs != nil, lateLimit > 0, ms > lateLimit {
                    stats.with { $0.lateSkips += 1; $0.interpMsMax = max($0.interpMsMax, ms) }
                } else if let outs {
                    stats.with {
                        $0.interpDone += outs.count; $0.interpMsSum += ms * Double(outs.count)
                        $0.interpMsMax = max($0.interpMsMax, ms)
                        $0.allInterpMs.append(ms)
                        if outs.count > 1 { $0.doubleInterp += 1 }
                    }
                    for o in outs {
                        // 补出来的帧如果是补帧分辨率（720p），先放大回原分辨率再显示：
                        // 尺寸和真实帧一样，显示层不会每帧切换尺寸（那样会闪）
                        let up = interp.upscaleToDisp(o)
                        // 字幕保护：字幕区里不动的文字换回真实帧（不然补出来的帧里字幕被拖变形，看起来在闪）
                        for g in textGuards { g.compose(interp: up, real: real) }
                        emit(up, interpolated: true, arrivalMs: t)
                    }
                } else {
                    stats.with { $0.failures += 1; $0.lastError = err.map { "\($0)" } ?? "未知" }
                }
                emit(real, interpolated: false, arrivalMs: t)
            }
        }
        if copy == nil { copy = interp.copyDisp(pb) }
        // 先更新字幕保护（< 1ms），再把真实帧交给补帧回调：回调里合成时用的是这一帧算出的字幕范围
        if interpEnabled, let c = copy { for g in textGuards { g.observe(c) } }
        realBox.set(copy)
        guard let copy else {
            stats.with { $0.copyFails += 1; $0.lastError = "拷贝采集缓冲失败" }
            return
        }
        let tCopy2 = nowMs()
        stats.with { $0.copyMsSum += tCopy1 - tCopy0; $0.obsMsSum += tCopy2 - tCopy1; $0.prepN += 1 }
        let frame = UniqueFrame(buffer: copy, proc: proc, pts: pts, arrivalMs: t)
        prev = frame
        if count > 0 {
            // 已经交给补帧了，回调里会显示中间帧和真实帧
        } else if setInFlight(0) > 0 {
            // 前一个中间帧还在算：排在它后面，保证显示顺序
            interp.enqueue { [self] in
                emit(frame.buffer, interpolated: false, arrivalMs: frame.arrivalMs)
            }
        } else {
            // 没有在算的补帧：直接进显示队列（补帧会话启动中 workQ 被占住，不能排在它后面）
            emit(frame.buffer, interpolated: false, arrivalMs: frame.arrivalMs)
        }
    }

    /// 补帧开着、而且画面最近还在动（0.1 秒内有新画面）——这时没帧可显示才算"空拍"。画面静止不算
    var interpActive: Bool { interpEnabled && interp.ready }

    /// 字幕保护（每条管线一个，换输入时自然清零）
    let textGuards = SubtitleGuard.gtaSet()

    /// 清晰放大（Lanczos 缩放到屏幕大小 + 锐化）；开着时代替旧的画面增强
    var scaler: SharpScaler?

    /// 画面增强（放大 + 锐化）；nil = 不处理
    var enhancer: Enhancer?

    /// 送去显示：先过画面增强，再进显示队列。在单独的串行队列上做，不占采集线程
    /// （采集线程一忙，系统就会把新来的帧直接丢掉）。所有帧按调用顺序进这个队列，显示顺序不变。
    private let outputQ = DispatchQueue(label: "pipeline.output", qos: .userInteractive)
    private func emit(_ buffer: CVPixelBuffer, interpolated: Bool, arrivalMs: Double) {
        outputQ.async { [self] in emitNow(buffer, interpolated: interpolated, arrivalMs: arrivalMs) }
    }
    /// 补出来的帧直接上屏的出口（显示视图设置）。返回 false 表示没上屏，照常进队列
    var directInterp: ((CVPixelBuffer, Double) -> Bool)?

    private func emitNow(_ buffer: CVPixelBuffer, interpolated: Bool, arrivalMs: Double) {
        var out = buffer
        defer { _ = out }
        // 清晰放大：缩放到屏幕大小 + 锐化，所有帧一样处理（代替下面旧的锐化）
        if let s = scaler, s.enabled {
            out = s.process(buffer)
            stats.with { $0.enhanceMsSum += s.lastMs; $0.enhanceN += 1; $0.enhanceMsMax = max($0.enhanceMsMax, s.lastMs) }
            if interpolated, queue.count == 0, let d = directInterp, d(out, arrivalMs) { return }
            queue.push(.init(buffer: out, interpolated: interpolated, arrivalMs: arrivalMs))
            return
        }
        // 只锐化补出来的帧（平衡档）：720p 补出来的帧偏软，单独锐化追上真实帧；真实帧不动
        let interpSharp: Float? = interpEnabled && interpSharpness > 0 && (interpolated || interpSharpAll) ? max(interpSharpness, enhancer?.sharpness ?? 0) : nil
        if let e = enhancer, !e.enabled, let sh = interpSharp {
            // 只锐化补出来的帧：直接在 420v 的亮度上做，输出还是 420v（和真实帧同一种格式，显示层不用来回切换）
            out = e.sharpenLuma(buffer, sharpness: sh)
            let ms = e.lastMs
            stats.with { $0.enhanceMsSum += ms; $0.enhanceN += 1; $0.enhanceMsMax = max($0.enhanceMsMax, ms) }
        } else if let e = enhancer, e.enabled {
            out = e.process(buffer, sharpnessOverride: interpSharp)
            let ms = e.lastMs
            stats.with { $0.enhanceMsSum += ms; $0.enhanceN += 1; $0.enhanceMsMax = max($0.enhanceMsMax, ms) }
        }
        // 补出来的帧：前面的帧都已经显示了（队列是空的）就直接上屏，省掉"等下一次刷新回调"的那一段
        if interpolated, queue.count == 0, let d = directInterp, d(out, arrivalMs) { return }
        queue.push(.init(buffer: out, interpolated: interpolated, arrivalMs: arrivalMs))
    }
    var countsEmpty: Bool { interpActive && nowMs() - lastUniqueMs < 100 }
    private(set) var lastUniqueMs = 0.0

    private let flightLock = NSLock()
    private var inFlight = 0
    @discardableResult private func setInFlight(_ d: Int) -> Int {
        flightLock.lock(); defer { flightLock.unlock() }
        inFlight += d
        return inFlight
    }
}


/// 补帧回调里要用、但补帧开始时还没拷好的真实帧（原分辨率）
final class BufferBox: @unchecked Sendable {
    private let sem = DispatchSemaphore(value: 0)
    private var value: CVPixelBuffer?
    func set(_ v: CVPixelBuffer?) { value = v; sem.signal() }
    func wait() -> CVPixelBuffer? { sem.wait(); sem.signal(); return value }
}
