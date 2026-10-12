import Foundation

/// 设备列表接口返回的一台空调。
///
/// 字段名严格对齐 docs/PROTOCOL.md §2.2（来自公开抓包记录）。
struct Device: Identifiable, Codable, Hashable {
    let did: String
    let productKey: String
    let alias: String?
    let mac: String?
    let deviceId: String?
    let password: String?
    /// 设备是否在线。设备列表页用它点一个小圆点。
    /// 缺失时按「在线」处理——宁可少报一次离线，也不要把拿不到字段当离线吓人。
    let online: Bool?
    let data: [String: JSONValue]?

    var id: String { did }
    var pk: String { productKey }

    /// 设备在**奥克斯服务器上**的名字（alias），不带本地备注。
    /// 带备注的显示名走 `AppModel.name(for:)`。
    var displayName: String { alias?.isEmpty == false ? alias! : (mac ?? did) }

    enum CodingKeys: String, CodingKey {
        case did, productKey, alias, mac, deviceId, password, online, data
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        did = try c.decode(String.self, forKey: .did)
        productKey = try c.decode(String.self, forKey: .productKey)
        alias = try? c.decodeIfPresent(String.self, forKey: .alias)
        mac = try? c.decodeIfPresent(String.self, forKey: .mac)
        deviceId = try? c.decodeIfPresent(String.self, forKey: .deviceId)
        password = try? c.decodeIfPresent(String.self, forKey: .password)
        online = try? c.decodeIfPresent(Bool.self, forKey: .online)
        data = try? c.decodeIfPresent([String: JSONValue].self, forKey: .data)
    }
}

/// 通用 JSON 值。设备状态字段会随固件/机型变化，
/// 用宽松容器接住，避免因为多一个未知字段就整条解析失败。
enum JSONValue: Codable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let d = try? c.decode(Double.self) { self = .number(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        self = .null
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let d):
            // 整数就编码成整数，避免下发 29 变成 29.0 被服务端拒绝
            if d == d.rounded() && abs(d) < 1e15 { try c.encode(Int(d)) } else { try c.encode(d) }
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    var intValue: Int? {
        switch self {
        case .number(let d): return Int(d)
        case .bool(let b): return b ? 1 : 0
        case .string(let s): return Int(s) ?? Double(s).map(Int.init)
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .number(let d): return d
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .number(let d): return d != 0
        case .string(let s):
            if let i = Int(s) { return i != 0 }
            return nil
        default: return nil
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .number(let d): return d == d.rounded() ? String(Int(d)) : String(d)
        default: return nil
        }
    }
}

/// 设备状态的语义化视图：把 `data` 里一堆裸字段翻译成 UI 能用的类型。
///
/// 这里刻意做成「宽松读取 + 多候选字段名」：PROTOCOL.md 的待确认清单
/// #4（模式字段名）、#6（风速取值）、#7（扫风取值）还没实测确认，
/// 所以同一个语义尽量尝试多个可能的键名，避免实测时全盘返工。
struct ACState {
    let raw: [String: JSONValue]

    init(raw: [String: JSONValue]?) { self.raw = raw ?? [:] }

    private func first(_ keys: String...) -> JSONValue? {
        for k in keys { if let v = raw[k], v != .null { return v } }
        return nil
    }

    var isOn: Bool { first("on_off", "onOff", "power")?.boolValue ?? false }

    /// 目标温度，已折算成摄氏度（含半度）。
    ///
    /// 设备把半度**拆成两个字段**存：`temperature` 是整数部分，`temperature_decimal`
    /// 非 0（实测为 `5`）表示再加 0.5。但**下发**时不用拆——直接给 `temperature`
    /// 一个浮点摄氏度即可（实测 `{"temperature":24.5}` 被接受）。
    var targetTemperature: Double? {
        guard let t = first("temperature")?.doubleValue else { return nil }
        let d = first("temperature_decimal")?.doubleValue ?? 0
        return t + (d > 0 ? 0.5 : 0)
    }

    /// 目标温度是否带半度（`half` 或 `temperature_decimal`）。
    var hasHalfDegree: Bool {
        let h = first("half")?.intValue ?? 0
        let d = first("temperature_decimal")?.intValue ?? 0
        return h != 0 || d != 0
    }

    /// 模式原始整数。**实测确认字段名是 `air_con_func`**。
    ///
    /// 注意：下发 `{"mode":2}` 会返回 `{"code":200,"message":"OK"}` 但**状态里纹丝不动**
    /// ——服务端对未知键静默忽略。只有 `air_con_func` 会真正改变状态。
    var modeRaw: Int? { first("air_con_func", "mode", "work_mode", "running_mode", "workMode")?.intValue }

    /// 风速原始整数。字段名实测确认为 `wind_speed_1`（状态里就是这么命名的）。
    var fanRaw: Int? { first("wind_speed_1", "wind_speed", "windSpeed", "fan_speed")?.intValue }

    var upDownSwingRaw: Int? { first("up_down_swing", "upDownSwing")?.intValue }
    var leftRightSwingRaw: Int? { first("left_right_swing", "leftRightSwing")?.intValue }

    // MARK: - 扫风档位（⚠️ 极性是反的，且左右档位编号错位）
    //
    // 服务端 `deviceMutex` 表（`GET /app/getConfig?id=deviceMutex`）给出的取值：
    //   up_down_swing:   0=开启(摆动), 1..5=定格1..5, 7=关闭
    //   left_right_swing: 0=开启(摆动), 1=定格1, 2=定格2, 3=定格3,
    //                     4=开启(摆动), 5=定格5, 6=定格4, 7=关闭
    //
    // 两条要命的细节：
    // 1. **`0` = 自动摆动，其余 = 固定角度**，`7` 是明确的「关闭」。
    //    早期按布尔写成 `on ? 1 : 0`，点「开」反而把叶片停住，被用户报「扫风反了」。
    // 2. **左右那两个定档是错位的**：`5` 是定格5、`6` 才是定格4。
    //    照数字顺序做会把定格 4/5 弄反，所以映射专门写成数组，别用算术推。
    //
    // 用户抓包实测按过 `up_down_swing` = 1 / 3 / 5（定格1/3/5），
    // 确认这些定格档位是真在用的功能，不是表里的摆设。

    /// 上下扫风「界面档位索引 → 线上取值」。索引 0=摆动、1..5=定格1..5、6=关闭。
    static let upDownSwingValues = [0, 1, 2, 3, 4, 5, 7]
    /// 左右扫风「界面档位索引 → 线上取值」。⚠️ 索引 4/5 对应线上 6/5，是**交叉**的。
    static let leftRightSwingValues = [0, 1, 2, 3, 6, 5, 7]
    /// 与上面两个数组一一对应的界面文案。
    static let swingLabels = ["摆动", "1", "2", "3", "4", "5", "关闭"]

    /// 当前上下扫风档位索引（未知返回 nil）。
    var upDownSwingIndex: Int? {
        upDownSwingRaw.flatMap { ACState.upDownSwingValues.firstIndex(of: $0) }
    }

    /// 当前左右扫风档位索引。表里 `0` 与 `4` 都表示摆动，统一归到索引 0。
    var leftRightSwingIndex: Int? {
        guard let raw = leftRightSwingRaw else { return nil }
        return ACState.leftRightSwingValues.firstIndex(of: raw == 4 ? 0 : raw)
    }

    /// 上下扫风是否**正在摆动**。判的是 `== 0`，不是 `!= 0`。
    var upDownSwingOn: Bool? { upDownSwingRaw.map { $0 == 0 } }

    /// 左右扫风是否正在摆动（表里 `0` 与 `4` 都是「开启」）。
    var leftRightSwingOn: Bool? { leftRightSwingRaw.map { $0 == 0 || $0 == 4 } }

    var sleepMode: Bool { first("sleep_mode", "sleepMode")?.boolValue ?? false }
    var eco: Bool { first("eco")?.boolValue ?? false }
    var clean: Bool { first("clean")?.boolValue ?? false }
    var antiFungus: Bool { first("anti_fungus", "antiFungus")?.boolValue ?? false }
    var healthy: Bool { first("healthy")?.boolValue ?? false }

    /// 屏显。
    ///
    /// ⚠️ **状态字段名与下发字段名不是一个**：状态里叫 `screen_on_off`，
    /// 而**下发要用 `screen`**（0=关闭 / 1=开启屏显 / 2=智能光感）。
    /// 早期版本拿 `screen_on_off` 去下发，服务端回 200 但设备静默忽略，
    /// 被用户报为「屏显无效」。真机确认改成 `screen` 后 4 秒写回。
    var screenOn: Bool { first("screen_on_off", "screenOnOff")?.boolValue ?? false }

    /// 童锁（`electric_lock`）。官方 `deviceMutex` 表里**几乎每一项** `toastMutex`
    /// 的第一条都是它（`"空调已锁定，解锁后才可操作"`），所以它是一道全局闸。
    var electricLockOn: Bool { first("electric_lock", "electricLock")?.boolValue ?? false }

    /// S+ 黄金舒睡（`sleep_diy`）。表里 `temperature` / `wind_speed` / `sleep_mode`
    /// 都带一条「请关闭 S+黄金舒睡后进行操作」，即它开着时那几项不能设。
    /// （注意它和普通的 `sleep_mode` 睡眠是**两个不同字段**，别混。）
    var sleepDIYOn: Bool { first("sleep_diy", "sleepDiy")?.boolValue ?? false }

    var supportsHeat: Bool { first("support_heat", "supportHeat")?.boolValue ?? false }

    /// 室温。**已定案：云 API 不返回室温**（见 `docs/PROTOCOL.md` §2.5），
    /// 所以这里恒为 nil，界面会退化掉「室温」那半句。
    /// 保留这几个候选键名是为了兼容可能的其他机型/固件，不是为了等它变非 nil。
    var roomTemperature: Double? {
        first("room_temperature", "roomTemperature", "indoor_temperature",
              "indoorTemperature", "current_temperature", "currentTemperature")?.doubleValue
    }
}

/// 服务端 `deviceMutex` 表（官方 App 自己的「哪个功能什么时候不能按」规则表）。
///
/// 表是从 `GET /app/getConfig?id=deviceMutex` 拿的——**不需要鉴权**，只要带对
/// User-Agent 就能拉（60 项功能，已落盘 `/tmp/auxrev/dm.json`）。官方 App 就是
/// 按这张表灰按钮 / 弹 toast 的。
///
/// 写成**纯函数**（输入 `ACState`，输出「不能用的原因」或 nil）有两个好处：
/// 一是 `--selftest` 能不联网直接断言，二是界面与下发走的是同一份判断，
/// 不会出现「按钮亮着但发出去被拦」。
///
/// ## 一个刻意的取舍：表比设备严
///
/// 表里 `temperature` / `wind_speed` / 两个摆风都带一条
/// 「`on_off=0` → 请先开机后再使用该功能」，但真机逐个实测**关机态也能写回**
/// （见 `AppModel.requirePower` 上方那张表）。所以这里**不抄电源那一条**，
/// 只抄「物理上说不通」的几条——否则会把本来能用的功能灰掉。
/// 真被设备忽略的只有 `sleep_mode` / `eco`，那两个由 `requirePower` 兜。
enum ControlMutex {

    /// 童锁。表里连开关机那条也只有这一项，所以是全局闸。
    static func lock(_ s: ACState) -> String? {
        s.electricLockOn ? "空调已锁定（童锁），请先在奥克斯A+ App 里解锁" : nil
    }

    /// `temperature` 条（去掉 `on_off` 那条之后剩余的）。
    static func temperature(_ s: ACState) -> String? {
        if let reason = lock(s) { return reason }
        if s.modeRaw == ACMode.autoRawValue { return "自动模式下不能调节温度" }
        if s.modeRaw == ACMode.fan.rawValue { return "送风模式下不能调节温度" }
        if s.sleepDIYOn { return "请关闭 S+黄金舒睡后操作" }
        return nil
    }

    /// `wind_speed` 条（去掉 `on_off` 那条之后剩余的）。
    static func fan(_ s: ACState) -> String? {
        if let reason = lock(s) { return reason }
        if s.modeRaw == ACMode.dry.rawValue { return "除湿模式下不能调节风速" }
        if s.sleepDIYOn { return "请关闭 S+黄金舒睡后操作" }
        return nil
    }

    /// `sleep_mode` 条。
    static func sleep(_ s: ACState) -> String? {
        if let reason = lock(s) { return reason }
        if s.modeRaw == ACMode.autoRawValue { return "自动模式下无效" }
        if s.modeRaw == ACMode.fan.rawValue { return "送风模式下无效" }
        if s.sleepDIYOn { return "S+黄金舒睡开启时不能设置" }
        return nil
    }

    /// `eco` 条。表里对取值 `0`/`2`/`4`/`6` 各列了一条「仅制冷模式有效」，
    /// 也就是**只有制冷模式能用**（这是本机实测之外、纯从表里读出来的约束）。
    static func eco(_ s: ACState) -> String? {
        if let reason = lock(s) { return reason }
        guard let mode = s.modeRaw else { return nil }
        return mode == ACMode.cool.rawValue ? nil : "仅制冷模式有效"
    }

    /// `air_con_func` / 两个摆风 / `screen` / `on_off`：表里除童锁外没有别的互斥项。
    static func none(_ s: ACState) -> String? { lock(s) }
}

/// 运行模式。字段名是 `air_con_func`。
///
/// 取值表来自服务端下发的 `GET /app/getConfig?id=deviceMutex`（官方 App 就是按它建界面的）：
/// `0=自动 / 1=制冷 / 2=除湿 / 4=制热 / 6=送风`。
///
/// ⚠️ 早期版本按「行业惯例」猜成 1/2/3/4 = 制冷/制热/送风/除湿，**是错的**：
/// 3 在服务端表里根本不存在，而 6（送风）实测能写回。以真机实测 + 服务端表为准。
///
/// 注意：本机 `feature.mode` 声明为 `["1,2,3,4","1"]`，与 mutex 表不一致；
/// 但实测 `air_con_func=6`（送风）与 `=2`（除湿）都能写回状态，故以 mutex 表为准。
/// 「自动」(0) 本机未验证，暂不提供。
enum ACMode: Int, CaseIterable, Identifiable {
    case cool = 1, dry = 2, heat = 4, fan = 6

    /// 自动档。**本机不支持**——`feature.mode` = `["1,2,3,4"]` 里没有 0，
    /// 且真机抓包里官方 App 从未下发过 0。所以**不作为可选项暴露**，只给互斥表用：
    /// `ControlMutex` 要按「`air_con_func == 0` 就是自动模式」来判断。
    static let autoRawValue = 0

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .cool: return "制冷"
        case .heat: return "制热"
        case .fan:  return "送风"
        case .dry:  return "除湿"
        }
    }

    var symbol: String {
        switch self {
        case .cool: return "snowflake"
        case .heat: return "sun.max"
        case .fan:  return "wind"
        case .dry:  return "drop"
        }
    }
}

/// 风速档位。
///
/// **键名**：下发用 `wind_speed`，而 `wind_speed_1` 只是**状态上报**里的字段名
/// （用它下发服务端回 200 但完全忽略，状态纹丝不动）。
///
/// **取值表**来自服务端 `GET /app/getConfig?id=deviceMutex`：
/// `0=低档 / 1=中档 / 2=高档 / 3=静音 / 4=自动 / 5=强力 / 6=中低 / 7=中高`。
///
/// ⚠️ 早期版本猜成 `0=自动, 1…6=1…6 档`，**是错的**。现在按上表，声明顺序即界面顺序
/// （按实际风量从弱到强排，`auto` 放最前）。
///
/// **不含「强力」(5)**：真机实测下发 `wind_speed=5` 状态纹丝不动，本机不支持。
/// 「强力」在官方 App 里也点不动（见 README「本机不支持的功能」）。
///
/// `wind_speed_1` 上报的是**另一套刻度**（实测下发 0 上报 1、下发 4 上报 6），
/// 无法反推用户选了哪一档，所以界面高亮认 `AppModel.preferredFan`。
enum FanSpeed: Int, CaseIterable, Identifiable {
    case auto = 4, quiet = 3, low = 0, mediumLow = 6, medium = 1, mediumHigh = 7, high = 2

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .auto:       return "自动"
        case .quiet:      return "静音"
        case .low:        return "低档"
        case .mediumLow:  return "中低"
        case .medium:     return "中档"
        case .mediumHigh: return "中高"
        case .high:       return "高档"
        }
    }
}

// MARK: - 能耗

/// 能耗图表的时间范围。
///
/// ⚠️ 注意 `unit` 是**服务端的粒度**，不等于用户选的范围，而且服务端**完全忽略
/// `timestart`/`timeend` 的范围**——它只按起始日决定返回哪个月/哪一年的完整数据。
/// 实测：传 `10-05~10-11` 和传 `10-01~10-31` 返回一模一样的一整月每日数据；
/// 传 `2026-01-01~2026-12-31&unit=year` 返回整年每月合计。
///
/// 后果：「近 7 天」拿不到一个只有 7 条的响应，只能拉整月再在本地截取；
/// 如果这 7 天跨月，还得再拉一次上个月（官方那个网页也是这么干的，
/// 它自己会打印「周视图跨越两个月，需要请求两次API」）。
enum EnergyRange: String, CaseIterable, Identifiable {
    case week
    case month
    case year

    var id: String { rawValue }

    var label: String {
        switch self {
        case .week:  return "近 7 天"
        case .month: return "本月"
        case .year:  return "今年"
        }
    }

    /// 要传给服务端的 `unit`。只有「今年」是 year，其余都用 month 粒度。
    var unit: String { self == .year ? "year" : "month" }
}

/// 能耗图上的一个柱子。`label` 就是要显示的轴标签，由 `dtval` 转成形。
struct EnergyPoint: Identifiable, Hashable {
    /// 服务端给的 `dtval` 原文，例如 `"2026-10-07"` 或 `"2026-09"`。
    /// 留着它是因为范围裁剪要在本地做（服务端忽略时间范围），比拿 label 反解日期可靠。
    let key: String
    /// 日粒度是 `"10-07"`，月粒度是 `"9月"`。
    let label: String
    let kwh: Double

    var id: String { key }
}
