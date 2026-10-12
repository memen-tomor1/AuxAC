import Foundation

/// `auxac://` URL 命令——本 App 的自动化入口。
///
/// ## 为什么是 URL scheme，而不是真正的「App Intents」
///
/// 苹果现在推荐用 App Intents 给快捷指令提供原生动作，但那要求 Xcode 在构建时
/// 额外跑 `appintentsmetadataprocessor`，把 `Metadata.appintents` 塞进 bundle。
/// 本工程是 `swiftc` 直接编译的（原因见 `build.sh` 顶部注释），做不了这一步，
/// 硬写上也不会被系统发现。所以走 URL scheme：效果一样，且对**任何**能执行
/// `open` 的东西都可用。
///
/// ## 谁能用
///
/// | 谁 | 怎么调 |
/// |---|---|
/// | 快捷指令（Shortcuts.app） | 「打开 URL」动作，填 `auxac://on` |
/// | AppleScript | `do shell script "open 'auxac://on'"` |
/// | 终端 / Alfred / Raycast / Hammerspoon | `open 'auxac://on'` |
/// | 定时任务（launchd / cron） | 同上 |
///
/// 一个**做不到**的命令：没有「把面板弹开」这一条。`MenuBarExtra` 的面板由系统托管，
/// 没有公开 API 能从代码里展开它（`NSApp.activate` 也没用）。与其写一个假装能用的
/// 命令，不如不写。
///
/// ⚠️ 中文输入法下别手打 URL——冒号和斜杠容易被替换成全角，`open` 会报
/// `The file ... does not exist`。复制粘贴最稳。
///
/// ## 命令表
///
/// 完整列表见 `AuxCommand.helpText()`（`open 'auxac://help'` 也能看）。
enum AuxCommand: Equatable {
    case power(Bool)
    case toggle
    case temperature(Double)
    case nudge(Double)
    case mode(ACMode)
    case fan(FanSpeed)
    case screen(Bool)
    case refresh
    case help

    // MARK: - 解析

    /// 解析 `auxac://…`。
    ///
    /// 两种写法都收：
    /// * `auxac://on` —— 短，适合手打。这时 `on` 落在 URL 的 **host** 上。
    /// * `auxac://temp/24.5` —— 带参数。这时 `temp` 是 host、`24.5` 是 path。
    ///
    /// 也兼容 `auxac://temp?value=24.5` 这种 query 写法（有些工具会把路径吃掉）。
    static func parse(_ url: URL) -> AuxCommand? {
        guard url.scheme?.lowercased() == "auxac" else { return nil }

        // `pathComponents` 对 "auxac://temp/24.5" 给 ["/", "24.5"]，先滤掉根。
        let parts = url.pathComponents.filter { $0 != "/" }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "value" })?.value

        // host 为空时（写成 `auxac:///on` 这类）退回第一个 path 段。
        let verbSource = (url.host?.isEmpty == false) ? url.host! : (parts.first ?? "")
        let verb = verbSource.lowercased()
        let argument = (url.host?.isEmpty == false) ? parts.first : (parts.count > 1 ? parts[1] : nil)
        let raw = argument ?? query

        switch verb {
        case "on", "power-on":
            return .power(true)
        case "off", "power-off":
            return .power(false)
        case "toggle":
            return .toggle

        case "temp", "temperature":
            guard let raw else { return nil }
            // 带正负号的是**微调**（`temp/+0.5`），不带的是**绝对值**（`temp/24.5`）。
            // 判断必须在 `number()` 之前做——它会把前导 `+` 吃掉。
            // 注意 `%2B` 也要算数：URL 编码后的 `+` 是我们的明确意图，不是空格。
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let isRelative = trimmed.hasPrefix("+") || trimmed.hasPrefix("-")
                || trimmed.hasPrefix("%2B") || trimmed.hasPrefix("%2b")
                || trimmed.hasPrefix("＋") || trimmed.hasPrefix("－")
            guard let value = number(raw) else { return nil }
            return isRelative ? .nudge(value) : .temperature(value)

        case "warmer", "up":
            return .nudge(+0.5)
        case "cooler", "down":
            return .nudge(-0.5)
        case "nudge":
            guard let raw, let value = number(raw), value != 0 else { return nil }
            return .nudge(value)

        case "mode":
            guard let raw, let mode = mode(named: raw) else { return nil }
            return .mode(mode)

        case "fan", "wind":
            guard let raw, let fan = fan(named: raw) else { return nil }
            return .fan(fan)

        case "screen":
            guard let raw else { return .screen(true) }   // `auxac://screen` 默认开
            switch raw.lowercased() {
            case "on", "1", "true", "open":  return .screen(true)
            case "off", "0", "false", "close": return .screen(false)
            default: return nil
            }

        case "refresh":
            return .refresh

        case "help", "?":
            return .help

        default:
            return nil
        }
    }

    /// 接受 `24.5` / `+0.5` / `-0.5` / `24,5`（中文输入法的逗号）。
    ///
    /// `+` 必须显式处理：URL 里 `+` 在 **query** 中传统上代表空格，
    /// 有些工具会替我们转义成 `%2B` 或干脆转成空格，所以三种都收。
    static func number(_ raw: String) -> Double? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        s = s.replacingOccurrences(of: ",", with: ".")
        s = s.replacingOccurrences(of: "%2B", with: "+")
        s = s.replacingOccurrences(of: "＋", with: "+")
        s = s.replacingOccurrences(of: " ", with: "+")   // query 里 `+` 被解成空格的情况
        if s.hasPrefix("+") { s.removeFirst() }
        return Double(s)
    }

    static func mode(named raw: String) -> ACMode? {
        switch raw.lowercased() {
        case "cool", "cold", "制冷", "1": return .cool
        case "heat", "hot", "制热", "4":  return .heat
        case "dry", "dehumidify", "除湿", "2": return .dry
        case "fan", "wind", "送风", "6":  return .fan
        default: return nil
        }
    }

    static func fan(named raw: String) -> FanSpeed? {
        switch raw.lowercased() {
        case "auto", "自动", "4":      return .auto
        case "quiet", "silent", "静音", "3": return .quiet
        case "low", "低", "低档", "0":  return .low
        case "mediumlow", "medlow", "中低", "6": return .mediumLow
        case "medium", "mid", "中", "中档", "1": return .medium
        case "mediumhigh", "medhigh", "中高", "7": return .mediumHigh
        case "high", "高", "高档", "2": return .high
        default: return nil
        }
    }

    // MARK: - 帮助

    /// 给用户抄的命令表。`open 'auxac://help'` 会把这整段弹到状态栏提示里。
    static func helpText() -> String {
        """
        auxac:// 命令：
          on / off / toggle          开关机
          temp/24.5                  设目标温度（16–32，支持 .5）
          temp/+0.5  temp/-0.5       微调
          warmer / cooler            等同于上面两条
          mode/cool|heat|dry|fan     切模式
          fan/auto|quiet|low|mediumlow|medium|mediumhigh|high   切风速
          screen/on|off              屏显
          refresh                    立刻拉一次状态
          help                       打印这张表

        用法：open 'auxac://on'      （终端 / AppleScript / 快捷指令「打开 URL」都一样）
        注意：中文输入法会把 : 和 / 打成全角，手打容易失败，复制粘贴最稳。
        """
    }
}

/// URL 与 `AppModel` 之间的中转站。
///
/// 为什么不把 `AppModel` 直接塞进 `AppDelegate`：`@NSApplicationDelegateAdaptor`
/// 创建的 delegate 比 SwiftUI 的 `@StateObject` **先**出生，那个时刻还没有 model
/// 实例可拿。所以 delegate 只负责把 URL 投递到这里，由 model 在自己的 init 里订阅。
///
/// 冷启动时（App 没在跑，直接 `open 'auxac://on'`）URL 会先于订阅到达，
/// 所以 `deliver` 在没有订阅者时先存着，等第一个订阅者来了再补投。
final class URLRouter {
    static let shared = URLRouter()

    private var observers: [(URL) -> Void] = []
    private var buffered: [URL] = []

    private init() {}

    func subscribe(_ observer: @escaping (URL) -> Void) {
        observers.append(observer)
        let pending = buffered
        buffered.removeAll()
        for url in pending { observer(url) }
    }

    func deliver(_ url: URL) {
        guard !observers.isEmpty else {
            buffered.append(url)
            return
        }
        for observer in observers { observer(url) }
    }
}
