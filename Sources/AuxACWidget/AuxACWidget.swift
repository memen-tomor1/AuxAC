// 桌面 / 通知中心小组件（WidgetKit）。
//
// ⚠️ 这个文件**不能**被 build.sh 的主 App 编译命令带上（那条命令的源码通配是
// `Sources/AuxAC/*.swift`，而这个文件在 `Sources/AuxACWidget/`）。原因是它和主 App
// 有两个 `@main` 级别的冲突：小组件自己是 `@main struct AuxACWidgetBundle: WidgetBundle`，
// 主 App 是 `@main struct AuxACApp: App`，编到一起会报 "multiple 'main' types"。
//
// 小组件是**独立进程**，拿不到 `AppModel`，也读不到它的内存。两条数据渠道：
//
//   1. 状态 ← `~/Library/Application Support/AuxAC/widget.json`
//      主 App 每次刷新完就重写它（见主 App 的 `WidgetSnapshot.swift`）。
//   2. 凭据 ← `~/Library/Application Support/AuxAC/session.json`
//      只在用户真的点了开关机按钮时才读，读完即用，不缓存。
//
// 为什么不把 token 也塞进 widget.json：凭据副本越少越好。现在全项目只有
// `session.json` 一个 0600 文件装 token，加个小组件不该让它变成两个。
//
// 为什么不用 App Group 共享容器：App Group 的 entitlement 要 Team ID 才生效，
// 本工程是 ad-hoc 匿名签名（`TeamIdentifier=not set`）。用普通文件是唯一走得通的路。

import AppIntents
import SwiftUI
import WidgetKit

// MARK: - 共享路径

/// 取**真实**的用户家目录。
///
/// 小组件是**沙箱**进程（见 `Sources/AuxACWidget/AuxACWidget.entitlements`），
/// 而 `FileManager.homeDirectoryForCurrentUser` 在沙箱里未必给真实家目录——
/// 一旦它返回扩展自己的容器路径（`~/Library/Containers/com.local.auxac.AuxACWidget/Data`），
/// 就再也找不到主 App 写的 `widget.json` 和 `session.json` 了，
/// 表现是小组件永远显示「未登录」。
///
/// 直接问 POSIX 要 `pw_dir` 最稳：这个值来自用户数据库，跟进程沙箱无关。
func auxRealHome() -> URL {
    if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
        return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
}

/// 主 App 与小组件约定的共享目录。
func auxSharedDirectory() -> URL {
    auxRealHome().appendingPathComponent("Library/Application Support/AuxAC", isDirectory: true)
}

// MARK: - 数据

/// 从 `widget.json` 解出来的设备状态。
///
/// 刻意**不用 Codable**：快照是主 App 用 `JSONSerialization` 写的，
/// 字段会随服务端变化（我们连室温字段都测出来「不存在」过），
/// 用 `[String: Any]` 加候选键名逐个取值，比写一堆 `Decodable` 更能扛住字段改名——
/// 这也正是主 App 里 `ACState` 的做法，两边保持一致。
/// ⚠️ 必须 `Codable`：WidgetKit 会把 timeline entry 归档到 chronod 的 store 里，
/// 不能编码的 entry 会让 store 报 `Encountered missing entry` / `Marking variant
/// removed from store`，于是桌面活跃时小组件退化成「灰条 + 方块」占位骨架
/// （图标变方框、数字文字全不见）。加 Codable 前就是这个症状。
struct ACStatus: Codable {
    var state: String = "empty"      // ok / empty / loggedOut
    var alias: String = "奥克斯空调"
    var did: String = ""
    var online: Bool = true
    var isOn: Bool = false
    var temperature: Double?
    var modeRaw: Int?
    var fanRaw: Int?
    var updatedAt: Date?

    static let placeholder = ACStatus(state: "empty", alias: "奥克斯空调")

    // 取值时把「数字」和「字符串数字」都当数字用：服务端两种都发过
    // （`dataOne` 是 "32" 字符串，`on_off` 是 1 数字）。
    private static func int(_ v: Any?) -> Int? {
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) }
        return nil
    }

    static func load() -> ACStatus {
        var st = ACStatus()
        let url = auxSharedDirectory().appendingPathComponent("widget.json")
        guard let raw = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else {
            // 文件不存在 = 主 App 从没跑过（或刚装上）。当成「未登录」，
            // 界面上要给出可操作的指引，而不是一个空白方块。
            st.state = "loggedOut"
            return st
        }
        st.state = (obj["state"] as? String) ?? "ok"
        st.alias = (obj["alias"] as? String) ?? "奥克斯空调"
        st.did = (obj["did"] as? String) ?? ""
        st.online = (obj["online"] as? NSNumber)?.boolValue ?? true
        if let ts = obj["updatedAt"] as? NSNumber {
            st.updatedAt = Date(timeIntervalSince1970: ts.doubleValue)
        }

        let data = (obj["data"] as? [String: Any]) ?? [:]
        st.isOn = (int(data["on_off"]) ?? 0) != 0
        st.modeRaw = int(data["air_con_func"]) ?? int(data["mode"])
        st.fanRaw = int(data["wind_speed_1"]) ?? int(data["wind_speed"])

        // 温度是整数 + 半度两个字段拼的：23 + decimal 5 → 23.5。
        // `half` 是另一个候选（老机型用它），三个都认。
        if let whole = int(data["temperature"]) {
            let dec = int(data["temperature_decimal"]) ?? ((int(data["half"]) ?? 0) != 0 ? 5 : 0)
            st.temperature = Double(whole) + (dec >= 5 ? 0.5 : 0)
        }
        return st
    }

    /// 显示用的温度文本。半度才带小数——`23.0°` 看着像没读到值。
    var temperatureText: String {
        guard let t = temperature else { return "--" }
        return t == t.rounded() ? "\(Int(t))°" : String(format: "%.1f°", t)
    }

    /// 按固定顺序循环的模式。**故意不含 0（自动）**——本机 `feature.mode`
    /// 只声明 1,2,3,4，自动档没在真机上验证过，宁可不给。
    static let cycleModes = [1, 2, 4, 6]

    static func modeName(_ raw: Int?) -> String {
        switch raw {
        case 0: return "自动"
        case 1: return "制冷"
        case 2: return "除湿"
        case 4: return "制热"
        case 6: return "送风"
        default: return "—"
        }
    }

    static func modeSymbol(_ raw: Int?) -> String {
        switch raw {
        case 0: return "arrow.triangle.2.circlepath"
        case 1: return "snowflake"
        case 2: return "drop"
        case 4: return "sun.max"
        case 6: return "wind"
        default: return "power"
        }
    }

    var modeName: String { ACStatus.modeName(modeRaw) }

    var modeSymbol: String { ACStatus.modeSymbol(modeRaw) }

    /// 送风/自动模式下温度没有意义——`ControlMutex.temperature` 用的就是这条判断。
    /// 小组件里没法弹提示，只能把按钮灰掉，所以要在这儿自己判一次。
    var canAdjustTemperature: Bool {
        modeRaw != 6 && modeRaw != 0
    }

    /// 下一个模式（循环）。当前模式认不出来时从头开始。
    var nextModeRaw: Int {
        let list = ACStatus.cycleModes
        guard let i = list.firstIndex(of: modeRaw ?? -1) else { return list[0] }
        return list[(i + 1) % list.count]
    }

    var fanName: String {
        switch fanRaw {
        case 0: return "低档"
        case 1: return "中档"
        case 2: return "高档"
        case 3: return "静音"
        case 4: return "自动"
        case 5: return "强力"
        case 6: return "中低"
        case 7: return "中高"
        default: return "—"
        }
    }
}

// MARK: - 控制（交互式小组件用）

/// 小组件里那个开关机按钮真正干活的地方。
///
/// 它在**小组件自己的进程**里跑，所以不能复用主 App 的 `AuxAPI`——那个类依赖
/// `AppModel` 的一堆状态。这里只保留最小的一发请求，形状必须和主 App 完全一致：
///
/// - `POST https://smarthome.aux-home.com/app/device/v2/control`
/// - body `{"intent":{"on_off":N},"deviceId":"<did>"}`
/// - 头 `Authorization: Bearer <token>`（**前缀不能省**，省了必回 60106）
///
/// 踩过的坑都记在这里，因为这个文件是唯一一处「不经过主 App 直接打云 API」的代码：
/// body 里键必须是 `intent`、设备标识必须放 `deviceId`（放 `did` 回 -100 参数不正确）。
enum WidgetControl {

    enum ControlError: LocalizedError {
        case notLoggedIn
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .notLoggedIn: return "还没登录，请先在菜单栏 App 里登录"
            case .http(let code, let msg): return "服务端返回 \(code)：\(msg)"
            }
        }
    }

    /// 主 App 留下的凭据。
    private static func loadToken() -> String? {
        let url = auxSharedDirectory().appendingPathComponent("session.json")
        guard let raw = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any]
        else { return nil }
        let token = obj["token"] as? String
        // 本地也判一次过期：token 一过就必然 60106，白跑一趟网络还多等两秒。
        if let exp = (obj["expireAt"] as? NSNumber)?.doubleValue,
           exp < Date().timeIntervalSince1970 {
            return nil
        }
        return token?.isEmpty == false ? token : nil
    }

    /// 所有控制都走这一个出口。
    ///
    /// body 必须是 `{"intent": {...}, "deviceId": "<did>"}`：
    /// - 键名是 `intent`，不是 `action`；发裸键（比如直接把 `{"wind_speed":5}` 当 body）
    ///   服务端回 `{"code":-100,"message":"参数不正确"}`，**连 on_off 都不会生效**。
    /// - 设备标识必须放 `deviceId`，放 `did` 同样回 -100。
    static func send(_ intent: [String: Any]) async throws {
        let st = ACStatus.load()
        guard st.did.isEmpty == false else { throw ControlError.notLoggedIn }
        guard let token = loadToken() else { throw ControlError.notLoggedIn }

        var req = URLRequest(url: URL(string:
            "https://smarthome.aux-home.com/app/device/v2/control")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("AUXHome/1.0 (iPhone; iOS) okhttp/3.12.0",
                     forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "intent": intent,
            "deviceId": st.did,
        ])

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let biz = (obj?["code"] as? NSNumber)?.intValue ?? -1
        // 200 不够：服务端「收到但懒得动」也回 200，得看 body 里的业务码。
        guard code == 200, biz == 200 else {
            let msg = (obj?["message"] as? String) ?? "HTTP \(code)"
            throw ControlError.http(biz != -1 ? biz : code, msg)
        }
    }

    /// 翻转开关机。`to` 由调用方按当前状态算好——小组件里没有「本地乐观状态」，
    /// 我们只下发一个明确的目标值，然后请系统重画时间线。
    static func setPower(_ to: Bool) async throws {
        try await send(["on_off": to ? 1 : 0])
    }

    /// 目标温度。**实测直接下发浮点摄氏度即可**（`{"temperature":24.5}` 被接受），
    /// 设备自己拆整数部分与小数位；不要再自己拆成
    /// `temperature` + `temperature_decimal` + `half` 三个字段发，那样会互相覆盖。
    static func setTemperature(_ celsius: Double) async throws {
        let clamped = min(32.0, max(16.0, celsius))
        try await send(["temperature": (clamped * 2).rounded() / 2])
    }

    /// 模式。字段名是 `air_con_func`——发 `{"mode":...}` 服务端回 200 但**不生效**。
    static func setMode(_ raw: Int) async throws {
        try await send(["air_con_func": raw])
    }
}

/// 小组件上的开关机按钮。macOS 14 起小组件才能放可点的按钮。
struct TogglePowerIntent: AppIntent {
    static var title: LocalizedStringResource = "开关空调"
    static var description = IntentDescription("切换奥克斯空调的开关机状态")

    /// 目标状态由按钮所在的那次时间线渲染决定，不在 intent 里猜。
    @Parameter(title: "开机")
    var to: Bool

    init() {}
    init(to: Bool) { self.to = to }

    func perform() async throws -> some IntentResult {
        try await WidgetControl.setPower(to)
        // 让系统立刻重画：否则按钮点完要等下一个刷新周期才变色，
        // 用户会以为没点上而连点。
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

/// 中号小组件上的「−」/「+」。**步进 0.5°C**——这台机器原生支持半度
/// （状态里 `temperature` + `temperature_decimal` + `half` 三个字段就是为它准备的）。
///
/// 基准值取的是**小组件进程当下读到的快照**，不是点按钮那一刻的最新温度：
/// 连点两下「+」时，第二下可能还基于旧值算，结果只加了 0.5。
/// 这是刻意的取舍——小组件里没有跨进程的乐观状态，宁可按慢一点，
/// 也不要像主 App 那样维护一份会和服务端打架的本地覆盖值。
struct NudgeTemperatureIntent: AppIntent {
    static var title: LocalizedStringResource = "调节温度"
    static var description = IntentDescription("把目标温度上调或下调半度")

    @Parameter(title: "变化")
    var delta: Double

    init() {}
    init(delta: Double) { self.delta = delta }

    func perform() async throws -> some IntentResult {
        let current = ACStatus.load().temperature ?? 26
        try await WidgetControl.setTemperature(current + delta)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

/// 中号小组件上的「模式」按钮：按固定顺序切到下一个模式。
///
/// 为什么是「切下一个」而不是弹选择：小组件的按钮只能触发 intent，
/// 没法弹菜单（拉预算也大）。本机支持的四个模式正好够循环。
struct CycleModeIntent: AppIntent {
    static var title: LocalizedStringResource = "切换模式"
    static var description = IntentDescription("在制冷/除湿/制热/送风之间循环")

    @Parameter(title: "目标模式")
    var raw: Int

    init() {}
    init(raw: Int) { self.raw = raw }

    func perform() async throws -> some IntentResult {
        try await WidgetControl.setMode(raw)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

// MARK: - 时间线

struct AuxACEntry: TimelineEntry, Codable {
    let date: Date
    let status: ACStatus
}

struct AuxACProvider: TimelineProvider {

    func placeholder(in context: Context) -> AuxACEntry {
        var s = ACStatus.placeholder
        s.state = "ok"
        s.alias = "主卧空调"
        s.isOn = true
        s.temperature = 23.5
        s.modeRaw = 1
        s.fanRaw = 5
        return AuxACEntry(date: Date(), status: s)
    }

    func getSnapshot(in context: Context, completion: @escaping (AuxACEntry) -> Void) {
        let st = context.isPreview ? placeholder(in: context).status : ACStatus.load()
        completion(AuxACEntry(date: Date(), status: st))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AuxACEntry>) -> Void) {
        let entry = AuxACEntry(date: Date(), status: ACStatus.load())
        // 15 分钟只是兜底。真正让小组件跟着动的是主 App 每次刷新完调的
        // `WidgetCenter.reloadAllTimelines()`——WidgetKit 有刷新预算，
        // 靠这边自己高频轮询会被系统限流，反而更不准。
        let next = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

// MARK: - 视图

struct AuxACWidgetView: View {
    @Environment(\.widgetFamily) private var family
    /// 强调渲染模式。macOS 桌面小组件在「后台」（桌面不活跃）时，系统就会切到 `.accented`。
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: AuxACEntry

    private var s: ACStatus { entry.status }

    var body: some View {
        Group {
            switch s.state {
            case "loggedOut":
                message(icon: "person.crop.circle.badge.questionmark",
                        title: "未登录", detail: "在菜单栏图标里登录后即可显示")
            case "empty":
                message(icon: "air.conditioner.horizontal",
                        title: "没有空调", detail: "这个账号下还没有绑定设备")
            default:
                if family == .systemSmall { small } else { medium }
            }
        }
        // macOS 14 起小组件必须自己声明背景，否则系统会盖一层
        // 「请适配 containerBackground」的提示把内容挤掉。
        .containerBackground(for: .widget) {
            LinearGradient(colors: s.isOn
                           ? [Color.accentColor.opacity(0.22), Color.accentColor.opacity(0.04)]
                           : [Color.secondary.opacity(0.14), Color.secondary.opacity(0.03)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private func message(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 22)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(detail)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(8)
    }

    // 小号：温度是主角（这是最常瞟一眼的东西），开关机缩成右下角一个小圆钮。
    //
    // 为什么只加开关机、不加温度 ±：132×132 里再塞两个圆按钮，温度字得缩到 30pt
    // 才排得下（试过，会截成「23....」），反而把主角挤小了。调温去中号或主面板。
    //
    // 版式 = Q2 全左对齐（读数卡片）：设备名 / 温度 /「模式·风速」全部靠左对齐成一条竖线，
    // 电源钮用 .overlay(alignment: .bottomTrailing) 浮在右下角、不占一行高度。
    // 演进记：S3 通栏灰按钮 → 用户「不合理不好看」；P1 三段居中 + 右上角独立雪花 → 用户
    // 「数字、右上角的雪花乱七八糟」——雪花浮在右上角与左上角的名字形成对角张力，42pt 温度
    // 又不与任何东西对齐，整块看着散。本版把模式图标收回到底行文字里，全块只剩一条左边缘，
    // 温度因此有了明确锚点。温度降到 36pt 是因为左对齐时右侧会留白，再大就显得空。
    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(s.alias)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)

            Spacer(minLength: 0)

            Text(s.isOn ? s.temperatureText : "--")
                .font(.system(size: 36, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(s.isOn ? .primary : .secondary)
                .minimumScaleFactor(0.6)
                .lineLimit(1)

            HStack(spacing: 4) {
                Image(systemName: s.isOn ? s.modeSymbol : "power")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(s.online ? (s.isOn ? Color.accentColor : Color.secondary) : Color.orange)
                Text(s.online ? (s.isOn ? "\(s.modeName) · \(s.fanName)" : "已关机") : "设备离线")
                    .font(.system(size: 10, weight: s.online ? .regular : .medium))
                    .foregroundStyle(s.online ? Color.secondary : Color.orange)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .overlay(alignment: .bottomTrailing) {
            // 离线时不给按钮（和中号一个规矩）：点了也只是排队等设备上线。
            if s.online {
                Button(intent: TogglePowerIntent(to: !s.isOn)) {
                    ZStack {
                        Circle().fill(circleFill())
                        Image(systemName: "power")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(buttonIcon(s.isOn ? Color.accentColor : Color.secondary,
                                                        enabled: true))
                    }
                    .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // 中号：左边状态，右边四个真能按的按钮。版式按 344×164（内容区约 312×132）配的：
    // 左信息列 150 + 右侧 2×2 按钮 66×42（含 10pt 间隔 = 142×94），加起来 292，
    // 留 20pt 呼吸位。比「按钮铺满右半」收敛，比原来 40×30 的一小撮舒展。
    private var medium: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(s.alias)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Image(systemName: s.isOn ? s.modeSymbol : "power")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(s.isOn ? Color.accentColor : .secondary)
                    Text(s.isOn ? s.modeName : "已关机")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if s.isOn {
                        Text("· \(s.fanName)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(s.isOn ? s.temperatureText : "--")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(s.isOn ? .primary : .secondary)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                if !s.online {
                    Text("设备离线").font(.system(size: 9)).foregroundStyle(.orange)
                }
            }
            // 左列定宽 150，右侧那组 142 宽的按钮才不会跟着文字长短飘。
            .frame(width: 150, alignment: .leading)

            Spacer(minLength: 0)

            // 离线时一个按钮都不给：点了也只是排队等设备上线，不如让面板直接说实话。
            if s.online {
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        padButton(NudgeTemperatureIntent(delta: -0.5), icon: "minus",
                                  tint: .secondary, enabled: s.isOn && s.canAdjustTemperature)
                        padButton(NudgeTemperatureIntent(delta: 0.5), icon: "plus",
                                  tint: .secondary, enabled: s.isOn && s.canAdjustTemperature)
                    }
                    HStack(spacing: 10) {
                        padButton(CycleModeIntent(raw: s.isOn ? s.nextModeRaw : 1),
                                  icon: ACStatus.modeSymbol(s.isOn ? s.nextModeRaw : 1),
                                  tint: .secondary, enabled: true)
                        padButton(TogglePowerIntent(to: !s.isOn), icon: "power",
                                  tint: s.isOn ? Color.accentColor : .secondary, enabled: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    // MARK: - 强调渲染模式（accented）
    //
    // macOS 桌面小组件在「后台」（桌面不是当前活跃窗口）时会切到 `.accented`。按 Apple
    // 《Optimizing your widget for accented rendering mode》的说明，该模式会：
    //   · 把 primary 与 accent 内容**一律染成白色**
    //   · **移除背景**，换成主题玻璃
    // 真机截图核对的后果：`.thinMaterial` 的按钮底变成一块浅灰实心，里面的图标被染成白色，
    // 白图标压浅灰底 = 整块什么都看不见 —— 就是用户报的「右边的按钮全部白色了看不到里面图标」。
    // 对策：该模式下不用 material、不用彩色，改成「白色 + 透明度」分层：15% 白的底 + 全白图标，
    // 在深色玻璃上依然分得清按钮轮廓和里面的符号。
    private var accented: Bool { renderingMode == .accented }

    private func buttonFill() -> AnyShapeStyle {
        accented ? AnyShapeStyle(Color.primary.opacity(0.15)) : AnyShapeStyle(.thinMaterial)
    }

    /// 按钮里的图标色。accented 下彩色会被系统染白，索性直接用 primary（那种模式下就是白），
    /// 用透明度区分可用/不可用，不再依赖色相。
    private func buttonIcon(_ tint: Color, enabled: Bool) -> Color {
        if accented { return Color.primary.opacity(enabled ? 1.0 : 0.35) }
        return enabled ? tint : Color.secondary.opacity(0.35)
    }

    /// 小号那个圆形电源钮的底。
    private func circleFill() -> Color {
        accented ? Color.primary.opacity(0.15) : Color.secondary.opacity(0.14)
    }

    /// 中号右边那种方形小按钮。`enabled: false` 时不发请求、只变淡——
    /// 在小组件里「按钮是灰的」比「按下去没反应」好懂得多。
    private func padButton<I: AppIntent>(_ intent: I, icon: String,
                                         tint: Color, enabled: Bool) -> some View {
        Button(intent: intent) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 66, height: 42)
        }
        .buttonStyle(.plain)
        .foregroundStyle(buttonIcon(tint, enabled: enabled))
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(buttonFill())
        )
        .disabled(!enabled)
    }
}

// MARK: - 注册

struct AuxACWidget: Widget {
    let kind = "AuxACWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AuxACProvider()) { entry in
            AuxACWidgetView(entry: entry)
        }
        .configurationDisplayName("奥克斯空调")
        .description("看一眼当前温度和模式，中号还能直接开关机。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct AuxACWidgetBundle: WidgetBundle {
    var body: some Widget {
        AuxACWidget()
    }
}
