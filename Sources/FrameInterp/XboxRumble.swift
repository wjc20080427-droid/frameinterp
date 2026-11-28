#if FI_XNATIVE
import CoreHaptics
import Foundation
import GameController

// MARK: - 原生 Xbox 串流 · 手柄震动（2026-11-28）
// 主机在 input 通道发类型 128 的包：震动类型、手柄号、左马达（强）、右马达（弱）、左扳机、右扳机（各 0～100），
// 持续毫秒（u16）、延迟毫秒（u16）、重复次数。格式参考 MIT 的 xbox-xcloud-player。
// 做法：每个马达一个 CoreHaptics 引擎 + 一个长的连续震动播放器，收到包只改强度（不重建，延迟低）；
// 手柄不支持扳机震动（蓝牙连 Mac 多半不支持）时，扳机震动并到左右握把上；连左右握把都分不开时，取最大值震整个手柄。
// FI_XNORUMBLE=1 关掉震动。

struct RumbleCommand: Equatable {
    var pad: Int
    var strong: Float, weak: Float, lt: Float, rt: Float   // 0～1
    var durationMs: Int, delayMs: Int, repeatCount: Int

    /// 解析 input 通道服务器包（type 是包头的 2 字节类型，data 是整个包）
    static func parse(_ data: Data) -> RumbleCommand? {
        let b = [UInt8](data)
        guard b.count >= 2 else { return nil }
        let type = UInt16(b[0]) | UInt16(b[1]) << 8
        guard type & 128 != 0 else { return nil }
        var o = 2
        if type & 16 != 0 { o += 8 }          // 前面有服务器视频尺寸
        guard b.count >= o + 11 else { return nil }
        func pct(_ v: UInt8) -> Float { min(Float(v), 100) / 100 }
        func u16(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
        return RumbleCommand(pad: Int(min(b[o + 1], 3)), strong: pct(b[o + 2]), weak: pct(b[o + 3]),
                             lt: pct(b[o + 4]), rt: pct(b[o + 5]),
                             durationMs: u16(o + 6), delayMs: u16(o + 8), repeatCount: Int(b[o + 10]))
    }
}

@MainActor
final class XboxRumble {
    static let enabled = ProcessInfo.processInfo.environment["FI_XNORUMBLE"] != "1"

    private final class Motor {
        let engine: CHHapticEngine
        var player: CHHapticPatternPlayer?
        var startedAt = 0.0
        var level: Float = 0
        init(engine: CHHapticEngine) { self.engine = engine }
    }

    private weak var controller: GCController?
    private var motors: [GCHapticsLocality: Motor] = [:]
    private var split = false        // 左右握把能分开震
    private var triggers = false     // 支持扳机震动
    private var generation = 0
    private(set) var received = 0
    private var statCount = 0, statPeak: Float = 0
    /// 统计（取完清零）：这段时间收到几条震动命令、最强一条的强度（0～1）
    func takeStats() -> (Int, Float) { defer { statCount = 0; statPeak = 0 }; return (statCount, statPeak) }
    private var logged = false

    /// 主线程：收到一条震动命令
    func handle(_ c: RumbleCommand) {
        guard Self.enabled else { return }
        received += 1
        statCount += 1
        statPeak = max(statPeak, c.strong, c.weak, c.lt, c.rt)
        if !logged {
            logged = true
            Log.write("原生串流：收到第一个震动包（强 \(Int(c.strong * 100))% 弱 \(Int(c.weak * 100))% LT \(Int(c.lt * 100))% RT \(Int(c.rt * 100))%，\(c.durationMs)ms）")
        }
        generation += 1
        let gen = generation
        let go = { [weak self] in
            guard let self, self.generation == gen else { return }
            self.apply(c)
            // 到时间自动停（新命令会让旧的停止计时作废）；持续 0 当作"直到下条命令"，最长 2 秒兜底
            let dur = c.durationMs > 0 ? Double(c.durationMs) / 1000 : 2
            if c.strong + c.weak + c.lt + c.rt > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + dur) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.generation == gen else { return }
                        self.apply(RumbleCommand(pad: c.pad, strong: 0, weak: 0, lt: 0, rt: 0, durationMs: 0, delayMs: 0, repeatCount: 0))
                    }
                }
            }
        }
        if c.delayMs > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(c.delayMs) / 1000) { MainActor.assumeIsolated { go() } }
        } else { go() }
    }

    func stop() {
        generation += 1
        for m in motors.values { try? m.player?.stop(atTime: CHHapticTimeImmediate); m.engine.stop() }
        motors = [:]; controller = nil
    }

    // MARK: 私有

    private func apply(_ c: RumbleCommand) {
        guard prepare() else { return }
        var left = c.strong, right = c.weak
        if !triggers { left = max(left, c.lt * 0.8); right = max(right, c.rt * 0.8) }
        if split {
            set(.leftHandle, left); set(.rightHandle, right)
        } else {
            set(.handles, max(left, right))
        }
        if triggers { set(.leftTrigger, c.lt); set(.rightTrigger, c.rt) }
    }

    /// 找手柄、建引擎（换了手柄就重建）
    private func prepare() -> Bool {
        guard let gc = GCController.controllers().first(where: { $0.extendedGamepad != nil }) else { return false }
        if gc === controller, !motors.isEmpty { return true }
        stop()
        guard let h = gc.haptics else {
            Log.write("原生串流：手柄「\(gc.vendorName ?? "?")」不支持震动")
            controller = gc
            return false
        }
        let loc = h.supportedLocalities
        split = loc.contains(.leftHandle) && loc.contains(.rightHandle)
        triggers = loc.contains(.leftTrigger) && loc.contains(.rightTrigger)
        var wanted: [GCHapticsLocality] = split ? [.leftHandle, .rightHandle] : [loc.contains(.handles) ? .handles : .default]
        if triggers { wanted += [.leftTrigger, .rightTrigger] }
        for l in wanted {
            guard let e = h.createEngine(withLocality: l) else { continue }
            e.playsHapticsOnly = true
            e.isAutoShutdownEnabled = false
            let m = Motor(engine: e)
            e.resetHandler = { [weak m] in try? m?.engine.start(); m?.player = nil }
            e.stoppedHandler = { [weak m] _ in m?.player = nil }
            do { try e.start() } catch { continue }
            motors[l] = m
        }
        controller = gc
        // 没有分左右时只有 .handles / .default 一个引擎，apply 里用 .handles 找；统一一下键
        if !split, let only = motors.first, only.key != .handles { motors = [.handles: only.value] }
        Log.write("原生串流：震动用手柄「\(gc.vendorName ?? "?")」，支持 \(loc.map(\.rawValue).sorted().joined(separator: "、"))；"
                  + "左右分开 \(split ? "是" : "否")，扳机 \(triggers ? "是" : "否（并到握把）")，引擎 \(motors.count) 个")
        return !motors.isEmpty
    }

    private func set(_ l: GCHapticsLocality, _ level: Float) {
        guard let m = motors[l] else { return }
        let v = max(0, min(level, 1))
        if v < 0.01 {
            if m.level > 0 { try? m.player?.stop(atTime: CHHapticTimeImmediate); m.player = nil }
            m.level = 0
            return
        }
        let now = CACurrentMediaTime()
        // 长播放器最长 30 秒（CoreHaptics 单个事件上限），快到了就重建
        if m.player == nil || now - m.startedAt > 28 {
            try? m.player?.stop(atTime: CHHapticTimeImmediate)
            let ev = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: l == .rightHandle || l == .rightTrigger || l == .leftTrigger ? 0.6 : 0.3),
            ], relativeTime: 0, duration: 30)
            guard let pat = try? CHHapticPattern(events: [ev], parameters: []),
                  let p = try? m.engine.makePlayer(with: pat) else { return }
            try? p.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: v, relativeTime: 0)], atTime: CHHapticTimeImmediate)
            do { try p.start(atTime: CHHapticTimeImmediate) } catch { return }
            m.player = p; m.startedAt = now
        } else if abs(v - m.level) > 0.005 {
            try? m.player?.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: v, relativeTime: 0)], atTime: CHHapticTimeImmediate)
        }
        m.level = v
    }
}
#endif

#if FI_XNATIVE
/// FI_XRUMBLETEST=1：解析几种假的震动包；接着手柄有的话按 强→弱→扳机→停 各震 0.4 秒
@MainActor
enum XboxRumbleTest {
    static var keep: XboxRumble?
    static func run() {
        func pkt(_ type: UInt16, meta: Bool, _ body: [UInt8]) -> Data {
            var b: [UInt8] = [UInt8(type & 0xff), UInt8(type >> 8)]
            if meta { b += [0x38, 0x04, 0, 0, 0x80, 0x07, 0, 0] }   // 1080 × 1920
            return Data(b + body)
        }
        let cases: [(String, Data, RumbleCommand?)] = [
            ("只有震动", pkt(128, meta: false, [0, 0, 80, 20, 0, 0, 0xF4, 0x01, 0, 0, 0]),
             RumbleCommand(pad: 0, strong: 0.8, weak: 0.2, lt: 0, rt: 0, durationMs: 500, delayMs: 0, repeatCount: 0)),
            ("尺寸 + 震动", pkt(144, meta: true, [0, 1, 0, 0, 50, 100, 0x64, 0, 0x0A, 0, 2]),
             RumbleCommand(pad: 1, strong: 0, weak: 0, lt: 0.5, rt: 1, durationMs: 100, delayMs: 10, repeatCount: 2)),
            ("只有尺寸", pkt(16, meta: true, []), nil),
            ("太短", pkt(128, meta: false, [0, 0, 80]), nil),
        ]
        var ok = 0
        for (name, d, want) in cases {
            let got = RumbleCommand.parse(d)
            if got == want { ok += 1 } else { Log.write("震动自测：\(name) 不对：\(String(describing: got))") }
        }
        Log.write("震动自测：解析 \(ok)/\(cases.count) 通过")
        let r = XboxRumble(); keep = r
        let steps: [(Double, RumbleCommand)] = [
            (0.0, RumbleCommand(pad: 0, strong: 1, weak: 0, lt: 0, rt: 0, durationMs: 400, delayMs: 0, repeatCount: 0)),
            (0.6, RumbleCommand(pad: 0, strong: 0, weak: 1, lt: 0, rt: 0, durationMs: 400, delayMs: 0, repeatCount: 0)),
            (1.2, RumbleCommand(pad: 0, strong: 0, weak: 0, lt: 1, rt: 1, durationMs: 400, delayMs: 0, repeatCount: 0)),
        ]
        // 等手柄连上：启动后系统要一会儿才把已连接的手柄报上来，最多等 15 秒（期间按一下手柄也行）
        GCController.shouldMonitorBackgroundEvents = true
        GCController.startWirelessControllerDiscovery {}
        func waitPad(_ left: Int) {
            if GCController.controllers().contains(where: { $0.extendedGamepad != nil }) { play(); return }
            if left == 15 { Log.write("震动自测：等手柄连上（最多 15 秒，可以按一下手柄）…") }
            guard left > 0 else { Log.write("震动自测：15 秒内没发现手柄，跳过实际震动"); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { waitPad(left - 1) } }
        }
        func play() {
            GCController.stopWirelessControllerDiscovery()
            do {
                for (t, c) in steps {
                    DispatchQueue.main.asyncAfter(deadline: .now() + t) { MainActor.assumeIsolated { r.handle(c) } }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                    MainActor.assumeIsolated { Log.write("震动自测：发了 \(r.received) 条震动命令（强马达 → 弱马达 → 扳机，各 0.4 秒）"); r.stop() }
                }
            }
        }
        waitPad(15)
    }
}
#endif
