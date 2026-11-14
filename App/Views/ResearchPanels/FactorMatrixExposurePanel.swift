import Foundation
import SwiftUI
import StockMonitorCore

/// Presentation-only view for caller-supplied factor correlation and exposure results.
/// It does not calculate, fetch, or infer any values.
struct FactorMatrixExposurePanel: View {
    @Environment(\.stockMonitorPalette) private var palette

    let matrix: LocalFactorCorrelationMatrix?
    let exposures: [LocalFactorExposureResult]
    let explanation: String?

    init(
        matrix: LocalFactorCorrelationMatrix? = nil,
        exposures: [LocalFactorExposureResult] = [],
        explanation: String? = nil
    ) {
        self.matrix = matrix
        self.exposures = exposures
        self.explanation = explanation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StockMonitorTokens.Space.large) {
            if let explanation, !explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(explanation)
                    .font(.system(size: StockMonitorTokens.TypeScale.body))
                    .foregroundStyle(palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Text("说明：\(explanation)"))
            }

            correlationSection
            exposureSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var correlationSection: some View {
        VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
            sectionHeading("因子相关矩阵", detail: "颜色仅编码已测得的相关系数；文本同时显示系数、样本数和缺失原因。")

            if let matrix {
                if matrix.factors.isEmpty {
                    missingPanel("矩阵没有因子；相关系数和样本数未知。")
                } else {
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: StockMonitorTokens.Space.small) {
                            ForEach(Array(matrix.factors.enumerated()), id: \.offset) { rowIndex, factor in
                                matrixRow(rowIndex: rowIndex, factor: factor, matrix: matrix)
                            }
                        }
                        .padding(.vertical, StockMonitorTokens.Space.xsmall)
                    }
                    .frame(maxHeight: 520)
                    .accessibilityLabel("因子相关矩阵，可滚动查看")
                }
            } else {
                missingPanel("尚无相关矩阵；相关系数、样本数和缺失原因未知。")
            }
        }
    }

    @ViewBuilder
    private var exposureSection: some View {
        VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
            sectionHeading("组合因子暴露", detail: "只展示核心结果明确提供的组合暴露；横截面结果不会被当作组合暴露。")

            let portfolioResults = exposures.filter { $0.kind == .portfolio }
            let crossSectionalResults = exposures.filter { $0.kind == .crossSectionalDistribution }
            if portfolioResults.isEmpty {
                missingPanel(exposures.isEmpty
                    ? "尚无因子暴露结果；组合权重和值未知。"
                    : "当前结果没有明确的组合暴露；可能只有横截面分布，因此组合权重和值保持未知。")
            } else {
                LazyVStack(alignment: .leading, spacing: StockMonitorTokens.Space.small) {
                    ForEach(Array(portfolioResults.enumerated()), id: \.offset) { _, result in
                        exposureRow(result)
                    }
                }
            }
            if !crossSectionalResults.isEmpty {
                sectionHeading("自选股横截面因子值", detail: "逐只显示本地缓存的观测；不等同于持仓加权的组合暴露。")
                LazyVStack(alignment: .leading, spacing: StockMonitorTokens.Space.small) {
                    ForEach(Array(crossSectionalResults.enumerated()), id: \.offset) { _, result in
                        crossSectionalRow(result)
                    }
                }
            }
        }
    }

    private func matrixRow(rowIndex: Int, factor: FactorID, matrix: LocalFactorCorrelationMatrix) -> some View {
        let cells = rowIndex < matrix.cells.count ? matrix.cells[rowIndex] : []
        return VStack(alignment: .leading, spacing: StockMonitorTokens.Space.small) {
            Text(factorLabel(factor))
                .font(.system(size: StockMonitorTokens.TypeScale.subhead, weight: .semibold))
                .foregroundStyle(palette.inkPrimary)

            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: StockMonitorTokens.Space.small) {
                    ForEach(Array(matrix.factors.enumerated()), id: \.offset) { columnIndex, columnFactor in
                        if columnIndex < cells.count {
                            correlationCell(cells[columnIndex], factor: columnFactor)
                        } else {
                            missingCell("列数据缺失", detail: "系数未知；样本数未知。", label: "列 \(factorLabel(columnFactor)) 数据缺失")
                        }
                    }
                }
                .padding(.bottom, StockMonitorTokens.Space.xsmall)
            }
            .accessibilityLabel(Text("\(factorLabel(factor))行，可横向滚动查看"))
        }
        .padding(StockMonitorTokens.Space.medium)
        .background(palette.paper1, in: RoundedRectangle(cornerRadius: StockMonitorTokens.Radius.medium))
        .overlay {
            RoundedRectangle(cornerRadius: StockMonitorTokens.Radius.medium)
                .stroke(palette.hair, lineWidth: StockMonitorTokens.Size.hairline)
        }
    }

    private func correlationCell(_ result: LocalFactorCorrelationResult, factor: FactorID) -> some View {
        let coefficientText = result.coefficient.map { String(format: "%.3f", $0) } ?? "未知"
        let reason = result.missingReason.map(missingReasonLabel) ?? "无"
        let detail = "样本数：\(result.sampleCount)；缺失原因：\(reason)"
        return VStack(alignment: .leading, spacing: StockMonitorTokens.Space.xsmall) {
            Text(factorLabel(result.right))
                .font(.system(size: StockMonitorTokens.TypeScale.caption, weight: .medium))
                .foregroundStyle(palette.inkSecondary)
                .lineLimit(2)
            Text(coefficientText)
                .font(.system(size: StockMonitorTokens.TypeScale.title, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(palette.inkPrimary)
            Text("n=\(result.sampleCount)")
                .font(.system(size: StockMonitorTokens.TypeScale.caption))
                .foregroundStyle(palette.inkSecondary)
            if result.coefficient == nil {
                Text(reason)
                    .font(.system(size: StockMonitorTokens.TypeScale.caption))
                    .foregroundStyle(palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(StockMonitorTokens.Space.small)
        .frame(width: StockMonitorTokens.Size.factorMatrixCellWidth,
               minHeight: StockMonitorTokens.Size.factorMatrixCellMinHeight, alignment: .topLeading)
        .background(cellColor(for: result.coefficient), in: RoundedRectangle(cornerRadius: StockMonitorTokens.Radius.small))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(factorLabel(factor))与\(factorLabel(result.right))，相关系数\(coefficientText)，样本数\(result.sampleCount)，缺失原因\(reason)"))
        .accessibilityHint(Text(detail))
    }

    private func exposureRow(_ result: LocalFactorExposureResult) -> some View {
        let valueText = result.exposure.map { String(format: "%.4f", $0) } ?? "未知"
        let reason = result.missingReason.map(missingReasonLabel) ?? "无"
        let detail = result.exposure == nil
            ? "组合暴露未知；样本数：\(result.sampleCount)；原因：\(reason)。请检查组合权重和因子值。"
            : "组合暴露：\(valueText)；样本数：\(result.sampleCount)。"

        return HStack(alignment: .top, spacing: StockMonitorTokens.Space.medium) {
            VStack(alignment: .leading, spacing: StockMonitorTokens.Space.xsmall) {
                Text(factorLabel(result.factor))
                    .font(.system(size: StockMonitorTokens.TypeScale.subhead, weight: .semibold))
                    .foregroundStyle(palette.inkPrimary)
                Text("样本数：\(result.sampleCount)")
                    .font(.system(size: StockMonitorTokens.TypeScale.caption))
                    .foregroundStyle(palette.inkSecondary)
                if result.exposure == nil {
                    Text("原因：\(reason)。组合权重或因子值不完整。")
                        .font(.system(size: StockMonitorTokens.TypeScale.footnote))
                        .foregroundStyle(palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: StockMonitorTokens.Space.small)
            Text(valueText)
                .font(.system(size: StockMonitorTokens.TypeScale.title, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(result.exposure == nil ? palette.inkMuted : palette.inkPrimary)
                .multilineTextAlignment(.trailing)
        }
        .padding(StockMonitorTokens.Space.medium)
        .frame(maxWidth: .infinity, minHeight: StockMonitorTokens.Size.minimumHitTarget, alignment: .leading)
        .background(palette.paper1, in: RoundedRectangle(cornerRadius: StockMonitorTokens.Radius.medium))
        .overlay {
            RoundedRectangle(cornerRadius: StockMonitorTokens.Radius.medium)
                .stroke(palette.hair, lineWidth: StockMonitorTokens.Size.hairline)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(factorLabel(result.factor))，\(detail)"))
    }

    private func crossSectionalRow(_ result: LocalFactorExposureResult) -> some View {
        let usable = result.symbolExposures.filter { $0.value?.isFinite == true }
        return VStack(alignment: .leading, spacing: StockMonitorTokens.Space.small) {
            HStack(alignment: .firstTextBaseline) {
                Text(factorLabel(result.factor))
                    .font(.system(size: StockMonitorTokens.TypeScale.subhead, weight: .semibold))
                    .foregroundStyle(palette.inkPrimary)
                Spacer(minLength: StockMonitorTokens.Space.small)
                Text("\(result.sampleCount) 只")
                    .font(.system(size: StockMonitorTokens.TypeScale.caption, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(palette.inkSecondary)
            }
            if usable.isEmpty {
                Text("当前样本没有可用的该因子值；值保持未知。")
                    .font(.system(size: StockMonitorTokens.TypeScale.footnote))
                    .foregroundStyle(palette.inkMuted)
            } else {
                ForEach(Array(usable.prefix(50).enumerated()), id: \.offset) { _, item in
                    HStack {
                        Text(item.symbol)
                            .font(.system(size: StockMonitorTokens.TypeScale.footnote, design: .monospaced))
                            .foregroundStyle(palette.inkSecondary)
                        Spacer(minLength: StockMonitorTokens.Space.small)
                        Text(item.value.map { $0.formatted(.number.precision(.fractionLength(0...4))) } ?? "未知")
                            .font(.system(size: StockMonitorTokens.TypeScale.footnote, weight: .semibold, design: .monospaced))
                            .foregroundStyle(palette.inkPrimary)
                    }
                    .frame(minHeight: StockMonitorTokens.Size.minimumHitTarget)
                    .accessibilityElement(children: .combine)
                }
                if usable.count > 50 {
                    Text("列表最多显示 50 只；横截面样本共 \(usable.count) 只。")
                        .font(.system(size: StockMonitorTokens.TypeScale.caption))
                        .foregroundStyle(palette.inkMuted)
                }
            }
            Text("来源：\(result.provenance.isEmpty ? "未知" : result.provenance.joined(separator: "、"))")
                .font(.system(size: StockMonitorTokens.TypeScale.caption))
                .foregroundStyle(palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(StockMonitorTokens.Space.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.paper1, in: RoundedRectangle(cornerRadius: StockMonitorTokens.Radius.medium))
        .overlay {
            RoundedRectangle(cornerRadius: StockMonitorTokens.Radius.medium)
                .stroke(palette.hair, lineWidth: StockMonitorTokens.Size.hairline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(factorLabel(result.factor)) 自选股横截面因子值，\(result.sampleCount) 只；非组合加权暴露")
    }

    private func sectionHeading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: StockMonitorTokens.Space.xsmall) {
            Text(title)
                .font(.system(size: StockMonitorTokens.TypeScale.title, weight: .semibold))
                .foregroundStyle(palette.inkPrimary)
            Text(detail)
                .font(.system(size: StockMonitorTokens.TypeScale.footnote))
                .foregroundStyle(palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func missingPanel(_ message: String) -> some View {
        Text(message)
            .font(.system(size: StockMonitorTokens.TypeScale.body))
            .foregroundStyle(palette.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(StockMonitorTokens.Space.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.paper2, in: RoundedRectangle(cornerRadius: StockMonitorTokens.Radius.medium))
            .accessibilityElement(children: .combine)
    }

    private func missingCell(_ title: String, detail: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: StockMonitorTokens.Space.xsmall) {
            Text(title)
                .font(.system(size: StockMonitorTokens.TypeScale.caption, weight: .medium))
                .foregroundStyle(palette.inkSecondary)
            Text(detail)
                .font(.system(size: StockMonitorTokens.TypeScale.caption))
                .foregroundStyle(palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(StockMonitorTokens.Space.small)
        .frame(width: StockMonitorTokens.Size.factorMatrixCellWidth,
               minHeight: StockMonitorTokens.Size.factorMatrixCellMinHeight, alignment: .topLeading)
        .background(palette.paper2, in: RoundedRectangle(cornerRadius: StockMonitorTokens.Radius.small))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
    }

    private func cellColor(for coefficient: Double?) -> Color {
        guard let coefficient, coefficient.isFinite else { return palette.paper2 }
        let normalized = min(1, max(0, (coefficient + 1) / 2))
        let index = min(palette.heatScale.count - 1, max(0, Int(normalized * Double(palette.heatScale.count))))
        return palette.heatScale[index]
    }

    private func factorLabel(_ factor: FactorID) -> String {
        FactorSubset.definitions[factor]?.displayName ?? factor.rawValue
    }

    private func missingReasonLabel(_ reason: LocalFactorMissingReason) -> String {
        switch reason {
        case .noFiniteObservations: "没有有限观测"
        case .missingAlignedObservations: "对齐观测缺失"
        case .insufficientObservations: "观测不足"
        case .constantSeries: "序列为常数"
        case .missingFactorValue: "因子值缺失"
        case .missingPortfolioWeight: "组合权重缺失"
        case .noExplicitPortfolioWeights: "没有明确组合权重"
        case .noUsableExposureValues: "没有可用暴露值"
        }
    }
}
