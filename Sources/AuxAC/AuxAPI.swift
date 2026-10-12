import Foundation

/// 奥克斯A+ 国内线云接口客户端。
///
/// 协议细节与可信度标注见 docs/PROTOCOL.md。这里的原则是：
/// **凡是尚未实测确认的地方（响应外层结构、错误码、字段名）都做多重兜底**，
/// 这样实测时不需要为了一个小结构差异重写整层。
final class AuxAPI {
    private let session: URLSession
    private let log = DebugLog.shared

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 40
        // 注意：**这里不设全局 Content-Type**。实测证明同一个服务端对不同接口
        // 要求的编码不一样：`/app/login_sms_code` 要 form-urlencoded（发 JSON 会被
        // 参数绑定拒成 400 "Bad Request!"），而 `/app/auth/loginBySms` 反过来要 JSON
        // （发 form 是 415 Unsupported Media Type）。所以由每次请求自己声明。
        cfg.httpAdditionalHeaders = [
            // 抓包记录里的 App UA 风格；服务端是否校验未知（PROTOCOL.md #11）
            "User-Agent": "AUXHome/1.0 (iPhone; iOS) okhttp/3.12.0",
        ]
        session = URLSession(configuration: cfg)
    }

    // MARK: - 底层请求

    /// 把 [String: String] 编码成 form-urlencoded。
    private func formEncode(_ params: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let pairs = params.map { k, v -> String in
            let ek = k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k
            let ev = v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v
            return "\(ek)=\(ev)"
        }
        return Data(pairs.sorted().joined(separator: "&").utf8)
    }

    /// 发一个请求并把整个响应体交出去。
    /// 这里**不做任何 JSON 结构假设**——成功与否、字段位置都由调用方兜底。
    @discardableResult
    private func send(
        _ path: String,
        method: String,
        query: [String: String] = [:],
        form: [String: String]? = nil,
        body: [String: Any]? = nil,
        token: String? = nil,
        rawFile: String? = nil
    ) async throws -> Data {
        guard let url = Endpoints.url(path, query: query) else { throw AuxError.invalidURL }

        var req = URLRequest(url: url)
        req.httpMethod = method
        if let token, !token.isEmpty {
            // ✅ 实测：**必须带 `Bearer ` 前缀**（2026-10，用真 token 验证）。
            // 2024 论坛帖说「token 直接作为 Authorization 值、不带前缀」，对这个后端是错的。
            // 注意：不带前缀时得到的是 `60106 用户账号缓存过期`，而这个码对**所有**
            // `/app/*` 路径都返回（连我瞎编的 `/app/zzz_totally_bogus` 也一样），
            // 所以它**不能**用来判断路径是否存在或 token 是否有问题——
            // 只有「带前缀 + 真 token」这一个组合能证明请求是对的。
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        var readableBody: String?
        if let form {
            req.setValue("application/x-www-form-urlencoded; charset=UTF-8",
                         forHTTPHeaderField: "Content-Type")
            req.httpBody = formEncode(form)
            readableBody = String(decoding: req.httpBody ?? Data(), as: UTF8.self)
        } else if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let d = try JSONSerialization.data(withJSONObject: body, options: [])
            req.httpBody = d
            readableBody = String(decoding: d, as: UTF8.self)
        }

        log.log("→ \(method) \(path)\(query.isEmpty ? "" : "?\(query.map { "\($0.key)=\($0.value)" }.joined(separator: "&"))")")
        if let readableBody {
            log.log("  请求体: \(DebugLog.redact(readableBody))")
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            log.log("✗ 传输失败: \(error.localizedDescription)")
            throw AuxError.transport(error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let text = String(decoding: data, as: UTF8.self)
        log.log("← HTTP \(status) (\(data.count) bytes) \(DebugLog.redact(String(text.prefix(1200))))")

        // 把完整原始响应落盘，方便事后核对字段（日志里的被截断了）
        if let rawFile {
            let url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/AuxAC", isDirectory: true)
                .appendingPathComponent(rawFile)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: url)
        }

        guard (200..<300).contains(status) else {
            throw AuxError.transport("HTTP \(status)")
        }
        return data
    }

    /// 尽力从响应里挖出「业务状态码」。挖不到就返回 nil，视为成功。
    private func businessCode(_ obj: Any) -> Int? {
        guard let dict = obj as? [String: Any] else { return nil }
        for key in ["code", "status", "statusCode", "resultCode"] {
            if let n = dict[key] as? Int { return n }
            if let n = dict[key] as? NSNumber { return n.intValue }
        }
        return nil
    }

    private func businessMessage(_ obj: Any) -> String {
        guard let dict = obj as? [String: Any] else { return "（无 message）" }
        for key in ["message", "msg", "errorMessage", "desc", "errMsg"] {
            if let s = dict[key] as? String, !s.isEmpty { return s }
        }
        return "（无 message）"
    }

    private func isSuccessCode(_ code: Int) -> Bool {
        code == 200 || code == 0 || code == 1
    }

    // MARK: - 登录

    /// 请求发送短信验证码。
    /// 实测：必须 form-urlencoded，发 JSON 会 `400 Bad Request!`（连手机号都没读到）。
    func requestSmsCode(phone: String) async throws {
        let data = try await send(
            Endpoints.loginSmsCode,
            method: "POST",
            form: ["phone": phone],
            rawFile: "last-login_sms_code.json")

        guard let obj = try? JSONSerialization.jsonObject(with: data) else {
            // 返回的不是 JSON 也先不报错——有些网关会返回纯文本 "OK"
            log.log("⚠️ login_sms_code 返回非 JSON，按成功处理")
            return
        }
        log.log("login_sms_code 原始响应: \(DebugLog.redact(String(decoding: data, as: UTF8.self)))")

        if let code = businessCode(obj), !isSuccessCode(code) {
            throw AuxError.api(code: code, message: businessMessage(obj))
        }
    }

    /// 用验证码换 token。返回解析出的凭据。
    ///
    /// 实测（2026-10-11，靠响应差异穷举出来的）：
    /// - 路径必须是 `/app/auth/loginBySms`；**必须发 JSON**（form → `415 Unsupported Media Type`）。
    /// - 字段名是 **`account`**（手机号）+ **`code`**（验证码），不是 `phone`/`smsCode`。
    ///   用任何其它名字组合都会得到同一个 `64012 手机号验证码不能为空`
    ///   （服务端 `@NotBlank` 校验），只有 `account`+`code` 能推进到 `9015 验证码错误`。
    func loginBySms(phone: String, code: String) async throws -> Credentials {
        let data = try await send(
            Endpoints.loginBySms,
            method: "POST",
            body: ["account": phone, "code": code],
            rawFile: "last-loginBySms.json")

        guard let obj = try? JSONSerialization.jsonObject(with: data) else {
            throw AuxError.decoding("响应不是合法 JSON")
        }
        log.log("loginBySms 原始响应: \(DebugLog.redact(String(decoding: data, as: UTF8.self)))")

        if let bc = businessCode(obj), !isSuccessCode(bc) {
            throw AuxError.api(code: bc, message: businessMessage(obj))
        }

        // token 可能出现在任意层级，递归找第一个叫 token 的字符串值；
        // expireAt 同理。抓包记录显示它们在 openApiToken 对象里。
        let token = Self.findString(in: obj, keys: ["token", "accessToken", "access_token"])
        let expire = Self.findDouble(in: obj, keys: ["expireAt", "expire_at", "expiresAt", "expiresIn"])

        guard let token, !token.isEmpty else {
            throw AuxError.decoding("响应里找不到 token 字段。原始响应已存到 ~/Library/Logs/AuxAC/last-loginBySms.json")
        }

        log.log("✅ 登录成功，token 长度 \(token.count)，expireAt=\(expire.map { String($0) } ?? "无")")
        return Credentials(token: token, phone: phone, expireAt: expire)
    }

    // MARK: - 设备

    func fetchDevices(token: String) async throws -> [Device] {
        let data = try await send(
            Endpoints.deviceBindings,
            method: "GET",
            query: ["getStatus": "true"],
            token: token,
            rawFile: "last-device_bindings.json")

        guard let obj = try? JSONSerialization.jsonObject(with: data) else {
            throw AuxError.decoding("设备列表响应不是合法 JSON")
        }

        if let bc = businessCode(obj), !isSuccessCode(bc) {
            throw AuxError.api(code: bc, message: businessMessage(obj))
        }

        // 兼容 data 直接是数组、或 data.devices / data.list 是数组三种形态
        guard let devices = Self.findDeviceArray(in: obj) else {
            throw AuxError.decoding("响应里找不到设备数组。原始响应已存到 ~/Library/Logs/AuxAC/last-device_bindings.json")
        }
        return devices
    }

    // MARK: - 控制

    /// 下发控制指令。
    ///
    /// - Parameters:
    ///   - intent: 要改变的字段。**增量下发**，只放变化的键。
    ///             例如 `["on_off": 1]`、`["temperature": 295]`。
    ///
    /// ⚠️ 两个来自真机抓包的硬约束（写错只回含糊错误码）：
    /// 1. 键名是 **`intent`**，不是 `action`；
    /// 2. 设备标识必须放在 **`deviceId`**，用 `did` 会回 `{"code":-100,"message":"参数不正确"}`。
    ///
    /// 抓包里 `dst`/`type`/`nickName`/`needControl`/`uid`/`environmentData`/`did`
    /// 实测**全部可省**，所以这里只发最小包络。
    func control(device: Device, intent: [String: JSONValue], token: String) async throws {
        // intent 的值用 JSONValue 编码，保证 Int 不被写成 29.0。
        // ⚠️ 必须传 `.fragmentsAllowed`：`JSONSerialization.jsonObject(with:)` 默认
        // **拒绝顶层标量片段**，而 intent 的值恰恰就是裸数字（如 on_off=1）。
        // 不加这个选项时 `o` 恒为 nil，整个 intent 会被静默丢空成 `{}`，
        // 服务端只会回一个含糊的 `{"code":-1,"message":"操作失败！"}`。
        var intentDict: [String: Any] = [:]
        for (k, v) in intent {
            if let d = try? JSONEncoder().encode(v),
               let o = try? JSONSerialization.jsonObject(with: d, options: .fragmentsAllowed) {
                intentDict[k] = o
            } else {
                log.log("⚠️ intent 字段 \(k) 编码失败，已跳过")
            }
        }
        let body: [String: Any] = ["intent": intentDict, "deviceId": device.id]

        let data = try await send(
            Endpoints.deviceControl,
            method: "POST",
            body: body,
            token: token,
            rawFile: "last-device_control.json")

        guard let obj = try? JSONSerialization.jsonObject(with: data) else {
            log.log("⚠️ 控制响应非 JSON，按成功处理")
            return
        }
        log.log("控制响应: \(DebugLog.redact(String(decoding: data, as: UTF8.self)))")

        if let bc = businessCode(obj), !isSuccessCode(bc) {
            throw AuxError.api(code: bc, message: businessMessage(obj))
        }
    }

    // MARK: - 能耗

    /// 拉一段能耗统计，返回按时间排好序的柱子。
    ///
    /// ⚠️ 三个都踩过的坑（2026-10 真机验证）：
    /// 1. `device_id` 要的是 **MAC 地址去掉冒号并小写**，**不是 did**。
    ///    传 did 会回 `{"code":"401","list":[{"error":"macaddr-error"}]}`——
    ///    这个错误藏在 200 HTTP 里、而且长得不像「参数错」，很容易当成接口坏了。
    /// 2. 服务端**忽略 `timestart`/`timeend` 的范围**，只按起始日决定返回哪个月/哪一年的
    ///    **完整**数据（传 10-05~10-11 和传 10-01~10-31 结果一模一样），所以范围裁剪
    ///    必须在本地做。详见 `EnergyRange` 的注释。
    /// 3. 外层 `code` 是**字符串** `"200"`（不是数字），数据在 `list` 里、每天/每月一条
    ///    `{"dtval":"2026-10-07","dval":"1"}`，**`dval` 也是字符串**——
    ///    直接按 `code == 200` 判会永远判失败。
    func energyStatistics(
        mac: String,
        unit: String,
        start: String,
        end: String,
        token: String
    ) async throws -> [EnergyPoint] {
        let data = try await send(
            Endpoints.energyStatistics,
            method: "GET",
            query: [
                "device_id": mac,
                "sub_index": "0",
                "timestart": start,
                "timeend": end,
                "unit": unit,
            ],
            token: token,
            rawFile: "last-energy.json")

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuxError.decoding("能耗响应不是合法 JSON")
        }

        // 字符串码和数字码都要认（实测是字符串 "200"）
        if let s = obj["code"] as? String, s != "200", s != "0" {
            throw AuxError.api(code: Int(s) ?? -1, message: Self.energyMessage(obj))
        }
        if let n = obj["code"] as? NSNumber, !isSuccessCode(n.intValue) {
            throw AuxError.api(code: n.intValue, message: Self.energyMessage(obj))
        }

        guard let list = obj["list"] as? [[String: Any]] else {
            // 服务端在没有数据时可能给 `list: []`，也可能干脆不给这个键。
            // 两者都当「这段时间没有用电」处理，不报错——报错会让整页变红，
            // 而「没数据」本身就是一个合法答案。
            return []
        }

        var points: [EnergyPoint] = []
        for item in list {
            guard let dtval = item["dtval"] as? String else { continue }
            // dval 实测是字符串（"4"），但也兜住数字形态
            let kwh = (item["dval"] as? String).flatMap(Double.init)
                ?? (item["dval"] as? NSNumber)?.doubleValue
                ?? 0
            points.append(EnergyPoint(key: dtval, label: Self.energyLabel(dtval, unit: unit), kwh: kwh))
        }
        return points
    }

    /// 服务端报错时把原因挖出来。它把错误放在 `list[0].error` 里，而不是 `message`。
    private static func energyMessage(_ obj: [String: Any]) -> String {
        if let list = obj["list"] as? [[String: Any]],
           let err = list.first?["error"] as? String {
            return err
        }
        return (obj["message"] as? String) ?? "（无 message）"
    }

    /// 把 `dtval` 转成轴标签：日粒度 `"2026-10-07"` → `"10-07"`，月粒度 `"2026-09"` → `"9月"`。
    private static func energyLabel(_ dtval: String, unit: String) -> String {
        let parts = dtval.split(separator: "-")
        if unit == "year" {
            guard parts.count >= 2, let m = Int(parts[1]) else { return dtval }
            return "\(m)月"
        }
        guard parts.count >= 3 else { return dtval }
        return "\(parts[1])-\(parts[2])"
    }

    // MARK: - 宽松解析工具

    /// 在整个 JSON 树里递归找第一个匹配 key 的字符串值。
    private static func findString(in obj: Any, keys: [String]) -> String? {
        guard let dict = obj as? [String: Any] else { return nil }
        for key in keys {
            if let s = dict[key] as? String, !s.isEmpty { return s }
        }
        for (_, v) in dict {
            if let found = findString(in: v, keys: keys) { return found }
        }
        return nil
    }

    private static func findDouble(in obj: Any, keys: [String]) -> Double? {
        guard let dict = obj as? [String: Any] else { return nil }
        for key in keys {
            if let n = dict[key] as? NSNumber { return n.doubleValue }
            if let s = dict[key] as? String, let d = Double(s) { return d }
        }
        for (_, v) in dict {
            if let found = findDouble(in: v, keys: keys) { return found }
        }
        return nil
    }

    private static func findDeviceArray(in obj: Any) -> [Device]? {
        // 形态一：data 直接是设备数组
        if let dict = obj as? [String: Any] {
            for key in ["data", "result", "devices", "list", "rows"] {
                guard let v = dict[key] else { continue }
                if let devices = decodeDevices(v) { return devices }
            }
            // 形态二：整个响应就是一个设备（极少见）
            if dict["did"] != nil, let devices = decodeDevices(dict) { return devices }
            // 形态三：递归下去找
            for (_, v) in dict {
                if let devices = findDeviceArray(in: v), !devices.isEmpty { return devices }
            }
        }
        if let arr = obj as? [Any] { return decodeDevices(arr) }
        return nil
    }

    private static func decodeDevices(_ v: Any) -> [Device]? {
        guard JSONSerialization.isValidJSONObject(v) else { return nil }
        guard let d = try? JSONSerialization.data(withJSONObject: v) else { return nil }
        return try? JSONDecoder().decode([Device].self, from: d)
    }
}
