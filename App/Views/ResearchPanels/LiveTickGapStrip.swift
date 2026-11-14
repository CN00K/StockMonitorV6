import SwiftUI
import StockMonitorCore

/// A presentation-only view of recent live tick and reconciliation status records.
struct LiveTickGapStrip: View {
    @Environment(\.stockMonitorPalette) private var palette

    private let records: [LiveTickStatusRecord]
    private let loadingMessage: String?
    private let errorMessage: String?
    private let emptyMessage: String?

    init(
        records: [LiveTickStatusRecord],
        loadingMessage: String? = nil,
        errorMessage: String? = nil,
        emptyMessage: String? = nil
    ) {
        self.records = records
        self.loadingMessage = loadingMessage
        self.errorMessage = errorMessage
        self.emptyMessage = emptyMessage
    }

    private var chronologicalRecords: [LiveTickStatusRecord] {
        records.sorted {
            if $0.recordedAt == $1.recordedAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.recordedAt < $1.recordedAt
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
            if let loadingMessage {
                StockMonitorDataStatePanel(state: .loading, detail: loadingMessage)
            } else if let errorMessage {
                StockMonitorDataStatePanel(state: .error, detail: errorMessage)
            } else if chronologicalRecords.isEmpty {
                StockMonitorDataStatePanel(
                    state: .empty,
                    detail: emptyMessage ?? "暂无实时 tick 或 reconcile 记录。"
                )
            } else {
                if chronologicalRecords.contains(where: { $0.dataStatus == .partial }) {
                    StockMonitorDataStatePanel(
                        state: .partial,
                        detail: "记录中包含部分数据；缺失符号未在此处推断或补全。"
                    )
                }

                StockMonitorSurface {
                    VStack(alignment: .leading, spacing: StockMonitorTokens.Space.small) {
                        Text("会话 tick / 离线补齐")
                            .font(.system(size: StockMonitorTokens.TypeScale.subhead, weight: .semibold))
                            .foregroundStyle(palette.inkPrimary)

                        ForEach(chronologicalRecords) { record in
                            LiveTickGapRow(record: record)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("实时 tick 和 reconcile 记录")
                .accessibilityValue("共 \(chronologicalRecords.count) 条，按时间正序")
            }
        }
    }
}

private struct LiveTickGapRow: View {
    @Environment(\.stockMonitorPalette) private var palette

    let record: LiveTickStatusRecord

    private var operationTitle: String {
        switch record.operation {
        case .tick: "实时 tick"
        case .reconcile: "离线补齐"
        }
    }

    private var dataStatusTitle: String {
        switch record.dataStatus {
        case .complete: "完整"
        case .partial: "部分"
        case .empty: "无数据"
        }
    }

    private var reconcileOutcomeTitle: String {
        switch record.reconcileOutcome {
        case .success: "成功"
        case .failure: "失败"
        case .unknown: "未知"
        }
    }

    private var statusColor: Color {
        switch record.dataStatus {
        case .complete: palette.dataUp
        case .partial: palette.accent2
        case .empty: palette.dataFlat
        }
    }

    private var outcomeColor: Color {
        switch record.reconcileOutcome {
        case .success: palette.dataUp
        case .failure: palette.dataDown
        case .unknown: palette.inkMuted
        }
    }

    private var accessibilitySummary: String {
        let timestamp = ChartFormatters.dateTime(record.recordedAt)
        return "\(timestamp)，操作 \(operationTitle)，数据 \(dataStatusTitle)，请求 \(record.requestedSymbols)，返回 \(record.returnedSymbols)，缺失 \(record.missingSymbols.count)，reconcile \(reconcileOutcomeTitle)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StockMonitorTokens.Space.xsmall) {
            HStack(alignment: .firstTextBaseline, spacing: StockMonitorTokens.Space.small) {
                Text(ChartFormatters.dateTime(record.recordedAt))
                    .font(.system(size: StockMonitorTokens.TypeScale.caption))
                    .monospacedDigit()
                    .foregroundStyle(palette.inkMuted)

                Text(operationTitle)
                    .font(.system(size: StockMonitorTokens.TypeScale.body, weight: .semibold))
                    .foregroundStyle(palette.inkPrimary)

                Spacer(minLength: StockMonitorTokens.Space.small)

                Text(dataStatusTitle)
                    .font(.system(size: StockMonitorTokens.TypeScale.caption, weight: .semibold))
                    .foregroundStyle(statusColor)
            }

            HStack(spacing: StockMonitorTokens.Space.medium) {
                countLabel("请求", value: record.requestedSymbols)
                countLabel("返回", value: record.returnedSymbols)
                countLabel("缺失", value: record.missingSymbols.count)

                Spacer(minLength: StockMonitorTokens.Space.small)

                Text("补齐：\(reconcileOutcomeTitle)")
                    .font(.system(size: StockMonitorTokens.TypeScale.caption))
                    .foregroundStyle(outcomeColor)
            }
            .frame(minHeight: StockMonitorTokens.Size.minimumHitTarget, alignment: .leading)
        }
        .padding(.vertical, StockMonitorTokens.Space.small)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(palette.hair)
                .frame(height: StockMonitorTokens.Size.hairline)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private func countLabel(_ label: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: StockMonitorTokens.Space.xsmall) {
            Text(label)
                .font(.system(size: StockMonitorTokens.TypeScale.caption))
                .foregroundStyle(palette.inkMuted)
            Text(value, format: .number)
                .font(.system(size: StockMonitorTokens.TypeScale.body, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(palette.inkPrimary)
        }
    }
}
