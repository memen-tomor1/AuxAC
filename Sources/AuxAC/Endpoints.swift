import Foundation

/// 国内线（奥克斯A+ / AUX Home）的接口常量。
///
/// 注意：AUX 另有海外线 `eu-smthome-api.aux-global.com`（AC Freedom App），
/// 协议完全不同（邮箱密码 + RSA/AES 加密），不要混用。详见 docs/PROTOCOL.md
enum Endpoints {
    /// 来自 APK（com.broadlink.auxair, versionCode 440）里硬编码的 `https://smarthome.aux-home.com/app/`。
    /// `smthomeav.aux-home.com` 是同一个后端的另一条边缘（实测两边接口/返回完全一致），
    /// 2024 年论坛帖用的就是它，所以留作兜底。
    static let host = "https://smarthome.aux-home.com"
    static let fallbackHost = "https://smthomeav.aux-home.com"

    /// 发送短信验证码。POST **form-urlencoded**，参数 `phone`。
    static let loginSmsCode = "/app/login_sms_code"
    /// 用手机号 + 验证码换 token。POST **JSON**，字段是 `account`（手机号）+ `code`（验证码）。
    ///
    /// 注意路径是 `auth/` 不是 `wechatMini/`——后者是旧版/小程序线，
    /// 对同一份 body 只会回 `60008 token 无效`（详见 docs/PROTOCOL.md §1）。
    static let loginBySms = "/app/auth/loginBySms"
    /// 设备列表；getStatus=true 才会带实时状态
    static let deviceBindings = "/app/device_bindings"
    /// 下发控制指令。POST **JSON**，body 为 `{"intent": {...}, "deviceId": "..."}`。
    ///
    /// 这是 2026-10 用 MITM 从 iPhone 真机抓到的**现行**接口。
    /// 实测 `deviceId` 是唯一必填的设备标识（`did` 只是可选别名，用 `did` 代替
    /// `deviceId` 会回 `{"code":-100,"message":"参数不正确"}`）；抓包的完整包络里
    /// `dst`/`type`/`nickName`/`needControl`/`uid`/`environmentData`/`did` **全部可省**。
    /// 旧的 `/app/wechatMini/new_device_control` 已不是现行接口，见 docs/PROTOCOL.md §4。
    static let deviceControl = "/app/device/v2/control"

    /// 能耗统计。GET，query 为
    /// `device_id=<MAC 去掉冒号并小写>&sub_index=0&timestart=<yyyy-MM-dd>&timeend=<yyyy-MM-dd>&unit=month|year`。
    ///
    /// 这是官方 App 里那个「用电量」图表页**自己**在用的接口。来源不是猜的：那个页面是一个
    /// 明文 vite 打包网页（`https://smarthome.aux-home.com/battery100/index.html`，
    /// JS 里 `bl/statistics/status` 出现 5 次），直接下载下来读出来的。详见 docs/PROTOCOL.md §9。
    static let energyStatistics = "/app/bl/statistics/status"

    static func url(_ path: String, query: [String: String] = [:]) -> URL? {
        var comps = URLComponents(string: host + path)
        if !query.isEmpty {
            comps?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return comps?.url
    }
}

enum AuxError: LocalizedError {
    case invalidURL
    case transport(String)
    case api(code: Int, message: String)
    case decoding(String)
    case notLoggedIn

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "接口地址构造失败"
        case .transport(let s):
            return "网络错误：\(s)"
        case .api(let code, let message):
            return "服务端返回错误 \(code)：\(message)"
        case .decoding(let s):
            return "响应解析失败：\(s)"
        case .notLoggedIn:
            return "尚未登录"
        }
    }
}

extension AuxError {
    /// 服务端判定「这个 token 不能用了」，应当退回登录态。
    ///
    /// **`60106` 才是 AUX 实际会回的那个。** 它不用 HTTP 的 401/403 那一套，
    /// 而是把鉴权失败塞在 body 的 `code` 里：无 token / 假 token / 裸 token
    /// （少了 `Bearer ` 前缀）对 `/app/*` 下**任意**路径都回
    /// `{"code":60106,"message":"用户账号缓存过期，请重新登录"}`。
    ///
    /// 这条最常触发的场景不是自然过期（token 有效期实测约 30 天），而是**手机 App
    /// 登录了同一个账号**——AUX 一个账号只允许一个会话，手机一登，Mac 这边的
    /// token 立刻作废。所以必须认这个码，否则界面只会停在「同步失败」，
    /// 用户看不懂，也不知道该重新登录。
    var isAuthExpired: Bool {
        if case .api(let code, _) = self {
            return code == 401 || code == 403 || code == 60106
        }
        return false
    }
}
