#if FI_XNATIVE
import AppKit
import CoreMedia
import CoreVideo
import GameController
import VideoToolbox
@preconcurrency import WebRTC

// MARK: - 原生 Xbox 串流 · 第 2 步：连自己的主机（开发中，只在测试版）
// 协议参考 MIT 开源的 xbox-xcloud-player（unknownskl）：只参考接口和数据格式，代码自己写。
//   1. POST {base}/v5/sessions/home/play（serverId = 主机）→ sessionPath
//   2. 轮询 {sessionPath}/state：Provisioning → Provisioned（ReadyToConnect 时先 POST /connect 送转移令牌）
//   3. WebRTC：音频 sendrecv、视频 recvonly（H.264 优先），数据通道 input(1.0) / control(controlV1) / message(messageV1) / chat(chatV1)
//      offer → POST /sdp → 轮询 GET /sdp 拿 answer（exchangeResponse 里的 JSON）；本地 ICE → POST /ice → GET /ice 拿对方的
//   4. message 通道握手（Handshake → HandshakeAck）后：control 送授权和"手柄 0 接上了"，input 送客户端信息，message 送界面 / 分辨率配置
//   5. 每 30 秒 POST /keepalive
// 解码后的画面（VideoToolbox 解出来的 CVPixelBuffer）直接交给补帧管线，不抓屏、不经过网页。声音由 WebRTC 自己播放。
// 手柄：每 16ms 读 GameController，按 Xbox 的二进制格式经 input 通道发出（和每个视频帧的时间戳一起）。

/// 原生串流的画质设置（2026-11-27 参考 XboxPad 的做法：报设备类型选分辨率 + 连接请求里要高码率）
enum XboxQuality {
    /// 想要的分辨率：720 / 1080 / 1440（UserDefaults xboxRes.v1）
    static var height: Int {
        get { let h = UserDefaults.standard.integer(forKey: "xboxRes.v1"); return [720, 1080, 1440].contains(h) ? h : 1080 }
        set { UserDefaults.standard.set(newValue, forKey: "xboxRes.v1") }
    }
    static var width: Int { height == 1440 ? 2560 : height == 720 ? 1280 : 1920 }
    /// 服务器按设备类型给分辨率：android 720p、windows 1080p、tizen（三星电视）1440p
    static var osName: String { height == 1440 ? "tizen" : height == 720 ? "android" : "windows" }
    /// 码率要求（kbps）：最低 / 起步 / 最高。FI_XBITRATE=0 关掉（对照）
    static let minKbps = 10_000, startKbps = 20_000, maxKbps = 40_000
    static var boost: Bool { ProcessInfo.processInfo.environment["FI_XBITRATE"] != "0" }
    /// FI_XNOTWCC=1：offer 里去掉 transport-cc（让 WebRTC 改发 REMB，试试能不能把码率推上去）
    static var noTWCC: Bool { ProcessInfo.processInfo.environment["FI_XNOTWCC"] == "1" }

    /// 改本地 offer：视频段加 b=AS 和 x-google 码率提示；可选去掉 transport-cc；音频立体声
    static func munge(_ sdp: String) -> String {
        var lines = sdp.components(separatedBy: "\r\n")
        if lines.last == "" { lines.removeLast() }
        var out: [String] = []
        var inVideo = false
        var h264: Set<String> = []
        // 先找视频段里 H.264 的 payload
        var scanVideo = false
        for l in lines {
            if l.hasPrefix("m=") { scanVideo = l.hasPrefix("m=video") }
            if scanVideo, l.hasPrefix("a=rtpmap:"), l.uppercased().contains(" H264/") {
                h264.insert(String(l.dropFirst("a=rtpmap:".count).split(separator: " ")[0]))
            }
        }
        for l in lines {
            if l.hasPrefix("m=") { inVideo = l.hasPrefix("m=video") }
            var line = l
            if l.contains("useinbandfec=1") && !l.contains("stereo=1") { line = l.replacingOccurrences(of: "useinbandfec=1", with: "useinbandfec=1;stereo=1") }
            if inVideo && noTWCC && (l.contains("transport-cc") || l.contains("transport-wide-cc")) { continue }
            if inVideo && boost, l.hasPrefix("a=fmtp:"), let pt = l.dropFirst("a=fmtp:".count).split(separator: " ").first, h264.contains(String(pt)) {
                line += ";x-google-min-bitrate=\(minKbps);x-google-start-bitrate=\(startKbps);x-google-max-bitrate=\(maxKbps)"
            }
            if inVideo && boost && l.hasPrefix("b=AS:") { continue }
            out.append(line)
            if inVideo && boost && l.hasPrefix("c=IN") { out.append("b=AS:\(maxKbps)") }
        }
        return out.joined(separator: "\r\n") + "\r\n"
    }
}

/// 一次串流会话
@MainActor
final class XboxStreamSession: NSObject {
    let console: XboxConsole
    /// 画面（在 WebRTC 的解码线程上回调）：已转成补帧要的尺寸和格式
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)? {
        get { sink.onFrame }
        set { sink.onFrame = newValue }
    }
    var onStatus: ((String) -> Void)?
    var onEnded: ((String) -> Void)?
    /// 主机发来的画面分辨率（变了就回调）
    var onSize: ((Int, Int) -> Void)? {
        get { sink.onSize }
        set { sink.onSize = newValue }
    }

    private let base: String, gsToken: String
    private var sessionPath = ""
    private var pc: RTCPeerConnection?
    /// 视频轨道的包装对象要一直留着：WebRTC 的 RTCVideoTrack 被释放时会把挂在上面的接收器全摘掉
    /// （2026-11-27 实测：解码 60 帧/秒，接收器一帧都没收到，就是因为只临时取了轨道、挂完就释放了）
    private var videoTrack: RTCVideoTrack?
    private var channels: [String: RTCDataChannel] = [:]
    private var timers: [Timer] = []
    private let sink: FrameSink
    private let input = XboxInput()
    private var stopped = false
    private var localCandidates: [RTCIceCandidate] = []
    private var gathered = false
    private var connectedAt: Date?

    init?(console: XboxConsole, width: Int, height: Int, pixelFormat: OSType) {
        guard let gs = XboxAccount.shared.gsToken, let b = XboxAccount.shared.baseURI else { return nil }
        self.console = console
        gsToken = gs; base = b
        sink = FrameSink(width: width, height: height, pixelFormat: pixelFormat)
        super.init()
        sink.onMetadata = { [input] key, ms in input.queueMetadata(key: key, arrivalMs: ms) }
    }

    // MARK: 开始 / 结束
    func start() async throws {
        status("正在请求主机串流…")
        let r = try await http("POST", "/v5/sessions/home/play", body: [
            "clientSessionId": "", "titleId": "", "systemUpdateGroup": "",
            "settings": [
                "nanoVersion": "V3;WebrtcTransport.dll", "enableOptionalDataCollection": false, "enableTextToSpeech": false,
                "highContrast": 0, "locale": "zh-CN", "useIceConnection": false,
                "timezoneOffsetMinutes": TimeZone.current.secondsFromGMT() / 60, "sdkType": "web", "osName": XboxQuality.osName,
            ],
            "serverId": console.id, "fallbackRegionNames": [String](),
        ])
        guard let path = r["sessionPath"] as? String else { throw XErr("主机没有接受串流请求：\(r["code"] as? String ?? r["message"] as? String ?? "未知原因")") }
        sessionPath = "/" + path
        Log.write("原生串流：会话已建（\(console.name)）")

        // 等主机准备好
        status("等主机准备好…")
        let deadline = Date().addingTimeInterval(90)
        var sentConnect = false
        var lastState = ""
        while Date() < deadline {
            try Task.checkCancellation()
            if stopped { return }
            let st = try await http("GET", sessionPath + "/state")
            let state = st["state"] as? String ?? "?"
            if state != lastState {
                lastState = state
                Log.write("原生串流：会话状态 \(state)" + ((st["errorDetails"] as? [String: Any]).map { " \($0)" } ?? ""))
            }
            switch state {
            case "Provisioned":
                Log.write("原生串流：主机已就绪")
                try await connectWebRTC()
                return
            case "ReadyToConnect":
                if !sentConnect {
                    sentConnect = true
                    status("正在验证…")
                    let lpt = try await XboxAccount.shared.transferToken()
                    _ = try await http("POST", sessionPath + "/connect", body: ["userToken": lpt])
                    Log.write("原生串流：已送转移令牌")
                }
            case "Failed":
                let d = st["errorDetails"] as? [String: Any]
                throw XErr("主机拒绝串流：\(d?["code"] as? String ?? "") \(d?["message"] as? String ?? "")")
            default:
                break   // Provisioning / New
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw XErr("等了 90 秒主机还没准备好（主机要开机或待机可唤醒）")
    }

    func stop(_ why: String = "已断开") {
        guard !stopped else { return }
        stopped = true
        timers.forEach { $0.invalidate() }; timers = []
        input.stop()
        videoTrack?.remove(sink); videoTrack = nil
        pc?.close(); pc = nil
        channels = [:]
        let path = sessionPath, b = base, gs = gsToken
        if !path.isEmpty {
            // 告诉服务器结束会话（不等结果）
            var req = URLRequest(url: URL(string: b + path)!)
            req.httpMethod = "DELETE"
            req.setValue("Bearer \(gs)", forHTTPHeaderField: "Authorization")
            URLSession.shared.dataTask(with: req).resume()
        }
        Log.write("原生串流：结束（\(why)）")
        onEnded?(why)
    }

    /// 状态提示（画面上的字）。已经连上（握手完成）后，连接过程里的提示不再显示——局域网里握手可能比发完地址信息还早，
    /// 之前"正在连接主机…"会盖在画面上一直不消失
    private func status(_ s: String) {
        Log.write("原生串流：" + s)
        if connectedAt != nil && s != "已连接" { return }
        onStatus?(s)
    }

    // MARK: WebRTC
    private func connectWebRTC() async throws {
        status("正在建立连接…")
        let factory = XboxRTC.factory
        let cfg = RTCConfiguration()
        cfg.sdpSemantics = .unifiedPlan
        cfg.iceServers = []
        // 2026-11-28 参考 XboxPad：不用链路本地网络（AWDL 的 awdl0 / llw0）建连接——碰了会把 AWDL 的切频道扫描唤醒，
        // Wi-Fi 每 ~0.5 秒卡 ~100ms；音视频包打 DSCP 优先级标记，Wi-Fi 按互动视频优先发。FI_XNOLL=1 关掉（对照）
        let noLL = ProcessInfo.processInfo.environment["FI_XNOLL"] != "1"
        cfg.disableLinkLocalNetworks = noLL
        cfg.enableDscp = noLL
        Log.write("原生串流：\(noLL ? "不用 AWDL 等链路本地网卡，包打 DSCP 优先级" : "链路本地网卡照用（对照）")")
        guard let pc = factory.peerConnection(with: cfg, constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self) else {
            throw XErr("建 WebRTC 连接失败")
        }
        self.pc = pc
        let sr = RTCRtpTransceiverInit(); sr.direction = .sendRecv
        pc.addTransceiver(of: .audio, init: sr)
        let ro = RTCRtpTransceiverInit(); ro.direction = .recvOnly
        if let vt = pc.addTransceiver(of: .video, init: ro) {
            // H.264：Main（4d）> Baseline（42e0）> 其他 42 开头；再加纠错和 VP9 / VP8 兜底
            let caps = factory.rtpReceiverCapabilities(forKind: kRTCMediaStreamTrackKindVideo).codecs
            func pid(_ c: RTCRtpCodecCapability) -> String { c.parameters["profile-level-id"]?.lowercased() ?? "" }
            let h264 = caps.filter { $0.name.uppercased() == "H264" }
            let ordered = h264.filter { pid($0).hasPrefix("4d") } + h264.filter { pid($0).hasPrefix("42e") } + h264.filter { pid($0).hasPrefix("420") }
                + caps.filter { ["ulpfec", "flexfec-03", "VP9", "VP8", "rtx", "red"].contains($0.name) }
            vt.setCodecPreferences(ordered)   // 新写法 setCodecPreferences:error: 在 Swift 里和旧的重名，用旧的
            _ = vt   // 接收器在 setRemoteDescription 之后统一挂（attachVideo）
        }
        for (label, proto) in [("input", "1.0"), ("control", "controlV1"), ("message", "messageV1"), ("chat", "chatV1")] {
            let c = RTCDataChannelConfiguration()
            c.isOrdered = true
            c.protocol = proto
            if let ch = pc.dataChannel(forLabel: label, configuration: c) {
                ch.delegate = self
                channels[label] = ch
            }
        }
        input.channel = channels["input"]

        // offer → 服务器 → answer
        let offer = try await withCheckedThrowingContinuation { (c: CheckedContinuation<RTCSessionDescription, Error>) in
            pc.offer(for: RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveAudio": "true", "OfferToReceiveVideo": "true"], optionalConstraints: nil)) { sdp, err in
                if let sdp { c.resume(returning: sdp) } else { c.resume(throwing: err ?? XErr("生成 offer 失败")) }
            }
        }
        let local = RTCSessionDescription(type: .offer, sdp: XboxQuality.munge(offer.sdp))
        Log.write("原生串流：请求 \(XboxQuality.height)p（\(XboxQuality.osName)）" + (XboxQuality.boost ? "，码率 \(XboxQuality.minKbps / 1000)/\(XboxQuality.startKbps / 1000)/\(XboxQuality.maxKbps / 1000) Mbps" : "，不加码率要求")
                  + (XboxQuality.noTWCC ? "，去掉 transport-cc" : ""))
        try await pc.setLocalDescription(local)
        _ = try await http("POST", sessionPath + "/sdp", body: [
            "messageType": "offer", "sdp": local.sdp, "requestId": "1",
            "configuration": [
                "chatConfiguration": ["bytesPerSample": 2, "expectedClipDurationMs": 20, "format": ["codec": "opus", "container": "webm"],
                                      "numChannels": 1, "sampleFrequencyHz": 24000],
                "chat": ["minVersion": 1, "maxVersion": 1], "control": ["minVersion": 1, "maxVersion": 3],
                "input": ["minVersion": 1, "maxVersion": 9], "message": ["minVersion": 1, "maxVersion": 1],
                "reliableinput": ["minVersion": 9, "maxVersion": 9], "unreliableinput": ["minVersion": 9, "maxVersion": 9],
            ],
        ])
        let answer = try await pollExchange(sessionPath + "/sdp", interval: 0.5)
        guard let ans = (answer as? [String: Any])?["sdp"] as? String else { throw XErr("主机没给 answer") }
        try await pc.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: ans))
        logCodec(ans)
        attachVideo(pc)

        // ICE：等本地候选收集完（最多 3 秒），一起发过去，再拿主机的
        let t0 = Date()
        while !gathered && Date().timeIntervalSince(t0) < 3 { try await Task.sleep(nanoseconds: 100_000_000) }
        let mine = localCandidates.map { c -> String in
            let d: [String: Any] = ["candidate": c.sdp, "sdpMid": c.sdpMid ?? "0", "sdpMLineIndex": Int(c.sdpMLineIndex), "usernameFragment": NSNull()]
            return String(data: try! JSONSerialization.data(withJSONObject: d), encoding: .utf8)!
        }
        Log.write("原生串流：本机 \(mine.count) 个候选地址：" + localCandidates.map { c in
            let f = c.sdp.split(separator: " "); return f.count > 7 ? "\(f[4])(\(f[7]))" : "?" }.joined(separator: "、"))
        _ = try await http("POST", sessionPath + "/ice", body: ["candidates": mine])
        let remote = try await pollExchange(sessionPath + "/ice", interval: 1)
        var n = 0
        for item in remote as? [[String: Any]] ?? [] {
            guard var cand = item["candidate"] as? String, cand != "a=end-of-candidates" else { continue }
            if cand.hasPrefix("a=") { cand.removeFirst(2) }
            let mid = item["sdpMid"] as? String
            let idx = Int32(item["sdpMLineIndex"] as? Int ?? 0)
            try? await pc.add(RTCIceCandidate(sdp: cand, sdpMLineIndex: idx, sdpMid: mid))
            n += 1
        }
        Log.write("原生串流：主机 \(n) 个候选地址")
        status("正在连接主机…")

        // 诊断：每 2 秒记一次视频 / 音频接收统计（前 2 分钟，之后每 10 秒）
        var statTicks = 0
        var lastBytes = 0.0, lastQP = 0.0, lastFrames = 0.0
        timers.append(Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.stopped, let pc = self.pc else { return }
                statTicks += 1
                if statTicks > 60 && statTicks % 5 != 0 { return }
                pc.statistics { report in
                    var lines: [String] = []
                    var bwe = ""
                    // 选中的连接路径（双方地址类型、IP、协议）：只在前几次记
                    if statTicks <= 3 {
                        let all = report.statistics
                        for st in all.values where st.type == "candidate-pair" && (st.values["nominated"] as? NSNumber)?.boolValue == true {
                            func desc(_ id: Any?) -> String {
                                guard let id = id as? String, let c = all[id]?.values else { return "?" }
                                func f(_ k: String) -> String { c[k].map { "\($0)" } ?? "?" }
                                return "\(f("candidateType"))/\(f("protocol")) \(c["address"] != nil ? f("address") : f("ip")):\(f("port"))" + (c["networkType"] != nil ? " " + f("networkType") : "")
                            }
                            let state = st.values["state"].map { "\($0)" } ?? "?"
                            DispatchQueue.main.async { Log.write("原生串流：选中路径 本机 \(desc(st.values["localCandidateId"])) → 主机 \(desc(st.values["remoteCandidateId"]))（\(state)）") }
                        }
                    }
                    for st in report.statistics.values where st.type == "candidate-pair" {
                        if let b = st.values["availableIncomingBitrate"] as? NSNumber { bwe = " 估计可用带宽 \(b.intValue / 1000) kbps" }
                        if (st.values["nominated"] as? NSNumber)?.boolValue == true, let rtt = st.values["currentRoundTripTime"] as? NSNumber {
                            bwe += " 往返 \(Int(rtt.doubleValue * 1000))ms"
                        }
                    }
                    for st in report.statistics.values where st.type == "inbound-rtp" {
                        let v = st.values
                        func n(_ k: String) -> String { (v[k] as? NSNumber).map { "\($0.intValue)" } ?? "-" }
                        let kind = v["kind"] as? String ?? "?"
                        if kind == "video" {
                            let bytes = (v["bytesReceived"] as? NSNumber)?.doubleValue ?? 0
                            let qp = (v["qpSum"] as? NSNumber)?.doubleValue ?? 0, fd = (v["framesDecoded"] as? NSNumber)?.doubleValue ?? 0
                            let kbps = Int((bytes - lastBytes) * 8 / 1000 / 2)
                            let avgQP = fd > lastFrames ? (qp - lastQP) / (fd - lastFrames) : 0
                            lastBytes = bytes; lastQP = qp; lastFrames = fd
                            lines.append("码率 \(kbps) kbps 平均QP \(Int(avgQP))")
                            func d(_ k: String) -> Double { (v[k] as? NSNumber)?.doubleValue ?? 0 }
                            let jb = d("jitterBufferEmittedCount") > 0 ? d("jitterBufferDelay") / d("jitterBufferEmittedCount") * 1000 : 0
                            let dec = d("framesDecoded") > 0 ? d("totalDecodeTime") / d("framesDecoded") * 1000 : 0
                            lines.append(String(format: "网络抖动 %.0fms WebRTC缓冲 %.0fms 解码 %.1fms 冻结 %d 次", d("jitter") * 1000, jb, dec, Int(d("freezeCount"))))
                            lines.append("视频 包 \(n("packetsReceived")) 丢 \(n("packetsLost")) 收帧 \(n("framesReceived")) 解码 \(n("framesDecoded")) 关键帧 \(n("keyFramesDecoded")) 丢帧 \(n("framesDropped")) \(n("frameWidth"))×\(n("frameHeight")) \(n("framesPerSecond"))帧/秒 解码器 \(v["decoderImplementation"] as? String ?? "-") PLI \(n("pliCount")) NACK \(n("nackCount"))")
                        } else {
                            lines.append("音频 包 \(n("packetsReceived")) 丢 \(n("packetsLost"))")
                        }
                    }
                    lines.append(bwe)
                    let ps = self.sink.takePacingStats()
                    lines.append(ps.on ? "平滑缓冲 余量 \(String(format: "%.1f", ps.margin))ms 来晚 \(ps.late) \(ps.detail)" : "平滑缓冲关")
                    let msg = (lines.isEmpty ? "还没有收到媒体流" : lines.joined(separator: " | ")) + " | 接收器收到 \(self.sink.calls) 帧"
                    DispatchQueue.main.async { Log.write("原生串流统计：" + msg) }
                }
            }
        })

        // 保活
        timers.append(Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                Task { _ = try? await self.http("POST", self.sessionPath + "/keepalive", body: nil) }
            }
        })
    }

    /// 从所有收发通道里找视频那一路，把画面接收器挂上去（重复挂没关系）
    private func attachVideo(_ pc: RTCPeerConnection) {
        for t in pc.transceivers where t.mediaType == .video {
            let tr = t.receiver.track
            if let v = tr as? RTCVideoTrack {
                v.isEnabled = true
                if let old = videoTrack { old.remove(sink) }
                v.add(sink)
                videoTrack = v
                Log.write("原生串流：画面接收器挂到视频轨道（\(v.trackId)，mid \(t.mid)）；接收器有 renderFrame: \(sink.responds(to: NSSelectorFromString("renderFrame:")))、setSize: \(sink.responds(to: NSSelectorFromString("setSize:")))")
            } else {
                Log.write("原生串流：视频通道的轨道是 \(tr.map { "\(type(of: $0))" } ?? "空")，挂不上")
            }
        }
    }

    /// 轮询 GET：没准备好时返回 204 / 空；准备好时 exchangeResponse 是一段 JSON 字符串
    private func pollExchange(_ path: String, interval: Double) async throws -> Any {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            try Task.checkCancellation()
            let r = try await http("GET", path, allowEmpty: true)
            if let s = r["exchangeResponse"] as? String, let d = s.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) {
                return obj
            }
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        throw XErr("等主机回应超时（\(path.split(separator: "/").last ?? "")）")
    }

    private func logCodec(_ sdp: String) {
        // answer 里视频选了哪个编码
        let lines = sdp.split(separator: "\r\n")
        guard let m = lines.first(where: { $0.hasPrefix("m=video") }), let pt = m.split(separator: " ").dropFirst(3).first,
              let map = lines.first(where: { $0.hasPrefix("a=rtpmap:\(pt) ") }) else { return }
        let fmtp = lines.first(where: { $0.hasPrefix("a=fmtp:\(pt) ") }).map { " " + $0.split(separator: " ", maxSplits: 1).last! } ?? ""
        Log.write("原生串流：视频编码 \(map.split(separator: " ").last ?? "?")\(fmtp)")
    }

    // MARK: HTTP
    private func http(_ method: String, _ path: String, body: Any? = nil, allowEmpty: Bool = false) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: base + path)!)
        req.httpMethod = method
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("XboxComBrowser", forHTTPHeaderField: "X-Gssv-Client")
        req.setValue("Bearer \(gsToken)", forHTTPHeaderField: "Authorization")
        req.setValue(XboxStreamSession.deviceInfo(), forHTTPHeaderField: "X-MS-Device-Info")
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) } else if method == "POST" { req.httpBody = Data() }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if !(200..<300).contains(code) {
            Log.write("原生串流：\(method) \(path.split(separator: "/").last ?? "") 返回 \(code) \(String(data: data.prefix(300), encoding: .utf8) ?? "")")
            throw XErr("服务器返回 \(code)")
        }
        return obj
    }

    /// 和参考客户端一样的设备信息（服务器按这个决定能给多高的分辨率）
    static func deviceInfo() -> String {
        let d: [String: Any] = [
            "appInfo": ["env": ["clientAppId": "www.xbox.com", "clientAppType": "browser", "clientAppVersion": "21.1.98",
                                "clientSdkVersion": "8.5.3", "httpEnvironment": "prod", "sdkInstallId": ""]],
            "dev": ["hw": ["make": "Microsoft", "model": "unknown", "sdktype": "web"],
                    "os": ["name": XboxQuality.osName, "ver": "22631.2715", "platform": "desktop"],
                    "displayInfo": ["dimensions": ["widthInPixels": XboxQuality.width, "heightInPixels": XboxQuality.height], "pixelDensity": ["dpiX": 2, "dpiY": 2]],
                    "browser": ["browserName": "chrome", "browserVersion": "119.0"]],
        ]
        return String(data: try! JSONSerialization.data(withJSONObject: d), encoding: .utf8)!
    }

    // MARK: 数据通道
    private func channelOpened(_ label: String) {
        Log.write("原生串流：\(label) 通道已打开")
        if label == "message" {
            send("message", ["type": "Handshake", "version": "messageV1", "id": UUID().uuidString.lowercased(), "cv": "0"])
        }
    }

    private func received(_ label: String, _ data: Data, binary: Bool) {
        switch label {
        case "message":
            guard let m = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            switch m["type"] as? String {
            case "HandshakeAck":
                Log.write("原生串流：握手完成")
                connectedAt = Date()
                status("已连接")
                send("control", ["message": "authorizationRequest", "accessKey": "4BDB3609-C1F1-4195-9B37-FEFF45DA8B8E"])
                send("control", ["message": "gamepadChanged", "gamepadIndex": 0, "wasAdded": true])
                send("control", ["message": "videoKeyframeRequested", "ifrRequested": true])
                input.start()
                sendConfig()
            case "TransactionStart", "Message":
                let target = m["target"] as? String ?? ""
                Log.write("原生串流：主机消息 \(target)")
                if target == "/streaming/sessionLifetimeManagement/serverInitiatedDisconnect" {
                    completeTransaction(m["id"] as? String ?? "", "")
                    stop("主机断开了")
                } else if target.hasPrefix("/streaming/systemUi/messages/") {
                    completeTransaction(m["id"] as? String ?? "", ["Result": 0])
                }
            default: break
            }
        case "input":
            guard binary, data.count >= 2 else { return }
            let type = UInt16(data[0]) | UInt16(data[1]) << 8
            if type & 16 != 0, data.count >= 10 {   // 服务器视频尺寸
                let h = data.subdata(in: 2..<6).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
                let w = data.subdata(in: 6..<10).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
                Log.write("原生串流：主机画面 \(w)×\(h)")
            } else if type & 128 != 0 {
                // 震动（待做）
            }
        default: break
        }
    }

    private func sendConfig() {
        func msg(_ target: String, _ content: [String: Any]) {
            let c = String(data: try! JSONSerialization.data(withJSONObject: content), encoding: .utf8)!
            send("message", ["type": "Message", "content": c, "id": UUID().uuidString.lowercased(), "target": target, "cv": ""])
        }
        msg("/streaming/systemUi/configuration", ["version": [0, 2, 0], "systemUis": [Int]()])
        msg("/streaming/properties/clientappinstallidchanged", ["clientAppInstallId": XboxStreamSession.installID])
        msg("/streaming/characteristics/orientationchanged", ["orientation": 0])
        msg("/streaming/characteristics/touchinputenabledchanged", ["touchInputEnabled": false])
        msg("/streaming/characteristics/clientdevicecapabilities", [:])
        let w = XboxQuality.width, h = XboxQuality.height
        msg("/streaming/characteristics/dimensionschanged", ["horizontal": w, "vertical": h, "preferredWidth": w, "preferredHeight": h,
                                                             "safeAreaLeft": 0, "safeAreaTop": 0, "safeAreaRight": w, "safeAreaBottom": h,
                                                             "supportsCustomResolution": true])
    }

    /// 这台 Mac 的安装 ID（随机，存起来）
    static let installID: String = {
        if let s = UserDefaults.standard.string(forKey: "xboxInstallId.v1") { return s }
        let s = UUID().uuidString.lowercased()
        UserDefaults.standard.set(s, forKey: "xboxInstallId.v1")
        return s
    }()

    private func completeTransaction(_ id: String, _ content: Any) {
        let c = String(data: (try? JSONSerialization.data(withJSONObject: content, options: .fragmentsAllowed)) ?? Data(), encoding: .utf8) ?? "\"\""
        send("message", ["type": "TransactionComplete", "content": c, "id": id, "cv": ""])
    }

    private func send(_ label: String, _ obj: [String: Any]) {
        guard let ch = channels[label], ch.readyState == .open, let d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        ch.sendData(RTCDataBuffer(data: d, isBinary: false))
    }
}

// MARK: WebRTC 回调（在 WebRTC 的线程上来，转回主线程）
extension XboxStreamSession: RTCPeerConnectionDelegate, RTCDataChannelDelegate {
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        let s = newState.rawValue
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let names = ["new", "checking", "connected", "completed", "failed", "disconnected", "closed"]
                Log.write("原生串流：ICE \(s < names.count ? names[s] : "\(s)")")
                if newState == .failed { self.stop("连接失败（网络打不通）") }
            }
        }
    }
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        if newState == .complete { DispatchQueue.main.async { MainActor.assumeIsolated { self.gathered = true } } }
    }
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.localCandidates.append(candidate) } }
    }
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
    /// 收到对方的轨道：视频轨道再挂一次画面接收器（建连接时挂过一次，以防那时轨道还没准备好）
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        let track = rtpReceiver.track
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                Log.write("原生串流：收到\(track?.kind == "video" ? "视频" : "音频")轨道（\(track?.trackId ?? "?")，\(track?.isEnabled == true ? "开" : "关")）")
                if self.videoTrack == nil, let v = track as? RTCVideoTrack { v.isEnabled = true; v.add(self.sink); self.videoTrack = v }
            }
        }
    }

    nonisolated func dataChannelDidChangeState(_ ch: RTCDataChannel) {
        let label = ch.label, open = ch.readyState == .open, closed = ch.readyState == .closed
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if open { self.channelOpened(label) }
                if closed && label == "message" && !self.stopped { self.stop("连接断开") }
            }
        }
    }
    nonisolated func dataChannel(_ ch: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        let label = ch.label, data = buffer.data, bin = buffer.isBinary
        DispatchQueue.main.async { MainActor.assumeIsolated { self.received(label, data, binary: bin) } }
    }
}

// MARK: - 画面：WebRTC 解码出的帧 → 补帧管线
/// 在 WebRTC 的解码线程上被调用。2026-11-27 改：不再统一缩成 1920×1080，保持主机发来的尺寸（局域网 2560×1440、公网常掉到 1280×720），
/// 只把颜色从全范围（420f）转成视频范围（420v，管线和显示都按这个算）。补帧时管线自己按面积平均缩到 1080p（和采集卡 2K 一样），
/// 不补帧时原尺寸交给清晰放大，只缩放一次到屏幕
final class FrameSink: NSObject, RTCVideoRenderer, @unchecked Sendable {
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    var onMetadata: ((UInt32, Double) -> Void)?
    var onSize: ((Int, Int) -> Void)?   // 主机发来的分辨率变了（主线程）
    private let format: OSType
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var poolSize = (0, 0)
    private var frames = 0
    private var lastSize = (0, 0)
    // 时间戳用 RTP（主机打的，90kHz）：WebRTC 的 timeStampNs 对远端画面不是真实帧间隔，补帧按它算间隔一直"不用补"
    // （2026-11-27：开补帧后补帧 0 次，被误判"太慢"切 720p，原生串流跟着断开重连）。32 位会回绕，展开成单调递增
    private var lastRTP: UInt32?
    private var rtpBase: Int64 = 0

    // 平滑缓冲（2026-11-27）：网络让画面到达时快时慢，补帧队列就会一会儿空拍、一会儿丢帧（看门狗 2 实测 30 → 54 帧，每秒空拍、丢帧各 4～5 次）。
    // 按主机时间交帧：偏差 = 到达时间 − 主机时间（RTP），取最近 3 秒最小偏差当基准，再加余量（最近偏差的 95% 分位，3～40ms），
    // 在"主机时间 + 基准 + 余量"那一刻交给管线。FI_XNOPACE=1 关掉（对照）
    private let pacing = ProcessInfo.processInfo.environment["FI_XNOPACE"] != "1"
    private let paceQ = DispatchQueue(label: "xbox.pace", qos: .userInteractive)
    private var offsets: [(t: Double, off: Double)] = []
    private var lastTarget = 0.0
    private let statLock = NSLock()
    private var marginSum = 0.0, marginN = 0, lateN = 0
    private var p50Sum = 0.0, p95Sum = 0.0, maxSpread = 0.0
    /// 余量上限（秒），FI_XPACEMAX=毫秒 可改（诊断用）
    private let paceMax = (ProcessInfo.processInfo.environment["FI_XPACEMAX"].flatMap(Double.init) ?? 25) / 1000
    /// 这一秒的平均余量（毫秒）和赶不上（来得太晚直接交）的帧数，读完清零
    func takePacingStats() -> (margin: Double, late: Int, on: Bool, detail: String) {
        statLock.lock(); defer { statLock.unlock() }
        let n = Double(max(marginN, 1))
        let m = marginN > 0 ? marginSum / n * 1000 : 0
        let d = String(format: "抖动 中位 %.0f / 95%% %.0f / 最大 %.0f ms", p50Sum / n * 1000, p95Sum / n * 1000, maxSpread * 1000)
        let r = (m, lateN, pacing, d)
        marginSum = 0; marginN = 0; lateN = 0; p50Sum = 0; p95Sum = 0; maxSpread = 0
        return r
    }

    /// 按主机时间安排交帧
    private var dbgN = 0, dbgLast: (Double, Double)?, dbgLines: [String] = []
    private let dbg = ProcessInfo.processInfo.environment["FI_XFRAMELOG"] == "1"
    private func deliver(_ pb: CVPixelBuffer, pts: CMTime, mediaSec: Double) {
        // 诊断（FI_XFRAMELOG=1）：第 300～900 帧，每帧记"主机时间间隔 / 到达间隔"（毫秒），攒够了一次写进日志
        if dbg {
            let nowD = CACurrentMediaTime()
            dbgN += 1
            if let l = dbgLast, dbgN > 300, dbgN <= 900 { dbgLines.append(String(format: "%.1f/%.1f", (mediaSec - l.0) * 1000, (nowD - l.1) * 1000)) }
            dbgLast = (mediaSec, nowD)
            if dbgN == 900 { let t = dbgLines.joined(separator: " "); DispatchQueue.main.async { Log.write("逐帧（主机间隔/到达间隔 ms）：" + t) } }
        }
        guard pacing, let out = onFrame else { onFrame?(pb, pts); return }
        let now = CACurrentMediaTime()
        let off = now - mediaSec
        offsets.append((now, off))
        while let f = offsets.first, now - f.t > 3 { offsets.removeFirst() }
        let minOff = offsets.map(\.off).min() ?? off
        let spread = offsets.map { $0.off - minOff }.sorted()
        let p95 = spread[min(spread.count - 1, Int(Double(spread.count) * 0.95))]
        let margin = min(max(p95, 0.003), paceMax)
        statLock.lock(); p50Sum += spread[spread.count / 2]; p95Sum += p95; maxSpread = max(maxSpread, spread.last ?? 0); statLock.unlock()
        var target = mediaSec + minOff + margin
        if target < lastTarget { target = lastTarget }   // 不乱序
        lastTarget = target
        let delay = target - now
        statLock.lock(); marginSum += margin; marginN += 1; if delay <= 0.0005 { lateN += 1 }; statLock.unlock()
        let box = PBBox(pb)
        if delay <= 0.0005 {
            paceQ.async { out(box.pb, pts) }
        } else {
            paceQ.asyncAfter(deadline: .now() + delay) { out(box.pb, pts) }
        }
    }
    private let t0 = CACurrentMediaTime()
    private let callLock = NSLock()
    private var _calls = 0
    var calls: Int { callLock.lock(); defer { callLock.unlock() }; return _calls }

    init(width: Int, height: Int, pixelFormat: OSType) {
        format = pixelFormat
        super.init()
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
        if let t = transfer { VTSessionSetProperty(t, key: kVTPixelTransferPropertyKey_RealTime, value: kCFBooleanTrue) }
    }

    func setSize(_ size: CGSize) { DispatchQueue.main.async { Log.write("原生串流：接收器 setSize \(Int(size.width))×\(Int(size.height))") } }

    func renderFrame(_ frame: RTCVideoFrame?) {
        callLock.lock(); _calls += 1; callLock.unlock()
        guard let frame else { return }
        if frames == 0 { DispatchQueue.main.async { Log.write("原生串流：收到第一帧画面（\(type(of: frame.buffer))）") } }
        let now = (CACurrentMediaTime() - t0) * 1000
        onMetadata?(UInt32(bitPattern: frame.timeStamp), now)
        guard let src = (frame.buffer as? RTCCVPixelBuffer)?.pixelBuffer else {
            if frames == 0 { Log.write("原生串流：解码出来的不是 CVPixelBuffer（\(type(of: frame.buffer))），暂不支持") }
            frames += 1
            return
        }
        frames += 1
        let sw = CVPixelBufferGetWidth(src), sh = CVPixelBufferGetHeight(src), sf = CVPixelBufferGetPixelFormatType(src)
        if (sw, sh) != lastSize {
            lastSize = (sw, sh)
            let fc = String(bytes: [UInt8(sf >> 24 & 255), UInt8(sf >> 16 & 255), UInt8(sf >> 8 & 255), UInt8(sf & 255)], encoding: .ascii) ?? "?"
            let cb = onSize
            DispatchQueue.main.async { Log.write("原生串流：解码画面 \(sw)×\(sh) \(fc)（原尺寸送进管线）"); cb?(sw, sh) }
        }
        let rtp = UInt32(bitPattern: frame.timeStamp)
        if let last = lastRTP, rtp < last, last - rtp > 0x8000_0000 { rtpBase += 1 << 32 }   // 回绕
        lastRTP = rtp
        let pts = CMTime(value: rtpBase + Int64(rtp), timescale: 90_000)
        let mediaSec = Double(rtpBase + Int64(rtp)) / 90_000
        if sf == format { deliver(src, pts: pts, mediaSec: mediaSec); return }
        // 只转颜色格式，尺寸不变（池子按当前尺寸建，尺寸变了重建）
        if (sw, sh) != poolSize {
            poolSize = (sw, sh)
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: format, kCVPixelBufferWidthKey as String: sw, kCVPixelBufferHeightKey as String: sh,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            pool = nil
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 6] as CFDictionary, attrs as CFDictionary, &pool)
        }
        guard let pool, let transfer else { return }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let dst = out, VTPixelTransferSessionTransferImage(transfer, from: src, to: dst) == noErr else { return }
        deliver(dst, pts: pts, mediaSec: mediaSec)
    }
}

/// 让 CVPixelBuffer 能放进 @Sendable 闭包
final class PBBox: @unchecked Sendable { let pb: CVPixelBuffer; init(_ p: CVPixelBuffer) { pb = p } }

// MARK: - 手柄输入：按 Xbox 串流的二进制格式发
/// 包头 14 字节：报告类型 UInt16、序号 UInt32、时间（毫秒）Float64，都是小端；后面按类型接各段
final class XboxInput: @unchecked Sendable {
    var channel: RTCDataChannel?
    private let q = DispatchQueue(label: "xbox.input")
    private var metadata: [(UInt32, Double)] = []
    private var pads: [[UInt8]] = []
    private var seq: UInt32 = 0
    private var timer: DispatchSourceTimer?
    private let t0 = CACurrentMediaTime()
    private var latestPad: [UInt8]?

    private func ms() -> Double { (CACurrentMediaTime() - t0) * 1000 }

    func start() {
        // 先送客户端信息（最多触点数 1）
        var p = header(type: 8, seq: 0)
        p.append(1)
        sendRaw(p)
        DispatchQueue.main.async { MainActor.assumeIsolated { GCController.shouldMonitorBackgroundEvents = true } }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.016, repeating: 0.016)
        t.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.tick() } }
        t.resume()
        timer = t
    }

    func stop() { timer?.cancel(); timer = nil }

    /// 每个视频帧一条（服务器用它算延迟）
    func queueMetadata(key: UInt32, arrivalMs: Double) {
        q.async {
            self.metadata.append((key, arrivalMs))
            self.flush(force: false)
        }
    }

    /// 主线程：每 16ms 读一次手柄
    @MainActor private func tick() {
        guard let g = GCController.controllers().first(where: { $0.extendedGamepad != nil })?.extendedGamepad else { return }
        let frame = XboxInput.encodePad(g)
        q.async {
            self.pads.append(frame)
            self.flush(force: false)
        }
    }

    /// 和参考客户端一样：有视频帧信息时，连同手柄状态一起发；视频帧信息攒到 6 条也发
    private func flush(force: Bool) {
        guard force || metadata.count > 5 || (!metadata.isEmpty && !pads.isEmpty) else { return }
        seq &+= 1
        var type: UInt16 = 0
        if !metadata.isEmpty { type |= 1 }
        if !pads.isEmpty { type |= 2 }
        var p = header(type: type, seq: seq)
        if !metadata.isEmpty {
            p.append(UInt8(min(metadata.count, 255)))
            let now = UInt32(ms())
            for (key, arrival) in metadata.prefix(255) {
                for v in [key, UInt32(arrival), UInt32(arrival), now, now, now, now] { p.append(contentsOf: le32(v)) }
            }
        }
        if !pads.isEmpty {
            p.append(UInt8(min(pads.count, 255)))
            for f in pads.prefix(255) { p.append(contentsOf: f) }
        }
        metadata.removeAll(); pads.removeAll()
        sendRaw(p)
    }

    private func header(type: UInt16, seq: UInt32) -> [UInt8] {
        var p: [UInt8] = []
        p.append(contentsOf: [UInt8(type & 255), UInt8(type >> 8)])
        p.append(contentsOf: le32(seq))
        withUnsafeBytes(of: ms().bitPattern.littleEndian) { p.append(contentsOf: $0) }
        return p
    }

    private func sendRaw(_ bytes: [UInt8]) {
        guard let ch = channel, ch.readyState == .open else { return }
        ch.sendData(RTCDataBuffer(data: Data(bytes), isBinary: true))
    }

    /// 一个手柄 23 字节：编号、按键位、四个摇杆轴（Int16，y 向上为正）、两个扳机（UInt16）、两个 UInt32 的 1
    @MainActor static func encodePad(_ g: GCExtendedGamepad, index: UInt8 = 0) -> [UInt8] {
        var mask: UInt16 = 0
        func on(_ b: GCControllerButtonInput?, _ bit: UInt16) { if (b?.value ?? 0) > 0.1 { mask |= bit } }
        on(g.buttonHome, 2); on(g.buttonMenu, 4); on(g.buttonOptions, 8)
        on(g.buttonA, 16); on(g.buttonB, 32); on(g.buttonX, 64); on(g.buttonY, 128)
        on(g.dpad.up, 256); on(g.dpad.down, 512); on(g.dpad.left, 1024); on(g.dpad.right, 2048)
        on(g.leftShoulder, 4096); on(g.rightShoulder, 8192); on(g.leftThumbstickButton, 16384); on(g.rightThumbstickButton, 32768)
        // 视图 + 菜单一起按 = Xbox 键（和参考客户端一样）
        if mask & 4 != 0 && mask & 8 != 0 { mask &= ~12; mask |= 2 }
        func axis(_ v: Float) -> Int16 { Int16(max(-32767, min(32767, v * 32767))) }
        func trig(_ v: Float) -> UInt16 { UInt16(max(0, min(65535, v * 65535))) }
        var p: [UInt8] = [index]
        p.append(contentsOf: [UInt8(mask & 255), UInt8(mask >> 8)])
        for a in [axis(g.leftThumbstick.xAxis.value), axis(g.leftThumbstick.yAxis.value),
                  axis(g.rightThumbstick.xAxis.value), axis(g.rightThumbstick.yAxis.value)] {
            let u = UInt16(bitPattern: a); p.append(contentsOf: [UInt8(u & 255), UInt8(u >> 8)])
        }
        for t in [trig(g.leftTrigger.value), trig(g.rightTrigger.value)] { p.append(contentsOf: [UInt8(t & 255), UInt8(t >> 8)]) }
        p.append(contentsOf: le32(1))             // 实体手柄
        p.append(contentsOf: [0, 0, 0, 1])        // 参考客户端这里是大端的 1
        return p
    }
}

private func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 255), UInt8(v >> 8 & 255), UInt8(v >> 16 & 255), UInt8(v >> 24 & 255)] }
#endif
