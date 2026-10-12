import SwiftUI

/// 设备管理页：空调列表 + 备注编辑。
///
/// 为什么用「整页切换」而不是在控制面板里折叠展开：面板宽度固定 300，
/// 设备一多、备注一长，折叠列表会把面板撑得很高，而菜单栏弹窗顶到屏幕上沿
/// 就很难看。整页切换有独立的空间，多台设备只是让列表变长、可以滚动。
struct DeviceListView: View {
    @EnvironmentObject private var model: AppModel

    /// 由 `ControlView` 持有；返回时置回 false。
    @Binding var isPresented: Bool

    /// 正在编辑备注的设备 did（nil = 没有在编辑）。
    @State private var editingDID: String?
    @State private var draft: String = ""
    @FocusState private var focused: String?

    private let pad: CGFloat = 13

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.devices.isEmpty {
                Text("还没有设备")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(pad)
            } else if model.devices.count > 5 {
                // 设备真的多了才套滚动区，免得面板被撑到屏幕上沿。
                ScrollView { rows }
                    .frame(height: 232)
            } else {
                // 设备少时直接铺开，面板高度随内容走。
                //
                // 这不只是审美选择：`ImageRenderer` 渲染 `ScrollView` 的内容会得到
                // 一片空白（滚动区在离屏布局里拿不到内容尺寸），不套滚动区才能用
                // 离屏预览核对列表排版。这条踩过一次坑，别再改回去。
                rows
            }
            Divider()
            footer
        }
        .frame(width: PanelMetrics.width)
    }

    // MARK: - 头部 / 底部

    private var header: some View {
        HStack(spacing: 7) {
            Button {
                isPresented = false
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("返回控制面板")

            Text("设备")
                .font(.system(size: 12, weight: .semibold))

            Spacer(minLength: 2)

            Text("\(model.devices.count) 台")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, pad)
        .padding(.top, 10)
        .padding(.bottom, 7)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("点一行切换空调，点铅笔改备注。")
            Text("备注只存在本机，不会改动空调在奥克斯服务器上的名字。")
        }
        .font(.system(size: 9))
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, pad)
        .padding(.top, 7)
        .padding(.bottom, 11)
    }

    // MARK: - 列表

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.devices.enumerated()), id: \.element.did) { idx, d in
                row(d)
                if idx < model.devices.count - 1 {
                    Divider().padding(.leading, 24)
                }
            }
        }
    }

    // MARK: - 单行

    @ViewBuilder
    private func row(_ d: Device) -> some View {
        let isSelected = d.did == model.selectedDevice?.did
        let isEditing = editingDID == d.did

        HStack(alignment: .top, spacing: 7) {
            // 在线状态点：绿=在线，灰=离线
            Circle()
                .fill((d.online ?? true) ? Color.green : Color.secondary.opacity(0.35))
                .frame(width: 6, height: 6)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 1) {
                if isEditing {
                    TextField("备注（留空恢复原名）", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5))
                        .focused($focused, equals: d.did)
                        .onSubmit { commit(d) }
                } else {
                    HStack(spacing: 4) {
                        Text(model.name(for: d))
                            .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                            .lineLimit(1)
                        if model.note(for: d.did) != nil {
                            // 有本地备注时标一支小铅笔，提醒这个名字是本机改的。
                            // 用 pencil.circle 而不是 pencil：后者在 9pt 下渲染出来
                            // 就是一道看不清的斜杠，认不出是铅笔。
                            Image(systemName: "pencil.circle")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Text(subtitle(d))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 2)

            if isEditing {
                Button("好") { commit(d) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10, weight: .medium))
            } else {
                Button {
                    startEdit(d)
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("改备注")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            // 正在编辑时不要被行点击抢走：否则改一半就切设备了
            guard editingDID == nil else { return }
            model.select(d)
            isPresented = false
        }
    }

    /// 「奥克斯空调 · AABBCCDDEEFF · 运行中 23.5°」
    private func subtitle(_ d: Device) -> String {
        var parts: [String] = []
        if let a = d.alias, !a.isEmpty, a != model.name(for: d) {
            parts.append(a)
        }
        if let m = d.mac { parts.append(m) }
        if (d.online ?? true) == false { parts.append("离线") }
        // 只有当前选中的那台有实时状态（其余设备的数据是列表接口最后一次给的快照）
        if d.did == model.selectedDevice?.did {
            let st = model.state
            if st.isOn {
                let t = st.targetTemperature.map { String(format: "%.1f°", $0) } ?? ""
                parts.append("运行中 \(t)")
            } else {
                parts.append("已关机")
            }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 编辑动作

    private func startEdit(_ d: Device) {
        draft = model.note(for: d.did) ?? ""
        editingDID = d.did
        // 等这一帧的 TextField 真正插进视图树再抢焦点，否则 @FocusState 会落空
        DispatchQueue.main.async { focused = d.did }
    }

    private func commit(_ d: Device) {
        model.setNote(draft, for: d.did)
        editingDID = nil
        focused = nil
    }
}
