import AppKit
import SwiftUI

// MARK: - 配置向导：只选主机，套用这台主机的默认配置
// 2026-11-20 第一版是 5 步（主机 → 显示器 → 主机输出 → 诊断采集卡 → 推荐），用户觉得太复杂、诊断还会闪退
// （诊断时选到只支持 120 帧的档位硬设 60 帧，AVFoundation 抛异常），改成只选主机。
// 主机数据来自 Digital Foundry 对 GTA 6 的测试：四台主机都锁 30 帧；PS5 Pro / PS5 / Series X 内部 1440p，Series S 内部 720p（FSR 到约 1080p）。
// 四台都开补帧；补帧最高 1080p（Apple 补帧的上限），所以都采 1080p 不压缩（还能用 4:2:2，颜色细节多一倍）。

enum Console: Int, CaseIterable, Identifiable {
    case ps5, ps5Pro, xss, xsx
    var id: Int { rawValue }
    var name: String { ["PS5", "PS5 Pro", "Xbox Series S", "Xbox Series X"][rawValue] }
    /// GTA 6 在这台主机上的情况
    var gta6: String {
        switch self {
        case .ps5Pro: return "GTA 6 内部 1440p，PSSR 放大到接近 4K（四台里最清楚），稳定 30 帧"
        case .ps5: return "GTA 6 内部 1440p（TAA 放大），30 帧，激烈场景掉到 20 多"
        case .xsx: return "GTA 6 内部 1440p（TAA 放大），30 帧，偶尔掉到 20 出头"
        case .xss: return "GTA 6 内部 720p，FSR 放大到约 1080p，二十多到 30 帧"
        }
    }
    /// 主机该输出多少
    var output: String {
        switch self {
        case .ps5Pro, .ps5, .xsx: return "2160p"
        case .xss: return "1080p"
        }
    }
    var outputWhy: String {
        switch self {
        case .ps5Pro: return "PSSR 重建出来的细节只有输出 2160p 才拿得到"
        // 2026-11-24 改：原来推荐输出 1440p。游戏按输出分辨率做重建（动态分辨率最高到 4K），输出 2160p 细节最多；
        // 采集卡缩到 1080p 正好 2 倍，画面最干净
        case .ps5, .xsx: return "游戏按输出分辨率重建画面，输出 2160p 细节最多；采集 1080p 时正好缩小 2 倍，画面最干净"
        case .xss: return "内部只有 720p、放大到约 1080p，输出更高没有更多细节"
        }
    }
    /// 锐化档（0 关 / 1 柔和 / 2 标准）：画面越软锐化越多；PS5 Pro 的 PSSR 本身已经很锐
    var sharpLevel: Int {
        switch self {
        case .ps5Pro: return 0
        case .ps5, .xsx: return 1
        case .xss: return 2
        }
    }
    var sharpWhy: String {
        switch self {
        case .ps5Pro: return "PSSR 本来就很锐，再锐化容易出白边"
        case .ps5, .xsx: return "TAA 放大的画面偏软一点"
        case .xss: return "内部只有 720p，画面最软"
        }
    }
    /// 主机设置里在哪改
    var settingsPath: String {
        switch self {
        case .ps5Pro, .ps5: return "设置 → 屏幕和视频 → 视频输出：分辨率 \(output)，HDR 关，VRR 关，120Hz 输出 关"
        case .xsx, .xss: return "设置 → 常规 → 电视和显示选项：分辨率 \(output)，刷新率 60Hz；视频模式里关掉 HDR10、自动 HDR、VRR"
        }
    }
    var sharpName: String { ["关", "柔和", "标准"][sharpLevel] }
}

@MainActor
final class WizardModel: ObservableObject {
    @Published var console: Console?
    /// 采集分辨率和帧率（选主机页面里选，默认 1080p 60）
    @Published var captureHeight = 1080
    @Published var captureFps = 60
    /// 当前采集卡支持的分辨率（打开时从主界面拿）
    var availableHeights: [Int] = [1080, 1440, 2160]
    var heightMaxFps: [Int: Int] = [:]
    /// 分辨率按钮上的字：没有这一档标"不支持"，跑不满所选帧率标最高帧率
    func resLabel(_ h: Int) -> String {
        if !availableHeights.contains(h) { return UIModel.resName(h) + "（不支持）" }
        if let mx = heightMaxFps[h], mx < captureFps { return UIModel.resName(h) + "（\(mx) 帧）" }
        return UIModel.resName(h)
    }
    @Published var appliedSummary = ""      // 上次应用的配置（首页和设置里显示）
    var onApply: (Console) -> Void = { _ in }
    var onClose: () -> Void = {}

    static let key = "wizard.v2"
    var done: Bool { UserDefaults.standard.dictionary(forKey: WizardModel.key)?["done"] as? Bool ?? false }
    func load() {
        guard let d = UserDefaults.standard.dictionary(forKey: WizardModel.key) else { return }
        console = (d["console"] as? Int).flatMap(Console.init(rawValue:))
        appliedSummary = d["applied"] as? String ?? ""
    }
    func save(done: Bool) {
        var d: [String: Any] = ["done": done || self.done, "applied": appliedSummary]
        if let console { d["console"] = console.rawValue }
        UserDefaults.standard.set(d, forKey: WizardModel.key)
    }
}

struct SetupWizardView: View {
    @ObservedObject var w: WizardModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("选你的主机").font(.system(size: 16, weight: .bold))
                        Text("按主机套用推荐配置（按 GTA 6 这类 30 帧游戏定的），以后可以在设置里改").font(.system(size: 12)).foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    IconSquare(icon: "xmark", help: "关闭（以后可在首页或 设置 → 输入来源 里重新打开）") { w.onClose() }
                }
                .padding(18)
                Theme.border.frame(height: 1)
                VStack(alignment: .leading, spacing: 12) {
                    Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                        GridRow { card(.ps5); card(.ps5Pro) }
                        GridRow { card(.xss); card(.xsx) }
                    }
                    .fixedSize(horizontal: false, vertical: true) // 每行按最高的那张卡片定高，不往外撑
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("采集分辨率").font(.system(size: 12, weight: .semibold))
                            Segmented(labels: [1080, 1440, 2160].map { w.resLabel($0) },
                                      selection: [1080, 1440, 2160].firstIndex(of: w.captureHeight) ?? 0) { i in
                                let h = [1080, 1440, 2160][i]
                                if w.availableHeights.contains(h) { w.captureHeight = h }
                            }
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("采集帧率").font(.system(size: 12, weight: .semibold))
                            Segmented(labels: ["60 帧", "120 帧"], selection: w.captureFps == 120 ? 1 : 0) { w.captureFps = $0 == 1 ? 120 : 60 }
                        }
                        .frame(width: 200)
                    }
                    Hint(w.captureHeight > 1080
                         ? "补帧最高按 1080p 做：开补帧时采 \(UIModel.resName(w.captureHeight)) 也会先降到 1080p；不补帧时更清楚。采集卡带宽不够时会自动退到能跑的档"
                         : "1080p 60 帧最稳，补帧最高也是 1080p。" + (w.captureFps == 120 ? "120 帧只有主机输出 120Hz 时才有用" : ""))
                    if let c = w.console {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("主机上要改的").font(.system(size: 12, weight: .semibold))
                            Hint("· " + c.settingsPath)
                            Hint("· HDR 一定要关：采集卡不支持 HDR，开着画面发灰、偏暗")
                        }
                    } else {
                        Hint("点一台主机看推荐配置")
                    }
                }
                .padding(18)
                Theme.border.frame(height: 1)
                HStack {
                    Spacer()
                    OutlineButton(title: "关闭", icon: "xmark", color: Theme.muted) { w.onClose() }
                    OutlineButton(title: w.console.map { "应用 \($0.name) 配置" } ?? "应用", icon: "checkmark", color: Theme.ok) {
                        if let c = w.console { w.onApply(c) }
                    }
                    .disabled(w.console == nil)
                    .opacity(w.console == nil ? 0.4 : 1)
                }
                .padding(14)
            }
            .frame(width: 640)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
            .shadow(color: .black.opacity(0.6), radius: 30, y: 10)
        }
    }

    private func card(_ c: Console) -> some View {
        let sel = w.console == c
        return Button { w.console = c } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(c.name).font(.system(size: 15, weight: .bold)).foregroundStyle(sel ? Theme.accent : Theme.text)
                Text(c.gta6).font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                Theme.border.frame(height: 1).padding(.vertical, 2)
                row("主机输出", c.output, c.outputWhy)
                row("补帧", "开", "30 帧补到 60 帧")
                row("锐化", c.sharpName, c.sharpWhy)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(sel ? Theme.accent.opacity(0.08) : Theme.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(sel ? Theme.accent : Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func row(_ k: String, _ v: String, _ why: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(k).font(.system(size: 11)).foregroundStyle(Theme.faint).frame(width: Lang.english ? 92 : 52, alignment: .leading)
                Text(v).font(.system(size: 12, weight: .semibold))
            }
            Text(why).font(.system(size: 10)).foregroundStyle(Theme.faint).padding(.leading, Lang.english ? 98 : 58).fixedSize(horizontal: false, vertical: true)
        }
    }
}
