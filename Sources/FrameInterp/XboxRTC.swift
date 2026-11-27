#if FI_XNATIVE
import Foundation
@preconcurrency import WebRTC

// MARK: - 原生 Xbox 串流 · WebRTC（开发中，只在测试版）
// WebRTC 用 stasel/WebRTC 社区编译的 Google WebRTC（M158，Vendor/WebRTC.xcframework）。
// 目前只有自测：建一个和 Xbox 串流一样的连接（只收视频、只收音频、数据通道），生成 offer，看 H.264 解码器在不在。

@MainActor
enum XboxRTC {
    static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: RTCDefaultVideoDecoderFactory())
    }()

    /// FI_XRTCTEST=1：自测
    static func selfTest() {
        let cfg = RTCConfiguration()
        cfg.sdpSemantics = .unifiedPlan
        cfg.iceServers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
        let cons = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = factory.peerConnection(with: cfg, constraints: cons, delegate: nil) else {
            Log.write("WebRTC 自测：建连接失败"); return
        }
        let recv = RTCRtpTransceiverInit()
        recv.direction = .recvOnly
        pc.addTransceiver(of: .video, init: recv)
        pc.addTransceiver(of: .audio, init: recv)
        let dc = RTCDataChannelConfiguration()
        dc.isOrdered = true
        _ = pc.dataChannel(forLabel: "input", configuration: dc)
        let decoders = RTCDefaultVideoDecoderFactory().supportedCodecs().map { $0.name + ($0.parameters["profile-level-id"].map { " " + $0 } ?? "") }
        Log.write("WebRTC 自测：版本 M158，可用视频解码器：\(decoders.joined(separator: "、"))")
        pc.offer(for: cons) { sdp, err in
            let text = sdp?.sdp ?? ""
            let codecs = text.split(separator: "\r\n").filter { $0.hasPrefix("a=rtpmap:") }
                .compactMap { $0.split(separator: " ").last?.split(separator: "/").first.map(String.init) }
            let uniq = Array(NSOrderedSet(array: codecs)) as? [String] ?? codecs
            DispatchQueue.main.async {
                if let err { Log.write("WebRTC 自测：生成 offer 失败：\(err.localizedDescription)") }
                else { Log.write("WebRTC 自测：offer \(text.count) 字节，编码：\(uniq.joined(separator: " "))") }
                pc.close()
            }
        }
    }
}
#endif
