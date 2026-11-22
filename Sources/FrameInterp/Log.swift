import Foundation

/// 同时写到终端和日志文件：~/Library/Logs/FrameInterp/年月日-时分秒.log
/// （从 Finder 打开时没有终端，统计只能靠日志文件留下来）
enum Log {
    private static let queue = DispatchQueue(label: "log")
    private static var handle: FileHandle?
    private(set) static var path: String?

    static func open() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/FrameInterp")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let url = dir.appendingPathComponent("\(f.string(from: Date())).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        path = url.path
        // 只保留最近 20 个日志
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "log" }).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }), files.count > 20 {
            for old in files.dropFirst(20) { try? FileManager.default.removeItem(at: old) }
        }
    }

    static func write(_ s: String) {
        print(s)
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        let line = "\(f.string(from: Date())) \(s)\n"
        queue.async { handle?.write(line.data(using: .utf8)!) }
    }
}
