import Foundation
import SwiftUI
import WidgetKit

/// App 的全局状态。
///
/// 所有网络与状态变更都收敛到这里，视图层只读 `@Published` 属性并调用意图方法。
@MainActor
final class AppModel: ObservableObject {

    enum Phase: Equatable {
        case loggedOut
        case needCode(phone: String)   // 短信已发出，等验证码
        case ready
    }

    // MARK: - 对外状态

    @Published private(set) var phase: Phase = .loggedOut
    @Published private(set) var devices: [Device] = []
    @Published private(set) var selectedDID: String?
    /// 用户给设备起的本地备注，键是设备的 `did`。持久化在 `DeviceNoteStore`。
    @Published private(set) var notes: [String: String] = [:]
    @Published private(set) var isBusy = false
    @Published private(set) var isRefreshing = false
    @Published var lastError: String?
    @Published var statusLine: String = ""

    /// 自动刷新间隔（秒）。空调状态变化慢，30 秒足够，也能少打扰服务端。
    var refreshInterval: TimeInterval = 30

    /// 本地乐观覆盖的一条记录：用户已经下发、但设备还没上报回来的字段。
    private struct Pending {
        let value: JSONValue
        let until: Date
    }

    /// 乐观覆盖表，键是**状态字段名**（不是下发键名——两者不完全一样，见 PROTOCOL.md §3.3）。
    ///
    /// 为什么需要它：设备把新状态报到云端要 **≤4 秒**（§2.3）。这段时间里如果界面
    /// 只显示服务端读数，用户看到的就是「点了开关没反应、得手动刷新一下才变」。
    /// 覆盖表专门用来消除这段空窗期：一旦回读到一致的值就撤掉，超时也撤掉
    /// （宁可退回真实旧值，也不要一直显示一个设备从未确认过的状态）。
    @Published private var pending: [String: Pending] = [:]

    /// 乐观覆盖的存活时间。
    ///
    /// 实测下发到状态回读一致只要 **4 秒**（比早先估计的 15–30 秒、8 秒都快，
    /// 那两个只是更松的上限，见 docs/PROTOCOL.md §3.4(d)），所以 25 秒已经很宽裕；
    /// 再长只会让一个设备其实没接受的假值在界面上多挂十几秒。
    private let pendingLifetime: TimeInterval = 25

    /// 官方 `baseConfig.configContent.controlMinimumInterval` = **3 秒**。
    ///
    /// 抓包自 `GET /app/getConfig?id=baseConfig`（同一族接口，只有 User-Agent 要求）。
    /// 官方 App 自己遵守它，我们也遵守——因为**违反它的代价是静默失败**：
    /// 比 3 秒更密的连点会被服务端吞掉，回的是 `{"code":200,"message":"OK"}`，
    /// 但设备状态纹丝不动，用户看到的就是「点了没反应」。
    /// 在本地拦下并说明，比让用户对着一个假的 200 发呆强。
    static let minimumControlInterval: TimeInterval = 3

    /// 上一次**真正发出去**的控制时间。只有走到发送那一步才更新，被闸门拦下的不算。
    private var lastControlAt: Date?

    /// 用户最近一次选的风速档。
    ///
    /// 为什么不能只看上报值：下发 `wind_speed=2`，设备上报回来的 `wind_speed_1`
    /// 却是 5（实测 0→1、1→3、2→5、4→6…，高位还会饱和到 6）。上报值是**被设备
    /// 量化过的**，无法可靠地反推用户选了哪一档，拿它做高亮会让分段条指到错的位置。
    /// 所以风速高亮认「用户的选择」，另外把上报原值用小字显示在旁边，
    /// 两者不一致时一眼就能看出来。
    @Published private(set) var preferredFan: FanSpeed?

    // MARK: - 能耗

    /// 能耗图的柱子。范围由 `energyRange` 决定。
    @Published private(set) var energy: [EnergyPoint] = []
    /// 当前范围里所有柱子的合计（度）。显示在图上方。
    @Published private(set) var energyTotal: Double = 0
    /// 时间范围里**其实没有数据**（设备刚绑定、或那几天真的没用）。用来区分
    /// 「加载失败」和「这段时间就是 0 度」——后者不该显示成错误。
    @Published private(set) var energyEmpty = false
    @Published private(set) var energyLoading = false
    @Published var energyRange: EnergyRange = .week

    // MARK: - 菜单栏外观

    /// 菜单栏图标旁边是否显示目标温度。
    ///
    /// 存 `UserDefaults`——一个布尔开关不值得像 token / 备注那样单开一个文件。
    /// 默认开：不展开面板就能看到空调设了几度，这正是这个功能存在的全部理由。
    @Published var menuBarShowsTemperature: Bool = true {
        didSet {
            UserDefaults.standard.set(menuBarShowsTemperature, forKey: Self.menuBarShowsTemperatureKey)
        }
    }
    private static let menuBarShowsTemperatureKey = "menuBarShowsTemperature"

    private let api = AuxAPI()
    private let log = DebugLog.shared
    private var credentials: Credentials?
    private var refreshTask: Task<Void, Never>?
    private var confirmTask: Task<Void, Never>?

    init() {
        // 属性声明里的 `= true` 只是兜底值；这里用用户存过的选择覆盖它。
        // （在 init 里赋值不会触发 didSet，所以不会把读到的值又写回去。）
        if let saved = UserDefaults.standard.object(forKey: Self.menuBarShowsTemperatureKey) as? Bool {
            menuBarShowsTemperature = saved
        }
        notes = DeviceNoteStore.load()
        if let creds = TokenStore.load() {
            credentials = creds
            if creds.isExpired {
                log.log("本地 token 已过期（expireAt=\(creds.expireAt.map { String($0) } ?? "无")），需要重新登录")
                phase = .loggedOut
                statusLine = "登录已过期，请重新登录"
            } else {
                phase = .ready
                log.log("载入本地 token，路径 \(TokenStore.path)")
                // 常驻轮询，而不是只在面板打开时轮询：
                // 菜单栏图标本身就在显示开关状态，只在打开时刷新会让图标长期过时。
                startAutoRefresh()
            }
        } else {
            log.log("无本地凭据，等待登录")
        }
        subscribeToURLCommands()
    }

    // MARK: - auxac:// 命令
    //
    // 命令表与解析在 `URLCommands.swift`。这里只负责「拿到命令之后做什么」。

    /// 订阅 URL 命令。
    ///
    /// 走 `URLRouter` 中转而不是直接实现 `NSApplicationDelegate`：delegate 由
    /// `@NSApplicationDelegateAdaptor` 创建，比 `@StateObject` 先出生，那一刻
    /// 还没有这个实例可拿。详见 `URLRouter` 的注释。
    ///
    /// 冷启动（App 没在跑，直接 `open 'auxac://on'`）时 URL 会先到、订阅后到，
    /// `URLRouter` 会把先到的存下来，等这里订阅时补投。
    private func subscribeToURLCommands() {
        URLRouter.shared.subscribe { [weak self] url in
            guard let self else { return }
            Task { @MainActor in await self.perform(url) }
        }
    }

    /// 执行一条 `auxac://` 命令（来自 AppDelegate 或 `--url-probe`）。
    func perform(_ url: URL) async {
        guard let command = AuxCommand.parse(url) else {
            // 命令写错时**必须留痕**：这个入口没有界面反馈，用户是从快捷指令或
            // 脚本里发的，看不到 statusLine 就得翻日志。
            log.log("⚠️ 收到不认识的自定义 URL：\(url.absoluteString)")
            log.log(AuxCommand.helpText())
            statusLine = "不认识的命令，试 open 'auxac://help'"
            return
        }
        log.log("▶︎ URL 命令 \(url.absoluteString)")
        await perform(command)
    }

    func perform(_ command: AuxCommand) async {
        // `help` 不需要登录，先接住——只想看命令表的人本来就不打算控制空调，
        // 用「还没登录」把他挡掉是没道理的。
        if case .help = command {
            log.log(AuxCommand.helpText())
            statusLine = "命令表已写进日志（齿轮菜单里也能复制）"
            return
        }
        guard phase == .ready else {
            log.log("⚠️ 收到 URL 命令但当前未登录，已忽略")
            statusLine = "还没登录，命令没执行"
            return
        }
        switch command {
        case .power(let on):      await setPower(on)
        case .toggle:             await setPower(!state.isOn)
        case .temperature(let t): await setTemperature(t)
        case .nudge(let delta):   await nudgeTemperature(by: delta)
        case .mode(let mode):     await setMode(mode)
        case .fan(let fan):       await setFan(fan)
        case .screen(let on):     await setScreen(on)
        case .refresh:            await refresh()
        case .help:
            // 上面已经处理过，这里只是为了让 switch 穷尽。
            log.log(AuxCommand.helpText())
        }
    }

    #if PREVIEW
    /// 仅用于离屏渲染预览（编译时加 `-D PREVIEW`，生产构建里这段不存在）。
    ///
    /// 目的：把 `ControlView` 渲染成 PNG 自己看排版，而不是盲改界面。
    /// 塞一份真机样例，不读凭据、不联网、不启动轮询。
    /// `poweredOn: false` 用来渲染「空调关机」态：那时四个功能 chip 应显示为变暗，
    /// 而模式/风速/扫风**仍然可用**（真机实测关机态也能写回）。
    /// `locked: true` 用来渲染「童锁开着」的面板——那时整块控制区都该变暗。
    init(previewSample: Bool, poweredOn: Bool = true, locked: Bool = false) {
        let json = """
        [{"did":"YOUR_DEVICE_ID","productKey":"YOUR_PRODUCT_KEY",
        "alias":"奥克斯空调","mac":"AABBCCDDEEFF","online":true,
        "data":{"on_off":\(poweredOn ? 1 : 0),"air_con_func":1,"temperature":23,"temperature_decimal":5,"half":1,
        "wind_speed_1":5,"up_down_swing":0,"left_right_swing":1,"screen_on_off":1,
        "sleep_mode":0,"sleep_diy":0,"eco":0,"turbo_silence":0,"support_heat":1,
        "healthy":0,"clean":0,"comfort_wind":0,"anti_fungus":0,"electric_heating":0,
        "electric_lock":\(locked ? 1 : 0),"power_limit":0,"power_limit_percent":0,"ventilate":0,
        "ventilate_auxiliary":0,"ventilate_heap_notify":0,"wind_child":0,"wind_far":0,
        "wind_light":0,"wind_ring":0,"wind_smart":0,"zero_wind_feeling":0,"hanging":1,
        "no_speech":0,"air_q_light":0,"auto_screen":0}},
        {"did":"d3000000001111222233","productKey":"YOUR_PRODUCT_KEY",
        "alias":"奥克斯空调","mac":"AABBCCDDEEFF","online":false,
        "data":{"on_off":0,"air_con_func":2,"temperature":26,"temperature_decimal":0,"half":0,
        "wind_speed_1":1,"up_down_swing":1,"left_right_swing":1,"screen_on_off":1,
        "sleep_mode":0,"eco":0,"turbo_silence":0,"support_heat":1,"hanging":1}}]
        """
        devices = (try? JSONDecoder().decode([Device].self, from: Data(json.utf8))) ?? []
        selectedDID = devices.first?.did
        // 塞一条备注，好让「设备页」渲染出来就是有备注的样子。
        // 两台样例设备的 alias 故意都是「奥克斯空调」——这正是需要备注的场景。
        notes = [devices[0].did: "主卧空调"]
        phase = .ready
        // 能耗页样例：7 天、高低错落（含一个 0），好看出柱状图的形状和「0 度」的样子。
        // 离线渲染不会真的去拉数据，所以这里必须自己塞。
        energy = [
            ("2026-10-05", "10-05", 0.8), ("2026-10-06", "10-06", 2.4),
            ("2026-10-07", "10-07", 1.1), ("2026-10-08", "10-08", 3.6),
            ("2026-10-09", "10-09", 0.0), ("2026-10-10", "10-10", 2.9),
            ("2026-10-11", "10-11", 1.7),
        ].map { EnergyPoint(key: $0.0, label: $0.1, kwh: $0.2) }
        energyTotal = energy.reduce(0) { $0 + $1.kwh }
        energyEmpty = energy.allSatisfy { $0.kwh == 0 }
        log.log("PREVIEW 样例设备数 = \(devices.count)")
    }
    #endif

    /// 菜单栏 / 面板头部共用的图标：同时体现**开关**和**当前模式**。
    ///
    /// 早先菜单栏图标只区分开关（开着永远是雪花），切到制热、送风也还是雪花，
    /// 不展开面板就分不清空调在干嘛。现在统一走这里，两处不会各写一份逻辑。
    var menuBarSymbol: String {
        guard state.isOn, let m = state.modeRaw, let mode = ACMode(rawValue: m) else {
            return "power"
        }
        return mode.symbol
    }

    /// 菜单栏图标旁边要显示的温度文字。**关机或用户关掉开关时返回 `nil`**（只留图标）。
    ///
    /// 半度就带一位小数（`23.5°`），整度不带 `.0`（`24°`）——菜单栏那点宽度是从
    /// 别的 App 手里抢来的，能省两个字符就省。`°` 用半角符，比 `℃` 窄。
    ///
    /// 读的是 `state`，也就是**带乐观覆盖**的那个值：点一下 +/- 数字立刻变，
    /// 不用等设备那 4 秒上报。
    var menuBarTemperatureText: String? {
        Self.menuBarTemperatureText(
            isOn: state.isOn,
            showsTemperature: menuBarShowsTemperature,
            temperature: state.targetTemperature,
            hasHalfDegree: state.hasHalfDegree
        )
    }

    /// 上面那个属性的纯函数内核。抽出来只为了一件事：`--selftest` 能直接断言
    /// 格式化规则，不必先造一个带设备的 `AppModel`（那要联网）。
    nonisolated static func menuBarTemperatureText(
        isOn: Bool,
        showsTemperature: Bool,
        temperature: Double?,
        hasHalfDegree: Bool
    ) -> String? {
        guard showsTemperature, isOn, let temperature else { return nil }
        return hasHalfDegree
            ? String(format: "%.1f°", temperature)
            : String(format: "%.0f°", temperature)
    }

    var selectedDevice: Device? {
        guard let selectedDID else { return devices.first }
        return devices.first { $0.did == selectedDID } ?? devices.first
    }

    /// 界面看到的设备状态 = **服务端读数 + 尚未被设备确认的本地意图**。
    var state: ACState {
        var raw = selectedDevice?.data ?? [:]
        let now = Date()
        for (key, p) in pending where now < p.until { raw[key] = p.value }
        return ACState(raw: raw)
    }

    /// 是否有还没被设备确认的本地意图。UI 用它显示「等设备上报」。
    var hasUnconfirmedIntent: Bool {
        let now = Date()
        return pending.contains { now < $0.value.until }
    }

    // MARK: - 登录

    /// 第一步：请求短信验证码
    func requestCode(phone rawPhone: String) async {
        let phone = rawPhone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phone.count >= 11, phone.allSatisfy(\.isNumber) else {
            lastError = "请填写 11 位手机号（纯数字）"
            return
        }
        isBusy = true
        lastError = nil
        statusLine = "正在发送验证码…"
        defer { isBusy = false }

        do {
            try await api.requestSmsCode(phone: phone)
            phase = .needCode(phone: phone)
            statusLine = "验证码已发送到 \(phone.prefix(3))****\(phone.suffix(4))"
            log.log("✅ 短信验证码请求成功")
        } catch {
            lastError = error.localizedDescription
            statusLine = "发送验证码失败"
            log.log("✗ 发送验证码失败: \(error.localizedDescription)")
        }
    }

    /// 第二步：用验证码换 token
    func submitCode(_ rawCode: String) async {
        guard case .needCode(let phone) = phase else { return }
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            lastError = "请填写验证码"
            return
        }
        isBusy = true
        lastError = nil
        statusLine = "正在登录…"
        defer { isBusy = false }

        do {
            let creds = try await api.loginBySms(phone: phone, code: code)
            credentials = creds
            TokenStore.save(creds)
            phase = .ready
            statusLine = "登录成功"
            startAutoRefresh()
        } catch {
            lastError = error.localizedDescription
            statusLine = "登录失败"
            log.log("✗ 登录失败: \(error.localizedDescription)")
        }
    }

    func logout() {
        stopAutoRefresh()
        TokenStore.clear()
        credentials = nil
        devices = []
        selectedDID = nil
        pending = [:]
        phase = .loggedOut
        statusLine = "已退出登录"
        log.log("用户主动退出登录，本地凭据已清除")
        // 上面已经把 credentials 置 nil，所以这里必然走「未登录」那一支，
        // 顺带让小组件重画成「请先登录」。
        publishWidgetSnapshot()
    }

    // MARK: - 刷新

    func refresh() async {
        guard let token = credentials?.token else { return }
        if isRefreshing { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let list = try await api.fetchDevices(token: token)
            devices = list
            if selectedDID == nil || !list.contains(where: { $0.did == selectedDID }) {
                selectedDID = list.first?.did
            }
            reconcilePending(against: list)
            statusLine = "已同步 \(list.count) 台设备 · \(Self.timeString())"
            lastError = nil
            publishWidgetSnapshot()
        } catch let e as AuxError {
            // 鉴权失效 → 退回登录态（60106 才是 AUX 实际回的码，见 AuxError.isAuthExpired）
            if e.isAuthExpired {
                handleAuthExpired()
            } else {
                lastError = e.localizedDescription
                statusLine = "同步失败"
            }
            log.log("✗ 刷新失败: \(e.localizedDescription)")
        } catch {
            lastError = error.localizedDescription
            statusLine = "同步失败"
            log.log("✗ 刷新失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 乐观覆盖的收敛

    /// 每次拿到服务端读数后，决定哪些本地意图可以撤掉。
    ///
    /// - 服务端已经和本地意图**一致** → 撤掉（设备确认了）。
    /// - 服务端仍不一致但**没超时** → 留着（设备还没上报完）。
    /// - **超时了** → 撤掉并记一条日志。这条日志很重要：它意味着「这个键
    ///   服务端回 200 但设备其实没接受」，是发现假生效字段的唯一线索（§3.4）。
    private func reconcilePending(against list: [Device]) {
        guard !pending.isEmpty else { return }
        let now = Date()

        var expired: [String] = []
        for (key, p) in pending where now >= p.until { expired.append(key) }
        for key in expired { pending.removeValue(forKey: key) }
        if !expired.isEmpty {
            log.log("⚠️ 乐观覆盖超时失效（设备始终没有上报这个值，可能该字段服务端回 200 但未生效）：\(expired.joined(separator: ", "))")
        }

        let reported = (list.first { $0.did == selectedDID } ?? list.first)?.data ?? [:]
        var confirmed: [String] = []
        for (key, p) in pending where reported[key] == p.value { confirmed.append(key) }
        for key in confirmed { pending.removeValue(forKey: key) }
        if !confirmed.isEmpty {
            log.log("✅ 设备已上报，撤销本地覆盖：\(confirmed.joined(separator: ", "))")
        }
    }

    private func handleAuthExpired() {
        stopAutoRefresh()
        TokenStore.clear()
        credentials = nil
        pending = [:]
        phase = .loggedOut
        statusLine = "登录已过期，请重新登录"
        log.log("服务端判定 token 失效，已清除本地凭据")
        // 上面已经把 credentials 置 nil，所以这里必然走「未登录」那一支，
        // 顺带让小组件重画成「请先登录」。
        publishWidgetSnapshot()
    }

    /// 把当前状态推给桌面小组件。
    ///
    /// 小组件是**另一个进程**，读不到 `AppModel`；它只能读我们落盘的快照文件。
    /// 所以每次状态有变化（刷新完 / 切了设备 / 下发成功）都要推一次，
    /// 否则桌面上的数字会停在旧值上，看起来像坏了。
    ///
    /// 注意这里**不区分 pending 乐观值**：快照只反映服务端事实。
    /// 小组件上显示一个还没被设备确认的值会误导人，宁可慢 4 秒。
    func publishWidgetSnapshot() {
        let changed: Bool
        if credentials == nil {
            changed = WidgetSnapshot.write(device: nil, displayName: nil, state: "loggedOut")
        } else if let device = selectedDevice {
            changed = WidgetSnapshot.write(
                device: device, displayName: name(for: device), state: "ok")
        } else {
            changed = WidgetSnapshot.write(device: nil, displayName: nil, state: "empty")
        }
        // 只在内容真的变了的时候才喊小组件重画。WidgetKit 有每日刷新配额，
        // 每 30 秒无脑 reload 一次会把它烧光，之后系统接管刷新时机，桌面数字更不准。
        if changed {
            WidgetCenter.shared.reloadTimelines(ofKind: "AuxACWidget")
        }
    }

    // MARK: - 自动刷新

    func startAutoRefresh() {
        stopAutoRefresh()
        refreshTask = Task { [weak self] in
            // 先立刻拉一次再进循环。原来这里是「先睡 30 秒再拉」，
            // 于是面板一打开看到的必然是旧状态，要等半分钟才自愈
            // ——这正是「还得手动点刷新」的直接来源。
            await self?.refresh()

            while !Task.isCancelled {
                guard let interval = self?.refreshInterval else { return }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }
                await self?.refresh()
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        confirmTask?.cancel()
        confirmTask = nil
    }

    /// 下发成功后安排两次延迟回读，把乐观覆盖收掉。
    ///
    /// 不走「下发完 sleep 700ms 再刷新」——那个时机设备**根本还没上报**，
    /// 读回来的必然是旧值，只会白白把乐观状态冲掉一次。
    /// 用后台任务而不是在 `apply` 里 sleep，是为了让 `isBusy` 尽早复位，
    /// 不把界面锁住十几秒。
    ///
    /// 时点按实测延迟（约 4 秒）定：10 秒那次通常就能拿到确认，
    /// 20 秒那次是兜底（偶尔上报慢或在两次轮询之间错过）。
    private func scheduleConfirmation() {
        confirmTask?.cancel()
        confirmTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)
            if Task.isCancelled { return }
            await self?.refresh()
            try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)
            if Task.isCancelled { return }
            await self?.refresh()
        }
    }

    // MARK: - 控制意图

    /// 把**控制意图**的键名翻译成**状态字段**的键名，用于本地乐观覆盖。
    ///
    /// 两套名字并不完全一样（§3.3）：
    /// - 下发 `wind_speed`，上报却叫 `wind_speed_1`
    /// - 下发 `temperature` 一个浮点数，上报拆成 `temperature` +
    ///   `temperature_decimal` + `half` 三个字段
    ///
    /// 翻译错了的后果不是崩溃，而是「覆盖永远对不上、于是永远撤不掉」，
    /// 表现成界面卡在乐观值上。所以这里必须和 ACState 的读法严格镜像。
    private static func stateKeys(for intent: [String: JSONValue]) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for (key, value) in intent {
            switch key {
            case "wind_speed":
                // 故意不翻译：上报值被设备量化，覆盖值等不到一致（见 preferredFan 注释）。
                continue

            case "temperature":
                guard let t = value.doubleValue else { continue }
                let whole = t.rounded(.down)
                let hasHalf = (t - whole) >= 0.25
                out["temperature"] = .number(whole)
                out["temperature_decimal"] = .number(hasHalf ? 5 : 0)
                out["half"] = .number(hasHalf ? 1 : 0)

            default:
                out[key] = value
            }
        }
        return out
    }

    /// 官方要求的两次控制最小间隔。拦在本地而不是等被服务端吞——被吞的响应
    /// 长得跟成功一模一样（`200 OK`），从响应上根本分不出来。
    private func requireInterval(_ what: String) -> Bool {
        guard let last = lastControlAt else { return true }
        let elapsed = Date().timeIntervalSince(last)
        guard elapsed < Self.minimumControlInterval else { return true }
        let wait = Self.minimumControlInterval - elapsed
        lastError = String(format: "发得太快了：官方要求两次控制间隔至少 %.0f 秒，请再等 %.1f 秒。",
                           Self.minimumControlInterval, wait)
        statusLine = String(format: "已拦下：距上次控制仅 %.1f 秒（官方最小 %.0f 秒）",
                            elapsed, Self.minimumControlInterval)
        log.log(String(format: "⊘ 拦下「%@」：距上次控制仅 %.1f 秒（< %.0f 秒）",
                       what, elapsed, Self.minimumControlInterval))
        return false
    }

    /// 所有控制动作下发前的**唯一**准入点。
    ///
    /// 顺序：功能自己的互斥项（含童锁，`mutex` 由 `ControlMutex` 算好）→ 最小间隔。
    /// 做成一道闸而不是散在每个 setter 里，是为了让「界面亮着但发不出去」不可能发生：
    /// 界面的 `enabled` 和这里的 `mutex` 读的是同一份 `ControlMutex`。
    private func controlGate(_ what: String, mutex: String?) -> Bool {
        if let reason = mutex {
            lastError = "「\(what)」\(reason)"
            statusLine = "已拦下：\(reason)"
            log.log("⊘ 拦下「\(what)」：\(reason)")
            return false
        }
        return requireInterval(what)
    }

    private func apply(_ action: [String: JSONValue], optimistic: String, mutex: String?) async {
        // ⚠️ 闸门必须在 `lastError = nil` **之前**：闸门就是靠 lastError
        // 告诉用户「为什么没反应」的，放后面会被这一行当场擦掉。
        guard controlGate(optimistic, mutex: mutex) else { return }
        guard let device = selectedDevice, let token = credentials?.token else { return }
        isBusy = true
        lastError = nil
        statusLine = "正在下发：\(optimistic)"
        defer { isBusy = false }

        // 先本地覆盖，界面立刻有反馈；下发失败再撤回。
        let overlay = Self.stateKeys(for: action)
        let until = Date().addingTimeInterval(pendingLifetime)
        for (key, value) in overlay { pending[key] = Pending(value: value, until: until) }

        do {
            try await api.control(device: device, intent: action, token: token)
            lastControlAt = Date()
            log.log("✅ 控制成功 \(optimistic)")
            statusLine = "已下发：\(optimistic) · 等设备上报"
            scheduleConfirmation()
        } catch let e as AuxError where e.isAuthExpired {
            // 控制途中 token 失效（典型场景：手机 App 同时登录，把 Mac 这个会话踢了）。
            // 这里不弹「下发失败」那种普通错误，直接退回登录态——否则用户对着一个
            // 点了没反应的按钮，只会以为工具坏了。
            for key in overlay.keys { pending.removeValue(forKey: key) }
            log.log("✗ 控制失败，token 已失效: \(e.localizedDescription)")
            handleAuthExpired()
        } catch {
            for key in overlay.keys { pending.removeValue(forKey: key) }
            lastError = error.localizedDescription
            statusLine = "下发失败：\(optimistic)"
            log.log("✗ 控制失败 \(optimistic): \(error.localizedDescription)")
        }
    }

    func setPower(_ on: Bool) async {
        await apply(["on_off": .number(on ? 1 : 0)], optimistic: on ? "开机" : "关机",
                    mutex: ControlMutex.none(state))
    }

    func setMode(_ mode: ACMode) async {
        // 字段名是 `air_con_func`。实测下发 `{"mode":...}` 服务端会回 200 但**不生效**。
        await apply(["air_con_func": .number(Double(mode.rawValue))], optimistic: "模式→\(mode.label)",
                    mutex: ControlMutex.none(state))
    }

    func setFan(_ fan: FanSpeed) async {
        // ⚠️ 下发的键名是 `wind_speed`；`wind_speed_1` 只是**状态**里的字段名，
        // 用它下发服务端会回 200 但完全忽略（实测状态纹丝不动）。
        //
        // 这里刻意**不做**乐观覆盖：上报值被设备量化（下发 2 会回 5），
        // 覆盖值永远等不到一致，只会在 40 秒后白记一条「该字段未生效」的假警告。
        // 高亮交给 preferredFan。
        preferredFan = fan
        await apply(["wind_speed": .number(Double(fan.rawValue))], optimistic: "风速→\(fan.label)",
                    mutex: ControlMutex.fan(state))
    }

    /// 目标温度。**实测：直接下发浮点摄氏度即可**（`{"temperature":24.5}` 被接受），
    /// 设备自己拆分整数部分与 `temperature_decimal`。不要再拆成 `half` 另发——
    /// 实测那样做反而容易和 `temperature` 互相覆盖。
    func setTemperature(_ celsius: Double) async {
        let clamped = min(32.0, max(16.0, celsius))
        await apply([
            "temperature": .number((clamped * 2).rounded() / 2),
        ], optimistic: String(format: "温度→%.1f°C", clamped),
           mutex: ControlMutex.temperature(state))
    }

    func nudgeTemperature(by delta: Double) async {
        // `state` 已经包含乐观覆盖，所以连按两下 ± 会从乐观值继续加，
        // 不会退回到设备还没上报的旧温度。
        let current = state.targetTemperature ?? 26
        await setTemperature(current + delta)
    }

    /// 关机态下设备会**静默忽略**部分字段——拦下并说明原因，而不是让按钮点了没反应。
    ///
    /// 真机逐个实测结论（空调 `on_off=0` 时下发，每次等 ≥4 秒回读）：
    ///
    /// | 字段 | 关机态 | 备注 |
    /// |---|---|---|
    /// | `sleep_mode`（睡眠） | ❌ 静默忽略 | 服务端 mutex 也标了「请先开机后再使用该功能」 |
    /// | `eco`（节能） | ❌ 静默忽略 | 同上 |
    /// | `screen`（屏显） | ✅ 4 秒写回 | mutex 也确认它只受 `electric_lock` 约束 |
    /// | `temperature` / `air_con_func` / `wind_speed` / `up_down_swing` / `left_right_swing` | ✅ 能写回 | 同上 |
    ///
    /// 所以现在**只有睡眠和节能**需要 `requirePower`。
    /// ⚠️ 注意失败时的响应是 `{"code":200,"message":"OK"}`——**「200 OK」不代表生效**，
    /// 只有「下发 → 等 ≥4 秒 → 读回」才算证据。
    private func requirePower(_ what: String) -> Bool {
        guard state.isOn else {
            lastError = "「\(what)」需要空调运行中才能设置，请先开机。"
            statusLine = "已拦下：空调当前是关机态"
            log.log("⊘ 拦下「\(what)」：关机态设备会静默忽略该字段（实测 200 OK 但状态不变）")
            return false
        }
        return true
    }

    func setSleep(_ on: Bool) async {
        guard requirePower("睡眠") else { return }
        await apply(["sleep_mode": .number(on ? 1 : 0)], optimistic: on ? "睡眠开" : "睡眠关",
                    mutex: ControlMutex.sleep(state))
    }

    func setEco(_ on: Bool) async {
        guard requirePower("节能") else { return }
        await apply(["eco": .number(on ? 1 : 0)], optimistic: on ? "节能开" : "节能关",
                    mutex: ControlMutex.eco(state))
    }

    // MARK: - 互斥规则（给界面用）
    //
    // 界面读这几个属性决定按钮亮不亮 / 提示写什么，`apply` 读 `ControlMutex` 决定放不放行。
    // **两边必须是同一份判断**，否则又会出现「点得下去但发不出去」。
    // 规则来源与取舍见 `ControlMutex` 的文档注释。

    /// `nil` 表示可以操作；非 nil 就是要显示给用户的原因。
    var lockReason: String? { ControlMutex.lock(state) }
    var temperatureMutexReason: String? { ControlMutex.temperature(state) }
    var fanMutexReason: String? { ControlMutex.fan(state) }
    var sleepMutexReason: String? { ControlMutex.sleep(state) }
    var ecoMutexReason: String? { ControlMutex.eco(state) }

    // MARK: - 本机不支持的功能
    //
    // 「强劲 / 超静音」在本机上是**硬件不存在**，不是我们没找对键名：
    // 真机实测 `turbo` / `silence` / `ultra_silence`（表里取值 1=关闭 / 2=开启）
    // 以及 `wind_speed=5`（强力档）**全部被设备静默忽略**（服务端回
    // `{"code":200,"message":"OK"}`，但状态纹丝不动）。
    //
    // 本机 `feature.deviceSupport` = ["0,1,2,3,5,6,7,9"]，而服务端 mutex 表里
    // 超静音要求设备含位 `38`，对不上是预期内的。官方 App 里这个按钮同样点不动。
    // 因此面板上不再提供「强劲」，`setTurboSilence` 已删除。

    /// 上下扫风：`index` 是**界面档位索引**（0=摆动 / 1..5=定格1..5 / 6=关闭）。
    ///
    /// ⚠️ **极性与直觉相反**：`0` 才是「自动摆动」，`1`–`5` 是固定定格，`7` 是关闭。
    /// 早期按布尔写成 `on ? 1 : 0`，点「开」反而把叶片停住。
    /// 索引 ↔ 线上取值的映射收在 `ACState.upDownSwingValues`，
    /// 显示侧读 `ACState.upDownSwingIndex`，两处务必保持一致。
    ///
    /// 不受电源门控：关机态实测也能写回（同模式/风速/屏显）。
    func setUpDownSwing(index: Int) async {
        guard ACState.upDownSwingValues.indices.contains(index) else { return }
        let value = ACState.upDownSwingValues[index]
        await apply(["up_down_swing": .number(Double(value))],
                    optimistic: "上下扫风→\(ACState.swingLabels[index])",
                    mutex: ControlMutex.none(state))
    }

    /// 左右扫风：索引语义同 `setUpDownSwing(index:)`，但线上取值**错位**。
    ///
    /// ⚠️ 表里 `5`=定格5、`6`=定格4，照数字顺序推会把这两档弄反，
    /// 所以映射写在 `ACState.leftRightSwingValues` 里，别用算术。
    func setLeftRightSwing(index: Int) async {
        guard ACState.leftRightSwingValues.indices.contains(index) else { return }
        let value = ACState.leftRightSwingValues[index]
        await apply(["left_right_swing": .number(Double(value))],
                    optimistic: "左右扫风→\(ACState.swingLabels[index])",
                    mutex: ControlMutex.none(state))
    }

    /// 屏显（内机面板 LED）。
    ///
    /// **下发键名是 `screen`，不是状态字段名 `screen_on_off`。**
    /// 服务端 mutex 表：`0=关闭 / 1=开启屏显 / 2=智能光感`。
    ///
    /// ⚠️ 早期版本拿状态字段名 `screen_on_off` 去下发 —— 服务端照回
    /// `{"code":200,"message":"OK"}`，但设备静默忽略、状态纹丝不动，
    /// 用户报「屏显无效」。真机确认改用 `screen` 后 4 秒写回。
    ///
    /// **不受电源门控**：真机实测关机态下发 `screen=0` 同样 4 秒写回
    /// （与 mutex 表一致——`screen` 的约束里只有 `electric_lock`，没有 `on_off`）。
    ///
    /// 智能光感(2) 本机不支持（无光感硬件，实测被忽略），故不暴露。
    func setScreen(_ on: Bool) async {
        await apply(["screen": .number(on ? 1 : 0)], optimistic: on ? "屏显开" : "屏显关",
                    mutex: ControlMutex.none(state))
    }

    // MARK: - 能耗

    private static let energyDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// 按 `energyRange` 拉能耗数据。
    ///
    /// 需要发两次请求的唯一情形是「近 7 天」跨月，理由见 `EnergyRange` 的注释：
    /// 服务端按起始日返回**整月**数据，所以那 7 天里落在上个月的部分得再拉一次上个月
    /// （官方那个网页也是这么做的，还会在控制台打印「周视图跨越两个月，需要请求两次API」）。
    /// 范围裁剪全部在本地做——服务端根本不看 `timestart`/`timeend` 的范围。
    func loadEnergy() async {
        guard let token = credentials?.token else { return }
        guard let device = selectedDevice else {
            energy = []; energyTotal = 0; energyEmpty = true
            return
        }
        // ⚠️ 能耗接口只认 MAC（去掉冒号、小写）。传 did 会回
        // `{"code":"401","list":[{"error":"macaddr-error"}]}` —— 那个错误藏在
        // HTTP 200 里、长得也不像「参数错」，很容易误判成接口坏了。
        guard let rawMAC = device.mac, !rawMAC.isEmpty else {
            lastError = "这台设备没有 MAC，能耗接口只认 MAC（传 did 会回 macaddr-error）"
            energy = []; energyTotal = 0; energyEmpty = true
            return
        }
        let mac = rawMAC.replacingOccurrences(of: ":", with: "").lowercased()

        energyLoading = true
        defer { energyLoading = false }

        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let unit = energyRange.unit

        do {
            // 用字典按 dtval 去重：跨月两次请求即使有重叠也不会出重复柱子。
            var byKey: [String: EnergyPoint] = [:]
            for month in Self.monthsToFetch(range: energyRange, today: today, cal: cal) {
                // 起始日和结束日都给同一天就够——服务端只看起始日落在哪个月/哪一年。
                let day = Self.energyDayFormatter.string(from: month)
                for p in try await api.energyStatistics(
                    mac: mac, unit: unit, start: day, end: day, token: token) {
                    byKey[p.key] = p
                }
            }
            let all = byKey.values.sorted { $0.key < $1.key }

            // 本地裁剪：只有「近 7 天」需要截，另外两个范围服务端已经是整月/整年了。
            let shown: [EnergyPoint]
            if energyRange == .week {
                let cutoff = Self.energyDayFormatter.string(
                    from: cal.date(byAdding: .day, value: -6, to: today) ?? today)
                shown = all.filter { $0.key >= cutoff }
            } else {
                shown = all
            }

            energy = shown
            energyTotal = shown.reduce(0) { $0 + $1.kwh }
            // 「全 0」和「没数据」都算空。设备刚绑定的那几天服务端会回一排 dval="0"，
            // 那不是错误，只是真的没用电，界面要能区分这两件事。
            energyEmpty = shown.isEmpty || shown.allSatisfy { $0.kwh == 0 }
            lastError = nil
            log.log("✅ 能耗已加载：\(energyRange.label)，\(shown.count) 个柱子，合计 \(String(format: "%.2f", energyTotal)) 度")
        } catch let e as AuxError {
            if e.isAuthExpired { handleAuthExpired() }
            lastError = e.localizedDescription
            energy = []; energyTotal = 0; energyEmpty = false
            log.log("✗ 能耗加载失败: \(e.localizedDescription)")
        } catch {
            lastError = error.localizedDescription
            energy = []; energyTotal = 0; energyEmpty = false
            log.log("✗ 能耗加载失败: \(error.localizedDescription)")
        }
    }

    /// 切换范围并立刻重拉。先清空再拉，避免切到「今年」的瞬间还挂着上个月那批柱子，
    /// 一秒后才跳成新的，看起来像数据错乱。
    func setEnergyRange(_ r: EnergyRange) async {
        guard r != energyRange else { return }
        energyRange = r
        energy = []
        energyTotal = 0
        await loadEnergy()
    }

    /// 为了覆盖 `range` 需要请求哪几个「月/年」的起点。只有「近 7 天」跨月时是两个。
    private static func monthsToFetch(range: EnergyRange, today: Date, cal: Calendar) -> [Date] {
        guard range == .week,
              let start = cal.date(byAdding: .day, value: -6, to: today),
              !cal.isDate(start, equalTo: today, toGranularity: .month)
        else { return [today] }
        return [today, start]
    }

    func select(_ device: Device) {
        selectedDID = device.did
        log.log("切换设备 → \(name(for: device))")
        publishWidgetSnapshot()
    }

    // MARK: - 备注

    /// 设备在本工具里的显示名：**本地备注优先**，其次服务器 alias，最后 mac/did。
    ///
    /// 为什么备注优先：同一账号下多台空调的 alias 很可能一模一样
    /// （A+ App 默认就叫「奥克斯空调」），光看 alias 分不清哪台是哪台——
    /// 这正是需要备注的场景。
    func name(for device: Device) -> String {
        if let n = note(for: device.did) { return n }
        return device.displayName
    }

    /// 当前选中设备的显示名。
    var selectedName: String {
        selectedDevice.map { name(for: $0) } ?? "空调"
    }

    func note(for did: String) -> String? {
        guard let n = notes[did], !n.isEmpty else { return nil }
        return n
    }

    /// 设置备注。**留空等于删除备注**（恢复显示服务器 alias），
    /// 这样用户不需要先找到「清除」按钮再删一遍。
    func setNote(_ text: String, for did: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            notes.removeValue(forKey: did)
            log.log("清除设备备注 → \(did)")
        } else {
            notes[did] = trimmed
            log.log("设备备注 → \(trimmed)")
        }
        DeviceNoteStore.save(notes)
    }

    private static func timeString() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }
}
