# 奥克斯A+ 云 API 协议笔记

本文档记录 **奥克斯A+ / AUX Home（国内线，`aux-home.com`）** 的云端接口协议。

> ⚠️ **可信度标注**
> - ✅ = **本机实测确认**（有真实请求/响应）
> - ⚠️ = 样例不完整，字段名可信、取值/语义待实测
> - ❓ = 推测
>
> 本文档 2026-10-11 做过一次大改：早先版本里 §1.3（Bearer）、§3（控制接口）、
> §3.2（温度编码）**都是错的**，靠 MITM 抓真机才纠正过来。历史错误一并保留在 §6，
> 因为它们的**误导方式**比结论本身更有参考价值。

---

## 0. 为什么不能用海外那套实现

AUX 有**两条完全独立、互不兼容**的云端线路：

| | 国内线（本文档） | 海外线 |
|---|---|---|
| App | 奥克斯A+ / AUX Home | AC Freedom |
| 域名 | `smthomeav.aux-home.com` | `eu-smthome-api.aux-global.com` |
| 登录 | 短信验证码 | 邮箱+密码（RSA-1024 + AES-128-ECB） |
| 状态 | **结构化 JSON 字段** | hex UART 帧，需解字节位 |
| User-Agent | `AUXSmartHome/7.2.7 (iPhone; iOS 27.0; Scale/3.00)` | `AUXAC/2.3.2 (iPhone; iOS 18.6.2; Scale/3.00)` |
| 开源实现 | 几乎没有 | 有若干 |

**不要**把海外线的 RSA/AES 加密逻辑套到这里。国内线是**明文 JSON over HTTPS**，
除了短信登录以外没有任何加密/签名环节（§1.2、§6.4）。

### 域名沿革（实测，别照抄旧帖）

| 域名 | 状态 |
|---|---|
| `smthomeav.aux-home.com` | ✅ **本项目在用的**，2026-10 全程实测可用 |
| `smarthome.aux-home.com` | ✅ APK `com.broadlink.auxair` vc440 里硬编码；**与上面是同一后端**，返回逐字一致 |
| `smarthomelink.aux-home.com`、`iot.aux-home.com`、`ecicss.aux-home.com` | 同 APK 里出现的其它 AUX 主机，未逐一使用 |
| `smarthomeuat2.aux-home.com:30082/30083/8080` | UAT 环境 |

**2024 年那份抓包记录里的登录接口、设备接口和字段名，和现在真实 App 用的已经全都不一样了**
（见 §1.2、§3.1、§6.3）。照抄它只会得到 `60008 token 无效` 或 `65001 设备不存在`。这是本项目最大的一个坑。

---

## 1. 认证流程

### 1.1 发送短信验证码 ✅

```
POST https://smthomeav.aux-home.com/app/login_sms_code
Content-Type: application/x-www-form-urlencoded

phone=13xxxxxxxxx
```

- ✅ 实测返回：`{"code":200,"message":"OK","data":{"newUser":true}}`（`newUser` 表示该号是否首次注册）
- ✅ 路径与 2024 帖一致，没变。注意它是 `/app/login_sms_code`，
  **没有 `auth/` 前缀**——`/app/auth/login_sms_code` 是 404。
- ✅ 请求方式：`GET` → `405 Method Not Allowed`；`POST` + form ✅；`POST` + query string ✅；`POST` + JSON ❌。

> ⚠️ **编码方式必须是 form-urlencoded，不能发 JSON**。发 `application/json`
> 会返回 `{"code":400,"message":"Bad Request!"}`——连手机号都没被读进去，
> 所以**换任何手机号都一样是 400**。这是最容易误判成「协议失效」的坑，详见 §6.1。

### 1.2 用验证码换 token ✅ 实测已打通

```
POST https://smthomeav.aux-home.com/app/auth/loginBySms
Content-Type: application/json
Accept: application/json

{"account": "13xxxxxxxxx", "code": "123456"}
```

三个关键点，**缺一个就失败**：

1. **路径是 `/app/auth/loginBySms`**，不是 2024 帖里的 `/app/wechatMini/loginBySms`。
   旧路径仍然存在（不是 404），但对同一份 body 只回 `{"code":60008,"message":"token 无效"}`——
   它属于小程序/旧客户端那条线，**不适合这里**。
2. **必须发 JSON**。发 form-urlencoded 会被 Spring 拒成 `415 Unsupported Media Type`；
   发 JSON 才能进入 `@RequestBody` 绑定。
3. **字段名是 `account` + `code`**，不是 `phone` + `smsCode`。

成功响应（✅ 实测）：

```json
{
  "code": 200,
  "message": "OK",
  "data": {
    "openApiToken": {
      "token": "YOUR_TOKEN",
      "expireAt": 1794302138
    },
    "…": "还有 appUser 等字段"
  }
}
```

- `token` — **32 位 hex**，之后所有接口放进 `Authorization` 请求头（§1.3）
- `expireAt` — ✅ 确认是 **Unix 秒时间戳**（1794302138 ≈ 2026-11-11），不是有效期秒数

实测错误码（`smarthome` 与 `smthomeav` 行为一致）：

| 请求体 | 响应 |
|---|---|
| `{}`、`{"phone":...}`、`{"account":...}`（只有一个） | `{"code":64012,"message":"手机号验证码不能为空"}` |
| `{"account":"13800138000","code":"999999"}`（验证码错） | `{"code":9015,"message":"验证码错误"}` |

> ⚠️ **`64012` 是「字段名没对上」的信号，不是「值不对」。** 服务端对手机号和验证码用同一条
> `@NotBlank` 提示，所以**只变一边、固定另一边去试永远区分不出来**——必须做字段名的
> **交叉穷举**（§6.2）。这是本项目的第二个大坑。

### 1.3 鉴权头 ✅ **必须带 `Bearer ` 前缀**

```
Authorization: Bearer <token>
```

- ✅ **实测确认**：不写 `Bearer `、只放裸 token → **所有** `/app/*` 请求都返回
  `{"code":60106,"fail":true,"message":"用户账号缓存过期，请重新登录","success":false}`。
- ✅ 服务端**大小写都收**；真实 App 发的是小写 `bearer `。
- ⚠️ **`60106` 是 `/app/*` 的通用「未通过鉴权」响应，几乎没有诊断价值**：
  无 token / 假 token / 裸 token，对**任意**路径（包括瞎编的 `/app/zzz_bogus`）
  都返回同一个 `60106`。所以它**既不能证明路径存在，也不能证明 token 有效**。
  只有带上**合法 Bearer** 访问瞎编路径，才会得到 Spring 的
  `{"timestamp":…,"status":404,"error":"Not Found","path":"/app/zzz_bogus"}`。

> 早先版本的本节写的是「不带前缀」，依据是 2024 论坛帖。**那是错的**，
> 害得整个设备接口线卡在 60106 上。详见 §6.3。

### 1.4 会话是单点的 ⚠️ 实测踩过

**同一个 AUX 账号同时只能有一个有效会话。**

- 手机 App 登录 → Mac 端 token 立即失效（回 60106）
- Mac 端登录 → 手机 App 被踢

调试时如果两边来回切，会看到「刚才还好好的 token 突然 60106」——不是 bug，是互踢。
建议给工具单独注册一个账号，或接受「用 App 时 Mac 工具会掉线」。

#### token 到底能活多久

**不是 7 天，也不是永不过期。实测约 30 天。**

| 场景 | 结果 |
|---|---|
| 关掉 App 再打开 | **不用重新登录**——token 存在 `~/Library/Application Support/AuxAC/session.json`（0600），启动时直接读 |
| 自然到期 | 服务端给的 `expireAt` 是**过期时刻**（Unix 秒）。2026-10-11 那次登录拿到 `1794316455` → 2026-11-10 21:14，即 **30 天后** |
| 手机 App 登录同账号 | **立即失效**，不等 30 天 |

**客户端必须认 `60106` 这个码。** AUX 不走 HTTP 的 401/403，它把鉴权失败塞在 body 里：

```json
{"code":60106,"fail":true,"message":"用户账号缓存过期，请重新登录","success":false}
```

漏认它的后果很隐蔽：界面只会显示「同步失败」，用户看不出是登录过期，也不知道该重新登录。
代码里收在 `AuxError.isAuthExpired`（`Sources/AuxAC/Endpoints.swift`），
刷新、控制、能耗三条路径都会据此退回登录页。`--selftest` 有一条断言专门钉这个码。

本地也做了一层提前判断：启动时若 `expireAt` 已过，直接进登录页，不做一次注定失败的请求。

---

## 2. 设备列表 + 状态 ✅

```
GET https://smthomeav.aux-home.com/app/device_bindings?getStatus=true
Authorization: Bearer <token>
```

`getStatus=true` 是拿到实时状态的关键，**不要漏**；也可以写 `getStatus=1`。

### 2.1 顶层结构

```json
{ "code": 200, "message": "OK", "data": [ { /* 设备对象 */ } ] }
```

### 2.2 设备对象（本机实测真值）

| 字段 | 本机值 | 说明 |
|---|---|---|
| `deviceId` | `YOUR_DEVICE_ID` | **控制接口必填**，本机上与 `did` 相同 |
| `did` | `YOUR_DEVICE_ID` | 与 `deviceId` 相同 |
| `productKey` | `YOUR_PRODUCT_KEY` | **32 位 hex**，不是旧帖的 `00010001` |
| `mac` | `AABBCCDDEEFF` | MAC（无分隔符大写） |
| `alias` | `奥克斯空调` | 用户备注名，显示用 |
| `password` / `passcode` | `YOUR_PASSCODE` | 本地直连凭据（本机实测**用不上**，见 §5） |
| `sn` | `YOUR_SERIAL_NUMBER` | 序列号 |
| `modelId` | `YOUR_MODEL_ID` | UUID |
| `wifi_hard_version` | `2C007682` | WiFi 模块硬件版本 |
| `wifi_soft_version` | `00047019` | WiFi 模块固件版本 |
| `dataOne` / `dataTwo` / `dataThree` | `32` / `05` / `83` | ❓ 语义未解 |
| `terminalId` | `0` | ❓ |
| `source` | `1` | ❓ |
| `online` | `true` | 在线状态 |
| `feature` | JSON 字符串 | 能力位图，见 §2.4 |
| `data` | 对象 | 实时状态，见 §2.3 |

### 2.3 状态 `data` 字段 ✅ **模式字段是 `air_con_func`**

**这是本项目最关键的一次纠正**：状态里**没有** `mode` 字段。
模式上报在 **`air_con_func`**。

本机实测完整快照（36 个字段，全部为普通 JSON 数值，**不需要解任何二进制**）：

```json
"data": {
  "on_off": 0,
  "temperature": 23,
  "temperature_decimal": 5,
  "half": 1,
  "air_con_func": 1,
  "wind_speed_1": 6,
  "wind_speed_2": 0,
  "up_down_swing": 0,
  "left_right_swing": 0,
  "screen_on_off": 1,
  "auto_screen": 0,
  "support_heat": 1,
  "eco": 0,
  "sleep_mode": 0,
  "sleep_diy": 0,
  "turbo_silence": 0,
  "comfort_wind": 0,
  "clean": 0,
  "freshing": 0,
  "healthy": 0,
  "anti_fungus": 0,
  "electric_heating": 0,
  "electric_lock": 0,
  "power_limit": 0,
  "power_limit_percent": 0,
  "ventilate": 0,
  "ventilate_auxiliary": 0,
  "ventilate_heap_notify": 0,
  "wind_child": 0,
  "wind_far": 0,
  "wind_light": 0,
  "wind_ring": 0,
  "wind_smart": 0,
  "zero_wind_feeling": 0,
  "hanging": 1,
  "no_speech": 0
}
```

- **`temperature` + `temperature_decimal`** 是两个字段共同表示温度：
  上例 = 23 + 0.5 = **23.5°C**（`temperature_decimal` 非 0 时即 5，代表 +0.5；`half` 同步为 1）。
- **`air_con_func`** = 模式。本机 1。映射见 §3.3。
- **`wind_speed_1`** = 风速上报值。**注意它是上报字段，不能用来下发**（§3.3）。
- ⚠️ **状态上报延迟约 4 秒**（早先 15–30 秒、8 秒两次估计都偏保守）。
  开机态逐字段探测显示下发后 **4 秒**回读即已一致，20 秒是宽松上限。
  但**改完立刻读仍会读到旧值**，别用「读完没变」判定字段名错——
  要么 sleep ≥6 秒，要么持续轮询。另见 §3.4：响应 `200 OK` 与设备是否真接受无关。
- ❌ **室温：云 API 拿不到。**（`feature.roomTempDisplay` 为 `["1","0"]` 只说明**室内机自己**
  能显示室温，不代表云端会透传。）判定依据见 §2.5。

### 2.5 室温为什么拿不到（三重证据）❌

1. **本机状态快照**：`data` 的 36 个字段（开机态与关机态各抓一次）里没有任何室温语义的键。
2. **官方 App 抓包全量扫描**：对 `/tmp/newcap.txt`（126 条响应，全部是明文 JSON）做
   正则扫描，`room*` / `indoor*` / `ambient*` 类键名 **0 命中**；
   `temp` 类键名只有 `outdoorTemperature`(24)、`temperature`(7)、`temperature_decimal`(3)、
   `temperatureRange`(3)。官方 App 自己拉的三次 `device_bindings?...&getStatus=1`
   返回的 `data` 与本项目拿到的完全一致，同样没有室温。
3. **官方 App 那一轮抓到的全部 AUX 接口**（去重后 30 个）里，唯一带温度的天气接口是
   `GET /app/getAirLevel?city=苏州市&lat=…&lng=…` →
   `{"aqi":"49","level":"优","weather":"晴","temperature":"23","humidity":"56","pm25":null}`
   —— 这是**室外**天气（按经纬度查天气服务），也是 App 控制请求里
   `environmentData.outdoorTemperature / outdoorHumidity` 的来源。
   `GET /app/device/getRoomInfo` 返回的是**房间面积档位**，不是温度。
   唯一按 tag 查设备字段的 `POST /app/device/through/commonQuery` 连官方 App 自己调用都失败
   （`{"code":65061}`）。

**结论**：A+ 云这条路上没有室内温度。官方 App 在整轮控制过程中的**全部**响应里
（183 KB，见 §7 的抓包文件），温度类键只有四个：

| 键 | 出现次数 | 是什么 |
|---|---|---|
| `outdoorTemperature` | 24 | **室外**天气（`getAirLevel` 按经纬度查来的） |
| `temperature` | 7 | 目标温度（整数部分） |
| `temperature_decimal` | 3 | 目标温度的半度位 |
| `temperatureRange` | 3 | 可设温度区间 |

室内/环境温度语义（`room*` / `indoor*` / `inside*` / `ambient*` / `env*`）**零命中**。
本项目是纯云 API 实现，因此**不显示室温**（面板上那半句已退化掉）。

### 2.5.1 ~~BLE 近场直连~~ 这个推断已作废 ❌

早先这里写过「App 上那个温度也可能是走 BLE 从室内机蓝牙读的」，依据是
`baseConfig` 里的 `nearSupportBleControl=1`、`homeSupportBleControl=1`，以及 DEX
路由表里的 `device/bindBle` / `device/updateBle`。**复查后该推断站不住，原因有两条：**

1. **那是个全局 App 开关，不是本机的能力位。** 这两个键出现在
   `GET /app/getConfig?id=baseConfig` 的响应里，该响应的
   `{"configId":"baseConfig","name":"APP基础配置","configType":1}` 已说明它是
   **App 级别**的配置；同一个 `configContent` 里还躺着
   `supportScanNearDevice: 0`（全局关掉了「扫描附近设备」）和 `onlineVoiceACMAC`
   （一段 `(?i)^(c0cbf11|0c8b952|e89f6dd|e05a1ba|9015641).*` 的 MAC 前缀正则，
   显然只对部分机型生效）。**App 为部分机型编了 BLE 通道 ≠ 本机有蓝牙模块。**
2. **本机的证据全部指向纯 WiFi。** `wifi_hard_version = 2C007682`、
   `wifi_soft_version = 00047019` 齐全；`source = 1`；控制全程经 `smarthome.aux-home.com`
   中转；`feature` 里没有任何 BLE/近场能力位。

**教训**：`getConfig?id=xxx` 这一族响应里，`configType` 和 `name` 决定了它是全局还是
按机型/按设备。看到一个「支持某功能」的开关就当成手里这台的能力，会得出完全错误的结论
——判断能力位优先看**这台设备自己的 `feature` 字符串**和 `device_bindings` 里的型号/固件字段。

### 2.4 `feature` 能力声明 ✅

`feature` 是**一个 JSON 字符串**（注意：是字符串，需要二次解析）：

本机实测值：

```json
{
  "coolType":        ["1","0"],
  "frenquency":      ["1","0"],
  "tempInterval":    ["0","0"],
  "roomTempDisplay": ["1","0"],
  "screen":          ["2","0"],
  "windSpeed":       ["2","0"],
  "faultSupport":    ["0","0"],
  "timing":          ["0","0"],
  "mode":            ["1,2,3,4","1"],
  "deviceSupport":   ["0,1,2,3,5,6,7,9","1"],
  "appSupport":      ["0,1,2,3,4,5","1"]
}
```

- `frenquency` 是原厂的**拼写错误**（frequency），不要"修正"，解析时按原样匹配。
- 每项形如 `[可选值, ?]`，第一个元素是逗号分隔的枚举，第二个元素语义 ❓。
- ✅ **`mode: "1,2,3,4"` → 本机只支持 4 个模式，且不含 `0`**，即**没有自动挡**
  （2024 帖那台的 `mode` 是 `"0,1,2,3,4"`，支持自动——**同一 App 下不同机型能力不同**）。
- `deviceSupport: "0,1,2,3,5,6,7,9"`（比 2024 帖少了 `4` 和 `10`）。
- `windSpeed: "2"` ❓ 语义待确认（可能是档位数量或编码类型）。

---

## 3. 控制 ✅ **已换成 `/app/device/v2/control`**

```
POST https://smthomeav.aux-home.com/app/device/v2/control
Authorization: Bearer <token>
Content-Type: application/json
```

> ⚠️ 2024 帖的 `/app/wechatMini/new_device_control` **已废弃**。
> 它现在仍在服务端（不是 404），但认的是 `did`/`pk`/`uart`/`action` 那套老字段，
> 用 `deviceId` 会被判 `65001 设备不存在`。**别用它。**

### 3.1 请求体 ✅ **最小可用形态**

真机抓到的完整请求体（iPhone A+ 7.2.7）：

```json
{
  "intent": { "on_off": 1 },
  "dst": 1,
  "type": "app",
  "nickName": "177****2116",
  "needControl": true,
  "deviceId": "YOUR_DEVICE_ID",
  "uid": "YOUR_UID",
  "environmentData": { "outdoorTemperature": 25, "outdoorHumidity": 52 },
  "did": "YOUR_DEVICE_ID"
}
```

**实测（9 组删字段对照）：只有 `deviceId` 是必填。** 最小可用请求体：

```json
{ "intent": { "on_off": 0 }, "deviceId": "YOUR_DEVICE_ID" }
```

- 逐项删掉 `environmentData` / `nickName` / `uid` / `type` / `needControl` / `dst` / `did` → 全部仍然成功。
- 删掉 `deviceId` → `{"code":-100,"message":"参数不正确"}`。
- 把 `deviceId` 写成 `did` → 同样 `-100`（**只认 `deviceId`**）。

响应有两种成功形态，**都算成功**（走了不同代码路径）：

```json
{"code":200,"message":"","data":32803}
{"code":200,"message":"OK"}
```

`data` 是个递增整数，疑似服务端序列号，❓ 语义未解，无需处理。

### 3.2 温度编码 ✅ **直接给浮点摄氏度**

```json
{"intent": {"temperature": 24.5}, "deviceId": "..."}
```

- ✅ `{"temperature":24.5}` 被接受；`{"temperature":25}` → 25°C。
- **不是** 2024 帖说的「0.1 度整数」。发 `245` 是错的。
- 代码路径：`AppModel.setTemperature` → `JSONValue.number(Double)` → `JSONEncoder`。

### 3.3 控制键与取值表 ✅ **权威来源：`GET /app/getConfig?id=deviceMutex`**

**这是本文件最重要的一节。** 取值表不要靠猜、也不要靠 `feature` 字段，
直接问服务端要官方 App 用的那份规则表：

```bash
curl -H "Authorization: Bearer $TOKEN" \
  "https://smarthome.aux-home.com/app/getConfig?id=deviceMutex"
```

返回的 `data.configContent` 是一个 **以功能名为键**的字典（本机实测 60 项），
每项含 `keyN`（中文名）、`specs`（每个取值一个 `valueN`）、`toastMutex`（前置条件提示）。
官方 App 就是照这张表建界面的。本机抓到的那份已存到 `/tmp/auxrev/deviceMutex.json`。

#### (a) 键名与取值

| 键 | 中文 | 取值 |
|---|---|---|
| `on_off` | 开关 | `0` 关闭 / `1` 开启 |
| `temperature` | 温度 | 浮点摄氏度，16–32（设备自己拆 `temperature_decimal`） |
| `air_con_func` | 模式 | `0` 自动 / `1` 制冷 / `2` 除湿 / `4` 制热 / `6` 送风 |
| `wind_speed` | 风速 | `0` 低档 / `1` 中档 / `2` 高档 / `3` 静音 / `4` 自动 / `5` 强力 / `6` 中低 / `7` 中高 |
| `screen` | 屏显 | `0` 关闭 / `1` 开启屏显 / `2` 智能光感 |
| `up_down_swing` | 上下摆风 | `0` 开启（摆动）/ `1`–`5` 定格 1–5 / `7` 关闭 |
| `left_right_swing` | 左右摆风 | `0` 开启 / `1`–`3` 定格 / `4` 开启 / `5` 定格5 / `6` 定格4 / `7` 关闭 |
| `sleep_mode` | 睡眠 | `0` 关闭 / `1` 开启 |
| `eco` | 智省电 | `0` 关闭 / `1` 开启（**仅制冷模式有效**） |
| `ultra_silence` | 超静音 | `1` 关闭 / `2` 开启（**本机不支持**，见 (d)） |

🔴 **三个曾经写错、后来靠这张表纠正的地方**：

1. **模式编号**：早期按「行业惯例」猜成 `1/2/3/4` = 制冷/制热/送风/除湿，**全错**。
   表里 `3` 根本不存在；正确是 `1`=制冷、`2`=除湿、`4`=制热、`6`=送风。
   真机实测 `air_con_func=6` 与 `=2` 都能 4 秒写回。
2. **风速编号**：早期猜成 `0`=自动、`1`–`6`=档位，**全错**。正确见表。
3. **屏显的键名是 `screen`，不是状态字段名 `screen_on_off`**。
   早期拿 `screen_on_off` 去下发，服务端照回 `{"code":200,"message":"OK"}`，
   但设备**静默忽略**、状态纹丝不动 —— 这就是用户报的「屏显无效」。
   真机确认改用 `screen` 后 4 秒写回。

#### (b) `wind_speed` 下发值 ≠ 上报值

下发用 `wind_speed`，**读状态要用 `wind_speed_1`**（`wind_speed_1`/`wind_speed_2`
是状态字段名；拿它下发会被静默忽略）。而且两者**刻度不同**，实测：

```
下发 0 → 上报 1      下发 4 → 上报 6      下发 5 → 被忽略
```

上报值被设备折算过（DEX 里有 `changeWindSpeedToNetParam`），**无法从上报值反推用户选了哪一档**。
所以界面高亮认 `AppModel.preferredFan`（用户自己的选择），右侧小字另显示原始上报值。

#### (c) `200 OK` 不代表生效 ⚠️

服务端对**不生效**的下发照样回 `200`。判断某键是否生效**只能靠回读**。
注意响应还有两种形态，但**都不能当判据**（`wind_speed=5` 那次回的是带 `data` 的
「生效形态」，状态却纹丝不动）：

| 形态 | 例子 |
|---|---|
| 生效形态 | `{"code":200,"message":"","data":32923}`（`data` 是递增整数，不是状态） |
| 忽略形态 | `{"code":200,"message":"OK"}` |

**唯一有效的证据链是：下发 → 等 ≥4 秒 → 读回状态。**
本机实测设备上报延迟约 **4 秒**（早期估的 8–30 秒偏保守）。
⚠️ 别用「连续两次读数相同就算稳定」的轮询脚本——设备本来就停在旧值上，
脚本会立刻在旧值上判定「稳定」并提前返回。

#### (d) 本机硬件不支持的功能

| 功能 | 尝试过的键 | 结果 |
|---|---|---|
| 强劲 / 超静音 | `turbo`、`silence`、`ultra_silence`(1/2)、`wind_speed=5` | **全部被静默忽略** |

不是键名没找对：本机 `feature.deviceSupport` = `["0,1,2,3,5,6,7,9"]`，
而表里超静音要求设备含位 `38`（`"value": "38&&2", "key": "deviceSupport&&ultra_silence"`），
对不上是预期内的。**官方 App 里这个按钮同样点不动。**
所以面板上不再提供「强劲」，`AppModel.setTurboSilence` 已删除。

#### (e) 那条 DEX 5 键清单不是白名单

从 `classes.dex` 明文段（`strings -n 4`，第 135551 行）能读到一条逗号连接的清单：

```
air_con_func,temperature,wind_speed,up_down_swing,left_right_swing
```

早先据此推断「这就是全部可下发字段」——**错的**。它只是某个「common control」子集。
`on_off` / `screen` / `sleep_mode` / `eco` 都是合法可下发字段（mutex 表里都有）。

#### (f) 扫风极性是反的（真机确认，踩过坑）

`up_down_swing` / `left_right_swing` 都是「**`0` = 自动摆动，其余 = 固定角度**」，`7` 是明确的「关闭」。

下发 `1` 会让叶片**停止**，下发 `0` 才是**开始自动摆动**。
早期实现按直觉写成 `on ? 1 : 0`，结果点「开」把叶片停住，被用户报为「扫风反了」。
**别把它当布尔用**，非 0 值是固定档位（`1`–`5` = 定格 1–5），不是布尔真值。

逐字段探测（`/tmp/auxrev/swing_probe.py` + `probe_on2.py`，开机态）：

| 下发 | 回读 | 是否串扰 | 生效耗时 |
|---|---|---|---|
| `{"up_down_swing": 0}` | `up_down_swing = 0` | 否 | 4 秒 |
| `{"up_down_swing": 7}` | `up_down_swing = 7` | 否 | 4 秒 |
| `{"left_right_swing": 0}` | `left_right_swing = 0` | 否 | 4 秒 |

键名没有互换、值一比一写回同名状态字段，唯一的问题就是语义极性。
左右扫风未单独做叶片观察（按同族对称处理；表里 `0` 与 `4` 都表示「开启」）。

**⚠️ 左右的两条定档是错位的**，照数字顺序做必然弄反：

| 语义 | `up_down_swing` | `left_right_swing` |
|---|---|---|
| 摆动（开启） | `0` | `0` **或 `4`** |
| 定格1 | `1` | `1` |
| 定格2 | `2` | `2` |
| 定格3 | `3` | `3` |
| 定格4 | `4` | **`6`** |
| 定格5 | `5` | **`5`** |
| 关闭 | `7` | `7` |

所以代码里两个方向各自有一份映射数组，**不要用算术互相推**：
`ACState.upDownSwingValues = [0,1,2,3,4,5,7]`、
`ACState.leftRightSwingValues = [0,1,2,3,6,5,7]`（界面索引 ↔ 线上取值），
文案统一用 `ACState.swingLabels = ["摆动","1","2","3","4","5","关闭"]`。
`--selftest` 里有一条断言专门钉住这两张表。

> 📌 **这个功能是用户提醒才发现的**：早期把扫风做成了「开/关」两态布尔，
> 但用户报「扫风它还能控制上下的角度啊，有固定的几个位置档位」，
> 翻抓包确认他按过 `up_down_swing` = `1` / `3` / `5`（定格1/3/5）——
> 表里那 5 个定格档是真在用的，不是摆设。
> 面板因此从「⇅上下 / ↔左右」两个开关胶囊改成两行各 7 段的档位条。

### 3.4 电源门控：只有「睡眠」和「节能」🔴 **真机逐个实测**

在**空调关机（`on_off = 0`）**状态下逐个下发、回读：

| 字段 | 语义 | 关机态能否写回 |
|---|---|---|
| `temperature` | 目标温度 | ✅ 能（实测 23 → 26） |
| `air_con_func` | 模式 | ✅ 能（实测 2 → 4） |
| `wind_speed` | 风速 | ✅ 能（状态 `wind_speed_1` 1 → 3） |
| `up_down_swing` | 上下摆风 | ✅ 能（实测 0 → 1） |
| `left_right_swing` | 左右摆风 | ✅ 能（实测 0 → 1） |
| `screen` | 屏显 | ✅ 能（实测 1 → 0，**4 秒**） |
| `sleep_mode` | 睡眠 | ❌ **静默忽略**（停在 0） |
| `eco` | 节能 | ❌ **静默忽略**（停在 0） |

服务端 mutex 表也是这么标的：只有 `sleep_mode` / `eco` 等带
「请先开机后再使用该功能」，而 `screen` 的约束里**只有 `electric_lock`**。

> 🔴 **用户报的「强劲和屏显无效」是两件不同的事，别混为一谈：**
> - **强劲**：本机**硬件不支持**（见 §3.3 (d)），跟电源状态无关，永远无效。
> - **屏显**：**键名写错**（用了状态字段名 `screen_on_off`）。改 `screen` 后开机/关机态都能写回。
>
> 而早先归因的「关机态门控」只对 `sleep_mode` / `eco` 成立。
>
> 界面对策（已实现）：这两个 chip 在关机时只**变暗**（`ControlView.sleepEcoEnabled`），
> **不**用 `.disabled()`——点击照常进入 `AppModel.requirePower`，由它弹一句
> 「「睡眠」需要空调运行中才能设置，请先开机。」
> 早先的写法是 `.disabled()`，用户点下去毫无反应，只能报「无效」。

#### 关机态下「一次只改一个设置」

关机态下**同时下发多个设置会被忽略**（海外线评测也踩到同一现象）。
要预置多项就一条命令只改一个字段、逐条发，每条之间留出上报延迟。
实测踩过：还原脚本 1 秒内连发两条，第一条被吞掉。

#### (d) 延迟：实测 ≤4 秒

用「改完立刻读，没变」来判定字段名对错会得出**错误**结论。
本机实测下发后 **4 秒**回读即已一致（20 秒是宽松上限，见 §2.3）。
⚠️ 早先「约 8 秒」和「15–30 秒」两次估计都只是**更松的上限**——它们用的轮询间隔就是 8 秒 /
15 秒，所以只能证明「到那个时刻已经生效」，不能证明要等那么久。4 秒是目前最紧的下界。

> **「改完立刻读，没变」≈ 什么都不能证明。** 必须等 ≥20 秒再读。

**另一个不要用的判据**：「连续两次读数相同就算稳定」的轮询脚本在这里**没用**——
设备本来就停在旧值上，脚本会立刻在旧值上判定「稳定」并提前返回。要等就老实 `sleep`。

---

### 3.5 服务端互斥表 `deviceMutex` ✅ **官方自己的「什么时候不能按」规则表**

```bash
curl -A "AUXSmartHome/7.2.7 (iPhone; iOS 27.0; Scale/3.00)" \
     'https://smarthome.aux-home.com/app/getConfig?id=deviceMutex'
```

**不需要鉴权**——带对 User-Agent 就能拉，46783 字节，60 项功能。官方 App 就是按这张表
灰按钮 / 弹 toast 的，所以**不要自己猜规则，照抄它**。返回外层是
`{"code":200,"message":"OK","data":{"configId":"deviceMutex","name":"互斥逻辑表","configType":1,"configContent":{…}}}`。

每一项形如：

```json
{"toastMutex": [{"toast": "空调已锁定，解锁后才可操作", "value": "1", "key": "electric_lock"},
                {"toast": "请先开机后再使用该功能", "value": "0", "key": "on_off"}],
 "specs": {}, "controlMutex": [], "keyN": "温度", "key": "temperature"}
```

- `toastMutex` 是「前置条件不满足就不让按」，`toast` 就是官方那句提示文案，
  `key` + `value` 是判定条件（`value` 里可以出现 `&&`、`||`、范围等表达式）。
- `controlMutex` 是「按下去之后联动/隐藏别的字段」（例如切到自动模式时强制
  `temperature=24`、`half=0`、`comfort_wind=0`）。本项目**未实现**联动，只实现了拦截。

**童锁是一道全局闸**：几乎每一项 `toastMutex` 的第一条都是
`electric_lock`，「空调已锁定，解锁后才可操作」——连 `on_off` 那条也只有它。

#### 逐项约束（去掉童锁和 `on_off` 之后的剩余部分）

| 功能 | 除了童锁，还受什么约束 |
|---|---|
| `temperature` | 自动模式不能调、**送风模式不能调**、S+黄金舒睡（`sleep_diy`）开着时不能调 |
| `wind_speed` | **除湿模式不能调**、S+黄金舒睡开着时不能调 |
| `sleep_mode` | 自动/送风模式下无效、S+黄金舒睡开着时不能设 |
| `eco` | 对取值 `0/2/4/6` 各列一条「仅制冷模式有效」→ **只有制冷能用** |
| `air_con_func` / `up_down_swing` / `left_right_swing` / `screen` / `on_off` | 只有童锁 |

#### ⚠️ 表比设备严：`on_off` 那一条刻意没抄

表里 `temperature` / `wind_speed` / 两个摆风都带「`on_off=0` → 请先开机后再使用该功能」，
但 §3.4 的真机逐个实测证明**关机态一样能写回**。照抄那条会把本来能用的功能灰掉，
所以本项目只抄「物理上说不通」的几条（童锁 / 模式冲突 / S+黄金舒睡），
真正会被设备忽略的只有 `sleep_mode` 和 `eco`，那两个交给「请先开机」的拦截兜。

> 教训：**服务端规则表是「官方 UI 的意图」，不等于「设备的实际能力」。**
> 两者冲突时，立项依据是真机实测，但用户可见的文案可以照抄官方（用户对得上号）。

#### 3 秒最小控制间隔

同一个 `getConfig` 接口的 `id=baseConfig` 里有：

```json
{"configId":"baseConfig","name":"APP基础配置","configType":1,
 "configContent":{"controlMinimumInterval":3, "onlineVoiceACMAC":"(?i)^(c0cbf11|0c8b952|e89f6dd|e05a1ba|9015641).*",
                  "wifiFirmWareUpdate":1,"supportAI":1,"nearSupportBleControl":1,
                  "supportHuaweiAI":1,"homeSupportBleControl":1,"supportScanNearDevice":0}}
```

`controlMinimumInterval: 3` → 官方 App 自己两次控制之间至少隔 3 秒。本项目据此在下发前
做节流（连点会被拦并提示），避免请求被服务端吞掉。

⚠️ **同一个响应里的 `nearSupportBleControl` / `homeSupportBleControl` 曾被误读成
「本机支持 BLE」**——`configType: 1` + `name: "APP基础配置"` 说明它是 **App 的全局能力开关**，
不是按设备的能力位（同一对象里还躺着 `supportScanNearDevice: 0`）。判断某台机器有什么能力，
**优先看设备自己的 `feature` 和 `device_bindings` 字段**，不要看这族全局配置。详见 §2.5.1。

---

## 4. UART 帧（已不需要）✅

`/app/device/v2/control` **不传也不返回 `uart`**——控制完全走结构化 JSON。
早先基于 2024 帖以为要自己构造 UART 帧，**这个方向已经作废**。

保留本节仅作背景：`uart` 帧是 `bb … 9b` 结构，属于 **Broadlink 系空调协议**，
与海外线状态块、ESPHome `aux_ac` 组件（`baud_rate: 4800`、`even` 校验）同源。
它只在走局域网直连时才需要（§5）。

---

## 5. 局域网直连 ❌ **本机实测不可用**

理论上的两条线索：

1. 设备对象里有 `password` / `passcode`（`YOUR_PASSCODE`）——Broadlink 本地认证需要它
2. `uart` 帧是 Broadlink 格式，说明云端只是**透传通道**

**实测结论：本机这台空调不在局域网上。**

- 扫描 `192.168.2.0/24` 的 `80/8080/443/8888/6668` 端口 → **只有路由器 `192.168.2.1` 开放**
- 向广播地址发 Broadlink UDP:80 发现包 → **无任何回应**

对照：荷兰的 Homey 实现作者也明确说他的新机型**不吃**本地协议
（UDP 握手直接 timeout）；而 HA 社区有人用老机型 `ASW-H09A4` 走通过。
→ **取决于模块世代，本机这台属于"新款"，老协议已废弃。**

所以本项目**只能走云**。局域网直连路线到此关闭。

---

## 6. 已知坑

1. **同一账号的会话会互踢** —— 见 §1.4。
2. **短信登录无法全自动** —— token 过期就得手动收验证码。这是云路线的最大体验缺陷
   （但 §5 已关闭，没有替代方案）。
3. **`feature` 是字符串不是对象** —— 必须二次 `JSON.parse`。
4. **`frenquency` 拼写错误** —— 按原样匹配，别写成 `frequency`。
5. **状态上报延迟 ≤4 秒** —— 见 §2.3、§3.4。**改完立刻读等于没读。**

### 6.1 编码方式按接口分，不能一刀切 ⚠️ 实测踩过

服务端是 Spring 后端，同一域名下**不同接口的 Content-Type 要求不一样**：

| 接口 | form-urlencoded | application/json |
|---|---|---|
| `POST /app/login_sms_code` | ✅ 200 | ❌ `400 Bad Request!` |
| `POST /app/auth/loginBySms` | ❌ `415 Unsupported Media Type` | ✅ `@RequestBody` 绑定 |
| `GET /app/device_bindings` | （GET，无 body） | — |
| `POST /app/device/v2/control` | ❌ `415 Unsupported Media Type` | ✅ 按 JSON 发 |

`login_sms_code` 的参数走 `@RequestParam` 绑定，只认 form / query string；发 JSON 时参数绑定阶段
就失败了，返回的 `400 Bad Request!` **与手机号内容无关**——这是关键判据：
**如果换个手机号得到完全相同的报错，问题在请求格式而不在参数。**

**教训：抓包记录没写 Content-Type 时不要默认 JSON，也不要默认 form——要逐个接口试。**
一份只贴了 URL 和 body 的抓包足以让协议「看起来对、实际全错」。

### 6.2 `64012 手机号验证码不能为空` = 字段名没对上 ⚠️ 实测踩过

`/app/auth/loginBySms` 上，**任何字段名不对的 body 都返回同一个 `64012`**，因为服务端对
手机号和验证码用同一条 `@NotBlank` 提示。后果是：

- 固定 `smsCode`、穷举 25 个 phone 名 → 25 次全是 `64012`
- 固定 `phone`、穷举 47 个 code 名 → 47 次全是 `64012`

**单边变化永远区分不出**是哪一个名字错了。必须做**交叉穷举**：25 × 47 = 1175 组并发打，
只有 `{"account":…, "code":…}` 一组返回了不同的 `9015 验证码错误`。

脚本：`/tmp/auxrev/cross.py`（`ThreadPoolExecutor(max_workers=6)`，只打印不含 `64012` 的响应）。

顺带否掉的两条路（别重试）：
- **RSA**：`GET /app/auth/getPubkey` 确实返回 1024-bit 公钥，但用它对 phone/code 做
  `RSA/ECB/PKCS1Padding` 加密（base64 → 172 字符）后无论塞进哪个字段名，**仍全是 `64012`**，
  说明失败点不在解密而在字段名。
- **旧路径**：`/app/wechatMini/loginBySms` 换任何参数名都只给 `60008 token 无效`（含假验证码），
  根本没走到验证码校验——它是另一条产品线。

### 6.3 `60106` 是万能错误码，几乎不能用来诊断 ⚠️ 实测踩过

`60106 用户账号缓存过期` 在「无 token / 假 token / 裸 token」三种情况下，
对**任意** `/app/*` 路径（含瞎编的 `/app/zzz_bogus`）**都返回同一个值**。

后果是追查方向会被带偏：

- 看到设备接口 60106，很自然会猜「设备接口路径也换过了」，于是花大量时间去 DEX 里翻路由表
  （确实翻出了一大堆，见 §6.5），但**真正的原因只是 `Authorization` 少写了 `Bearer `**（§1.3）。
- 用**假 deviceId** 探测请求体 schema 时也踩了同一个坑：`-100 参数不正确` 和
  `65001 设备不存在` 在不同接口上含义不同，**必须用真 id 才能区分「字段名错」和「设备不存在」**。

**教训：一个对所有输入都返回同一值的错误码，零信息量。**
先想办法让它**分化**（换个维度：改 HTTP 方法、改路径、改鉴权），再开始猜。

### 6.4 没有签名、没有加密 ✅

云端**不要求任何请求签名**。除了登录要短信验证码、以及全局的 `Bearer` token 之外，
所有请求都是**明文 JSON over HTTPS**。
早先担心的「App 可能有请求签名」已被排除。

### 6.5 前端 JS 读不了，但 DEX 字符串表能读 ⚠️

A+ 的界面部分是 uni-app，`assets/apps/__UNI__*/www/app-service.js` **全部加密**
（printable 21–37%，三个包前 40 字节完全相同 = 固定 keystream），grep `loginBySms`/`token`/`https://`
零命中。`classes.dex` 是 **SecNeo/梆梆加固壳**（52 个类全是 `com.secneo.apkwrapper.*` 和 ARouter 路由表，
真正的 `dexdata0` 段被加密）。

→ **别指望静态读完代码**，但字符串表在 ~11.1 MB 处是**明文**，可以用
`strings -n 4 classes.dex` 捞出常量和路由（本项目就是靠它拿到 §3.3 那 5 个控制键的）。
字段名这种**语义**仍然要靠运行时行为反推（§6.2）或抓包（§7）。

---

## 7. 怎么抓的：自写 MITM 代理 ✅

现成工具都装不上（`brew` 拒绝以 root 运行，`sudo`/`su` 被沙箱拦，
`pip install mitmproxy` 反复失败），所以用 **Python 标准库 + openssl 手写了一个**：

- 脚本：`/tmp/auxrev/mitm.py`（零依赖，监听 `0.0.0.0:8080`）
- 根证书：`/tmp/auxrev/certs/ca.crt`，由 `python3 -m http.server 8081 --bind 0.0.0.0`
  在 `http://192.168.2.3:8081/ca.crt` 提供
- 命中 `/tmp/auxrev/captured.txt`

**手机侧必须做两步**（少一步都会「连不上」）：
1. 设置 → 通用 → VPN与设备管理 → **安装**描述文件
2. 设置 → 通用 → 关于本机 → **证书信任设置 → 开启完全信任**

只做第 1 步的典型症状是 Safari 报「**此连接非私人连接**」。

踩过的四个坑（都有强迷惑性）：

| 坑 | 症状 | 原因/修法 |
|---|---|---|
| 只处理 CONNECT | 手机设了代理后**连下载根证书都失败** | 明文 HTTP 被丢弃。`else` 分支要 `urlsplit` 后原样转发 |
| 叶子证书 825 天 | TLS **握手中途 EOF**（`SSLEOFError`），连 `init.push.apple.com` 都失败 | **iOS 13+ 拒收 >398 天**的服务器证书。改 `-days 397 -sha256` |
| CA 缺扩展 | 描述文件能装、信任开关能开，但 Safari 仍报「非私人连接」 | LibreSSL `openssl req -x509` **默认不加任何扩展**，缺 `basicConstraints=critical,CA:TRUE`。必须用 `-config` 显式声明 |
| CN 超 64 字符 | `openssl req` 报 `CalledProcessError ... exit status 1` | 阿里云 xtrace 那种超长域名。`-subj f"/CN={host[:64]}"` 截断（客户端校验 SAN，不看 CN） |

诊断技巧：在连接处理入口对**每一条**连接无条件打日志（带时间戳），
否则分不清「代理没被用」和「代理被用了但域名不匹配」。

---

## 8. 待确认清单（实测后勾掉）

认证线 ✅ **已全部打通**：

- [x] #1 `login_sms_code` 的完整响应结构 —— `{"code":200,"message":"OK","data":{"newUser":bool}}`
- [x] #2 `loginBySms` 成功的返回结构 —— `data.openApiToken.token`（32 hex）+ `.expireAt`（Unix 秒）
- [x] #3 `expireAt` 是过期时刻还是有效期秒数 —— **Unix 秒时间戳**
- [x] #11 云端是否要求请求签名 —— **不需要**（§6.4）
- [x] #13 登录接口的路径 + 编码 + 字段名 —— `/app/auth/loginBySms` + JSON + `account`/`code`
- [x] #14 `Authorization` 到底带不带 `Bearer ` 前缀 —— **必须带**（§1.3）

设备与控制线 ✅ **基本打通**：

- [x] #4 状态里模式字段的真实名字 —— **`air_con_func`**，不是 `mode`（§2.3）
- [x] #6 风速字段 —— 下发 `wind_speed`，上报 `wind_speed_1`（§3.3）
- [x] #7 `up_down_swing` / `left_right_swing` 取值语义 —— **`0` = 摆动，非 0 = 停止**（极性反，真机确认，§3.3）
- [x] #9 `transport` 字段含义 —— 实测为 `0`，语义 ❓（影响不大）
- [x] #10 控制接口的响应结构 + 是否接受 JSON —— `/app/device/v2/control`，要 JSON；成功响应两种形态（§3.1）
- [x] #12 是否支持局域网直连 —— ❌ **本机不支持**，不在局域网（§5）
- [x] #18 **「设备只认 5 个控制键」是错的** —— 那条 DEX 清单只是某个 common-control 子集。
      权威取值表在 `GET /app/getConfig?id=deviceMutex`（服务端自己的规则表，§3.3）
- [x] #5 **`air_con_func` 取值** —— mutex 表：`0` 自动 / `1` 制冷 / `2` 除湿 / `4` 制热 / `6` 送风。
      真机实测 `6` 与 `2` 均 4 秒写回。**早先猜的 `1/2/3/4` 全是错的**（§3.3）
- [x] #15 **`wind_speed` 取值** —— mutex 表：`0` 低 / `1` 中 / `2` 高 / `3` 静音 / `4` 自动 /
      `5` 强力 / `6` 中低 / `7` 中高。上报值经设备折算（下发 `0` → 上报 `1`、下发 `4` → 上报 `6`），
      故 App 的风速高亮认「用户的选择」而非回读值（§3.3 (b)）
- [x] #19 **「屏显」的键名** —— 下发用 `screen`（`0` 关 / `1` 开 / `2` 智能光感），
      **不是**状态字段名 `screen_on_off`（§3.3 (a)）
- [x] #20 **「强劲 / 超静音」** —— 本机硬件不支持：`turbo` / `silence` / `ultra_silence` /
      `wind_speed=5` 全被静默忽略，官方 App 里也点不动（§3.3 (d)）

**仍未确认（按重要性排序）**：

- [x] #8 **室温字段名** —— **已定案：云 API 根本没有室温字段**（见 §2.5）。
  `feature.roomTempDisplay=["1","0"]` 指的是室内机面板能显示，不是云端透传。
  App 上那个温度是 `getAirLevel` 的**室外**天气；「走 BLE」那条推断已作废（见 §2.5.1）
- [ ] #16 `dataOne` / `dataTwo` / `dataThree`（`32`/`05`/`83`）的含义
- [ ] #17 控制响应里 `data`（递增整数）的含义

---

## 9. 参考实现（本项目）

`auxac-mac/` —— macOS 菜单栏 App（Swift，零第三方依赖）：

| 文件 | 职责 |
|---|---|
| `Sources/AuxAC/Endpoints.swift` | 接口地址常量 |
| `Sources/AuxAC/AuxAPI.swift` | HTTP 客户端（`send(_:method:query:form:body:token:)`） |
| `Sources/AuxAC/Models.swift` | `Device` / `JSONValue` / `ACState` / `ACMode` / `FanSpeed` |
| `Sources/AuxAC/AppModel.swift` | 全局状态与 `setPower`/`setMode`/`setFan`/`setTemperature`/… |
| `Sources/AuxAC/ControlView.swift` | 控制面板 UI |
| `Sources/AuxAC/LoginView.swift` | 手机号 + 短信验证码登录 |

---

## 10. 来源

- **真机 MITM 抓包**（本项目，2026-10-11）：iPhone A+ 7.2.7，§3.1 的完整请求体就是这么来的
- 真实 APK：`奥克斯A+` from 豌豆荚 `https://www.wandoujia.com/apps/6508836/download/dot?ch=detail`
  → 包名 `com.broadlink.auxair`，versionCode 440（126,994,023 B）。本地副本 `/tmp/auxrev/b2`。
  域名、路由与 §3.3 的控制键清单从它的 `classes.dex` 明文段提取（§6.5）。
- 抓包记录（**已过时，仅作历史参考**）：[『瀚思彼岸』智能家居技术论坛 · 奥克斯A+ app 空调抓包数据接口](https://bbs.hassbian.com/thread-26607-1-64.html)（楼主 liuxiaobo，2024-08-23）
- Broadlink 协议参考：[makleso6/broadlink-aircon-api](https://github.com/makleso6/broadlink-aircon-api)、[liaan/broadlink_ac_mqtt](https://github.com/liaan/broadlink_ac_mqtt)
- 海外线实现（仅供对照，协议不同）：[GijsZwegers/com.zwegersit.auxairco](https://github.com/GijsZwegers/com.zwegersit.auxairco)、[fparrav/homebridge-aux-cloud](https://github.com/fparrav/homebridge-aux-cloud)、[maeek/ha-aux-cloud](https://github.com/maeek/ha-aux-cloud)
