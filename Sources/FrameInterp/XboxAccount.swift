#if FI_XNATIVE
import AppKit
import Foundation
import SwiftUI

// MARK: - 原生 Xbox 串流 · 第 1 步：登录（开发中，2026-11-27 开始；只在测试版，编译开关 FI_XNATIVE）
// 不用微软的网页：自己走微软账号登录 → Xbox Live → 串流服务（gssv），拿到令牌和主机列表。后面几步（开会话、WebRTC、画面进补帧）另做。
// 流程（和开源客户端 Greenlight / XStreaming 一样的公开接口；代码自己写）：
//   1. 设备码登录：login.microsoftonline.com/consumers/oauth2/v2.0/devicecode → 用户在 microsoft.com/link 输入码 → 轮询 /token 拿 MSA 令牌
//   2. Xbox Live 用户令牌：user.auth.xboxlive.com/user/authenticate（RpsTicket = "d=" + MSA 令牌）
//   3. XSTS：xsts.auth.xboxlive.com/xsts/authorize，RelyingParty http://gssv.xboxlive.com/（串流用）、http://xboxlive.com（拿玩家代号）
//   4. 串流登录：xhome.gssv-play-prod.xboxlive.com/v2/login/user（offeringId xhome）→ gsToken + 服务器地址
//   5. 主机列表：{baseUri}/v6/servers/home
// 刷新令牌存 ~/Library/Application Support/FrameInterp/xbox-login（权限 600，下次打开自动登录）；日志里不记任何令牌。不伪装 IP / 地区。

enum XboxAPI {
    /// Xbox 官方应用的公开客户端 ID（开源客户端都用这个；不是我们注册的应用）
    static let clientID = "1f907974-e22b-4810-a9de-d9647380c97e"
    static let scope = "xboxlive.signin openid profile offline_access"
    static let msaBase = "https://login.microsoftonline.com/consumers/oauth2/v2.0"
}

struct XboxConsole: Identifiable, Hashable {
    let id: String          // serverId
    let name: String
    let type: String        // XboxSeriesS / XboxSeriesX / XboxOne…
    let power: String       // On / ConnectedStandby / Off
    var typeName: String {
        switch type {
        case "XboxSeriesS": return "Xbox Series S"
        case "XboxSeriesX": return "Xbox Series X"
        case "XboxOneX": return "Xbox One X"
        case "XboxOneS": return "Xbox One S"
        case "XboxOne": return "Xbox One"
        default: return type
        }
    }
    var powerName: String {
        switch power {
        case "On": return "开机"
        case "ConnectedStandby": return "待机（可远程唤醒）"
        case "Off": return "关机"
        default: return power
        }
    }
}

@MainActor
final class XboxAccount: ObservableObject {
    static let shared = XboxAccount()

    enum State: Equatable {
        case signedOut
        case waitingCode(code: String, url: String)
        case working(String)
        case signedIn(gamertag: String)
        case failed(String)
    }
    @Published private(set) var state: State = .signedOut
    @Published private(set) var consoles: [XboxConsole] = []
    @Published private(set) var loadingConsoles = false

    /// 串流服务的令牌和服务器（第 2 步开会话要用）
    private(set) var gsToken: String?
    private(set) var baseURI: String?
    private var task: Task<Void, Never>?

    // MARK: 登录 / 退出
    /// 打开程序时：钥匙串里有刷新令牌就悄悄登录
    func restore() {
        guard case .signedOut = state, let rt = Keychain.read() else { return }
        task = Task {
            do {
                state = .working("正在登录…")
                let msa = try await refresh(rt)
                try await finish(msa)
            } catch {
                Log.write("Xbox 账号：自动登录失败：\(error.localizedDescription)")
                state = .signedOut
            }
        }
    }

    func signIn() {
        task?.cancel()
        task = Task {
            do {
                state = .working("正在向微软申请登录码…")
                let dc = try await form("\(XboxAPI.msaBase)/devicecode", ["client_id": XboxAPI.clientID, "scope": XboxAPI.scope])
                guard let code = dc["user_code"] as? String, let device = dc["device_code"] as? String,
                      let url = dc["verification_uri"] as? String else { throw XErr("微软没给登录码") }
                let interval = max(2, dc["interval"] as? Int ?? 5), expires = dc["expires_in"] as? Int ?? 900
                state = .waitingCode(code: code, url: url)
                Log.write("Xbox 账号：等用户在 \(url) 输入登录码")
                // 轮询，直到用户在网页上输完码
                let deadline = Date().addingTimeInterval(TimeInterval(expires))
                var wait = interval
                while Date() < deadline {
                    try await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000)
                    let r = try await form("\(XboxAPI.msaBase)/token", [
                        "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                        "client_id": XboxAPI.clientID, "device_code": device], allowError: true)
                    if let at = r["access_token"] as? String {
                        if let rt = r["refresh_token"] as? String { Keychain.save(rt) }
                        state = .working("正在登录 Xbox Live…")
                        try await finish(at)
                        return
                    }
                    switch r["error"] as? String {
                    case "authorization_pending": continue
                    case "slow_down": wait += 5
                    case "authorization_declined": throw XErr("在网页上拒绝了登录")
                    case "expired_token": throw XErr("登录码过期了，重新点登录")
                    default: throw XErr(r["error_description"] as? String ?? "登录失败")
                    }
                }
                throw XErr("登录码过期了，重新点登录")
            } catch is CancellationError {
                state = .signedOut
            } catch {
                Log.write("Xbox 账号：登录失败：\(error.localizedDescription)")
                state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() { task?.cancel(); task = nil; state = .signedOut }

    func signOut() {
        task?.cancel()
        Keychain.delete()
        gsToken = nil; baseURI = nil; consoles = []
        state = .signedOut
        Log.write("Xbox 账号：已退出")
    }

    func reloadConsoles() {
        task = Task { do { try await loadConsoles() } catch { Log.write("Xbox 账号：读主机列表失败：\(error.localizedDescription)") } }
    }

    /// 主机串流"转移令牌"：会话状态到 ReadyToConnect 时要 POST /connect 送过去（用钥匙串里的刷新令牌换）
    func transferToken() async throws -> String {
        guard let rt = Keychain.read() else { throw XErr("没有登录信息，重新登录") }
        var req = URLRequest(url: URL(string: "https://login.live.com/oauth20_token.srf")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.urlQueryAllowed; allowed.remove(charactersIn: "&=+:/ ")
        let fields = ["client_id": XboxAPI.clientID, "grant_type": "refresh_token", "refresh_token": rt,
                      "scope": "service::http://Passport.NET/purpose::PURPOSE_XBOX_CLOUD_CONSOLE_TRANSFER_TOKEN"]
        req.httpBody = fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&").data(using: .utf8)
        let r = try await send(req, allowError: false)
        guard let at = r["access_token"] as? String else { throw XErr("拿不到转移令牌") }
        if let nrt = r["refresh_token"] as? String { Keychain.save(nrt) }
        return at
    }

    // MARK: 令牌链
    private func refresh(_ rt: String) async throws -> String {
        let r = try await form("\(XboxAPI.msaBase)/token", ["grant_type": "refresh_token", "client_id": XboxAPI.clientID,
                                                             "refresh_token": rt, "scope": XboxAPI.scope])
        guard let at = r["access_token"] as? String else { throw XErr("刷新登录失败") }
        if let nrt = r["refresh_token"] as? String { Keychain.save(nrt) }
        return at
    }

    /// MSA 令牌 → Xbox Live 用户令牌 → XSTS → 串流登录 → 主机列表
    private func finish(_ msa: String) async throws {
        let user = try await json("https://user.auth.xboxlive.com/user/authenticate", [
            "Properties": ["AuthMethod": "RPS", "SiteName": "user.auth.xboxlive.com", "RpsTicket": "d=\(msa)"],
            "RelyingParty": "http://auth.xboxlive.com", "TokenType": "JWT"], headers: ["x-xbl-contract-version": "1"])
        guard let userToken = user["Token"] as? String else { throw XErr("Xbox Live 登录失败") }

        func xsts(_ rp: String) async throws -> [String: Any] {
            let r = try await json("https://xsts.auth.xboxlive.com/xsts/authorize", [
                "Properties": ["SandboxId": "RETAIL", "UserTokens": [userToken]],
                "RelyingParty": rp, "TokenType": "JWT"], headers: ["x-xbl-contract-version": "1"], allowError: true)
            if let x = r["XErr"] as? Int {
                // 常见：2148916233 没有 Xbox 档案；2148916238 未成年账号要家长同意
                throw XErr(x == 2148916233 ? "这个微软账号还没有 Xbox 档案，先在 xbox.com 登录一次建档"
                           : x == 2148916238 ? "未成年账号，要在家庭设置里允许" : "Xbox Live 拒绝了登录（\(x)）")
            }
            return r
        }
        let web = try await xsts("http://xboxlive.com")
        let gamertag = ((web["DisplayClaims"] as? [String: Any])?["xui"] as? [[String: Any]])?.first?["gtg"] as? String ?? "Xbox 玩家"
        let gssv = try await xsts("http://gssv.xboxlive.com/")
        guard let gssvToken = gssv["Token"] as? String else { throw XErr("串流授权失败") }

        state = .working("正在连接串流服务…")
        let login = try await json("https://xhome.gssv-play-prod.xboxlive.com/v2/login/user",
                                   ["token": gssvToken, "offeringId": "xhome"], headers: ["x-gssv-client": "XboxComBrowser"])
        guard let gs = login["gsToken"] as? String else { throw XErr("串流服务登录失败") }
        let regions = (login["offeringSettings"] as? [String: Any])?["regions"] as? [[String: Any]] ?? []
        let region = regions.first { $0["isDefault"] as? Bool == true } ?? regions.first
        guard let base = region?["baseUri"] as? String else { throw XErr("串流服务没给服务器地址") }
        gsToken = gs; baseURI = base
        Log.write("Xbox 账号：已登录，串流服务器区域 \(region?["name"] as? String ?? "?")")
        state = .signedIn(gamertag: gamertag)
        try await loadConsoles()
    }

    private func loadConsoles() async throws {
        guard let gs = gsToken, let base = baseURI else { return }
        loadingConsoles = true
        defer { loadingConsoles = false }
        var req = URLRequest(url: URL(string: "\(base)/v6/servers/home?mr=50")!)
        req.setValue("Bearer \(gs)", forHTTPHeaderField: "Authorization")
        let r = try await send(req, allowError: false)
        let list = (r["results"] as? [[String: Any]] ?? []).map {
            XboxConsole(id: $0["serverId"] as? String ?? "", name: $0["deviceName"] as? String ?? "Xbox",
                        type: $0["consoleType"] as? String ?? "", power: $0["powerState"] as? String ?? "")
        }
        consoles = list
        Log.write("Xbox 账号：\(list.count) 台主机：" + list.map { "\($0.name)（\($0.typeName)，\($0.power)）" }.joined(separator: "、"))
    }

    // MARK: HTTP
    private func form(_ url: String, _ fields: [String: String], allowError: Bool = false) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.urlQueryAllowed; allowed.remove(charactersIn: "&=+:/ ")
        req.httpBody = fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&").data(using: .utf8)
        return try await send(req, allowError: allowError)
    }

    private func json(_ url: String, _ body: [String: Any], headers: [String: String] = [:], allowError: Bool = false) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(req, allowError: allowError)
    }

    private func send(_ req: URLRequest, allowError: Bool) async throws -> [String: Any] {
        var r = req
        r.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if !(200..<300).contains(code) && !allowError {
            let host = r.url?.host ?? "?"
            Log.write("Xbox 账号：\(host) 返回 \(code)")
            throw XErr("服务器返回 \(code)（\(host)）")
        }
        return obj
    }
}

struct XErr: LocalizedError {
    let msg: String
    init(_ m: String) { msg = m }
    var errorDescription: String? { msg }
}

/// 刷新令牌存在 ~/Library/Application Support/FrameInterp/xbox-login（权限 600，只有当前用户能读）。
/// 2026-11-27 原来存钥匙串：自签证书没有开发者团队 ID，钥匙串按每次编译的代码哈希认 App，重新编译后每次都弹"允许访问"，
/// 而且是在启动时的主线程上读，整个程序卡住。名字沿用 Keychain，调用处不用改
enum Keychain {
    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FrameInterp")
        return dir.appendingPathComponent("xbox-login")
    }
    static func save(_ token: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        fm.createFile(atPath: url.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600])
    }
    static func read() -> String? {
        guard let d = FileManager.default.contents(atPath: url.path), !d.isEmpty else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func delete() { try? FileManager.default.removeItem(at: url) }
}

/// 首页「串流 → Xbox」里的一行：原生串流（开发中）的登录状态
/// 首页「串流 → Xbox」的内容（2026-11-27 改：去掉内嵌网页，只留原生串流；画质、刷新、退出收进右上角的齿轮里）
struct XboxNativeRow: View {
    @ObservedObject var acc = XboxAccount.shared
    var connect: (XboxConsole) -> Void = { _ in }
    @State private var showSettings = false
    var body: some View {
        switch acc.state {
        case .signedOut:
            InsetRow(icon: "person.crop.circle", title: "还没登录 Xbox 账号", detail: "登录后列出你的主机，点一下就能连", on: false)
        case .waitingCode(let code, let url):
            // 登录码要大、要完整：用户得照着输入
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "key").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                    Text("用手机或电脑打开 \(url.replacingOccurrences(of: "https://", with: ""))，输入登录码")
                        .font(.system(size: 12, weight: .semibold))
                }
                HStack(spacing: 10) {
                    Text(code).font(.system(size: 26, weight: .bold, design: .monospaced)).tracking(3)
                        .textSelection(.enabled)
                    Spacer(minLength: 6)
                    SmallButton(title: "复制并打开") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
                    }
                    SmallButton(title: "取消") { acc.cancel() }
                }
                Text("登录你的微软账号后，这里会自动继续（15 分钟内有效）").font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            .padding(12)
            .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.accent.opacity(0.45)))
        case .working(let msg):
            InsetRow(icon: "hourglass", title: msg, detail: "")
        case .failed(let msg):
            InsetRow(icon: "exclamationmark.triangle", title: "登录没成功", detail: msg) {
                SmallButton(title: "重试") { acc.signIn() }
            }
        case .signedIn(let gt):
            VStack(alignment: .leading, spacing: 6) {
                // 账号一行：名字 + 齿轮（画质、刷新、退出都在里面）
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.checkmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ok)
                    Text(gt).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text("· \(XboxQuality.height)p").font(.system(size: 11)).foregroundStyle(Theme.muted)
                    Spacer(minLength: 4)
                    // 2026-11-28 用户：齿轮太不显眼——改成带文字的主色胶囊按钮
                    Button { showSettings.toggle() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "slider.horizontal.3").font(.system(size: 11, weight: .bold))
                            Text("串流设置").font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 10).frame(height: 26)
                        .background(Theme.accent.opacity(showSettings ? 0.28 : 0.16), in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.45)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Xbox 串流设置")
                    .popover(isPresented: $showSettings, arrowEdge: .bottom) { XboxSettingsPopover(acc: acc) }
                    .onAppear {   // 测试：FI_XPOPOVER=1 启动后自动打开齿轮设置（截图看界面）
                        if ProcessInfo.processInfo.environment["FI_XPOPOVER"] == "1" {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { showSettings = true }
                        }
                    }
                }
                .padding(.horizontal, 2)
                if acc.consoles.isEmpty && acc.loadingConsoles {
                    InsetRow(icon: "hourglass", title: "正在读取主机…", detail: "", on: false)
                } else if acc.consoles.isEmpty {
                    InsetRow(icon: "gamecontroller", title: "没找到主机", detail: "主机要打开远程功能：设置 → 设备和连接 → 远程功能", on: false)
                }
                ForEach(acc.consoles) { c in
                    InsetRow(icon: "gamecontroller", title: c.name, detail: "\(c.typeName) · \(c.powerName)") {
                        ConnectButton { connect(c) }
                    }
                }
            }
        }
    }
}

/// 齿轮里的设置：画质、刷新主机列表、退出登录
struct XboxSettingsPopover: View {
    @ObservedObject var acc: XboxAccount
    @State private var res = XboxQuality.height
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Xbox 串流设置").font(.system(size: 13, weight: .bold))
            VStack(alignment: .leading, spacing: 6) {
                Text("画质").font(.system(size: 12, weight: .semibold))
                Segmented(labels: ["720p", "1080p", "1440p"], selection: [720, 1080, 1440].firstIndex(of: res) ?? 1) { i in
                    res = [720, 1080, 1440][i]; XboxQuality.height = res
                }
                Text(res == 1440 ? "1440p：局域网、网速好时用，Series X / S 都支持" : res == 720 ? "720p：网络差时更稳" : "1080p：一般用这个")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
                Text("下次连接生效").font(.system(size: 11)).foregroundStyle(Theme.faint)
                // 2026-11-28 用户：公网码率 / 分辨率还没解决，标开发中（主机走公网多半只给 720p，Google WebRTC 发不了 REMB 推码率）
                HStack(spacing: 6) {
                    Text("走公网时的码率和分辨率").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                    Text("开发中").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.amber)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Theme.amber.opacity(0.15), in: Capsule())
                }
                Text("现在走公网时主机多半只给 720p，会自动 AI 超分到 1080p；提高公网码率和分辨率还在做").font(.system(size: 11)).foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            XboxSRField()
            Theme.border.frame(height: 1)
            AWDLField()
            Theme.border.frame(height: 1)
            HStack(spacing: 8) {
                SmallButton(title: "刷新主机列表") { acc.reloadConsoles() }
                Spacer()
                SmallButton(title: "退出登录") { acc.signOut() }
            }
        }
        .padding(14)
        .frame(width: 300)
        .background(Theme.panel)
    }
}

/// 设置里的画质选择（和首页齿轮里的同一个设置）
struct XboxQualityField: View {
    @State private var res = XboxQuality.height
    var body: some View {
        Field("画质（下次连接生效）") {
            Segmented(labels: ["720p", "1080p", "1440p"], selection: [720, 1080, 1440].firstIndex(of: res) ?? 1) { i in
                res = [720, 1080, 1440][i]; XboxQuality.height = res
            }
        }
    }
}

/// AI 超分开关（首页齿轮、设置里同一个）：主机只给 720p 时用 Apple 的 AI 超分升到 1080p，连接中切换立刻生效
struct XboxSRField: View {
    var active = false   // 现在正在超分（原生串流、主机发 720p）
    @State private var on = SuperRes720.enabled
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SwitchLine(title: "串流 720p 自动 AI 超分到 1080p", isOn: Binding(get: { on }, set: { on = $0; SuperRes720.setEnabled($0) }))
            Text(on && active ? "正在超分：主机发来 1280×720，用 Apple 的 AI 超分升到 1920×1080，每帧多约 3～7ms"
                 : "原生 Xbox 串流时主机只给 720p（多半是走公网），自动用 Apple 的 AI 超分升到 1080p，压缩块和锯齿更少；每帧多约 3～7ms")
                .font(.system(size: 11)).foregroundStyle(on && active ? Theme.ok : Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 每台主机右边的「连接」：实心主色，就是这页的主要操作（2026-11-27 用户说底部「连接 某台主机」容易误导，删掉了，改成每台主机自己的按钮）
struct ConnectButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "bolt.fill").font(.system(size: 10, weight: .bold))
                Text("连接").font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Color.black)
            .padding(.horizontal, 14).frame(height: 28)
            .background(Theme.accent, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Xbox 页底部的主按钮：只在没登录时出现（「登录 Xbox 账号」）
struct XboxPrimaryButton: View {
    @ObservedObject var acc = XboxAccount.shared
    var connect: (XboxConsole) -> Void
    var body: some View {
        switch acc.state {
        case .signedOut, .failed:
            PillButton(title: "登录 Xbox 账号", icon: "person.crop.circle", filled: true) { acc.signIn() }
        default:
            EmptyView()
        }
    }
}

extension XboxAccount {
    /// 首页串流块右上角的状态
    var statusText: (String, Bool) {
        switch state {
        case .signedIn: return (consoles.isEmpty ? (loadingConsoles ? "正在读取主机" : "没找到主机") : "\(consoles.count) 台主机", !consoles.isEmpty)
        case .waitingCode, .working: return ("正在登录", false)
        default: return ("未登录", false)
        }
    }
}
#endif
