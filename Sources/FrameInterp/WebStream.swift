import AppKit
import GameController
import ScreenCaptureKit
import WebKit

// MARK: - 内嵌网页串流（实验，2026-11-27 开始）
// 网页版 Xbox 串流（xbox.com/play）在浏览器里一失去焦点就暂停。把网页放进 FrameInterp 里：
// · 平时网页就显示在主窗口的画面区里（登录、选主机 / 游戏都在这里点）；
// · 点「开始补帧」：网页挪进一个看不见的采集窗口——主窗口的子窗口，排在主窗口正后面、无边框无阴影、960×540 点
//   （主窗口最小 960×600，一定盖得住；子窗口跟着主窗口移动、进全屏桌面、最小化），用 ScreenCaptureKit 抓它补帧，
//   和其他串流窗口走同一条路；⌘J / 「回到网页」再挪回画面区。网页对象不重建，串流不断。
//   试过采集窗口完全透明（alpha 0）：放后面抓不到画面，放前面截图里有残影，不用；
// · WebKit 默认窗口被挡住就当成"页面隐藏"（停掉渲染），用私有接口 _setWindowOcclusionDetectionEnabled: 关掉。
//   M2 实测（FI_WEBSPIKE）：关掉后被挡住的网页照样 60 帧渲染、采集 57~60 帧；不关时 rAF 0 帧、画面不动；
// · 页面里注入脚本：document.visibilityState 永远 visible、hasFocus() 永远 true、拦掉 blur / visibilitychange；
// · 手柄：主窗口在前台时 WebKit 不把手柄给后面窗口里的网页。FrameInterp 自己读 GameController，
//   注入脚本把 navigator.getGamepads() 换成我们转过去的手柄（标准布局），网页前台 / 后台都一样。
// 不用 XboxPad 那种逆向的 Xbox 接口：网页是官方的，接口变了微软自己会跟着改。

@MainActor
final class WebStreamHost: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    let window: NSWindow                // 采集窗口（看不见，补帧时网页在这里）
    let webView: WKWebView
    let slot = NSView()                 // 主窗口画面区里放网页的位置（SwiftUI 里的 WebSlot）
    var onLog: ((String) -> Void)?
    /// 加载状态（界面画加载动画用）：正在加载、进度 0~1、出错原因
    var onLoadState: ((Bool, Double, String?) -> Void)?
    private var pageLoading = false, loadError: String?, progress = 0.0
    private var progressObs: NSKeyValueObservation?
    private var target = WebStreamHost.xboxURL
    /// 光标在网页的输入框里
    private(set) var typing = false
    /// 固定用 en-US：网址里的语言代码同时决定 Xbox 的服务区域。2026-11-27 试过按系统语言开 zh-CN，
    /// 结果是中国大陆区，进去显示"区域不支持"（云游戏 / 远程游玩不支持这个区）。写死 en-US 也能盖过 cookie 里记的区域
    static let xboxURL = URL(string: "https://www.xbox.com/en-US/play")!
    nonisolated static let size = CGSize(width: 960, height: 540)

    /// 页面里注入的脚本：假装页面一直可见、一直有焦点
    static let focusSpoof = """
    (() => {
      const def = (o, k, v) => { try { Object.defineProperty(o, k, { get: () => v, configurable: true }); } catch (e) {} };
      def(Document.prototype, 'visibilityState', 'visible');
      def(Document.prototype, 'webkitVisibilityState', 'visible');
      def(Document.prototype, 'hidden', false);
      def(Document.prototype, 'webkitHidden', false);
      Document.prototype.hasFocus = function () { return true; };
      const stop = e => { e.stopImmediatePropagation(); };
      window.addEventListener('blur', stop, true);
      window.addEventListener('pagehide', stop, true);
      document.addEventListener('visibilitychange', stop, true);
      document.addEventListener('webkitvisibilitychange', stop, true);
    })();
    """

    /// 网页画出内容了：页面上有字（xbox.com 一直有后台请求，didFinish 可能半分钟都不来，不能等它）。
    /// DOMContentLoaded 之后每 0.2 秒看一次 body 里有没有字，有了再等两帧（画到屏幕上）告诉 FrameInterp
    static let readyProbe = """
    (() => {
      let sent = false;
      const send = () => { if (sent) return; sent = true; requestAnimationFrame(() => requestAnimationFrame(() => { try { webkit.messageHandlers.fiReady.postMessage(location.href); } catch (e) {} })); };
      const check = () => { const b = document.body; if (b && b.innerText.trim().length > 10) send(); else if (!sent) setTimeout(check, 200); };
      if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', check); else check();
      addEventListener('load', send);
    })();
    """

    /// 串流诊断：记下网页建的 WebRTC 连接，每 2 秒报一次视频的分辨率、帧率、丢帧、码率、网络延迟、连接方式
    /// （host / srflx = 直连，relay = 走微软的中转；udp / tcp）。用来分清"串流本身卡"还是"我们抓得慢"
    static let statsProbe = """
    (() => {
      const Orig = window.RTCPeerConnection; if (!Orig || Orig.__fi) return;
      const pcs = new Set();
      const PC = function (...a) { const pc = new Orig(...a); pcs.add(pc);
        pc.addEventListener('connectionstatechange', () => { if (['closed', 'failed'].includes(pc.connectionState)) pcs.delete(pc); });
        return pc; };
      PC.prototype = Orig.prototype; Object.setPrototypeOf(PC, Orig); PC.__fi = true;
      window.RTCPeerConnection = PC;
      const last = new Map();
      setInterval(async () => {
        for (const pc of pcs) {
          let st; try { st = await pc.getStats(); } catch (e) { continue; }
          let v = null, pair = null; const cand = {};
          const codecs = {};
          st.forEach(r => {
            if (r.type === 'codec') codecs[r.id] = r.mimeType;
            if (r.type === 'inbound-rtp' && r.kind === 'video') v = r;
            if (r.type === 'candidate-pair' && r.nominated && r.state === 'succeeded') pair = r;
            if (r.type === 'local-candidate' || r.type === 'remote-candidate') cand[r.id] = r;
          });
          if (!v) continue;
          const p = last.get(pc); last.set(pc, { b: v.bytesReceived, f: v.framesDecoded, d: v.framesDropped || 0, t: v.timestamp });
          if (!p) continue;
          const dt = (v.timestamp - p.t) / 1000;
          const fps = ((v.framesDecoded - p.f) / dt).toFixed(0), kbps = Math.round((v.bytesReceived - p.b) * 8 / 1000 / dt);
          const lc = pair && cand[pair.localCandidateId], rc = pair && cand[pair.remoteCandidateId];
          const rtt = pair && pair.currentRoundTripTime != null ? Math.round(pair.currentRoundTripTime * 1000) + 'ms' : '?';
          const mf = window.__fiMirrorFrames ? window.__fiMirrorFrames() : 0;
          try { webkit.messageHandlers.fiStats.postMessage(`画布 ${Math.round(mf / dt)} 帧/秒 | ${(codecs[v.codecId] || '').replace('video/', '')} ${v.frameWidth || '?'}x${v.frameHeight || '?'} 解码 ${fps} 帧/秒 丢 ${(v.framesDropped || 0) - p.d} | 码率 ${kbps} kbps | 往返 ${rtt} 抖动 ${Math.round((v.jitter || 0) * 1000)}ms 丢包 ${v.packetsLost || 0} | 连接 ${lc ? lc.candidateType + '/' + (lc.protocol || '') : '?'} → ${rc ? rc.candidateType : '?'}`); } catch (e) {}
        }
      }, 2000);
    })();
    """

    /// 补帧时把视频画到画布上：H.264 硬件解码的视频在单独的视频图层里，窗口被挡住（网页挪到主窗口后面）时
    /// 这个图层几乎不更新 / 抓不到——2026-11-27 实测本机 WebRTC 回环：H.264 解码 50 帧，只抓到约 10 帧（VP8 40~50 帧）；
    /// 真 Xbox 串流解码 60 帧只抓到约 30 帧，用户看着一卡一卡。画布是网页自己画的普通图层，被挡住照常更新。
    /// __fiMirror(true)：找到正在播的最大 <video>，盖一个同样大小的 canvas，每来一帧（requestVideoFrameCallback）画一次；false：去掉
    static let mirrorScript = """
    (() => {
      let cv = null, ctx = null, vid = null, on = false, raf = 0, frames = 0;
      const pick = () => {
        let best = null, area = 0;
        document.querySelectorAll('video').forEach(v => {
          const r = v.getBoundingClientRect(), a = r.width * r.height;
          if (v.readyState >= 2 && !v.paused && a > area) { best = v; area = a; }
        });
        return best;
      };
      const draw = () => {
        if (!on) return;
        if (!vid || !vid.isConnected || vid.paused) vid = pick();
        if (vid && vid.videoWidth) {
          const r = vid.getBoundingClientRect();
          if (cv.width !== vid.videoWidth || cv.height !== vid.videoHeight) { cv.width = vid.videoWidth; cv.height = vid.videoHeight; }
          const st = cv.style;
          st.left = r.left + 'px'; st.top = r.top + 'px'; st.width = r.width + 'px'; st.height = r.height + 'px';
          st.objectFit = getComputedStyle(vid).objectFit || 'contain';
          ctx.drawImage(vid, 0, 0, cv.width, cv.height);
          frames++;
        }
        // 默认跟着网页刷新（requestAnimationFrame）画；FI_WEBMIRRORMODE=rvfc 改成视频来一帧画一次（对照）
        if (window.__fiMirrorRVFC && vid && vid.requestVideoFrameCallback) vid.requestVideoFrameCallback(draw); else raf = requestAnimationFrame(draw);
      };
      window.__fiMirror = (want) => {
        if (want === on) return on;
        on = want;
        if (on) {
          cv = document.createElement('canvas');
          cv.style.cssText = 'position:fixed;z-index:2147483647;pointer-events:none;background:#000';
          ctx = cv.getContext('2d', { alpha: false });
          document.documentElement.appendChild(cv);
          vid = pick(); frames = 0;
          draw();
          // 视频还没开始（菜单里）：每秒再找一次
          const again = () => { if (!on) return; if (!vid) { vid = pick(); if (vid) draw(); } setTimeout(again, 1000); };
          setTimeout(again, 1000);
        } else {
          cancelAnimationFrame(raf);
          if (cv) cv.remove();
          cv = null; ctx = null; vid = null;
        }
        return on;
      };
      window.__fiMirrorFrames = () => { const f = frames; frames = 0; return f; };
    })();
    """

    /// 光标在不在输入框里（键盘当手柄用：在输入框里时 B 照常打字）
    static let typingProbe = """
    (() => {
      const text = ['text', 'email', 'password', 'search', 'tel', 'url', 'number', ''];
      const isInput = el => !!el && (el.isContentEditable || el.tagName === 'TEXTAREA'
        || (el.tagName === 'INPUT' && text.includes((el.getAttribute('type') || '').toLowerCase())));
      const send = v => { try { webkit.messageHandlers.fiTyping.postMessage(v); } catch (e) {} };
      document.addEventListener('focusin', e => send(isInput(e.target)), true);
      document.addEventListener('focusout', () => send(false), true);
    })();
    """

    /// 手柄：navigator.getGamepads() 返回 FrameInterp 转过来的手柄（W3C 标准布局：17 个按键、4 个轴）
    static let padShim = """
    (() => {
      const pads = [null, null, null, null];
      const make = (i, id) => ({
        id, index: i, connected: true, mapping: 'standard', timestamp: performance.now(),
        axes: [0, 0, 0, 0],
        buttons: Array.from({ length: 17 }, () => ({ pressed: false, touched: false, value: 0 })),
        vibrationActuator: {
          type: 'dual-rumble', effects: ['dual-rumble'],
          playEffect: (t, p) => { try { webkit.messageHandlers.fiRumble.postMessage({ i, d: p.duration || 0, s: p.strongMagnitude || 0, w: p.weakMagnitude || 0 }); } catch (e) {} return Promise.resolve('complete'); },
          reset: () => Promise.resolve('complete')
        }
      });
      const fire = (type, p) => { const e = new Event(type); e.gamepad = p; window.dispatchEvent(e); };
      navigator.getGamepads = function () { return pads.slice(); };
      window.__fiPad = (i, id, b, a) => {
        let p = pads[i];
        if (!p) { p = pads[i] = make(i, id); fire('gamepadconnected', p); }
        for (let k = 0; k < 17; k++) { const v = b[k]; const o = p.buttons[k]; o.value = v; o.pressed = v > 0.1; o.touched = o.pressed; }
        for (let k = 0; k < 4; k++) p.axes[k] = a[k];
        p.timestamp = performance.now();
      };
      window.__fiPadGone = i => { const p = pads[i]; if (p) { p.connected = false; pads[i] = null; fire('gamepaddisconnected', p); } };
    })();
    """

    init(size: CGSize = WebStreamHost.size) {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()      // 记住登录
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.allowsAirPlayForMediaPlayback = false
        for js in [WebStreamHost.focusSpoof, WebStreamHost.padShim] {
            cfg.userContentController.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        cfg.userContentController.addUserScript(WKUserScript(source: WebStreamHost.readyProbe, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        cfg.userContentController.addUserScript(WKUserScript(source: WebStreamHost.typingProbe, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        cfg.userContentController.addUserScript(WKUserScript(source: WebStreamHost.statsProbe, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        cfg.userContentController.addUserScript(WKUserScript(source: WebStreamHost.mirrorScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: cfg)
        // 用 Safari 的 UA：xbox.com/play 只认 Safari / Chrome / Edge
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
        window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.backgroundColor = .black
        window.contentView = NSView(frame: CGRect(origin: .zero, size: size))
        slot.wantsLayer = true
        slot.layer?.backgroundColor = NSColor.black.cgColor
        cfg.userContentController.add(self, name: "fi")
        cfg.userContentController.add(self, name: "fiRumble")
        cfg.userContentController.add(self, name: "fiReady")
        cfg.userContentController.add(self, name: "fiTyping")
        cfg.userContentController.add(self, name: "fiStats")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        // 关掉"窗口被挡住就当页面隐藏"（私有接口，没有就算了）
        occlusionOff = disableOcclusionDetection()
        // 网页还没画出来时不显示 WebKit 默认的灰白底（看起来像加载失败），露出后面的深色
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = NSColor(red: 10 / 255, green: 10 / 255, blue: 10 / 255, alpha: 1)
        progressObs = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] w, _ in
            let p = w.estimatedProgress
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.progress = p; self?.report() } }
        }
    }

    private func report() { onLoadState?(pageLoading, progress, loadError) }

    /// 清掉内嵌网页存的 Xbox 数据（cookie、本地存储）：区域 / 语言记错时用（会退出登录）。
    /// 测试钩子 FI_WEBRESET=1；2026-11-27 开过一次中文页（zh-CN = 中国大陆区），之后一直显示"区域不支持"
    static func resetXboxData(_ done: @escaping () -> Void) {
        let store = WKWebsiteDataStore.default()
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            let xbox = records.filter { r in ["xbox", "microsoft", "live.com", "msn"].contains { r.displayName.lowercased().contains($0) } }
            Log.write("清掉网页数据：\(xbox.map(\.displayName).joined(separator: ", "))")
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: xbox) { done() }
        }
    }

    /// 打开（第一次或关掉后再开）时加载 xbox.com/play
    private(set) var loaded = false
    func openXbox() {
        // FI_WEBURL：测试用，换一个网址（比如打不开的，看失败界面）
        let url = ProcessInfo.processInfo.environment["FI_WEBURL"].flatMap(URL.init(string:)) ?? WebStreamHost.xboxURL
        if !loaded { loaded = true; load(url) }
    }
    /// 测试用（FI_WEBXBOX=test）：不开 xbox.com，用本地测试页（MediaStream 视频，30 帧，和串流一样走 <video>）
    func openTestPage() {
        guard !loaded else { return }
        loaded = true
        var page = WebSpike.testPage
        if ProcessInfo.processInfo.environment["FI_WEBXBOX"]?.hasPrefix("testrtc") == true {
            // 视频走本机 WebRTC 回环（编码 → 网络栈 → 解码），和 Xbox 串流同一条解码 / 显示路径；60 帧
            page = page.replacingOccurrences(of: "v.srcObject = c.captureStream(60);", with: """
            (async () => {
              const s = c.captureStream(60), pc1 = new RTCPeerConnection(), pc2 = new RTCPeerConnection();
              pc1.onicecandidate = e => e.candidate && pc2.addIceCandidate(e.candidate);
              pc2.onicecandidate = e => e.candidate && pc1.addIceCandidate(e.candidate);
              pc2.ontrack = e => { v.srcObject = e.streams[0]; };
              s.getTracks().forEach(t => pc1.addTrack(t, s));
              // 和 Xbox 一样用 H.264（硬件解码）
              try { const tr = pc1.getTransceivers()[0], caps = RTCRtpSender.getCapabilities('video').codecs;
                    tr.setCodecPreferences(caps.filter(c => /h264/i.test(c.mimeType)).concat(caps.filter(c => !/h264/i.test(c.mimeType)))); } catch (e) {}
              const o = await pc1.createOffer(); await pc1.setLocalDescription(o); await pc2.setRemoteDescription(o);
              const a = await pc2.createAnswer(); await pc2.setLocalDescription(a); await pc1.setRemoteDescription(a);
            })();
            """)
        } else {
            page = page.replacingOccurrences(of: "setInterval(draw, 1000 / 60)", with: "setInterval(draw, 1000 / 30)")
        }
        loadHTML(page)
    }
    /// 关掉：停掉网页（串流和声音），下次打开重新加载
    func close() {
        loaded = false
        showInApp()
        webView.load(URLRequest(url: URL(string: "about:blank")!))
        watchdog?.cancel()
        pageLoading = false; loadError = nil
        report()
        onLog?("网页已关闭，串流停止")
    }

    private(set) var occlusionOff = false
    private func disableOcclusionDetection() -> Bool {
        guard webView.responds(to: NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")) else { return false }
        webView.setValue(false, forKey: "windowOcclusionDetectionEnabled")
        return true
    }

    func load(_ url: URL) {
        target = url
        pageLoading = true; loadError = nil; progress = 0
        report()
        webView.load(URLRequest(url: url, timeoutInterval: 30))
        armWatchdog()
    }

    /// 页面有内容了：收起加载动画（就算之前已经显示"加载太久"）
    private func ready() {
        watchdog?.cancel()
        pageLoading = false; loadError = nil
        report()
    }

    /// 25 秒还没画出内容：显示"加载太久"和重试（网页继续在后台加载，加载出来就自动收起）。
    /// 有的网络（代理、DNS 劫持）打不开时不会马上报错，而是一直挂着
    private var watchdog: DispatchWorkItem?
    private func armWatchdog() {
        watchdog?.cancel()
        let sec = ProcessInfo.processInfo.environment["FI_WEBTIMEOUT"].flatMap(Double.init) ?? 25
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.pageLoading, self.loadError == nil else { return }
                self.onLog?("网页 \(Int(sec)) 秒还没画出内容（进度 \(Int(self.progress * 100))%）")
                self.loadError = L("加载太久了：网络可能比较慢，或者连不上 Xbox 服务器。可以再等等，或者重试")
                self.report()
            }
        }
        watchdog = w
        DispatchQueue.main.asyncAfter(deadline: .now() + sec, execute: w)
    }
    /// 重试（加载失败后）
    func retry() { load(target) }
    func loadHTML(_ html: String) { webView.loadHTMLString(html, baseURL: URL(string: "https://localhost/")) }

    var windowID: CGWindowID { CGWindowID(window.windowNumber) }
    /// 采集范围：整个采集窗口（无边框，没有标题栏）
    var captureRect: CGRect { CGRect(origin: .zero, size: window.frame.size) }
    /// 网页现在在采集窗口里（补帧中）
    private(set) var capturing = false
    private var parentObservers: [NSObjectProtocol] = []

    /// 网页放回主窗口画面区（用户操作：登录、选游戏、退出游戏）
    func showInApp() {
        capturing = false
        setMirror(false)
        parentObservers.forEach(NotificationCenter.default.removeObserver)
        parentObservers = []
        window.parent?.removeChildWindow(window)
        window.orderOut(nil)
        webView.removeFromSuperview()
        webView.frame = slot.bounds
        webView.autoresizingMask = [.width, .height]
        slot.addSubview(webView)
    }

    /// 网页挪进采集窗口：主窗口的子窗口，排在主窗口正后面（主窗口最小 960×600，盖得住 960×540）
    func moveToCapture(behind main: NSWindow) {
        capturing = true
        setMirror(true)
        webView.removeFromSuperview()
        webView.autoresizingMask = []
        webView.frame = CGRect(origin: .zero, size: WebStreamHost.size)
        window.contentView?.addSubview(webView)
        place(behind: main)
        main.addChildWindow(window, ordered: .below)
        // 主窗口改大小、进出全屏后重新对齐（移动时子窗口会自己跟着）
        let nc = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            parentObservers.append(nc.addObserver(forName: name, object: main, queue: .main) { [weak self, weak main] _ in
                MainActor.assumeIsolated { if let self, let main, self.capturing { self.place(behind: main) } }
            })
        }
    }

    /// 视频画到画布上（补帧时开，回到网页操作时关）。FI_WEBMIRROR=0 关掉（对照测试用）
    private func setMirror(_ on: Bool) {
        let want = on && ProcessInfo.processInfo.environment["FI_WEBMIRROR"] != "0"
        let rvfc = ProcessInfo.processInfo.environment["FI_WEBMIRRORMODE"] == "rvfc"
        webView.evaluateJavaScript("window.__fiMirrorRVFC = \(rvfc); window.__fiMirror ? __fiMirror(\(want)) : 'none'") { [weak self] r, _ in
            MainActor.assumeIsolated { if on { self?.onLog?("视频画到画布：\(want ? "开" : "关（FI_WEBMIRROR=0）")\((r as? String) == "none" ? "（页面里没有脚本）" : "")") } }
        }
    }

    /// 对齐到主窗口中间（完全被盖住）
    private func place(behind main: NSWindow) {
        let f = main.frame, sz = WebStreamHost.size
        window.setFrame(CGRect(x: f.midX - sz.width / 2, y: f.midY - sz.height / 2, width: sz.width, height: sz.height), display: false)
    }

    // MARK: 手柄
    private var pads: [ObjectIdentifier: Int] = [:]
    private var padObservers: [NSObjectProtocol] = []

    /// 开始把手柄转给网页（前台 / 后台都转）
    func startGamepads() {
        guard padObservers.isEmpty else { return }
        GCController.shouldMonitorBackgroundEvents = true
        let nc = NotificationCenter.default
        padObservers.append(nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated { if let c = n.object as? GCController { self?.attach(c) } }
        })
        padObservers.append(nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated { if let c = n.object as? GCController { self?.detach(c) } }
        })
        GCController.controllers().forEach(attach)
    }

    private func attach(_ c: GCController) {
        guard let g = c.extendedGamepad, pads[ObjectIdentifier(c)] == nil else { return }
        let used = Set(pads.values)
        guard let slot = (0..<4).first(where: { !used.contains($0) }) else { return }
        pads[ObjectIdentifier(c)] = slot
        let name = c.vendorName ?? "Controller"
        onLog?("手柄 \(slot + 1)：\(name)，转给网页")
        g.valueChangedHandler = { [weak self] g, _ in
            MainActor.assumeIsolated { self?.push(slot, name, g) }
        }
        push(slot, name, g)
    }

    private func detach(_ c: GCController) {
        guard let slot = pads.removeValue(forKey: ObjectIdentifier(c)) else { return }
        onLog?("手柄 \(slot + 1) 断开")
        webView.evaluateJavaScript("window.__fiPadGone && __fiPadGone(\(slot))")
    }

    /// GameController → W3C 标准布局
    private func push(_ slot: Int, _ name: String, _ g: GCExtendedGamepad) {
        let b: [Float] = [
            g.buttonA.value, g.buttonB.value, g.buttonX.value, g.buttonY.value,
            g.leftShoulder.value, g.rightShoulder.value, g.leftTrigger.value, g.rightTrigger.value,
            g.buttonOptions?.value ?? 0, g.buttonMenu.value,
            g.leftThumbstickButton?.value ?? 0, g.rightThumbstickButton?.value ?? 0,
            g.dpad.up.value, g.dpad.down.value, g.dpad.left.value, g.dpad.right.value,
            g.buttonHome?.value ?? 0,
        ]
        // 标准布局里 y 轴向下为正，GameController 向上为正
        let a: [Float] = [g.leftThumbstick.xAxis.value, -g.leftThumbstick.yAxis.value,
                          g.rightThumbstick.xAxis.value, -g.rightThumbstick.yAxis.value]
        let f: (Float) -> String = { String(format: "%.3f", $0) }
        let id = name.replacingOccurrences(of: "'", with: "")
        webView.evaluateJavaScript("window.__fiPad && __fiPad(\(slot),'\(id) (STANDARD GAMEPAD)',[\(b.map(f).joined(separator: ","))],[\(a.map(f).joined(separator: ","))])")
    }

    /// 第一个空着的手柄位置（键盘当手柄用）
    func freeSlot() -> Int { let used = Set(pads.values); return (0..<4).first { !used.contains($0) } ?? 3 }

    /// 直接给网页一个手柄状态（17 个按键 0~1、4 个轴 -1~1，W3C 标准布局）
    func pushRaw(_ slot: Int, _ name: String, _ b: [Float], _ a: [Float]) {
        let f: (Float) -> String = { String(format: "%.3f", $0) }
        webView.evaluateJavaScript("window.__fiPad && __fiPad(\(slot),'\(name) (STANDARD GAMEPAD)',[\(b.map(f).joined(separator: ","))],[\(a.map(f).joined(separator: ","))])")
    }
    func removePad(_ slot: Int) { webView.evaluateJavaScript("window.__fiPadGone && __fiPadGone(\(slot))") }

    /// 测试用：假手柄按下 A、左摇杆推到右上
    func pushFakePad() {
        webView.evaluateJavaScript("__fiPad(0,'Fake (STANDARD GAMEPAD)',[1,0,0,0,0,0,0,0.5,0,0,0,0,0,0,0,0,0],[1,-1,0,0])")
    }

    // MARK: 网页回调
    /// 网页发来的消息（测试页日志、手柄震动）
    nonisolated func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        MainActor.assumeIsolated {
            let name = m.name, body = m.body
            if name == "fiRumble" { rumble(body as? [String: Any] ?? [:]); return }
            if name == "fiStats" { Log.write("Xbox 串流：\(body)" + (capturing ? "（补帧中，网页在后面）" : "（网页在画面区）")); return }
            if name == "fiTyping" { typing = (body as? Bool) ?? ((body as? NSNumber)?.boolValue ?? false); return }
            if name == "fiReady" { if pageLoading || loadError != nil { onLog?("网页画出内容了：\(body)") }; ready(); return }
            onLog?("网页：\(body)")
        }
    }

    /// 震动：网页按标准接口要震，转给手柄的震动马达（手柄不支持就算了）
    private func rumble(_ p: [String: Any]) {
        // 待做：用 GCController.haptics 实现；先只记一次日志
        if !loggedRumble { loggedRumble = true; onLog?("网页请求手柄震动（暂不支持）") }
    }
    private var loggedRumble = false

    nonisolated func webView(_ w: WKWebView, didStartProvisionalNavigation n: WKNavigation!) {
        MainActor.assumeIsolated {
            guard w.url?.absoluteString != "about:blank", !pageLoading else { return }
            pageLoading = true; loadError = nil
            report()
            armWatchdog()
        }
    }

    nonisolated func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        MainActor.assumeIsolated {
            onLog?("网页加载完成：\(w.url?.absoluteString ?? "-")")
            ready()
        }
    }

    nonisolated func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { MainActor.assumeIsolated { failed(e) } }
    nonisolated func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { MainActor.assumeIsolated { failed(e) } }

    /// 加载失败：取消（换页、点了别的链接）不算
    private func failed(_ e: Error) {
        let ns = e as NSError
        guard !(ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled) else { return }
        onLog?("网页加载失败：\(ns.domain) \(ns.code) \(ns.localizedDescription)")
        watchdog?.cancel()
        pageLoading = false
        loadError = ns.domain == NSURLErrorDomain && [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost].contains(ns.code)
            ? L("没有网络连接，检查 Wi-Fi 后重试")
            : ns.domain == NSURLErrorDomain && ns.code == NSURLErrorTimedOut ? L("连接超时，网络可能比较慢，稍后重试")
            : ns.domain == NSURLErrorDomain && [NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed].contains(ns.code)
                ? L("连不上 Xbox 服务器（可能被网络拦了，或者 DNS 有问题）")
            : ns.localizedDescription
        report()
    }

    /// 登录等弹出的新窗口：在同一个网页里打开
    nonisolated func webView(_ w: WKWebView, createWebViewWith c: WKWebViewConfiguration, for a: WKNavigationAction, windowFeatures f: WKWindowFeatures) -> WKWebView? {
        MainActor.assumeIsolated { if a.targetFrame == nil, let u = a.request.url { _ = w.load(URLRequest(url: u)) } }
        return nil
    }
}


// MARK: - 自测（FI_WEBSPIKE=1 / occl）
// 不登录 Xbox：用本地测试页（canvas 动画 → captureStream → <video>，和 xbox.com/play 一样是 MediaStream 视频）。
// 网页窗口放到主窗口后面，用 ScreenCaptureKit 抓 5 秒，看收到多少帧、画面是不是在变；页面自己也每秒报 rAF 帧率和可见状态。
@MainActor
enum WebSpike {
    static let testPage = """
    <html><body style="margin:0;background:#000;overflow:hidden">
    <canvas id=c width=1920 height=1080 style="display:none"></canvas>
    <video id=v autoplay muted playsinline style="width:100vw;height:100vh;object-fit:contain"></video>
    <script>
    const c = document.getElementById('c'), g = c.getContext('2d'), v = document.getElementById('v');
    v.srcObject = c.captureStream(60);
    let n = 0, raf = 0, blur = 0, vis = 0;
    addEventListener('blur', () => blur++);
    document.addEventListener('visibilitychange', () => vis++);
    function draw() {
      n++;
      g.fillStyle = `hsl(${n * 3 % 360},70%,40%)`; g.fillRect(0, 0, 1920, 1080);
      g.fillStyle = '#fff'; g.fillRect((n * 16) % 1920, 400, 120, 280);
      g.font = 'bold 120px sans-serif'; g.fillText(n, 80, 200);
    }
    function tick() { raf++; requestAnimationFrame(tick); }
    requestAnimationFrame(tick);
    setInterval(draw, 1000 / 60);
    setInterval(() => {
      const q = v.getVideoPlaybackQuality ? v.getVideoPlaybackQuality().totalVideoFrames : -1;
      const gp = navigator.getGamepads()[0];
      const pad = gp ? `手柄 ${gp.id} A=${gp.buttons[0].pressed} RT=${gp.buttons[7].value} LT=${gp.buttons[6].value} L3=${gp.buttons[10].pressed} 左摇杆=${gp.axes[0].toFixed(2)},${gp.axes[1].toFixed(2)}，` : '没有手柄，';
      webkit.messageHandlers.fi.postMessage(pad + `rAF ${raf}/s，视频已显示 ${q} 帧，visibility=${document.visibilityState} hasFocus=${document.hasFocus()}，blur 事件 ${blur}，visibilitychange ${vis}，视频${v.paused ? '暂停' : '播放中'}`);
      raf = 0;
    }, 1000);
    </script></body></html>
    """

    static var host: WebStreamHost?
    static var counter: FrameCounter?

    static func run(mainWindow: NSWindow?) {
        let mode = ProcessInfo.processInfo.environment["FI_WEBSPIKE"] ?? "1"
        let h = WebStreamHost()
        host = h
        h.onLog = { Log.write("网页自测：" + $0) }
        if mode == "occl" {  // 对照组：不关遮挡检测
            h.webView.setValue(true, forKey: "windowOcclusionDetectionEnabled")
        }
        Log.write("网页自测开始（模式 \(mode)）：关遮挡检测 \(mode == "occl" ? "否（对照）" : (h.occlusionOff ? "成功" : "失败：没有这个私有接口"))")
        h.loadHTML(testPage)
        h.startGamepads()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { h.pushFakePad() }
        if let mw = mainWindow {
            h.moveToCapture(behind: mw)   // 和真正补帧时一样：主窗口的子窗口，排在后面
            mw.makeKeyAndOrderFront(nil)
        }
        // 3 秒后开始抓 5 秒
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            Log.write("网页窗口遮挡状态：\(h.window.occlusionState.contains(.visible) ? "可见" : "被挡住")，主窗口在前台：\(mainWindow?.isKeyWindow == true)")
            Task { @MainActor in
                do {
                    let c = try await FrameCounter.start(windowID: h.windowID)
                    counter = c
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    let r = c.stop()
                    Log.write("网页自测结果：5 秒收到 \(r.frames) 帧（约 \(r.frames / 5) 帧/秒），画面变化 \(r.changes) 次")
                } catch {
                    Log.write("网页自测：抓不到网页窗口：\(error)")
                }
            }
        }
    }
}

/// 自测用：抓一个窗口，数帧数，看画面有没有变（取中间一行像素做摘要）
final class FrameCounter: NSObject, SCStreamOutput, @unchecked Sendable {
    private var stream: SCStream?
    private let lock = NSLock()
    private var frames = 0, changes = 0, last: UInt64 = 0

    static func start(windowID: CGWindowID) async throws -> FrameCounter {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let w = content.windows.first(where: { $0.windowID == windowID }) else {
            throw NSError(domain: "FI", code: 1, userInfo: [NSLocalizedDescriptionKey: "窗口列表里没有网页窗口"])
        }
        let cfg = SCStreamConfiguration()
        cfg.width = Int(w.frame.width * 2); cfg.height = Int(w.frame.height * 2)
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.showsCursor = false
        let f = FrameCounter()
        let s = SCStream(filter: SCContentFilter(desktopIndependentWindow: w), configuration: cfg, delegate: nil)
        try s.addStreamOutput(f, type: .screen, sampleHandlerQueue: DispatchQueue(label: "webspike"))
        try await s.startCapture()
        f.stream = s
        return f
    }

    func stop() -> (frames: Int, changes: Int) {
        stream?.stopCapture { _ in }
        lock.lock(); defer { lock.unlock() }
        return (frames, changes)
    }

    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        // 只数"完整"的帧（没变化的帧系统会标 idle）
        guard let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let st = att.first?[.status] as? Int, st == SCFrameStatus.complete.rawValue,
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb), w = CVPixelBufferGetWidth(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        // 摘要：第 1/5 高度那一行（有帧号数字）+ 中间一行（有移动的白块）
        var hash: UInt64 = 1469598103934665603
        for row in [h / 5, h / 2] {
            let p = base.advanced(by: row * bpr).assumingMemoryBound(to: UInt8.self)
            for x in stride(from: 0, to: w * 4, by: 16) { hash = (hash ^ UInt64(p[x])) &* 1099511628211 }
        }
        lock.lock()
        frames += 1
        if hash != last { changes += 1; last = hash }
        lock.unlock()
    }
}
