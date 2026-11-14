import SwiftUI

struct DesignSystemPreviewGallery: View {
    @State private var appearance: StockMonitorAppearance

    init(appearance: StockMonitorAppearance = .dusk) {
        _appearance = State(initialValue: appearance)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: StockMonitorTokens.Space.xlarge) {
                    VStack(alignment: .leading, spacing: StockMonitorTokens.Space.small) {
                        Text("PR1 · 设计系统基础")
                            .font(.system(size: StockMonitorTokens.TypeScale.display, weight: .bold, design: .rounded))
                            .foregroundStyle(appearance.palette.inkPrimary)
                        Text("颜色、字阶、间距与图表状态令牌。预览不填造行情值。")
                            .font(.system(size: StockMonitorTokens.TypeScale.body))
                            .foregroundStyle(appearance.palette.inkSecondary)
                    }

                    Picker("外观", selection: $appearance) {
                        ForEach(StockMonitorAppearance.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(minHeight: StockMonitorTokens.Size.minimumHitTarget)
                    .accessibilityLabel("外观主题")

                    FourStatePreviewGallery()

                    VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
                        Text("数据过期 / 来源标注")
                            .font(.system(size: StockMonitorTokens.TypeScale.title, weight: .semibold))
                            .foregroundStyle(appearance.palette.inkPrimary)
                        StockMonitorDataStatePanel(
                            state: .stale,
                            detail: "来源时间已超出新鲜度窗口；图表应保留缺口，不做静默插值。")
                        StockMonitorProvenanceLine(
                            source: "Eastmoney",
                            timestamp: nil,
                            cadence: "1 分钟轮询 · 仅前台",
                            isProviderTimestamp: false)
                    }

                    VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
                        Text("32 项组件骨架")
                            .font(.system(size: StockMonitorTokens.TypeScale.title, weight: .semibold))
                            .foregroundStyle(appearance.palette.inkPrimary)
                        StockMonitorComponentCatalog()
                    }
                }
                .padding(StockMonitorTokens.Space.large)
            }
            .background(appearance.palette.paper0)
            .navigationTitle("UI v2 · PR1")
            .navigationBarTitleDisplayMode(.inline)
        }
        .stockMonitorAppearance(appearance)
    }
}

struct FourStatePreviewGallery: View {
    var body: some View {
        VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
            Text("四态数据展示")
                .font(.system(size: StockMonitorTokens.TypeScale.title, weight: .semibold))
            StockMonitorDataStatePanel(
                state: .loading,
                detail: "仅在 App 前台会话内采集。")
            StockMonitorDataStatePanel(
                state: .empty,
                detail: "此时间范围没有本机保存的匹配记录。")
            StockMonitorDataStatePanel(
                state: .partial,
                detail: "部分数据源有返回；缺失时段保持空白，不插值。")
            StockMonitorDataStatePanel(
                state: .error,
                detail: "请求失败；缓存值不会被标记为新鲜。",
                actionTitle: "重试",
                action: { })
        }
    }
}

#Preview("Dusk 暗色 · PR1") {
    DesignSystemPreviewGallery(appearance: .dusk)
}

#Preview("高对比浅色 · PR1") {
    DesignSystemPreviewGallery(appearance: .contrastLight)
}
