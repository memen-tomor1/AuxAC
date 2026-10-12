import AppKit
import SwiftUI

/// 接收 `auxac://` URL。
///
/// 为什么不用 SwiftUI 的 `.onOpenURL`：本 App 的场景是 `MenuBarExtra`，
/// 它的内容视图**只有用户点开面板时才存在**，而 URL 事件是在 App 层到达的
/// （`application(_:open:)`）；挂在面板上的 `.onOpenURL` 会漏掉「面板没开时」
/// 发来的命令——恰恰是自动化最常用的场景。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { URLRouter.shared.deliver(url) }
    }

    /// App 已在运行时又被双击/`open` 一次：把进程提到前台。
    ///
    /// 菜单栏面板没法从代码里展开（`MenuBarExtra` 没有这个 API），所以这里只能
    /// 做到「不静默」。至少日志里能看出来「用户又开了一次」。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        DebugLog.shared.log("▶︎ App 被重复打开（面板无法用代码展开，靠点菜单栏图标）")
        NSApp.activate(ignoringOtherApps: true)
        return true
    }
}

@main
struct AuxACApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var log = DebugLog.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// 无界面自检：只检查「代码能跑通 + 关键路径可写」，不弹窗、不联网。
    /// 用途是在 CI / 沙箱里验证构建产物是活的。
    init() {
        // 登录项自愈：如果正在用 LaunchAgent，plist 里写的是可执行文件的绝对路径，
        // App 被挪到别处之后那条路径就失效了。每次启动按当前路径重写一遍。
        if !CommandLine.arguments.contains("--selftest") {
            LaunchAtLogin.refreshIfEnabled()
        }
        if CommandLine.arguments.contains("--selftest") {
            print("AuxAC selftest")
            print("  bundleIdentifier = \(Bundle.main.bundleIdentifier ?? "(nil)")")
            print("  logFile          = \(DebugLog.shared.logFilePath)")
            print("  sessionFile      = \(TokenStore.path)")

            // 解析一条真实抓包记录的片段，验证 JSON/状态解析链路。
            // 字段名对齐真机：模式是 air_con_func，风速上报是 wind_speed_1，
            // 温度拆成 temperature（整数）+ temperature_decimal（0 或 5）+ half。
            let sample = """
            {"code":200,"message":"OK","data":[{"did":"d500010001e816566b4b98",
            "productKey":"00010001","alias":"主卧空调","mac":"E8165XXXXXXXX",
            "data":{"on_off":1,"temperature":23,"temperature_decimal":5,"half":1,
            "air_con_func":1,"wind_speed":6,"wind_speed_1":6,
            "up_down_swing":7,"left_right_swing":1,"support_heat":1}}]}
            """
            guard let obj = try? JSONSerialization.jsonObject(with: Data(sample.utf8)) as? [String: Any],
                  let arr = obj["data"] as? [Any],
                  let d = try? JSONSerialization.data(withJSONObject: arr),
                  let devices = try? JSONDecoder().decode([Device].self, from: d),
                  let dev = devices.first else {
                print("  ❌ 解析抓包样例失败")
                exit(1)
            }
            let st = ACState(raw: dev.data)
            print("  device           = \(dev.displayName) did=\(dev.did) pk=\(dev.pk)")
            print("  isOn             = \(st.isOn)")
            print("  targetTemperature= \(st.targetTemperature.map { String($0) } ?? "nil")")
            print("  hasHalfDegree    = \(st.hasHalfDegree)")
            print("  modeRaw          = \(st.modeRaw.map { String($0) } ?? "nil") (应为 1=air_con_func)")
            print("  fanRaw           = \(st.fanRaw.map { String($0) } ?? "nil") (应为 6=wind_speed_1)")
            print("  upDownSwingRaw   = \(st.upDownSwingRaw.map { String($0) } ?? "nil")")
            print("  supportsHeat     = \(st.supportsHeat)")

            // 温度必须是 23.5（整数 23 + decimal 5），不是 23、也不是 235。
            guard st.targetTemperature == 23.5 else {
                print("  ❌ 温度合成错误：得到 \(st.targetTemperature.map { String($0) } ?? "nil")，应为 23.5")
                exit(1)
            }
            print("  ✅ 温度合成 23 + decimal 5 → 23.5")

            // 温度下发是**浮点摄氏度**，不是旧协议的 0.1 度整数（PROTOCOL.md §3.2）。
            // 编码路径：AppModel.setTemperature → JSONValue.number(Double) → JSONEncoder。
            let intent: [String: JSONValue] = ["temperature": .number(24.5)]
            guard let intentJSON = try? JSONEncoder().encode(intent),
                  let intentStr = String(data: intentJSON, encoding: .utf8),
                  intentStr.contains("24.5") else {
                print("  ❌ 温度下发编码错误：24.5 未编成浮点")
                exit(1)
            }
            print("  ✅ 温度下发 \(intentStr)（非 245）")

            // 模式编号：以服务端 `GET /app/getConfig?id=deviceMutex` 为准
            // （0=自动 / 1=制冷 / 2=除湿 / 4=制热 / 6=送风）。
            // 早期版本按「行业惯例」猜成 1/2/3/4，是错的——3 在服务端表里不存在，
            // 而 6（送风）与 2（除湿）真机实测都能写回。这里把取值钉住。
            guard ACMode(rawValue: 1) == .cool, ACMode(rawValue: 2) == .dry,
                  ACMode(rawValue: 4) == .heat, ACMode(rawValue: 6) == .fan,
                  ACMode(rawValue: 3) == nil, ACMode(rawValue: 0) == nil else {
                print("  ❌ ACMode 映射错误")
                exit(1)
            }
            print("  ✅ ACMode 映射 1=制冷 / 2=除湿 / 4=制热 / 6=送风（无 3，无自动）")

            // 风速取值：同样以 deviceMutex 表为准
            // （0=低档 / 1=中档 / 2=高档 / 3=静音 / 4=自动 / 5=强力 / 6=中低 / 7=中高）。
            // 5（强力）本机实测被忽略，故刻意不建 case：rawValue 5 必须解不出档位。
            guard FanSpeed(rawValue: 0) == .low, FanSpeed(rawValue: 1) == .medium,
                  FanSpeed(rawValue: 2) == .high, FanSpeed(rawValue: 3) == .quiet,
                  FanSpeed(rawValue: 4) == .auto, FanSpeed(rawValue: 6) == .mediumLow,
                  FanSpeed(rawValue: 7) == .mediumHigh, FanSpeed(rawValue: 5) == nil else {
                print("  ❌ FanSpeed 映射错误")
                exit(1)
            }
            print("  ✅ FanSpeed 映射 0=低/1=中/2=高/3=静音/4=自动/6=中低/7=中高（5 强力本机不支持）")

            // 扫风极性：**反的**。真机确认 0 = 正在摆动，其余 = 固定角度（7 = 关闭）。
            // 早期版本按 `!= 0` 判「开」，结果点「开」把叶片停住，是用户报的
            // 「扫风反了」。这里把两个方向都钉住，防止以后再被「直觉」改回去。
            // 注意左右扫风表里 `4` 也是「开启」，故单独钉一条。
            let swingSwing = ACState(raw: ["up_down_swing": .number(0), "left_right_swing": .number(0)])
            let swingStop = ACState(raw: ["up_down_swing": .number(1), "left_right_swing": .number(7)])
            let swingLR4 = ACState(raw: ["left_right_swing": .number(4)])
            guard swingSwing.upDownSwingOn == true, swingSwing.leftRightSwingOn == true,
                  swingStop.upDownSwingOn == false, swingStop.leftRightSwingOn == false,
                  swingLR4.leftRightSwingOn == true else {
                print("  ❌ 扫风极性错误：0 应为「摆动中」，其余应为「已停止」（左右扫风 4 也是开启）")
                exit(1)
            }
            print("  ✅ 扫风极性 0=摆动 / 非0=停止（左右另含 4=开启；真机确认）")

            // 扫风**档位映射**：界面索引 ↔ 线上取值必须一一对上，且**顺序相反的两个
            // 方向要各自钉住**——左右那两个定格是错位的（`5`=定格5、`6`=定格4），
            // 照数字顺序做会把定格 4/5 弄反，这是纯靠读表才能发现、单测能防住的错。
            guard ACState.upDownSwingValues == [0, 1, 2, 3, 4, 5, 7],
                  ACState.leftRightSwingValues == [0, 1, 2, 3, 6, 5, 7],
                  ACState.swingLabels.count == ACState.upDownSwingValues.count,
                  ACState.swingLabels.count == ACState.leftRightSwingValues.count else {
                print("  ❌ 扫风档位取值表被改动（左右是错位的：5=定格5、6=定格4）")
                exit(1)
            }
            let swingIdx = ACState(raw: ["up_down_swing": .number(3), "left_right_swing": .number(6)])
            guard swingIdx.upDownSwingIndex == 3, swingIdx.leftRightSwingIndex == 4,
                  ACState(raw: ["left_right_swing": .number(4)]).leftRightSwingIndex == 0,
                  ACState(raw: ["up_down_swing": .number(7)]).upDownSwingIndex == 6 else {
                print("  ❌ 扫风档位索引映射错误（左右 6 应落在索引 4，即「定格4」）")
                exit(1)
            }
            print("  ✅ 扫风档位 索引0=摆动 / 1–5=定格1–5 / 6=关闭（左右线上 6=定格4 已错位校正）")

            // 菜单栏温度文字的格式化规则。纯字符串逻辑，坏了不会有任何报错，
            // 只能靠肉眼看菜单栏才发现——所以在这里把每条分支都钉死。
            // 规则：关机或用户关掉开关 → 不显示；半度带一位小数；整度不带 `.0`。
            let menuCases: [(on: Bool, shows: Bool, temp: Double?, half: Bool, want: String?)] = [
                (true, true, 23.5, true, "23.5°"),
                (true, true, 24.0, false, "24°"),
                (false, true, 23.5, true, nil),   // 关机：温度没意义，只留电源图标
                (true, false, 23.5, true, nil),   // 用户在齿轮菜单里把这个数字关掉了
                (true, true, nil, false, nil),    // 状态里还没有 temperature
            ]
            for c in menuCases {
                let got = AppModel.menuBarTemperatureText(
                    isOn: c.on, showsTemperature: c.shows,
                    temperature: c.temp, hasHalfDegree: c.half
                )
                guard got == c.want else {
                    let t = c.temp.map { String($0) } ?? "nil"
                    print("  ❌ 菜单栏温度文字错误：isOn=\(c.on) shows=\(c.shows) temp=\(t) half=\(c.half) → \(got ?? "nil")，应为 \(c.want ?? "nil")")
                    exit(1)
                }
            }
            print("  ✅ 菜单栏温度文字 23.5° / 24°（半度才带小数）· 关机或关开关 → 只留图标")

            // 互斥规则（来源：服务端 `deviceMutex` 表，见 docs/PROTOCOL.md §3.5）。
            // 这些是纯函数，坏了只会表现成「按钮该灰没灰 / 点下去只得到一句没头没尾
            // 的提示」，不写断言很难发现。
            let stLocked = ACState(raw: ["electric_lock": .number(1)])
            let stFan = ACState(raw: ["air_con_func": .number(6), "on_off": .number(1)])
            let stDry = ACState(raw: ["air_con_func": .number(2), "on_off": .number(1)])
            let stCool = ACState(raw: ["air_con_func": .number(1), "on_off": .number(1)])
            let stHeat = ACState(raw: ["air_con_func": .number(4), "on_off": .number(1)])
            let stDiy = ACState(raw: ["air_con_func": .number(1), "on_off": .number(1), "sleep_diy": .number(1)])
            let stOff = ACState(raw: ["air_con_func": .number(1), "on_off": .number(0)])

            guard ControlMutex.temperature(stFan) == "送风模式下不能调节温度",
                  ControlMutex.temperature(stCool) == nil,
                  ControlMutex.temperature(stDiy) != nil,
                  ControlMutex.fan(stDry) == "除湿模式下不能调节风速",
                  ControlMutex.fan(stCool) == nil,
                  ControlMutex.eco(stCool) == nil,
                  ControlMutex.eco(stHeat) == "仅制冷模式有效",
                  ControlMutex.sleep(stFan) == "送风模式下无效",
                  ControlMutex.sleep(stCool) == nil,
                  ControlMutex.lock(stLocked) != nil,
                  ControlMutex.temperature(stLocked) != nil,
                  ControlMutex.eco(stLocked) != nil else {
                print("  ❌ 互斥规则错误（来源 deviceMutex 表，见 docs/PROTOCOL.md §3.5）")
                exit(1)
            }
            print("  ✅ 互斥规则：童锁全局拦 / 送风不能调温 / 除湿不能调风速 / 节能仅制冷")

            // ⚠️ 刻意**不抄**表里「on_off=0 → 请先开机」那几条：真机逐个实测
            // temperature / wind_speed / 两个摆风在关机态都能写回，照抄会把本来
            // 能用的功能灰掉。这条断言就是防「以后有人对着表把电源门控加回来」。
            guard ControlMutex.temperature(stOff) == nil, ControlMutex.none(stOff) == nil else {
                print("  ❌ 温度/摆风不该因为关机被互斥拦下（真机实测关机态能写回）")
                exit(1)
            }
            print("  ✅ 电源门控只留给睡眠/节能（表比设备严，电源那条不照抄）")

            // `auxac://` 命令解析。手打 URL 极易出错（全角冒号、`+` 被当空格），
            // 每条命令的写法都在这里钉住。
            let urlCases: [(String, AuxCommand?)] = [
                ("auxac://on", .power(true)),
                ("auxac://off", .power(false)),
                ("auxac://toggle", .toggle),
                ("auxac://temp/24.5", .temperature(24.5)),
                ("auxac://temp/+0.5", .nudge(0.5)),
                ("auxac://temp/-0.5", .nudge(-0.5)),
                ("auxac://warmer", .nudge(0.5)),
                ("auxac://cooler", .nudge(-0.5)),
                ("auxac://mode/cool", .mode(.cool)),
                ("auxac://mode/heat", .mode(.heat)),
                ("auxac://mode/dry", .mode(.dry)),
                ("auxac://mode/fan", .mode(.fan)),
                ("auxac://fan/auto", .fan(.auto)),
                ("auxac://fan/mediumlow", .fan(.mediumLow)),
                ("auxac://fan/mediumhigh", .fan(.mediumHigh)),
                ("auxac://screen/off", .screen(false)),
                ("auxac://screen", .screen(true)),
                ("auxac://refresh", .refresh),
                ("auxac://help", .help),
                ("auxac://nonsense", nil),
                ("http://example.com", nil),
            ]
            for (raw, want) in urlCases {
                guard let url = URL(string: raw) else {
                    print("  ❌ URL 不合法: \(raw)")
                    exit(1)
                }
                let got = AuxCommand.parse(url)
                guard got == want else {
                    print("  ❌ URL 解析错误：\(raw) → \(got.map { String(describing: $0) } ?? "nil")，应为 \(want.map { String(describing: $0) } ?? "nil")")
                    exit(1)
                }
            }
            print("  ✅ auxac:// 命令解析 \(urlCases.count) 条全对（含 +/- 微调与非法输入）")

            // 鉴权失效判定。**60106 是 AUX 实际回的码**，漏掉它的后果是：手机 App
            // 一登录同账号，Mac 这边所有请求都回 60106，界面却停在「同步失败」，
            // 用户完全不知道该重新登录。这条断言就是钉住这个码。
            guard AuxError.api(code: 60106, message: "x").isAuthExpired,
                  AuxError.api(code: 401, message: "x").isAuthExpired,
                  !AuxError.api(code: -100, message: "x").isAuthExpired,
                  !AuxError.transport("timeout").isAuthExpired else {
                print("  ❌ isAuthExpired 判定错误（60106 必须算失效，-100 参数错误不算）")
                exit(1)
            }
            print("  ✅ 鉴权失效判定 60106/401 算失效 · -100/传输错误不算")

            // 校验 token 过期时间两种语义的兜底
            let abs = Credentials(token: "x", phone: "13800000000", expireAt: 1_726_762_443)
            let rel = Credentials(token: "x", phone: "13800000000", expireAt: 3600)
            print("  绝对时间戳语义 → \(abs.expiryDate.map { String(describing: $0) } ?? "nil")")
            print("  相对秒数语义   → \(rel.expiryDate.map { String(describing: $0) } ?? "nil")")

            print("OK")
            exit(0)
        }

        // 联网探针（开发验证用）：直接打一发真实的 login_sms_code 请求，
        // 验证编码方式（form vs JSON）。用法：
        //   AuxAC --probe-sms 13800138000
        // 请只用不会真收到短信的号做这个测试。
        if let idx = CommandLine.arguments.firstIndex(of: "--probe-sms") {
            let phone = CommandLine.arguments.count > idx + 1
                ? CommandLine.arguments[idx + 1]
                : "13800138000"
            print("probe-sms: POST login_sms_code phone=\(phone)")
            Task {
                do {
                    try await AuxAPI().requestSmsCode(phone: phone)
                    print("probe-sms: ✅ 成功（编码方式被服务端接受）")
                    exit(0)
                } catch {
                    print("probe-sms: ❌ 失败 \(error)")
                    exit(1)
                }
            }
            // 让 Task 有机会跑完
            dispatchMain()
        }

        // 端到端登录探针（开发验证用）：验证码换 token → 拉设备列表。
        // 用法：AuxAC --probe-login <手机号> <验证码>
        // 验证码只能人工收短信，所以只在你手上有新鲜验证码时用（一次性，用完即弃）。
        if let idx = CommandLine.arguments.firstIndex(of: "--probe-login") {
            let args = CommandLine.arguments
            guard args.count > idx + 2 else {
                print("用法: AuxAC --probe-login <手机号> <验证码>")
                exit(2)
            }
            let phone = args[idx + 1], code = args[idx + 2]
            print("probe-login: account=\(phone) code=<已隐藏>")
            Task {
                let api = AuxAPI()
                do {
                    let creds = try await api.loginBySms(phone: phone, code: code)
                    print("probe-login: ✅ token = \(creds.token)")
                    print("probe-login:    expireAt = \(creds.expireAt.map { String($0) } ?? "无")")
                    let devices = try await api.fetchDevices(token: creds.token)
                    print("probe-login: ✅ 设备 \(devices.count) 台")
                    for d in devices {
                        let st = ACState(raw: d.data)
                        print("  - \(d.displayName) did=\(d.did) pk=\(d.pk) on=\(st.isOn) temp=\(st.targetTemperature.map { String($0) } ?? "nil")")
                    }
                    print("OK")
                    exit(0)
                } catch {
                    print("probe-login: ❌ \(error)")
                    exit(1)
                }
            }
            dispatchMain()
        }

        // URL 解析探针（开发验证用）：只看解析结果，不联网、不下发。
        // 用法：AuxAC --url-probe 'auxac://temp/+0.5'
        if let idx = CommandLine.arguments.firstIndex(of: "--url-probe") {
            let raw = CommandLine.arguments.count > idx + 1
                ? CommandLine.arguments[idx + 1]
                : "auxac://help"
            guard let url = URL(string: raw) else {
                print("url-probe: ❌ 不是合法 URL: \(raw)")
                exit(1)
            }
            if let command = AuxCommand.parse(url) {
                print("url-probe: ✅ \(raw) → \(command)")
                exit(0)
            } else {
                print("url-probe: ❌ 解析不了: \(raw)")
                print(AuxCommand.helpText())
                exit(1)
            }
        }

        // 登录项探针（开发验证用）：打印系统当前认不认我们。
        // 只读，不改状态——注册/注销要用户点头，不该由探针偷偷做。
        if CommandLine.arguments.contains("--login-probe") {
            print("login-probe: SMAppService.mainApp.status = \(LaunchAtLogin.describe())")
            print("login-probe: bundleIdentifier = \(Bundle.main.bundleIdentifier ?? "(nil)")")
            print("login-probe: bundlePath = \(Bundle.main.bundlePath)")
            print("login-probe: agentURL = \(LaunchAtLogin.agentURL.path)")
            if let plist = try? LaunchAtLogin.agentPlist(),
               let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
               let text = String(data: data, encoding: .utf8) {
                print("login-probe: agent plist（内容核对，未写盘）——")
                print(text)
            } else {
                print("login-probe: ⚠️ 生成 agent plist 失败")
            }
            exit(0)
        }

        // 启动探针（开发验证用）：注册一个延时退出，然后照常构建 UI
        Self.installLaunchProbeIfRequested()
        Self.installWindowProbeIfRequested()
    }

    /// 启动探针：让 SwiftUI 真正跑起来（含 MenuBarExtra 初始化），写出心跳文件，
    /// 等指定的毫秒数后自动退出。
    ///
    /// 存在的意义：本机沙箱禁掉了 `ps`，没法用常规方式确认「GUI 起来之后没有立刻崩」。
    /// 探针把「活着」这件事变成一个可被 shell 断言的文件，从而能自动化验证。
    /// 仅用于开发验证，正常使用不会碰到——进程会按 `ms` 参数自己退出。
    private static func installLaunchProbeIfRequested() {
        guard let idx = CommandLine.arguments.firstIndex(of: "--launch-probe") else { return }
        let ms = CommandLine.arguments.count > idx + 1
            ? (Int(CommandLine.arguments[idx + 1]) ?? 2500)
            : 2500
        let marker = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("auxac-launch-probe.txt")
        try? FileManager.default.removeItem(at: marker)

        DispatchQueue.main.asyncAfter(deadline: .now() + Double(ms) / 1000.0) {
            let payload = "alive pid=\(ProcessInfo.processInfo.processIdentifier)\n"
            try? payload.write(to: marker, atomically: true, encoding: .utf8)
            print("launch-probe: 存活 \(ms)ms，写入 \(marker.path)")
            NSApplication.shared.terminate(nil)
        }
    }

    /// 窗口尺寸探针（开发验证用）：把 `NSApp.windows` 的尺寸打到 stdout，然后自己退出。
    ///
    /// 存在的意义：菜单栏面板宽度是用户直接投诉过的项（「面板左右多余宽度」），
    /// 而本机沙箱下没法用 Accessibility 或 `ps` 去量窗口——只能从进程内部读。
    /// 正常使用不会碰到（必须显式传 `--window-probe`）。
    private static func installWindowProbeIfRequested() {
        guard CommandLine.arguments.contains("--window-probe") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            print("window-probe: windows=\(NSApp.windows.count)")
            for w in NSApp.windows {
                print("  \(type(of: w)) frame=\(w.frame) contentView=\(w.contentView?.frame.size ?? .zero) visible=\(w.isVisible)")
            }
            NSApplication.shared.terminate(nil)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            RootView()
                .environmentObject(model)
                .environmentObject(log)
        } label: {
            // 图标同时反映开关与模式（开机时按模式显示雪花/太阳/风/水滴），
            // 不展开面板也能看出空调在干嘛。逻辑收在 AppModel.menuBarSymbol，
            // 面板头部用的是同一个属性，两处不会走偏。
            //
            // 开机时再跟一个目标温度（`23.5°`），连点都不用点就知道设了几度。
            // 关机时 menuBarTemperatureText 返回 nil，只留电源图标；用户也能在
            // 齿轮菜单里把它关掉。
            //
            // `.monospacedDigit()` 是必需的：数字不等宽的话，23.5 变成 24 时
            // 整条菜单栏会重新排版，旁边的图标会左右抖一下。
            HStack(spacing: 3) {
                Image(systemName: model.menuBarSymbol)
                if let temperature = model.menuBarTemperatureText {
                    Text(temperature)
                        .monospacedDigit()
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            switch model.phase {
            case .loggedOut, .needCode:
                LoginView()
            case .ready:
                ControlView()
            }
        }
        // 这里**刻意不套** `.frame(width:)`：宽度由两个子视图各自声明并保持一致。
        // 在外面统一套一个较宽的 frame，会把较窄的子视图居中、左右留出多余边距。
    }
}
