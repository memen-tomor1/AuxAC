import Foundation
import ServiceManagement

/// 「登录时自动打开」。两条路，自动选：
///
/// ## 1. `SMAppService.mainApp`（macOS 13+，优先）
///
/// 系统托管，优点明确：App 换位置它自动跟上，用户能在
/// 「系统设置 → 通用 → 登录项」里看到并手动关掉，不需要我们解释怎么注销。
///
/// **但它挑位置和签名。** 实测：本工程放在 `auxac-mac/build/` 下时
/// `SMAppService.mainApp.status` 是 `.notFound`——系统的原话是「找不到本 App」。
/// 同一个 bundle 从别处跑也一样，因为 ad-hoc 签名 + 不在 `/Applications`
/// 这两条它都不认。所以不能只靠它。
///
/// ## 2. `~/Library/LaunchAgents/<label>.plist`（兜底）
///
/// 老办法，但对 ad-hoc 签名和任意路径都有效。`RunAtLoad` + 放在 `LaunchAgents`
/// 目录里，launchd 下次登录时自己会加载，**不需要 `launchctl bootstrap`**——
/// 而且刻意不 bootstrap：那会立刻把 App 再启动一份，用户只是拨了个开关，
/// 不应该凭空多出一个进程。
///
/// plist 里写的是**可执行文件的绝对路径**，所以 App 一挪目录登录项就指向空气。
/// 对策：`setEnabled` 每次都会重写 plist（`refreshIfEnabled()` 在 App 启动时也会调），
/// 路径变了下次启动就自愈。用户不需要知道这件事。
///
/// 两条路的取舍写在 `describe()` 里，界面上会把当前用的是哪条显示出来。
enum LaunchAtLogin {

    /// 与 `Info.plist` 的 `CFBundleIdentifier` 保持一致。
    static let label = "com.local.auxac"

    static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    // MARK: - 查询

    /// 系统当前是否认为我们已登记（两条路任意一条生效即算）。
    ///
    /// `.requiresApproval` 也算「已登记」——那表示登记成功了，只是等用户在
    /// 「系统设置 → 通用 → 登录项」里点一下允许。界面上的开关要显示成「开」，
    /// 否则用户会以为没生效而反复拨。
    static var isRegistered: Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval: return true
        default: return FileManager.default.fileExists(atPath: agentURL.path)
        }
    }

    /// 走的是哪条路。给界面和自检用。
    static var mechanism: String {
        switch SMAppService.mainApp.status {
        case .enabled:           return "系统登录项（enabled）"
        case .requiresApproval:  return "系统登录项（等你在「系统设置 → 通用 → 登录项」里批准）"
        default:
            return FileManager.default.fileExists(atPath: agentURL.path)
                ? "LaunchAgent（\(agentURL.path)）"
                : "未设置"
        }
    }

    /// 给自检/排错用的一句话状态。
    static func describe() -> String {
        let sm: String
        switch SMAppService.mainApp.status {
        case .enabled:          sm = "enabled"
        case .notRegistered:    sm = "notRegistered"
        case .requiresApproval: sm = "requiresApproval"
        case .notFound:         sm = "notFound"
        @unknown default:       sm = "unknown"
        }
        let agent = FileManager.default.fileExists(atPath: agentURL.path) ? "有" : "无"
        return "SMAppService=\(sm) · LaunchAgent=\(agent) · 当前生效：\(mechanism)"
    }

    // MARK: - 开关

    /// 打开/关闭。返回 `nil` 表示成功，否则是给用户看的原因。
    static func setEnabled(_ on: Bool) -> String? {
        if on {
            // 先试系统托管那条路。它要求 App 在 /Applications 里且有有效签名，
            // 不满足时 register() 会抛，或者 status 直接就是 .notFound。
            if SMAppService.mainApp.status != .enabled {
                do {
                    try SMAppService.mainApp.register()
                    removeAgent()          // 别两条路同时生效，登录时会起两份
                    return nil
                } catch {
                    // 落到 LaunchAgent。系统给的那句错误留着，两条都失败时一起报。
                    do {
                        try writeAgent()
                        return nil
                    } catch let agentError {
                        return "系统登录项失败（\(error.localizedDescription)），"
                             + "退回 LaunchAgent 也失败（\(agentError.localizedDescription)）"
                    }
                }
            }
            removeAgent()
            return nil
        } else {
            var firstError: String?
            if SMAppService.mainApp.status == .enabled
                || SMAppService.mainApp.status == .requiresApproval {
                do { try SMAppService.mainApp.unregister() }
                catch { firstError = error.localizedDescription }
            }
            removeAgent()   // 删文件不抛错；万一删不掉，下次 isRegistered 读文件系统会看到它
            return firstError
        }
    }

    /// App 启动时调一次：如果 LaunchAgent 是开的，把 plist 按**当前**路径重写一遍。
    ///
    /// 这样 App 被挪到别处之后，不需要用户重新拨开关，下次启动就自愈了。
    /// 只在「正在用 LaunchAgent」时才动文件——用系统登录项时不该多写一个 plist。
    static func refreshIfEnabled() {
        let usingAgent = FileManager.default.fileExists(atPath: agentURL.path)
            && SMAppService.mainApp.status != .enabled
        guard usingAgent else { return }
        try? writeAgent()
    }

    // MARK: - LaunchAgent 的实现

    /// plist 的内容。抽出来是为了 `--login-probe` 能在**不写文件**的前提下
    /// 把它打印出来核对（写 `~/Library/LaunchAgents` 是用户点开关时才该发生的事）。
    static func agentPlist() throws -> [String: Any] {
        guard let executable = Bundle.main.executablePath else {
            throw NSError(domain: label, code: 1, userInfo: [
                NSLocalizedDescriptionKey: "拿不到可执行文件路径（不在 .app 外壳里跑？）"
            ])
        }
        return [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            // 只在图形登录会话里跑。不加这个的话，ssh 登录也会把它拉起来一份。
            "LimitLoadToSessionType": "Aqua",
            // 不设 KeepAlive：用户主动退出 App 之后不该被 launchd 反复拉起来。
            "KeepAlive": false,
        ]
    }

    private static func writeAgent() throws {
        let plist = try agentPlist()
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(
            at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: agentURL, options: .atomic)
    }

    private static func removeAgent() {
        try? FileManager.default.removeItem(at: agentURL)
    }
}
