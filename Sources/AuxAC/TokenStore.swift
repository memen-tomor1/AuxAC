import Foundation

/// 登录凭据的本地持久化。
///
/// 存到 `~/Library/Application Support/AuxAC/session.json`，文件权限 0600。
/// 用明文 JSON 而不是 Keychain 是刻意的取舍：token 有 `expireAt`、会过期，
/// 且登录必须人工收短信，安全等级不高；换成 Keychain 会让调试与清理都变麻烦。
struct Credentials: Codable {
    var token: String
    var phone: String
    /// Unix 秒级时间戳，来自接口的 `expireAt`。语义见 PROTOCOL.md #3：
    /// 可能是「过期时刻」也可能是「有效期秒数」，读取时两种都兜底。
    var expireAt: Double?

    /// 转换成绝对过期时间。
    var expiryDate: Date? {
        guard let e = expireAt, e > 0 else { return nil }
        // 大于这个阈值就当成绝对时间戳；否则当成「还有多少秒」
        if e > 1_600_000_000 {
            return Date(timeIntervalSince1970: e)
        }
        return Date().addingTimeInterval(e)
    }

    var isExpired: Bool {
        guard let d = expiryDate else { return false }  // 没给过期时间就不主动判定过期
        return Date() >= d.addingTimeInterval(-60)      // 提前 1 分钟视为过期
    }
}

enum TokenStore {
    private static var dirURL: URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AuxAC", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static var fileURL: URL { dirURL.appendingPathComponent("session.json") }

    static func load() -> Credentials? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }

    static func save(_ creds: Credentials) {
        guard let data = try? JSONEncoder().encode(creds) else { return }
        try? data.write(to: fileURL, options: [.atomic])
        // 收紧权限，避免同机其他用户读到 token
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    static var path: String { fileURL.path }
}
