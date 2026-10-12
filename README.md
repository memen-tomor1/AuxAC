# AuxAC — Mac 菜单栏控制奥克斯空调

在 macOS 菜单栏里直接开关、调温、切模式、调风速，不用掏手机、不用打开奥克斯A+ App。

**走的是奥克斯A+ / AUX Home 的国内云接口**（`smthomeav.aux-home.com`），
不是海外 AC Freedom 那条线。两条线的协议完全不同，详见 [`docs/PROTOCOL.md`](docs/PROTOCOL.md)。

---

## 现状

| 能力 | 状态 |
|---|---|
| 短信登录（手机号 + 验证码） | ✅ 已实测打通（真 token 到手） |
| token 本地持久化 + 过期自动退回登录 | ✅ 已实现 |
| 拉设备列表 + 实时状态 | ✅ 已实测 |
| 开关机 | ✅ **已实测**（真机开关成功） |
| 温度调节（含半度） | ✅ 已实测生效 |
| 模式（制冷/除湿/制热/送风） | ✅ 已实测生效，编号取自服务端 `deviceMutex` 表（`1/2/4/6`） |
| 风速（7 档 + 自动） | ✅ 已实测生效（自动/静音/低档/中低/中档/中高/高档） |
| 上下扫风 / 左右扫风 | ✅ 已实测生效（7 档：摆动 / 定格1–5 / 关闭；⚠️ 极性反且左右档位错位，见 `docs/PROTOCOL.md` §3.3） |
| 睡眠 / 节能 | ✅ 已实测生效（⚠️ **关机态设备会静默忽略**，需先开机，见下） |
| 屏显 | ✅ 已实测生效（⚠️ 键名是 `screen`，不是状态字段名 `screen_on_off`，见下） |
| 强劲 / 超静音 | ❌ **本机硬件不支持**（官方 App 里同样点不动，已从面板移除） |
| 室温显示 | ❌ **云 API 拿不到**（官方 App 整轮抓包里只有一个 `outdoorTemperature`＝室外天气；见 `docs/PROTOCOL.md` §2.5） |
| 多台空调切换 / 本地备注 | ✅ 已实现（备注只存本机，不动云端 alias） |
| 用电量柱状图（近 7 天 / 本月 / 今年） | ✅ 已实现（接口逆向自官方 App 的明文网页，见 `docs/PROTOCOL.md` §9） |
| 菜单栏直接显示目标温度 | ✅ 已实现（开机时图标旁显示 `23.5°`，关机时只留图标；齿轮菜单里可关掉） |
| 服务端互斥规则（童锁 / 模式冲突 / 3 秒最小间隔） | ✅ 已实现（规则直接读服务端的 `deviceMutex` 表，界面变暗 + 下发前拦截，见下） |
| 开机自启 | ✅ 已实现（齿轮菜单 → 「开机自动启动」，系统登录项优先，不到位就退回 LaunchAgent） |
| `auxac://` 自动化（快捷指令 / AppleScript / 终端） | ✅ 已实现（`open 'auxac://on'`，命令表见下） |
| 桌面 / 通知中心小组件 | ✅ 已实现（小号看温度，中号能直接开关机；见下） |
| 局域网直连（摆脱云端） | ❌ **已实测排除**，本机不支持 |

整个协议是靠 **真机 MITM 抓包**打通的，不是照抄网上记录。
抓包方法（含 iOS 根证书信任的坑）见 `docs/PROTOCOL.md` §7。

### 取值表是问服务端要的，不是猜的

**所有控制键的取值语义都来自服务端自己的规则表**，不用靠惯例假定：

```bash
curl -H "Authorization: Bearer $TOKEN" \
  "https://smarthome.aux-home.com/app/getConfig?id=deviceMutex"
```

官方 App 就是照这张表建界面的，完整表见 `docs/PROTOCOL.md` §3.3。要点：

| 键 | 取值 |
|---|---|
| `air_con_func` | `0` 自动 / `1` 制冷 / `2` 除湿 / `4` 制热 / `6` 送风 |
| `wind_speed` | `0` 低 / `1` 中 / `2` 高 / `3` 静音 / `4` 自动 / `5` 强力 / `6` 中低 / `7` 中高 |
| `screen` | `0` 关 / `1` 开 / `2` 智能光感 |

> ℹ️ 早期版本按「行业惯例」猜成 `1/2/3/4` = 制冷/制热/送风/除湿，**全是错的**。
> 现在已按表改正为 `1/2/4/6`，真机逐个验证过。

**风速的下发值和上报值刻度不同**：下发 `0` 上报 `1`、下发 `4` 上报 `6`，
上报值被设备折算过，所以无法从状态反推用户选了哪一档——App 的风速高亮
因此认「用户的选择」（`AppModel.preferredFan`），旁边小字另外显示设备上报的原值。

**扫风不只是开/关，还能定角度**：面板上「上下」「左右」各是一条 7 段档位条
——**摆动 / 1 / 2 / 3 / 4 / 5 / 关闭**（1–5 就是定格角度，来自服务端规则表）。

⚠️ **极性是反的**：`0` 才是「摆动」，别的值是固定角度，`7` 是明确的「关闭」。
所以别把它当布尔用（真机逐字段探测确认，见 `docs/PROTOCOL.md` §3.3）。

⚠️ **左右那两个定档是错位的**：线上 `5`=定格5、`6`=定格4，
照数字顺序做会把这两档弄反，所以映射写死在 `ACState.leftRightSwingValues` 里，
`--selftest` 有断言钉住。

**「睡眠」和「节能」这两个功能在关机态下会被设备静默忽略。**
下发照样返回 `200`，但状态纹丝不动——真机逐个实测过（见 `docs/PROTOCOL.md` §3.4）。
而**温度 / 模式 / 风速 / 扫风 / 屏显**这几项关机也能设。

所以面板上这两个按钮在关机时会显示为**变暗**，点下去会明确弹出
「需要空调运行中才能设置，请先开机」，而不是毫无反应。
（早先的写法是直接 `.disabled()`，点下去什么都不发生，用户只能报「无效」。）

**「强劲」已从面板移除**：本机 `feature.deviceSupport` 里没有超静音所需的设备位，
`turbo` / `silence` / `ultra_silence` / `wind_speed=5` 四种键名全试过，一律被静默忽略；
官方 App 里这个按钮同样点不动——是硬件不支持，不是我们没找对键。

**「屏显」的键名踩过坑**：状态字段叫 `screen_on_off`，但**下发**必须用 `screen`。
拿 `screen_on_off` 去下发，服务端照样回 `{"code":200,"message":"OK"}`，
设备却纹丝不动——这就是用户报的「屏显无效」。

### 已经踩掉的三个大坑

1. **2024 年那份公开抓包记录已经全面过时。** 它的登录接口
   （`/app/wechatMini/loginBySms`，字段 `phone`+`code`）、控制接口
   （`/app/wechatMini/new_device_control`，字段 `did`+`pk`+`uart`+`action`）、
   温度编码（0.1 度整数）**全是错的**。真实 App 用的是
   `/app/auth/loginBySms`（JSON，`account`+`code`）和
   `/app/device/v2/control`（JSON，`{"intent":{…},"deviceId":…}`，温度给浮点摄氏度）。
   详见 `docs/PROTOCOL.md` §1.2、§3。
2. **`64012 手机号验证码不能为空` 不代表参数值错，而是字段名没对上。**
   服务端对手机号和验证码共用一个 `@NotBlank` 提示，所以「固定一边、只变另一边」
   的试法**永远区分不出来**——最后是靠 25×47 的**交叉穷举**才定位到
   `account`+`code`（唯一返回不同错误码的一组）。详见 §6.2。
3. **`Authorization` 必须带 `Bearer ` 前缀。** 不带就得到 `60106 用户账号缓存过期`，
   而这个错误码**对所有无鉴权/弱鉴权的请求都返回同一个值**（连瞎编路径都一样），
   零诊断价值——害得我们一度以为「设备接口路径也换了」，白翻了一遍 DEX 路由表。
   详见 §1.3、§6.3。

另外，登录接口要 `form-urlencoded`，而换 token 接口反过来要 JSON，**同一域名下不统一**——
详见 §6.1。

---

## 构建

```bash
./build.sh              # 产出 build/AuxAC.app
./build.sh --install    # 额外装到 /Applications 并重新注册（小组件需要，见下）
open build/AuxAC.app
```

需要 Xcode 或 Command Line Tools。**零第三方依赖**，不需要网络下载任何东西。

> **小组件必须装在 `/Applications`。** 装在 `build/` 这种深目录里，小组件库搜不到它——
> 本机能看到的几个第三方小组件（AirBattery、Dynamic Lyrics、KanaOrigin）全在
> `/Applications`。所以要用小组件就跑 `./build.sh --install`，之后从
> `/Applications/AuxAC.app` 启动。
>
> 构建脚本用 `swiftc` 直接编译，没用 `swift build`。原因写在 `build.sh` 里：
> SwiftPM 的构建引擎在受限沙箱下会报 I/O error。本项目文件少、无依赖，
> 直接 `swiftc` 更快也更省事。
>
> 小组件（`Sources/AuxACWidget/`）由 `build.sh` 里的 **`xcodebuild`** 编成
> `AuxAC.app/Contents/PlugIns/AuxACWidget.appex`，最后自动 `pluginkit -a` 注册。
> 这一步**不能**退回 `swiftc`：手搓 `.appex` 的时候 chronod 认得它、也会启动它，
> 但进程每次都在 WidgetKit 引导阶段崩在 `ExtensionFoundation` 的
> `_EXRunningExtension` 初始化里（SIGTRAP / `brk 1`）。试过部署目标
> 11/12/13/14/20/24/25/26、`-Onone`、去掉 `-application-extension`、
> 补 `AppKit` / `AppIntents` / rpath、手写 `DT*` 与 `CFBundleSupportedPlatforms` 键，
> 全部照崩；换成 Xcode 工程编**同一个源文件**就稳定通过（连测 3 次不崩）。
>
> 工程文件（`Xcode/AuxACWidget.xcodeproj`）是复制本机一个真实工程改出来的——
> 手写的 pbxproj 一定会被 `xcodebuild` 判成 `damaged and cannot be opened`。
> 源码用符号链接指回 `Sources/AuxACWidget/`，全项目只有一份，改完直接 `./build.sh` 即可。
> 工程里保留了 Xcode 26 的默认项 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`。
>
> 还有两个坑写在 `build.sh` 注释里：
> 扩展**必须带 `com.apple.security.app-sandbox`**（没有沙箱的扩展 chronod 不会托管，
> 症状是小组件库里搜不到、且不报任何错）；外层 App **不能用 `codesign --deep`** 签，
> 因为它默认不保留内层已有的 entitlements，会把刚加上的沙箱权限抹掉。

## 使用

1. 启动后菜单栏出现图标（**不会**出现在 Dock 里，这是刻意的——`LSUIElement`）。
   **找不到图标时看屏幕右上角菜单栏**，图标多的话点 `«` 展开。
2. 点图标 → 输入**奥克斯A+ App 用的那个手机号** → 「发送验证码」。
3. 填入收到的短信验证码 → 「登录」。
4. 登录成功即是控制面板。菜单栏那块会随状态变化：
   开机时是当前模式的符号（雪花/太阳/风扇/水滴）**+ 目标温度**（如 `❄ 23.5°`），
   关机时只留电源符号。半度带一位小数，整度不带 `.0`——菜单栏宽度能省则省。
   不想要那个数字的话，点标题右边的齿轮 → 取消「菜单栏显示温度」（存在 `UserDefaults`）。
5. 点标题（设备名）右侧的 `›` 进入**设备页**：点一行切换要控制的空调；
   点行尾的铅笔可以给这台机器起个**只在本机生效的备注**，留空即恢复原名。
   备注存在 `~/Library/Application Support/AuxAC/notes.json`，
   不会改动空调在奥克斯服务器上的名字（也就不会影响手机 App 里看到的名字）。
6. 底栏右侧的「**用电量**」进入能耗页：近 7 天 / 本月 / 今年三个范围的柱状图。
   数据来自奥克斯服务器按天聚合的读数（不是实时功率），接口和三个坑见
   `docs/PROTOCOL.md` §9。旁边那个「原始数据」按钮则把服务端返回的原始 JSON 摊开，
   用来核对界面上某个值到底是从哪个字段来的。
7. 齿轮菜单里还有两个开关：「**菜单栏显示温度**」和「**开机自动启动**」。
   开机自启会**自动挑一条能走通的路**，两条都在用：
   - **系统登录项**（`SMAppService`）——优先。App 放在 `/Applications` 且签名有效时走这条，
     之后在「系统设置 → 通用 → 登录项」里能看到它、也能手动关。
   - **`~/Library/LaunchAgents`**——兜底。本工程是 ad-hoc 签名、还住在 `build/` 里，
     系统那条路的 `status` 直接是 `notFound`（等于「不认识这个 App」），所以实际生效的
     多半是这条。它对签名和路径都不挑，缺点是不会出现在「系统设置」里。
   - 当前走的是哪条，拨完开关底栏那行字会写出来（`LaunchAtLogin.mechanism`）。
     排错看 `--login-probe`，它把两个状态都打出来。
   - LaunchAgent 里写的是可执行文件的**绝对路径**，所以 App 挪了目录登录项会失效。
     对策是每次启动按当前路径重写一遍 plist，用户不需要管这件事。
   - 设置失败时面板上会弹一行原因。

### 桌面 / 通知中心小组件

右键桌面 → 「编辑小组件」→ 搜 **奥克斯空调**，拖出来即可；通知中心底部也是同一个入口。
两种尺寸：

- **小号**：机型名 + 当前模式符号 + 大号目标温度。看一眼就够，不做别的。
- **中号**：左边同样这些（多一行风速），右边一个**真能按的开关机按钮**。

几件需要知道的事：

- **前提：App 必须在 `/Applications` 里。** 用 `./build.sh --install` 装过去。
  装在 `build/` 里小组件库搜不到它，而且不报错——这就是第一次没做出来的原因。
- **小组件自己不联网查状态，它读的是主 App 写的快照**
  （`~/Library/Application Support/AuxAC/widget.json`）。
  所以主 App 至少要成功刷新过一次，小组件才有东西显示；否则它会明确写「未登录」或
  「没有空调」，而不是给个空白方块。
- **为什么要绕这一道**：小组件和主 App 是两个进程，共享内存谈不上；而唯一正规的共享通道
  App Group 需要 Team ID，本工程是 ad-hoc 匿名签名（`TeamIdentifier=not set`）。
  退而求其次用同一个用户目录下的普通文件，不涉及任何权限提升。
- **小组件跑在沙箱里**（`Sources/AuxACWidget/AuxACWidget.entitlements`），
  所以要一条 `temporary-exception` 把 `~/Library/Application Support/AuxAC/` 只读地
  豁免出来。另外沙箱进程里 `FileManager.homeDirectoryForCurrentUser` 未必给真实家目录，
  代码改用 `getpwuid` 取 `pw_dir`（见 `AuxACWidget.swift` 的 `auxRealHome()`）。
- **刷新时机由主 App 推**：状态一变，主 App 就喊 WidgetKit 重画（只有内容真变了才喊，
  因为 WidgetKit 有每日刷新配额）。小组件自己的时间线兜底是 15 分钟一次。
- **中号那个按钮是在小组件进程里直接打云 API 的**（这是全项目唯一一处绕过主 App 的请求）。
  它自己去读同一个目录的 `session.json` 拿 token，所以**不需要**主 App 正在运行——
  但需要你先登录过。
- 小组件要求 **macOS 14+**（交互按钮和 `containerBackground` 都是 14 才有的 API）；
  菜单栏 App 本体仍然能在 macOS 13 上跑。
- ⚠️ **`ACStatus` 和 `AuxACEntry` 必须 `Codable`。** WidgetKit 会把时间线条目归档进
  chronod 的 store，不能编码的条目会让 store 报 `Encountered missing entry` /
  `Marking variant removed from store`，于是**桌面活跃时**小组件退化成「灰条 + 方块」的
  占位骨架——图标变方框、温度和文字全不见（而某个 App 在前台时它却显示正常，
  因为那是现场渲染）。查这个坑的命令：
  ```bash
  log show --last 5m --info --debug --predicate 'process == "chronod"' | grep -i auxac
  ```
- 重新 `./build.sh` 或把 App 换个目录之后，已经拖到桌面上的小组件可能需要删掉重加一次
  （系统记的是扩展的注册信息，路径变了要重新认）。

### 用快捷指令 / AppleScript / 终端控制

本 App 注册了 `auxac://` URL scheme，任何能执行 `open` 的东西都能控制它：

```bash
open 'auxac://on'          # 开机
open 'auxac://off'         # 关机
open 'auxac://toggle'      # 取反
open 'auxac://temp/24.5'   # 设目标温度（16–32，支持 .5）
open 'auxac://temp/+0.5'   # 微调（带正负号＝相对当前值）
open 'auxac://warmer'      # 等同于 temp/+0.5
open 'auxac://cooler'      # 等同于 temp/-0.5
open 'auxac://mode/heat'   # cool / heat / dry / fan
open 'auxac://fan/mediumlow'
open 'auxac://screen/off'
open 'auxac://refresh'     # 立刻拉一次状态
open 'auxac://help'        # 打印命令表（也会写进日志）
```

- **快捷指令**：加一个「打开 URL」动作，填 `auxac://on` 即可。
  苹果现在更推荐 App Intents，但那要求 Xcode 在构建时跑 `appintentsmetadataprocessor`，
  而本工程是 `swiftc` 直接编译的，做不了那一步——URL scheme 效果一样，
  而且对 AppleScript / Raycast / Hammerspoon / launchd 全都通用。
- **AppleScript**：`do shell script "open 'auxac://on'"`
- 齿轮菜单里的「复制 auxac:// 命令表」可以把上表拷到剪贴板。
- ⚠️ 没有「把面板弹开」这条命令：`MenuBarExtra` 的面板由系统托管，
  没有公开 API 能从代码里展开（`NSApp.activate` 也没用）。与其写个假装能用的，不如不写。
- ⚠️ 中文输入法下手打 URL 容易把 `:` `/` 打成全角，`open` 会报
  `The file ... does not exist`。复制粘贴最稳。
- 命令需要**已登录**才会执行（`help` 除外）；未登录时会写一条日志并忽略。

### 控制被拦下时是为什么

本工具**照抄了官方 App 自己的互斥规则**——规则表是服务端下发的
`GET /app/getConfig?id=deviceMutex`（60 项功能，**不需要鉴权**，只要带对 User-Agent）。
命中规则时按钮会变暗、鼠标悬停给出原因，同时下发侧也会拦（`AppModel.apply`），
不会出现「按钮亮着但发出去没反应」。会拦的情况包括：

- **童锁**（`electric_lock`）：表里几乎每一项的第一条互斥都是它，等于全局闸。
- **送风模式下不能调温**、**自动模式下不能调温**、**除湿模式下不能调风速**。
- **「节能」只在制冷模式有效**；**S+黄金舒睡**开着时不能调温/风速/睡眠。
- **两次控制至少间隔 3 秒**（服务端 `baseConfig.controlMinimumInterval = 3`），
  连点会被这里挡住并提示「操作太频繁」。

有一处**刻意没抄**：表里 `temperature` / `wind_speed` / 两个摆风都写着
「`on_off=0` → 请先开机」，但真机逐个实测**关机态一样能写回**，所以这几项不按关机灰掉；
只有 `sleep_mode` 和 `eco` 确实会被设备静默忽略，那两个在关机态会提示先开机。

登录状态存在 `~/Library/Application Support/AuxAC/session.json`（权限 0600）。
token 过期会自动退回登录界面。

### 查看日志

齿轮菜单 → 「打开日志文件」，或直接看：

```
~/Library/Logs/AuxAC/auxac.log
```

日志里含完整请求/响应（已脱敏：手机号、token、设备 id 都只留前几位）。
另有原始响应备份在 `~/Library/Logs/AuxAC/last-*.json`。

**实测发现字段不对时，把这几个文件发我，就能直接改映射。**

---

## 已知限制

- **同一个账号的手机 App 会把本工具踢下线。** AUX 一个账号只能有一个有效会话，
  而且是双向的（Mac 登录也会踢掉手机 App）。建议给这个工具用一个专用/共享账号。
- **token 会过期，且只能人工收短信。** 这是短信登录方案的固有缺陷，
  而局域网直连已经实测排除（`docs/PROTOCOL.md` §5），所以没有替代方案。
  具体寿命：**约 30 天**（服务端 `expireAt` 给的过期时刻），
  **关掉 App 再打开不用重新登录**——token 存在
  `~/Library/Application Support/AuxAC/session.json`（权限 0600），启动时直接读。
  真正会让你重新登录的通常是「手机 App 登录了同一个账号」而不是自然到期。
- **设备状态上报约 4 秒延迟**（实测；早先「8 秒」「15–30 秒」两次估计都只是更松的上限）。
  点完开关后面板上的状态要等几秒才被设备确认；这段时间界面显示的是本地乐观值，
  底栏会出现一个橙色小钟表表示「等设备上报」。这是设备→云端的链路延迟，不是本工具的 bug。
- **首次登录后如果显示「账号下没有找到空调」**，确认空调绑在了同一个账号上。
- **小组件显示的是主 App 最后一次刷新的状态**，不是它自己查的。主 App 退出了也不会变旧得很快
  （服务端状态本身很少变），但如果你在手机 App 上改了设置，桌面上的小组件要等主 App
  下次刷新才会跟上。
- 只支持国内线。海外 AC Freedom 账号用不了。

---

## 代码结构

```
Sources/AuxAC/
  AuxACApp.swift    入口 + 菜单栏场景 + AppDelegate（接 auxac://）+ 各种 --probe-* 自检开关
  Endpoints.swift   接口地址常量 + 错误类型
  PanelMetrics.swift 面板宽度常量（登录页/控制面板/设备页共用，必须一致）
  Models.swift      Device / JSONValue / ACState（状态语义化视图）/ ACMode / FanSpeed
  AuxAPI.swift      HTTP 客户端（Bearer 鉴权 + 宽松解析）
  TokenStore.swift  凭据持久化
  DeviceNoteStore.swift 设备备注持久化（notes.json，只存本机）
  AppModel.swift    全局状态与控制意图
  LoginView.swift   登录流程
  ControlView.swift 控制面板（紧凑分段条）+ 原始数据面板
  DeviceListView.swift 设备列表页（切换空调 + 改本地备注）
  EnergyView.swift  用电量页（柱状图 + 近7天/本月/今年）
  LaunchAtLogin.swift 开机自启（SMAppService 优先 + LaunchAgent 兜底，把错误翻成人话）
  URLCommands.swift auxac:// 命令的解析/说明 + 投递中转站（URLRouter）
  WidgetSnapshot.swift 把当前状态写成 widget.json（主 App 侧，供小组件读）
  DebugLog.swift    脱敏日志
Sources/AuxACWidget/
  AuxACWidget.swift 小组件扩展（状态读取 + 小/中号视图 + 开关机 AppIntent）
Xcode/
  AuxACWidget.xcodeproj/            小组件的构建工程（xcodebuild 用，来历见「构建」）
  AuxACWidget/AuxACWidget.swift     符号链接 → ../../Sources/AuxACWidget/AuxACWidget.swift
  AuxACWidget/Info.plist            扩展的 Info.plist（用 $(...) 占位符，由 xcodebuild 展开）
  AuxACWidget/AuxACWidget.entitlements  扩展的沙箱权限
docs/PROTOCOL.md    协议笔记（含可信度标注、踩坑记录与待确认清单）
```

> `Sources/AuxACWidget/` 必须和 `Sources/AuxAC/` 分开：两边各有一个 `@main`
> （主 App 是 `AuxACApp: App`，小组件是 `AuxACWidgetBundle: WidgetBundle`），
> 编到一起会报 "multiple 'main' types"。

设计上有两条贯穿始终的原则：

1. **对未验证的结构做多重兜底。** 响应外层结构、错误码、字段名原本都不确定，
   所以解析层刻意写得宽松——同一个语义尝试多个候选键名，
   token 用递归查找而不是固定路径。协议现已基本落定，但这层兜底还在，
   用于容纳不同机型的能力差异。
2. **承认不确定，并把不确定性暴露给用户。** 控制面板里的「原始数据」面板
   是刻意保留的：与其猜错后静默失败，不如让用户一眼看到真实值。
   模式/风速旁边的「上报 N」提示同理。

### 自检

```bash
BIN=./build/AuxAC.app/Contents/MacOS/AuxAC
$BIN --selftest                                  # 无界面：解析链路 + 温度编码 + 模式/风速/扫风映射 + 菜单栏温度文字 + 互斥规则 + auxac:// 解析
$BIN --url-probe 'auxac://temp/+0.5'             # 只解析一条 URL 命令并打印结果（不联网、不需要登录）
$BIN --launch-probe 2500                         # 起 GUI，2.5 秒后自动退出
$BIN --window-probe                              # 打印 NSApp.windows 的尺寸后退出
$BIN --probe-sms 13800138000                     # 联网：验证 login_sms_code 的编码方式
$BIN --probe-login <手机号> <验证码>              # 联网：换 token → 拉设备列表（端到端）
```

`--launch-probe` 是为了在不能用 `ps` 的环境里确认「GUI 起来后没立刻崩」。

`--window-probe` 打印 `NSApp.windows` 的 frame。本机沙箱下没法用 Accessibility
去量窗口，只能从进程内部读。注意菜单栏面板的窗口**要等用户点开图标才创建**，
所以它一般只量得到 32×30 的状态栏窗口；面板宽度以 `ControlView.swift` 与
`LoginView.swift` 是否都引用 `PanelMetrics.width` 为准（两边不一致会让面板左右留白）。

**菜单栏那块本身没法自动化核对**：`screencapture` 在这台机器上报
`could not create image from display`（没有可截的图形会话），所以「图标旁边那个温度数字
显示得对不对」只能靠肉眼看。能在无界面下钉住的只有字符串格式化规则——那是
`--selftest` 里最后一条断言（半度 `23.5°` / 整度 `24°` / 关机与关开关都该是 `nil`）。
面板本身的排版可以用 `-D PREVIEW` 离屏渲染成 PNG 核对（见 `docs/PROTOCOL.md` 附录）。

`--probe-sms` 会真打一发 `login_sms_code`。**请用一个不会真收到短信的号**——
它验证的是编码方式被服务端接受（返回 200），不是手机号有没有注册。

`--probe-login` 需要一枚**新鲜**的短信验证码（验证码只能人工收，所以这个探针
只在你手上有码时用）。它是验证「登录 → 拿 token → 列设备」整条链路的最快方式，
成功时会打印 token 和设备清单；失败时原始响应会落盘到 `~/Library/Logs/AuxAC/last-loginBySms.json`。

---

## 后续

1. **~~人眼确认模式/风速编号~~ —— 已解决。** 取值表直接问服务端
   （`GET /app/getConfig?id=deviceMutex`），已写进 `docs/PROTOCOL.md` §3.3，
   代码按表改正为 `1/2/4/6`。剩一个可选的复核：真机上把四个模式各点一遍，
   确认空调面板显示的与 App 一致。
2. ~~找室温字段~~ —— **已定案：云 API 没有室温。** 官方 App 抓包全量扫描（126 条响应）
   `room*`/`indoor*`/`ambient*` 键名 0 命中；唯一带温度的天气接口
   `GET /app/getAirLevel?city=…&lat=…` 返回的是**室外**温度（也是 App 控制请求里
   `environmentData.outdoorTemperature` 的来源）。`feature.roomTempDisplay` 指的是
   室内机面板能显示，不是云端透传。详见 `docs/PROTOCOL.md` §2.5。
3. ~~局域网直连~~ —— **已实测排除**。扫描 `192.168.2.0/24` 的常见端口只有路由器开放，
   Broadlink UDP 发现包无回应。本机这台属于「新款模块」，不再讲老协议。
   荷兰的 Homey 实现作者在新机型上也得到同样结果（详见 `docs/PROTOCOL.md` §5）。
4. **多设备支持。** 目前设备选择器已写（多台时显示下拉），但只在单台设备上验证过。
5. ~~蓝牙兜底（室温的可能来源）~~ —— **已作废，别再往这条路上走。**
   早先看到 `baseConfig` 里有 `nearSupportBleControl=1`、`homeSupportBleControl=1`，
   加上 DEX 路由表里的 `device/bindBle`、`device/updateBle`，我据此猜过
   「室内温度可能是走 BLE 从室内机读的」。**复查后这个推断站不住**：
   那两个开关在 `GET /app/getConfig?id=baseConfig` 的响应里，该响应的
   `{"configId":"baseConfig","name":"APP基础配置","configType":1}` 说明它是
   **App 的全局能力开关**，不是本机的能力位；同一个对象里还躺着
   `supportScanNearDevice: 0`（全局关掉了「扫描附近设备」）和 `onlineVoiceACMAC`
   （一段给部分机型用的 MAC 前缀正则）。也就是说：**这个 App 为部分机型编了 BLE
   通道，不等于本机有蓝牙模块。**
   本机是纯 WiFi 设备——`wifi_hard_version`/`wifi_soft_version` 齐全、`source: 1`、
   控制全程走云、`feature` 里没有任何 BLE 能力位。详见 `docs/PROTOCOL.md` §2.5.1。
6. ~~补齐服务端互斥规则 + 3 秒最小控制间隔~~ —— **已完成**。
   规则表 `GET /app/getConfig?id=deviceMutex` 已读进来（纯函数 `ControlMutex`），
   界面变暗 + tooltip，下发侧同样拦；3 秒间隔见 `AppModel`。详见 `docs/PROTOCOL.md` §10。
7. ~~开机自启~~ —— **已完成**（`LaunchAtLogin.swift`，`SMAppService`）。
8. ~~快捷指令 / URL scheme / AppleScript~~ —— **已完成**（`auxac://`，见「使用」一节）。
   之所以不是 App Intents：本工程用 `swiftc` 直接编译，跑不了
   `appintentsmetadataprocessor`，硬写上也不会被系统发现。
9. **全局快捷键**（`KeyboardShortcuts` 之类）—— 需要引入第三方依赖或自己写 Carbon
   热键，目前没做；有 `auxac://` 之后用 Raycast/Hammerspoon 挂一个也能凑合。
10. **本地定时开关机** —— 服务端 `timing` 在本机 `feature` 里是 `["0","0"]`（硬件不支持），
    但「Mac 侧按点发一条 `auxac://on`」和空调硬件定时是两回事，可以做（挂 launchd 或
    直接在 App 里跑定时器都行），目前没做。
