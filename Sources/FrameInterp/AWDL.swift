#if FI_XNATIVE
import AppKit
import SwiftUI

// MARK: - 一键关 / 开 AWDL（2026-11-28）
// AWDL 是隔空投送、接力、随航用的无线直连。开着时 Wi-Fi 网卡大约每 0.5 秒切一次频道，原生串流会顿 ~100ms
// （用户手动 sudo ifconfig awdl0 down 实测：抖动 95% 分位 80 → 14ms）。客户端挡不住，只能临时关掉网卡。
// 关 / 开要管理员权限：用 AppleScript 的 "with administrator privileges"，系统弹窗让用户自己输密码（程序拿不到密码）。
// 重启后、或者系统要用隔空投送时，AWDL 会自己再开。读状态不用权限（ifconfig awdl0 的 UP 标志）。

enum AWDL {
    /// awdl0 开着吗；没有这个网卡返回 nil
    static func isUp() -> Bool? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
        p.arguments = ["awdl0"]
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let s = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8),
              let first = s.split(separator: "\n").first else { return nil }
        return first.contains("<UP,") || first.contains("<UP>")
    }

    /// 关（up = false）或开 AWDL。系统弹窗要管理员密码；返回错误说明（用户点取消返回 "已取消"），成功返回 nil
    @MainActor static func set(up: Bool) -> String? {
        let cmd = "/sbin/ifconfig awdl0 \(up ? "up" : "down")"
        var err: NSDictionary?
        let script = NSAppleScript(source: "do shell script \"\(cmd)\" with administrator privileges with prompt \"\(L(up ? "FrameInterp 要恢复 AWDL（隔空投送 / 接力）。" : "FrameInterp 要临时关闭 AWDL（隔空投送 / 接力），让 Wi-Fi 串流不再周期性卡顿。"))\"")
        script?.executeAndReturnError(&err)
        if let err {
            let code = err[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -128 { return "已取消" }
            let msg = err[NSAppleScript.errorMessage] as? String ?? "\(err)"
            Log.write("AWDL：\(up ? "恢复" : "关闭")失败 \(code) \(msg)")
            return msg
        }
        Log.write("AWDL：已\(up ? "恢复" : "关闭")（用户点的）")
        return nil
    }
}

/// 首页 Xbox 齿轮里的一行：AWDL 状态 + 一键关 / 恢复
struct AWDLField: View {
    @State private var up: Bool? = AWDL.isUp()
    @State private var note = ""
    private let tick = Timer.publish(every: 3, on: .main, in: .common).autoconnect()   // 系统可能自己又打开，开着弹窗时每 3 秒看一次

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: up == false ? "checkmark.circle.fill" : "wifi.exclamationmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(up == false ? Theme.ok : Theme.amber)
                Text("Wi-Fi 防卡顿（关 AWDL）").font(.system(size: 12, weight: .semibold))
                Spacer()
                if let up {
                    SmallButton(title: up ? "一键关闭" : "恢复") {
                        note = ""
                        if let e = AWDL.set(up: !up), e != "已取消" { note = e }
                        self.up = AWDL.isUp()
                    }
                }
            }
            Text(up == nil ? "这台 Mac 没有 AWDL 网卡，不用管"
                 : up! ? "AWDL 开着：Wi-Fi 串流可能每 0.5 秒顿一下。关掉要输一次电脑密码"
                 : "已关：串流更稳。隔空投送、接力、随航暂时不能用；点「恢复」或重启电脑就回来")
                .font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            if !note.isEmpty {
                Text(note).font(.system(size: 11)).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onReceive(tick) { _ in let v = AWDL.isUp(); if v != up { up = v } }
    }
}
#endif
