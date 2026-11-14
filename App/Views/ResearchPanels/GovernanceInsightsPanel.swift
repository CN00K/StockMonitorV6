import SwiftUI
import StockMonitorCore

struct GovernanceInsightsPanel: View {
    @Environment(\.stockMonitorPalette) private var palette

    let rejectionCounts: [(reason: String, count: Int)]
    let keywordReport: EventKeywordFrequencyReport?
    let isLoading: Bool
    let explanation: String?
    let loadError: String?
    let refresh: () -> Void

    init(
        rejectionCounts: [(reason: String, count: Int)],
        keywordReport: EventKeywordFrequencyReport? = nil,
        isLoading: Bool = false,
        explanation: String? = nil,
        loadError: String? = nil,
        refresh: @escaping () -> Void
    ) {
        self.rejectionCounts = rejectionCounts
        self.keywordReport = keywordReport
        self.isLoading = isLoading
        self.explanation = explanation
        self.loadError = loadError
        self.refresh = refresh
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
            header

            if let explanation, !explanation.isEmpty {
                Text(explanation)
                    .font(.system(size: StockMonitorTokens.TypeScale.footnote))
                    .foregroundStyle(palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("说明：\(explanation)")
            }

            if isLoading {
                StockMonitorDataStatePanel(
                    state: .loading,
                    detail: "正在读取本地 SQLite 治理数据；现有数据不会用零值替代。"
                )
            } else if let loadError {
                StockMonitorDataStatePanel(state: .error, detail: loadError)
            } else {
                rejectionSection
                keywordSection
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: StockMonitorTokens.Space.small) {
            Text("治理洞察")
                .font(.system(size: StockMonitorTokens.TypeScale.title, weight: .semibold))
                .foregroundStyle(palette.inkPrimary)

            Spacer(minLength: StockMonitorTokens.Space.small)

            Button(action: refresh) {
                Label("刷新治理数据", systemImage: "arrow.clockwise")
                    .frame(minHeight: StockMonitorTokens.Size.minimumHitTarget)
            }
            .buttonStyle(.bordered)
            .tint(palette.accent)
            .disabled(isLoading)
            .accessibilityLabel("刷新治理数据")
            .accessibilityHint("从本地 SQLite 重新读取拒绝原因和事件关键词样本")
        }
    }

    private var rejectionSection: some View {
        VStack(alignment: .leading, spacing: StockMonitorTokens.Space.small) {
            Text("事件拒绝原因")
                .font(.system(size: StockMonitorTokens.TypeScale.subhead, weight: .semibold))
                .foregroundStyle(palette.inkPrimary)

            if rejectionCounts.isEmpty {
                StockMonitorDataStatePanel(
                    state: .empty,
                    detail: "过去 24 小时的 SQLite 查询未返回拒绝记录（0 条）；若期间没有采集活动，不能据此评价来源质量。"
                )
            } else {
                StockMonitorSurface(padding: StockMonitorTokens.Space.medium) {
                    VStack(alignment: .leading, spacing: StockMonitorTokens.Space.small) {
                        ForEach(Array(rejectionCounts.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: StockMonitorTokens.Space.medium) {
                                Text(item.reason)
                                    .font(.system(size: StockMonitorTokens.TypeScale.body))
                                    .foregroundStyle(palette.inkSecondary)
                                    .fixedSize(horizontal: false, vertical: true)

                                Spacer(minLength: StockMonitorTokens.Space.small)

                                Text(String(item.count))
                                    .font(.system(size: StockMonitorTokens.TypeScale.body, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(palette.inkPrimary)
                                    .accessibilityLabel("\(item.reason)拒绝次数")
                                    .accessibilityValue(String(item.count))
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private var keywordSection: some View {
        VStack(alignment: .leading, spacing: StockMonitorTokens.Space.small) {
            Text("相邻 24 小时关键词")
                .font(.system(size: StockMonitorTokens.TypeScale.subhead, weight: .semibold))
                .foregroundStyle(palette.inkPrimary)

            if let keywordReport {
                sampleSummary(for: keywordReport)
                if keywordReport.frequencies.isEmpty {
                    StockMonitorDataStatePanel(
                        state: .partial,
                        detail: "相邻 24 小时没有可显示的关键词；样本为空，增长率未知。"
                    )
                } else {
                    StockMonitorSurface(padding: StockMonitorTokens.Space.medium) {
                        VStack(alignment: .leading, spacing: StockMonitorTokens.Space.small) {
                            ForEach(keywordReport.frequencies, id: \.token) { frequency in
                                HStack(alignment: .firstTextBaseline, spacing: StockMonitorTokens.Space.medium) {
                                    Text(frequency.token)
                                        .font(.system(size: StockMonitorTokens.TypeScale.body))
                                        .foregroundStyle(palette.inkSecondary)
                                    Spacer(minLength: StockMonitorTokens.Space.small)
                                    Text("最新 \(sampleValue(frequency.latestCount)) · 基线 \(sampleValue(frequency.baselineCount))")
                                        .font(.system(size: StockMonitorTokens.TypeScale.footnote, weight: .medium))
                                        .monospacedDigit()
                                        .foregroundStyle(palette.inkPrimary)
                                    Text(growthLabel(frequency.growthPercent))
                                        .font(.system(size: StockMonitorTokens.TypeScale.footnote, weight: .semibold))
                                        .foregroundStyle(frequency.growthPercent == nil ? palette.inkMuted : palette.accent2)
                                        .frame(minWidth: StockMonitorTokens.Size.minimumHitTarget, alignment: .trailing)
                                }
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("关键词 \(frequency.token)")
                                .accessibilityValue("最新样本 \(sampleValue(frequency.latestCount))，基线样本 \(sampleValue(frequency.baselineCount))，\(growthLabel(frequency.growthPercent))")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if !keywordReport.missingReasons.isEmpty {
                    Text("部分窗口没有本地事件，相关增长率保持未知。")
                        .font(.system(size: StockMonitorTokens.TypeScale.caption))
                        .foregroundStyle(palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("数据限制：部分相邻 24 小时窗口没有本地事件，相关增长率未知")
                }
            } else {
                StockMonitorDataStatePanel(
                    state: .empty,
                    detail: "尚无相邻 24 小时关键词报告；最新样本、基线样本和增长率未知。"
                )
            }
        }
    }

    private func sampleSummary(for report: EventKeywordFrequencyReport) -> some View {
        StockMonitorSurface(padding: StockMonitorTokens.Space.medium) {
            HStack(spacing: StockMonitorTokens.Space.medium) {
                sampleMetric(label: "最新 24 小时", value: sampleValue(report.latestSampleCount))
                sampleMetric(label: "前一相邻 24 小时", value: sampleValue(report.baselineSampleCount))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
        }
    }

    private func sampleMetric(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: StockMonitorTokens.Space.xsmall) {
            Text(label)
                .font(.system(size: StockMonitorTokens.TypeScale.caption, weight: .medium))
                .foregroundStyle(palette.inkMuted)
            Text(value)
                .font(.system(size: StockMonitorTokens.TypeScale.titleLarge, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(palette.inkPrimary)
                .accessibilityLabel(label)
                .accessibilityValue(value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func growthLabel(_ growth: Double?) -> String {
        guard let growth else { return "增长率未知" }
        return "增长 \(growth.formatted(.number.precision(.fractionLength(0...1))) )%"
    }

    private func sampleValue(_ count: Int) -> String {
        String(count)
    }
}
