import SwiftUI

/// 用电量页：柱状图 + 范围切换。
///
/// 用的就是官方 App 里那个「用电量」图表页的同一个接口——那个页面其实是个**明文
/// vite 打包网页**（`https://smarthome.aux-home.com/battery100/index.html`），
/// 直接下载下来读 JS 就拿到了接口名和参数，不需要反编译任何东西。
/// 接口形状与三个坑写在 `AuxAPI.energyStatistics` 的注释里，可复现的探测记录见
/// docs/PROTOCOL.md §9。
struct EnergyView: View {
    @EnvironmentObject private var model: AppModel

    /// 由 `ControlView` 持有；返回时置回 false。
    @Binding var isPresented: Bool

    private let pad: CGFloat = 13
    /// 柱子区域的最大高度（不含下面的轴标签）。
    private let chartHeight: CGFloat = 96

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: PanelMetrics.width)
        // 每次进来都重拉。能耗是按天聚合的，不会因为几秒钟的缓存而更准，
        // 而 stale 的「本月合计」比多一次请求更让人困惑。
        .onAppear { Task { await model.loadEnergy() } }
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

            Text("用电量")
                .font(.system(size: 12, weight: .semibold))

            Spacer(minLength: 2)

            if model.energyLoading {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, pad)
        .padding(.top, 10)
        .padding(.bottom, 7)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("数据来自奥克斯服务器按天聚合的用电量，不是实时功率。")
            Text("刚绑定的设备前几天会是 0 度，那是真的没用过电，不是出错。")
        }
        .font(.system(size: 9))
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, pad)
        .padding(.top, 7)
        .padding(.bottom, 11)
    }

    // MARK: - 主体

    private var content: some View {
        VStack(alignment: .leading, spacing: 11) {
            totalRow
            rangeStrip
            chartArea
        }
        .padding(.horizontal, pad)
        .padding(.top, 11)
        .padding(.bottom, 13)
    }

    private var totalRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(fmt(model.energyTotal))
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text("度")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(model.energyRange == .year ? "每月合计" : "每日合计")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
    }

    /// 三个范围的分段条。刻意和风速那条用同一个视觉规格（单容器 + 选中段填色），
    /// 免得面板里出现两种不同的「选择器」长相。
    private var rangeStrip: some View {
        HStack(spacing: 0) {
            ForEach(EnergyRange.allCases) { r in
                let selected = r == model.energyRange
                Button {
                    Task { await model.setEnergyRange(r) }
                } label: {
                    Text(r.label)
                        .font(.system(size: 10.5, weight: selected ? .semibold : .regular))
                        .frame(maxWidth: .infinity)
                        .frame(height: 25)
                        .background(selected ? Color.accentColor : Color.clear)
                        .foregroundStyle(selected ? Color.white : Color.primary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.energyLoading)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.secondary.opacity(0.10))
        )
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    @ViewBuilder
    private var chartArea: some View {
        let pts = model.energy
        if pts.isEmpty {
            Text(model.energyLoading ? "正在读取…" : "这段时间没有数据")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .frame(height: chartHeight + 16)
        } else {
            VStack(alignment: .leading, spacing: 5) {
                bars(pts)
                axis(pts)
                if model.energyEmpty {
                    Text("这段时间没有用电记录")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// 柱状图本体。
    ///
    /// 宽度是**算出来**的而不是交给 SwiftUI 自动分布：柱子最多 31 根（整月每日），
    /// 要让它们刚好铺满面板且间距随根数收缩，用 GeometryReader 反而更难预测
    /// （离屏 `ImageRenderer` 里尤其如此）。面板宽度是固定常量，直接算最稳。
    private func bars(_ pts: [EnergyPoint]) -> some View {
        let n = max(pts.count, 1)
        let spacing: CGFloat = n > 20 ? 1.5 : (n > 12 ? 3 : 6)
        let avail = PanelMetrics.width - pad * 2
        let barWidth = max(2, (avail - spacing * CGFloat(n - 1)) / CGFloat(n))
        // 全 0 时用一个下限当分母，否则所有柱子高度都是 0，图会变成一条空线。
        let maxKwh = max(pts.map(\.kwh).max() ?? 0, 0.5)
        // 柱子少的时候在柱顶标数字；多了会糊成一片，改成只在 tooltip 里给。
        let showValue = n <= 8
        // 柱顶数字要占一行，把柱子可用高度让出来。
        let barArea = showValue ? chartHeight - 12 : chartHeight

        return HStack(alignment: .bottom, spacing: spacing) {
            ForEach(pts) { p in
                VStack(spacing: 2) {
                    if showValue {
                        Text(fmt(p.kwh))
                            .font(.system(size: 7))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(p.kwh > 0 ? Color.accentColor : Color.secondary.opacity(0.18))
                        .frame(width: barWidth,
                               height: max(2, barArea * CGFloat(p.kwh / maxKwh)))
                }
                .help("\(p.label)：\(fmt(p.kwh)) 度")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: chartHeight + (showValue ? 12 : 0), alignment: .bottom)
    }

    /// 横轴。柱子少时每根都标；整月 30 根时逐根标必然重叠（每根只有 ~8pt 宽，
    /// 而 "10-07" 要 ~22pt），所以退化成「首尾两个日期」两端对齐。
    @ViewBuilder
    private func axis(_ pts: [EnergyPoint]) -> some View {
        if pts.count <= 12 {
            let n = max(pts.count, 1)
            let spacing: CGFloat = n > 12 ? 3 : 6
            let avail = PanelMetrics.width - pad * 2
            let barWidth = max(2, (avail - spacing * CGFloat(n - 1)) / CGFloat(n))
            HStack(spacing: spacing) {
                ForEach(pts) { p in
                    Text(p.label)
                        .font(.system(size: 7.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .frame(width: barWidth)
                }
            }
        } else if let first = pts.first, let last = pts.last {
            HStack {
                Text(first.label)
                Spacer(minLength: 4)
                Text(last.label)
            }
            .font(.system(size: 7.5))
            .foregroundStyle(.tertiary)
        }
    }

    /// 度数显示精度：大数不要小数，小数保留两位。柱顶那 7pt 的字尤其放不下 "0.06"。
    private func fmt(_ v: Double) -> String {
        if v >= 100 { return String(format: "%.0f", v) }
        if v >= 10 { return String(format: "%.1f", v) }
        return String(format: "%.2f", v)
    }
}
