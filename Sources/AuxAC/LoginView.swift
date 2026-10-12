import SwiftUI

/// 登录界面：手机号 → 短信验证码 → token。
///
/// 之所以把登录做进 GUI 而不是让用户填配置文件，是因为国内线**只支持短信登录**
/// （没有密码），token 过期后必须人工收一次验证码，做成界面流程最顺手。
struct LoginView: View {
    @EnvironmentObject private var model: AppModel

    @State private var phone = ""
    @State private var code = ""
    @FocusState private var focus: Field?

    private enum Field { case phone, code }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "wind.snow")
                    .font(.title2)
                VStack(alignment: .leading, spacing: 1) {
                    Text("奥克斯空调")
                        .font(.headline)
                    Text("使用奥克斯A+ App 的账号")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 2)

            Divider()

            switch model.phase {
            case .loggedOut:
                phoneEntry
            case .needCode:
                codeEntry
            case .ready:
                EmptyView()
            }

            if let err = model.lastError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !model.statusLine.isEmpty {
                Text(model.statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Text("仅支持国内线（A+/AUX Home）")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                SettingsMenu()
            }
        }
        .padding(14)
        // 必须与 ControlView 同宽。早先这里没有 width、由 RootView 外面套 340，
        // 而 ControlView 是 300 —— 控制面板就被居中放进 340 的窗口里，左右各空 20pt。
        .frame(width: PanelMetrics.width)
        .onAppear { focus = .phone }
    }

    private var phoneEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("手机号")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("13xxxxxxxxx", text: $phone)
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .phone)
                .onSubmit { Task { await model.requestCode(phone: phone) } }

            Button {
                Task { await model.requestCode(phone: phone) }
            } label: {
                HStack {
                    if model.isBusy { ProgressView().controlSize(.small) }
                    Text("发送验证码")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isBusy || phone.isEmpty)
        }
    }

    private var codeEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("短信验证码")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("4-6 位数字", text: $code)
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .code)
                .onSubmit { Task { await model.submitCode(code) } }

            HStack {
                Button("重新发送") {
                    if case .needCode(let p) = model.phase {
                        Task { await model.requestCode(phone: p) }
                    }
                }
                .disabled(model.isBusy)

                Spacer()

                Button {
                    Task { await model.submitCode(code) }
                } label: {
                    HStack {
                        if model.isBusy { ProgressView().controlSize(.small) }
                        Text("登录")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy || code.isEmpty)
            }
        }
        .onAppear { focus = .code }
    }
}

/// 日志与凭据管理的小菜单，登录前后都可用。
struct SettingsMenu: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var log: DebugLog

    /// 登录项状态。它是**系统**的状态（存在 launchd 那边），不是 App 的状态，
    /// 所以不进 `AppModel`。每次菜单出现都重新读一遍——用户可能刚在
    /// 「系统设置 → 通用 → 登录项」里手动改过，不重读这里就会显示旧值。
    @State private var launchAtLogin = LaunchAtLogin.isRegistered

    var body: some View {
        Menu {
            // 菜单栏图标旁边那个温度数字的开关。放在第一项——这是这个菜单里
            // 唯一一个「改外观」而不是「修东西」的选项。
            Toggle("菜单栏显示温度", isOn: $model.menuBarShowsTemperature)
            Toggle("开机自动启动", isOn: $launchAtLogin)
            Divider()
            Button("复制 auxac:// 命令表") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(AuxCommand.helpText(), forType: .string)
                model.statusLine = "命令表已复制到剪贴板"
            }
            Divider()
            Button("打开日志文件") { log.revealInFinder() }
            Button("清空日志") { log.clear() }
            Divider()
            Button("复制凭据路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(TokenStore.path, forType: .string)
            }
            if model.phase == .ready {
                Divider()
                Button("退出登录", role: .destructive) { model.logout() }
            }
            Divider()
            Button("退出 AuxAC") { NSApplication.shared.terminate(nil) }
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .onAppear { launchAtLogin = LaunchAtLogin.isRegistered }
        .onChange(of: launchAtLogin) { wanted in
            // 失败时把开关拨回系统的真实状态，并把原因丢给面板上那条现成的错误条——
            // 在这里自己弹 alert 要挂在菜单栏面板上，位置和层级都别扭。
            if let error = LaunchAtLogin.setEnabled(wanted) {
                launchAtLogin = LaunchAtLogin.isRegistered
                model.lastError = "设置开机自启失败：\(error)"
                log.log("✗ 设置开机自启失败：\(error)")
            } else {
                log.log("✓ 开机自启 → \(wanted ? "开" : "关")（系统状态 \(LaunchAtLogin.describe())）")
                model.statusLine = wanted
                    ? "已设为开机自启（\(LaunchAtLogin.mechanism)）"
                    : "已取消开机自启"
            }
        }
    }
}
