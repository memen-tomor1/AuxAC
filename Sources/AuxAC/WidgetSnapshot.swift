import Foundation

/// 桌面/通知中心小组件（WidgetKit）跟主 App **不在一个进程里**，拿不到 `AppModel`，
/// 也没法用 App Group 共享容器 —— App Group 的 entitlement 要有 Team ID 才生效，
/// 而本工程是 ad-hoc 匿名签名（`TeamIdentifier=not set`，见 README）。
///
/// 所以走最土也最稳的办法：主 App 每次刷完状态，就把一份**只读快照**写到
/// `~/Library/Application Support/AuxAC/widget.json`，小组件去读这个文件。
/// 两个进程都跑在同一个用户下，不涉及任何权限提升，也不需要沙箱豁免。
///
/// ## 快照里为什么没有 token
///
/// 交互式小组件（点一下开关机）确实需要凭据，但**不该在第二个文件里再存一份**——
/// 那样凭据就从「一个文件、一处权限」变成两处，将来清理或改权限时容易漏。
/// 小组件要用 token 就自己去读 `session.json`（同一个目录，同样 0600）。
/// 这个类只负责状态。
enum WidgetSnapshot {

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AuxAC", isDirectory: true)
    }

    static var url: URL { directory.appendingPathComponent("widget.json") }

    /// 写一份快照。
    ///
    /// `device` 传 `nil` 表示「登录了但账号下没有设备」。这时**也要写**文件，
    /// 否则小组件读不到文件，只能一直显示占位内容，跟「还没登录」分不开。
    /// 区分这几种状态对用户是有意义的，所以状态用 `state` 字段显式表达。
    /// 返回值是「看得见的内容变了没有」，调用方据此决定要不要让 WidgetKit 重画。
    ///
    /// 为什么要这个判断：WidgetKit 对每个小组件的刷新次数有每日配额，
    /// 主 App 每 30 秒刷新一次、每次都喊一声「重画」的话，配额几小时就烧光，
    /// 之后反而变成系统挑时间刷新，桌面上的数字会更不准。
    @discardableResult
    static func write(device: Device?, displayName: String?, state: String) -> Bool {
        var obj: [String: Any] = [
            "version": 1,
            "state": state,                       // "ok" | "empty" | "loggedOut"
            "updatedAt": Date().timeIntervalSince1970,
        ]
        if let d = device {
            obj["did"] = d.did
            obj["pk"] = d.pk
            obj["alias"] = displayName ?? d.displayName
            obj["online"] = d.online ?? true
            // 直接把服务端那份 `data` 原样带过去：字段名以后变了，
            // 小组件和主 App 用的是同一套原始键，不用两处同步维护。
            if let data = d.data,
               let encoded = try? JSONEncoder().encode(data),
               let plain = try? JSONSerialization.jsonObject(with: encoded) {
                obj["data"] = plain
            }
        }
        // 比变化时把 `updatedAt` 摘掉，否则每次写都必然「变了」。
        var previous: [String: Any] = [:]
        if let raw = try? Data(contentsOf: url),
           let o = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] {
            previous = o
        }
        previous.removeValue(forKey: "updatedAt")
        var comparable = obj
        comparable.removeValue(forKey: "updatedAt")
        let changed = !NSDictionary(dictionary: comparable).isEqual(to: previous)

        guard let out = try? JSONSerialization.data(
            withJSONObject: obj, options: [.sortedKeys]) else { return false }
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try? out.write(to: url, options: .atomic)
        return changed
    }
}
