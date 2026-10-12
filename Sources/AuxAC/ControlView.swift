import SwiftUI

/// 主控制面板。展开菜单栏图标后看到的就是这个。
///
/// 尺寸是这个文件的第一约束：菜单栏弹出的面板一旦太高就会顶到屏幕上沿，
/// 而且用户会直接说「太大了」。所以这里的做法是
/// - **开关并进头部**，不再单占一张卡片（省掉整整一行高度）；
/// - 模式/风速用**等宽分段条**（一个容器 + 若干段，选中段填强调色），
///   而不是一排各自带边框的胶囊——后者每颗都要留内边距，横向一下就撑开了；
/// - 每行的标签放在**左侧固定窄列**，而不是独占一行当小标题（省掉 4 行）；
/// - 面板**固定宽度**，否则菜单栏弹窗会随状态文案长度来回抖。
struct ControlView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var log: DebugLog

    @State private var showRaw = false
    /// 是否正在看「设备」页（列表 + 备注）。见 `body`。
    @State private var showDeviceList = false
    /// 是否正在看「用电量」页。见 `body`。
    @State private var showEnergy = false

    /// 与 `LoginView` 共用（见 `PanelMetrics` 注释：两边不一致会让面板左右留空）。
    private let panelWidth: CGFloat = PanelMetrics.width
    private let pad: CGFloat = 13
    private let rowGap: CGFloat = 9
    /// 左侧标签列的宽度。10pt 的「模式」两字约 20pt，留 28 够用且对齐好看。
    private let labelWidth: CGFloat = 28
    /// 分段条与开关胶囊的统一高度，行高才能整齐。
    private let controlHeight: CGFloat = 27

    var body: some View {
        Group {
            if showDeviceList {
                DeviceListView(isPresented: $showDeviceList)
            } else if showEnergy {
                EnergyView(isPresented: $showEnergy)
            } else {
                panel
            }
        }
        .frame(width: panelWidth)
        // 轮询由 AppModel 常驻管理（菜单栏图标本身也要准），这里只负责
        // 「面板一打开就立刻拉一次」——否则会看到上次打开时的旧状态。
        .onAppear { Task { await model.refresh() } }
        // 收起面板时退回控制面板：否则下次点开菜单栏图标还停在设备页/用电量页，
        // 会让人以为主界面不见了。
        .onDisappear {
            showDeviceList = false
            showEnergy = false
        }
    }

    /// 控制面板本体。设备页打开时它整体让位（见 `body`）。
    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if model.devices.isEmpty {
                emptyState
            } else {
                temperatureRow

                VStack(spacing: rowGap) {
                    modeRow
                    fanRow
                    swingRow
                    extraRow
                }
                .padding(.top, 9)
                .padding(.bottom, 12)
            }

            if let err = model.lastError {
                errorBanner(err)
            }

            footer
        }
    }

    // MARK: - 顶部（图标 + 名字 + 电源开关）

    private var header: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(model.state.isOn
                          ? Color.accentColor.opacity(0.15)
                          : Color.secondary.opacity(0.10))
                    .frame(width: 27, height: 27)
                Image(systemName: model.menuBarSymbol)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(model.state.isOn ? Color.accentColor : Color.secondary)
            }

            VStack(alignment: .leading, spacing: 0) {
                nameView
                Text(subtitle)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 2)

            if model.isRefreshing || model.isBusy {
                ProgressView().controlSize(.mini)
            }

            Toggle("", isOn: Binding(
                get: { model.state.isOn },
                set: { on in Task { await model.setPower(on) } }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(model.isBusy)
            .help(model.state.isOn ? "关机" : "开机")

            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("立即刷新")

            SettingsMenu()
        }
        .padding(.horizontal, pad)
        .padding(.top, 10)
        .padding(.bottom, 7)
    }

    /// 设备名同时是「打开设备页」的入口。
    ///
    /// 早先设备数 > 1 时这里是个 Picker 下拉，只有一个空调时则只是一串死文本——
    /// 于是备注功能无处可放。现在统一成一个按钮：点名字进设备页，
    /// 切换设备、改备注都在那里，也不再为「只有一个设备」分叉出一套逻辑。
    private var nameView: some View {
        Button {
            showDeviceList = true
        } label: {
            HStack(spacing: 3) {
                Text(model.selectedName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .help(model.devices.count > 1 ? "切换空调 / 改备注" : "改备注")
    }

    /// 「运行中 · 室温 27.5°C」。室温拿不到时退化成状态词，不留空。
    private var subtitle: String {
        let status = model.state.isOn ? "运行中" : "已关机"
        guard let room = model.state.roomTemperature else { return status }
        return String(format: "%@ · 室温 %.1f°C", status, room)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("账号下没有找到空调")
                .font(.system(size: 12, weight: .medium))
            Text("确认这台空调已经绑到奥克斯A+ App 的同一个账号上。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("重新获取") { Task { await model.refresh() } }
                .controlSize(.small)
        }
        .padding(.horizontal, pad)
        .padding(.bottom, 14)
    }

    // MARK: - 温度

    private var temperatureRow: some View {
        HStack(spacing: 8) {
            tempButton("minus", enabled: canDecrease && temperatureBlocked == nil,
                       blocked: temperatureBlocked) { await model.nudgeTemperature(by: -0.5) }

            VStack(spacing: -5) {
                Text(targetText)
                    .font(.system(size: 29, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(model.state.isOn ? Color.primary : Color.secondary)
                Text("目标温度")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)

            tempButton("plus", enabled: canIncrease && temperatureBlocked == nil,
                       blocked: temperatureBlocked) { await model.nudgeTemperature(by: 0.5) }
        }
        .padding(.vertical, 11)
        .padding(.horizontal, pad)
    }

    private var canDecrease: Bool {
        guard let t = model.state.targetTemperature else { return false }
        return t > 16
    }

    private var canIncrease: Bool {
        guard let t = model.state.targetTemperature else { return false }
        return t < 32
    }

    private func tempButton(_ symbol: String, enabled: Bool, blocked: String? = nil,
                            action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 31, height: 31)
                .background(
                    Circle().fill(enabled
                                  ? Color.secondary.opacity(0.13)
                                  : Color.secondary.opacity(0.05))
                )
                .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(model.isBusy || !enabled)
        .help(blocked ?? "")
    }

    private var currentTarget: Double? { model.state.targetTemperature }

    private var targetText: String {
        guard let t = currentTarget else { return "—" }
        return t.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f°", t)
            : String(format: "%.1f°", t)
    }

    // MARK: - 模式 / 风速

    private var modeRow: some View {
        labeledRow("模式", trailing: model.state.modeRaw == nil ? "未上报" : nil) {
            // 模式与风速**不受电源门控**：实测空调关机时 `air_con_func`/`wind_speed`
            // 一样能写回（全部功能字段里只有睡眠和节能会被静默忽略）。
            // 所以这里只挡「正在下发中」，不再要求开机。
            strip(ACMode.allCases.map(\.label),
                  selectedIndex: modeIndex,
                  enabled: !model.isBusy,
                  blocked: lockOnlyBlocked) { idx in
                Task { await model.setMode(ACMode.allCases[idx]) }
            }
        }
    }

    private var modeIndex: Int? {
        guard let raw = model.state.modeRaw, let m = ACMode(rawValue: raw) else { return nil }
        return ACMode.allCases.firstIndex(of: m)
    }

    private var fanRow: some View {
        // 高亮认用户的选择（preferredFan），因为上报值被设备量化过、无法反推
        // （见 AppModel.preferredFan 注释）。上报原值不再占标签那列，要看去「原始数据」面板。
        labeledRow("风速") {
            strip(FanSpeed.allCases.map(\.label),
                  selectedIndex: fanIndex,
                  enabled: !model.isBusy,
                  blocked: fanBlocked) { idx in
                Task { await model.setFan(FanSpeed.allCases[idx]) }
            }
        }
    }

    private var fanIndex: Int? {
        if let f = model.preferredFan { return FanSpeed.allCases.firstIndex(of: f) }
        guard let raw = model.state.fanRaw, let f = FanSpeed(rawValue: raw) else { return nil }
        return FanSpeed.allCases.firstIndex(of: f)
    }

    // MARK: - 扫风 / 附加功能

    private var swingRow: some View {
        // 上下 / 左右各占一行：每边有 7 档（摆动 / 定格1–5 / 关闭），挤一行塞不下。
        // 上报原值不再摆在标签那列，要看去「原始数据」面板。
        //
        // 扫风**不受电源门控**（关机态实测也能写回），同模式/风速，只挡 isBusy。
        VStack(spacing: rowGap) {
            labeledRow("上下") {
                strip(ACState.swingLabels,
                      selectedIndex: model.state.upDownSwingIndex,
                      enabled: !model.isBusy,
                      blocked: lockOnlyBlocked) { idx in
                    Task { await model.setUpDownSwing(index: idx) }
                }
            }
            labeledRow("左右") {
                strip(ACState.swingLabels,
                      selectedIndex: model.state.leftRightSwingIndex,
                      enabled: !model.isBusy,
                      blocked: lockOnlyBlocked) { idx in
                    Task { await model.setLeftRightSwing(index: idx) }
                }
            }
        }
    }

    private var extraRow: some View {
        labeledRow("功能") {
            HStack(spacing: rowGap) {
                chip("睡眠", icon: "moon.zzz.fill", selected: model.state.sleepMode,
                     enabled: sleepEcoEnabled,
                     blocked: sleepBlocked) { on in await model.setSleep(on) }
                chip("节能", icon: "leaf.fill", selected: model.state.eco,
                     enabled: sleepEcoEnabled,
                     blocked: ecoBlocked) { on in await model.setEco(on) }
                // 这里原本还有「强劲」。本机硬件不支持（见 AppModel「本机不支持的功能」
                // 一节：turbo / silence / ultra_silence / wind_speed=5 全部被静默忽略），
                // 官方 App 里也点不动，所以直接去掉，不留一个按下去没反应的按钮。
                chip("屏显", icon: "light.max", selected: model.state.screenOn,
                     enabled: !model.isBusy,
                     blocked: lockOnlyBlocked) { on in await model.setScreen(on) }
            }
        }
    }

    /// **只用于「睡眠」和「节能」两个 chip。**
    ///
    /// 真机逐个实测：只有 `sleep_mode` 和 `eco` 在关机态下会被设备静默忽略
    /// （下发返回 200 但状态不变）。其余全部关机态也能写回：
    /// `screen`（屏显，实测 4 秒写回）、`temperature`、`air_con_func`(模式)、
    /// `wind_speed`(风速)、`up_down_swing`、`left_right_swing`。
    /// 服务端 mutex 表也是这么标的（只有 sleep_mode / eco 等带
    /// 「请先开机后再使用该功能」，而 `screen` 的约束里只有 `electric_lock`）。
    ///
    /// 所以模式 / 风速 / 扫风 / 屏显都只用 `!model.isBusy`。
    /// 早先这里把这四行一起门控了，导致关机时连能用的模式/风速都点不动。
    ///
    /// 注意：chip 内部**不**用 `.disabled()`，只做变暗；点击仍会进到
    /// `AppModel.requirePower`，由它弹一句「请先开机」。否则按钮会静默失效，
    /// 用户只能看到「点了没反应」。
    private var sleepEcoEnabled: Bool { !model.isBusy && model.state.isOn }

    // MARK: - 服务端互斥表（deviceMutex）
    //
    // 官方 App 就是按这张表灰按钮 / 弹 toast 的，规则全部来自
    // `GET /app/getConfig?id=deviceMutex`（60 项，无需鉴权）。判断写在
    // `Models.swift` 的 `ControlMutex` 里，纯函数、`--selftest` 能直接断言。
    //
    // 这里只负责把「原因」接到界面上：变暗 + tooltip。**同时下发侧也会拦**
    // （`AppModel.apply`），两边共用同一份规则，不会出现「按钮亮着但发不出去」。

    private var temperatureBlocked: String? { ControlMutex.temperature(model.state) }
    private var fanBlocked: String? { ControlMutex.fan(model.state) }
    private var sleepBlocked: String? { ControlMutex.sleep(model.state) }
    private var ecoBlocked: String? { ControlMutex.eco(model.state) }
    /// 模式 / 两个摆风 / 屏显：表里除童锁外没有别的互斥项。
    private var lockOnlyBlocked: String? { ControlMutex.none(model.state) }

    // MARK: - 通用小部件

    /// 「左侧窄标签 + 右侧控件」的一行。标签列固定宽度，各行控件左边缘对齐。
    private func labeledRow<Content: View>(_ label: String, trailing: String? = nil,
                                           @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 8, weight: .regular))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .frame(width: labelWidth, alignment: .leading)

            content()
        }
        .padding(.horizontal, pad)
    }

    /// 等宽分段条（模式、风速、扫风档位）。选中段填强调色 + 白字，未选中段透明。
    ///
    /// 比「一排独立胶囊」紧凑得多：段与段之间只留 1pt，整个容器共用一圈
    /// 内边距，7 档风速也能塞进一行而不换行。
    ///
    /// `blocked` 是服务端 mutex 表给出的「为什么现在不能改」（童锁 / 模式冲突），
    /// 非 nil 时整条变暗并把原因挂成 tooltip。
    private func strip(_ labels: [String], selectedIndex: Int?, enabled: Bool,
                       blocked: String? = nil,
                       onTap: @escaping (Int) -> Void) -> some View {
        let active = enabled && blocked == nil
        return HStack(spacing: 1) {
            ForEach(Array(labels.enumerated()), id: \.offset) { idx, text in
                let isSelected = idx == selectedIndex
                Button {
                    onTap(idx)
                } label: {
                    Text(text)
                        .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity)
                        .frame(height: controlHeight)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(isSelected ? Color.accentColor : Color.clear)
                        )
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.secondary.opacity(0.10))
        )
        .disabled(!active)
        .opacity(active ? 1 : 0.45)
        .help(blocked ?? "")
    }

    /// 开关胶囊（屏显、睡眠、节能）。点击取反。
    private func chip(_ title: String, icon: String?, selected: Bool, enabled: Bool,
                      blocked: String? = nil,
                      action: @escaping (Bool) async -> Void) -> some View {
        let active = enabled && blocked == nil
        return Button {
            Task { await action(!selected) }
        } label: {
            HStack(spacing: 3) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 8.5, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 10, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .frame(height: controlHeight + 2)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? Color.accentColor : Color.secondary.opacity(0.10))
            )
            .foregroundStyle(selected ? Color.white : Color.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 刻意**不加** `.disabled(!active)`：功能类按钮在关机态若被真正禁用，点击会
        // 毫无反应，用户只能看到「无效」。改成只变暗、点击照常进入
        // `AppModel.requirePower` / `AppModel.apply`，由它弹出明确原因。
        .opacity(active ? 1 : 0.45)
        .help(blocked ?? (active ? "" : "空调运行中才可用"))
    }

    // MARK: - 错误 / 底部

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 10))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
        .padding(.horizontal, pad)
        .padding(.bottom, 10)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider()
            HStack(spacing: 5) {
                if model.hasUnconfirmedIntent {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .help("已下发，等设备上报（实测约 4 秒）")
                }
                Text(model.statusLine.isEmpty ? "—" : model.statusLine)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Button("用电量") { showEnergy = true }
                    .buttonStyle(.borderless)
                    .font(.system(size: 9.5))
                    .help("看这台空调每天的用电量")
                Button(showRaw ? "收起" : "原始数据") { showRaw.toggle() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 9.5))
            }
            .padding(.horizontal, pad)

            if showRaw {
                rawDump
                    .padding(.horizontal, pad)
                    .padding(.bottom, 10)
            }
        }
        .padding(.top, 8)
        // 这里必须留底边距：状态行是面板最后一行，不留就会贴着窗口下沿，
        // 看起来像被裁掉了（也是用户说「高度太小」的观感来源之一）。
        .padding(.bottom, 11)
    }

    /// 原始 `data` 字段的只读转储。
    ///
    /// 刻意保留这个视图：PROTOCOL.md §7 里仍有字段名/取值没完全确认，
    /// 有它用户自己就能看出「某个功能到底叫什么 key、上报值是多少」。
    private var rawDump: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if let raw = model.selectedDevice?.data, !raw.isEmpty {
                    ForEach(raw.keys.sorted(), id: \.self) { key in
                        HStack(alignment: .top, spacing: 6) {
                            Text(key)
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Text(raw[key]?.stringValue ?? String(describing: raw[key] ?? .null))
                                .font(.system(size: 9.5, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                } else {
                    Text("（暂无数据）")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(7)
        }
        .frame(maxHeight: 160)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
