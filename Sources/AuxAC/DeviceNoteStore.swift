import Foundation

/// 设备备注（用户自己起的名字）的本地持久化。
///
/// 存到 `~/Library/Application Support/AuxAC/notes.json`，权限 0600，键是设备的 `did`。
///
/// 为什么不做成云端改名：DEX 里确实有 `device/updateAlias` 路由，改完手机 App
/// 也能看到，但那会**覆盖设备原本的 alias**、在 AUX 服务器上留痕，且没有撤销按钮。
/// 备注的定位是「只有我在这个工具里看到的标记」，所以放本地最合适。
/// 代价是换一台 Mac 需要重设（但不会影响空调本身，也不会被 App 覆盖）。
enum DeviceNoteStore {
    private static var dirURL: URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AuxAC", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static var fileURL: URL { dirURL.appendingPathComponent("notes.json") }

    static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    static func save(_ notes: [String: String]) {
        guard let data = try? JSONEncoder().encode(notes) else { return }
        try? data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    static var path: String { fileURL.path }
}
