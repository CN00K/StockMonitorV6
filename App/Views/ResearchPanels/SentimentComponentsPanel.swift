import SwiftUI
import StockMonitorCore

/// Presentation-only panel for caller-measured local market sentiment.
/// This view does not fetch, infer, or create sentiment observations.
struct SentimentComponentsPanel: View {
    @Environment(\.stockMonitorPalette) private var palette

    let result: LocalMarketSentimentResult?
    let observations: [LocalMarketSentimentComponent: LocalMarketSentimentObservation]
    let availabilityExplanation: String

    init(
        result: LocalMarketSentimentResult?,
        observations: [LocalMarketSentimentComponent: LocalMarketSentimentObservation],
        availabilityExplanation: String
    ) {
        self.result = result
        self.observations = observations
        self.availabilityExplanation = availabilityExplanation
    }

    private var exclusions: [LocalMarketSentimentComponent: LocalMarketSentimentExclusionReason] {
        Dictionary(uniqueKeysWithValues: (result?.excludedComponents ?? []).map { ($0.component, $0.reason) })
    }

    private var validScore: Double? {
        guard let score = result?.score, score.isFinite, (-1...1).contains(score), result?.band != nil else {
            return nil
        }
        return score
    }

    private var isPartial: Bool {
        !(result?.excludedComponents.isEmpty ?? true)
    }

    var body: some View {
        StockMonitorSurface {
            VStack(alignment: .leading, spacing: StockMonitorTokens.Space.large) {
                header
                availability
                if let score = validScore, let band = result?.band {
                    scoreSummary(score: score, band: band)
                } else {
                    unavailableSummary
                }
                componentsList
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: StockMonitorTokens.Space.small) {
            Text("市场情绪组成")
                .font(.system(size: StockMonitorTokens.TypeScale.title, weight: .semibold))
                .foregroundStyle(palette.inkPrimary)
            Spacer(minLength: StockMonitorTokens.Space.small)
            if isPartial {
                Text("部分")
                    .font(.system(size: StockMonitorTokens.TypeScale.caption, weight: .semibold))
                    .foregroundStyle(palette.accent2)
                    .padding(.horizontal, StockMonitorTokens.Space.small)
                    .padding(.vertical, StockMonitorTokens.Space.xsmall)
                    .background(palette.accent2.opacity(StockMonitorTokens.Opacity.semanticWash), in: Capsule())
                    .accessibilityLabel("部分数据：有组件被排除")
            }
        }
    }

    private var availability: some View {
        Text(availabilityExplanation)
            .font(.system(size: StockMonitorTokens.TypeScale.footnote))
            .foregroundStyle(palette.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("可用性说明：\(availabilityExplanation)")
    }

    private func scoreSummary(score: Double, band: LocalMarketSentimentBand) -> some View {
        VStack(alignment: .leading, spacing: StockMonitorTokens.Space.small) {
            HStack(alignment: .firstTextBaseline, spacing: StockMonitorTokens.Space.medium) {
                Text("测得分数")
                    .font(.system(size: StockMonitorTokens.TypeScale.caption, weight: .medium))
                    .foregroundStyle(palette.inkMuted)
                Text(score, format: .number.precision(.fractionLength(2)))
                    .font(.system(size: StockMonitorTokens.TypeScale.display, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(scoreColor(score))
                Text(bandTitle(band))
                    .font(.system(size: StockMonitorTokens.TypeScale.body, weight: .semibold))
                    .foregroundStyle(palette.inkPrimary)
            }
            Text(isPartial ? "描述性测量，部分组件缺失或无效；不是预测。" : "描述性测量，不是预测。")
                .font(.system(size: StockMonitorTokens.TypeScale.caption))
                .foregroundStyle(palette.inkMuted)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            isPartial
                ? "测得分数 \(score.formatted(.number.precision(.fractionLength(2))))，\(bandTitle(band))，部分测量，不是预测"
                : "测得分数 \(score.formatted(.number.precision(.fractionLength(2))))，\(bandTitle(band))，不是预测"
        )
    }

    private var unavailableSummary: some View {
        VStack(alignment: .leading, spacing: StockMonitorTokens.Space.small) {
            Text("分数不可用")
                .font(.system(size: StockMonitorTokens.TypeScale.subhead, weight: .semibold))
                .foregroundStyle(palette.inkPrimary)
            Text("没有可展示的有效汇总分数；不会用零值或推断值补齐。")
                .font(.system(size: StockMonitorTokens.TypeScale.footnote))
                .foregroundStyle(palette.inkSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("分数不可用；不会用零值或推断值补齐")
    }

    private var componentsList: some View {
        VStack(alignment: .leading, spacing: StockMonitorTokens.Space.small) {
            Text("六项测量")
                .font(.system(size: StockMonitorTokens.TypeScale.subhead, weight: .semibold))
                .foregroundStyle(palette.inkPrimary)
            ForEach(LocalMarketSentimentComponent.allCases, id: \.self) { component in
                componentRow(component)
            }
        }
    }

    @ViewBuilder
    private func componentRow(_ component: LocalMarketSentimentComponent) -> some View {
        VStack(alignment: .leading, spacing: StockMonitorTokens.Space.xsmall) {
            HStack(alignment: .firstTextBaseline, spacing: StockMonitorTokens.Space.small) {
                Text(component.title)
                    .font(.system(size: StockMonitorTokens.TypeScale.body, weight: .medium))
                    .foregroundStyle(palette.inkPrimary)
                Spacer(minLength: StockMonitorTokens.Space.small)
                if let observation = observations[component], observation.score.isFinite,
                   (-1...1).contains(observation.score), observation.weight.isFinite, observation.weight >= 0 {
                    Text(observation.score, format: .number.precision(.fractionLength(2)))
                        .font(.system(size: StockMonitorTokens.TypeScale.body, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(scoreColor(observation.score))
                        .accessibilityLabel("测得分数 \(observation.score.formatted(.number.precision(.fractionLength(2))))")
                } else {
                    Text("不可用")
                        .font(.system(size: StockMonitorTokens.TypeScale.footnote, weight: .semibold))
                        .foregroundStyle(palette.inkMuted)
                }
            }
            if let observation = observations[component], let reason = invalidReason(for: observation) {
                Text(reason)
                    .font(.system(size: StockMonitorTokens.TypeScale.caption))
                    .foregroundStyle(palette.dataDown)
                metadata(for: observation)
            } else if let observation = observations[component] {
                metadata(for: observation)
            } else {
                Text(reasonText(for: exclusions[component] ?? .missing))
                    .font(.system(size: StockMonitorTokens.TypeScale.caption))
                    .foregroundStyle(palette.inkMuted)
            }
        }
        .padding(.vertical, StockMonitorTokens.Space.small)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(componentAccessibilityLabel(component))
    }

    private func metadata(for observation: LocalMarketSentimentObservation) -> some View {
        VStack(alignment: .leading, spacing: StockMonitorTokens.Space.xsmall) {
            Text("来源：\(observation.metadata.provenance)")
            Text("样本：\(observation.metadata.sampleDescription)")
            if let count = observation.metadata.sampleCount {
                Text("样本数：\(count)")
            }
            if let measuredAt = observation.metadata.measuredAt {
                Text("测量时间：\(measuredAt, format: .dateTime)")
            }
        }
        .font(.system(size: StockMonitorTokens.TypeScale.caption))
        .foregroundStyle(palette.inkMuted)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func invalidReason(for observation: LocalMarketSentimentObservation) -> String? {
        if !observation.score.isFinite || !(-1...1).contains(observation.score) {
            return reasonText(.invalidScore)
        }
        if !observation.weight.isFinite || observation.weight < 0 {
            return reasonText(.invalidWeight)
        }
        return nil
    }

    private func reasonText(_ reason: LocalMarketSentimentExclusionReason) -> String {
        switch reason {
        case .missing: "缺少实测值"
        case .invalidScore: "已排除：分数无效（须为有限值且在 −1 到 1 之间）"
        case .invalidWeight: "已排除：权重无效（须为有限且不小于 0）"
        }
    }

    private func componentAccessibilityLabel(_ component: LocalMarketSentimentComponent) -> String {
        if let observation = observations[component], invalidReason(for: observation) == nil {
            return "\(component.title)，\(observation.score.formatted(.number.precision(.fractionLength(2))))，来源 \(observation.metadata.provenance)，样本 \(observation.metadata.sampleDescription)"
        }
        return "\(component.title)，\(reasonText(exclusions[component] ?? .missing))"
    }

    private func scoreColor(_ score: Double) -> Color {
        if score > 0.2 { return palette.dataUp }
        if score < -0.2 { return palette.dataDown }
        return palette.dataFlat
    }

    private func bandTitle(_ band: LocalMarketSentimentBand) -> String {
        switch band {
        case .veryWeak: "很弱"
        case .weak: "偏弱"
        case .balanced: "平衡"
        case .strong: "偏强"
        case .veryStrong: "很强"
        }
    }
}

private extension LocalMarketSentimentComponent {
    var title: String {
        switch self {
        case .advancingDecliningBreadth: "涨跌家数宽度"
        case .returnDistribution: "收益分布"
        case .limitUpDownBalance: "涨跌停平衡"
        case .sealBreakPressure: "炸板压力"
        case .moneyFlowDirection: "资金流向"
        case .marketParticipation: "市场参与度"
        }
    }
}
