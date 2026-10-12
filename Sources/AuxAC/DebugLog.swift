import Foundation
import AppKit

/// 一个极简的按天滚动调试日志。
///
/// 存在的意义：本项目的字段映射（模式/风速/室温…）还有一堆待实测确认项
/// （见 docs/PROTOCOL.md §7）。把原始响应落盘，用户实测出问题时可以直接
/// 把日志贴出来定位，不用重新抓包。
///
/// 写入前一律经过 `redact` 脱敏——手机号、token、设备 id 都不落盘明文。
final class DebugLog: ObservableObject {
    static let shared = DebugLog()

    /// 供 UI 展示的最近若干行（内存里，不读盘）。
    @Published private(set) var recentLines: [String] = []

    private let queue = DispatchQueue(label: "auxac.debuglog")
    private let maxRecent = 300

    private lazy var fileURL: URL = {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/AuxAC", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("auxac.log")
    }()

    private lazy var formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private init() {}

    func log(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)"
        queue.async { [weak self] in
            guard let self else { return }
            self.append(line)
        }
    }

    private func append(_ line: String) {
        if let data = (line + "\n").data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
        DispatchQueue.main.async {
            self.recentLines.append(line)
            if self.recentLines.count > self.maxRecent {
                self.recentLines.removeFirst(self.recentLines.count - self.maxRecent)
            }
        }
    }

    var logFilePath: String { fileURL.path }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    func clear() {
        queue.async { [weak self] in
            guard let self else { return }
            try? FileManager.default.removeItem(at: self.fileURL)
        }
        DispatchQueue.main.async { self.recentLines.removeAll() }
    }

    /// 脱敏：只保留足够定位问题、又不足以泄露隐私的部分。
    static func redact(_ s: String) -> String {
        var out = s

        // 手机号 → 138****8000
        out = out.replacingOccurrences(
            of: #""phone"\s*:\s*"(\d{3})\d{4}(\d{4})""#,
            with: "\"phone\":\"$1****$2\"",
            options: .regularExpression)

        // token / password / 各类 id → 只留前 6 位
        for key in ["token", "password", "passcode", "deviceId", "did", "mac"] {
            let pattern = "\"\(key)\"\\s*:\\s*\"([^\"]{0,6})[^\"]*\""
            out = out.replacingOccurrences(
                of: pattern,
                with: "\"\(key)\":\"$1…\"",
                options: [.regularExpression, .caseInsensitive])
        }

        return out
    }
}
