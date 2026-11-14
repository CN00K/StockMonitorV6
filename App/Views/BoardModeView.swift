import SwiftUI
import StockMonitorCore

@MainActor
struct BoardModeView: View {
    @ObservedObject var model: MonitorViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.stockMonitorPalette) private var palette

    private var snapshot: MarketSnapshot? { model.state.latestSnapshot }

    private var quotesByCode: [String: Quote] {
        Dictionary((snapshot?.quotes ?? []).map { ($0.code, $0) },
                   uniquingKeysWith: { _, newest in newest })
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                palette.paper0.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: StockMonitorTokens.Space.large) {
                        header
                        snapshotSummary

                        if geometry.size.width >= 760 {
                            HStack(alignment: .top, spacing: StockMonitorTokens.Space.large) {
                                VStack(alignment: .leading, spacing: StockMonitorTokens.Space.large) {
                                    indexSection(columns: 2)
                                    breadthSection
                                }
                                .frame(maxWidth: .infinity, alignment: .topLeading)

                                watchlistSection
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                            }
                        } else {
                            indexSection(columns: geometry.size.width >= 520 ? 2 : 1)
                            breadthSection
                            watchlistSection
                        }

                        dataScopeNote
                    }
                    .frame(maxWidth: 1_360, alignment: .leading)
                    .padding(.horizontal, geometry.size.width >= 760
                        ? StockMonitorTokens.Space.xlarge : StockMonitorTokens.Space.large)
                    .padding(.vertical, StockMonitorTokens.Space.medium)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
        }
        .background(palette.paper0)
        .statusBarHidden(true)
        .tint(palette.accent)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: StockMonitorTokens.Space.medium) {
            VStack(alignment: .leading, spacing: StockMonitorTokens.Space.xsmall) {
                Text("全屏行情看板")
                    .font(.system(size: StockMonitorTokens.TypeScale.titleLarge, weight: .semibold))
                    .foregroundStyle(palette.inkPrimary)
                Text("仅汇总当前已加载的本机数据")
                    .font(.system(size: StockMonitorTokens.TypeScale.caption))
                    .foregroundStyle(palette.inkMuted)
            }
            Spacer(minLength: StockMonitorTokens.Space.small)

            Button {
                Task { await model.refreshNow() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(minWidth: StockMonitorTokens.Size.minimumHitTarget,
                           minHeight: StockMonitorTokens.Size.minimumHitTarget)
                    .background(palette.paper2, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("刷新当前行情快照")
            .accessibilityHint("遵循现有前台会话规则，不会扩展扫描或请求 Level-2")

            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: StockMonitorTokens.TypeScale.body, weight: .semibold))
                    .frame(minWidth: StockMonitorTokens.Size.minimumHitTarget,
                           minHeight: StockMonitorTokens.Size.minimumHitTarget)
                    .background(palette.paper2, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭全屏看板")
        }
        .padding(.bottom, StockMonitorTokens.Space.small)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(palette.hair)
                .frame(height: StockMonitorTokens.Size.hairline)
        }
    }

    private var snapshotSummary: some View {
        HStack(alignment: .center, spacing: StockMonitorTokens.Space.medium) {
            Circle()
                .fill(phaseColor)
                .frame(width: 9, height: 9)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: StockMonitorTokens.Space.xsmall) {
                Text(phaseTitle)
                    .font(.system(size: StockMonitorTokens.TypeScale.body, weight: .semibold))
                    .foregroundStyle(palette.inkPrimary)
                if let capturedAt = snapshot?.capturedAt {
                    Text("本机快照采集于 \(ChartFormatters.dateTime(capturedAt))")
                        .font(.system(size: StockMonitorTokens.TypeScale.caption))
                        .foregroundStyle(palette.inkSecondary)
                } else {
                    Text("尚无行情快照；报价与市场宽度未知。")
                        .font(.system(size: StockMonitorTokens.TypeScale.caption))
                        .foregroundStyle(palette.accent2)
                }
            }
            Spacer(minLength: StockMonitorTokens.Space.small)
            Text(snapshot == nil ? "数据未知" : "轮询快照")
                .font(.system(size: StockMonitorTokens.TypeScale.caption, weight: .semibold))
                .foregroundStyle(palette.inkSecondary)
                .padding(.horizontal, StockMonitorTokens.Space.medium)
                .padding(.vertical, StockMonitorTokens.Space.small)
                .background(palette.paper2, in: Capsule())
        }
        .padding(StockMonitorTokens.Space.medium)
        .background(palette.paper1, in: RoundedRectangle(cornerRadius: StockMonitorTokens.Radius.large))
        .overlay {
            RoundedRectangle(cornerRadius: StockMonitorTokens.Radius.large)
                .stroke(palette.hair, lineWidth: StockMonitorTokens.Size.hairline)
        }
        .accessibilityElement(children: .combine)
    }

    private func indexSection(columns: Int) -> some View {
        VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
            sectionHeading("核心指数", detail: "使用快照中已有的指数报价；每项单独显示来源新鲜度")
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: StockMonitorTokens.Space.medium),
                               count: max(1, columns)),
                alignment: .leading,
                spacing: StockMonitorTokens.Space.medium
            ) {
                ForEach(MarketIndex.core) { index in
                    indexCard(index)
                }
            }
        }
    }

    @ViewBuilder
    private func indexCard(_ index: MarketIndex) -> some View {
        if let quote = snapshot?.indexQuotes.first(where: { $0.code == index.code }) {
            quoteCard(title: index.name, subtitle: index.code, quote: quote, prominent: true)
        } else {
            StockMonitorSurface {
                VStack(alignment: .leading, spacing: StockMonitorTokens.Space.small) {
                    Text(index.name)
                        .font(.system(size: StockMonitorTokens.TypeScale.subhead, weight: .semibold))
                        .foregroundStyle(palette.inkPrimary)
                    Text(index.code)
                        .font(.system(size: StockMonitorTokens.TypeScale.caption, design: .monospaced))
                        .foregroundStyle(palette.inkMuted)
                    Text(snapshot == nil ? "暂无快照 · 指数报价未知" : "本次快照没有该指数报价")
                        .font(.system(size: StockMonitorTokens.TypeScale.caption))
                        .foregroundStyle(palette.accent2)
                }
                .frame(maxWidth: .infinity, minHeight: 116, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var breadthSection: some View {
        VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
            sectionHeading("市场宽度 · 扫描样本", detail: "仅统计已返回样本，不代表全市场总数")
            if let coverage = snapshot?.marketCoverage {
                let summary = coverage.summary
                let breadthCount = summary.up + summary.flat + summary.down

                StockMonitorSurface {
                    VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
                        if breadthCount > 0 {
                            HStack(alignment: .firstTextBaseline, spacing: StockMonitorTokens.Space.small) {
                                breadthValue(label: "上涨", count: summary.up, color: palette.dataUp)
                                breadthValue(label: "平盘", count: summary.flat, color: palette.dataFlat)
                                breadthValue(label: "下跌", count: summary.down, color: palette.dataDown)
                            }
                        } else {
                            Label("涨跌分布未知", systemImage: "questionmark.circle")
                                .font(.system(size: StockMonitorTokens.TypeScale.subhead, weight: .semibold))
                                .foregroundStyle(palette.accent2)
                        }

                        let reportedTotal = summary.reportedTotalCount.map(String.init) ?? "未知"
                        Text("返回样本 \(coverage.status.returnedCount) 行 · 服务端自报总数 \(reportedTotal)")
                            .font(.system(size: StockMonitorTokens.TypeScale.caption))
                            .foregroundStyle(palette.inkSecondary)
                        Text(summary.coverageComplete
                             ? "唯一返回数与服务端自报 total 对齐；非交易所独立核验全集。"
                             : "覆盖不完整或未知；不得将样本计数解释为全市场总数。")
                            .font(.system(size: StockMonitorTokens.TypeScale.caption))
                            .foregroundStyle(summary.coverageComplete ? palette.inkMuted : palette.accent2)
                            .fixedSize(horizontal: false, vertical: true)

                        sourceFreshnessLine(for: coverage.status)
                        if let error = coverage.status.error, !error.isEmpty {
                            Text("扫描来源异常：\(error)")
                                .font(.system(size: StockMonitorTokens.TypeScale.caption))
                                .foregroundStyle(palette.dataDown)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                StockMonitorDataStatePanel(
                    state: snapshot == nil ? .empty : .partial,
                    detail: snapshot == nil
                        ? "尚无行情快照；扫描样本与市场宽度未知。"
                        : "当前快照没有扫描覆盖数据；涨跌家数和覆盖率未知。"
                )
            }
        }
    }

    private var watchlistSection: some View {
        VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
            sectionHeading("自选快览", detail: "只展示当前本机快照已匹配的报价")
            StockMonitorSurface {
                VStack(alignment: .leading, spacing: StockMonitorTokens.Space.small) {
                    if model.state.watchCodes.isEmpty {
                        Text("自选列表为空。")
                            .font(.system(size: StockMonitorTokens.TypeScale.body))
                            .foregroundStyle(palette.inkMuted)
                            .frame(maxWidth: .infinity, minHeight: StockMonitorTokens.Size.minimumHitTarget,
                                   alignment: .leading)
                    } else {
                        let visibleCodes = Array(model.state.watchCodes.prefix(8))
                        ForEach(visibleCodes, id: \.self) { code in
                            if let quote = quotesByCode[code] {
                                quoteCard(title: quote.name.isEmpty ? code : quote.name,
                                          subtitle: "\(code) · \(quote.sourceID)",
                                          quote: quote, prominent: false)
                            } else {
                                missingWatchQuote(code)
                            }
                        }
                        if model.state.watchCodes.count > visibleCodes.count {
                            Text("另有 \(model.state.watchCodes.count - visibleCodes.count) 只未展开")
                                .font(.system(size: StockMonitorTokens.TypeScale.caption))
                                .foregroundStyle(palette.inkMuted)
                                .padding(.top, StockMonitorTokens.Space.xsmall)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func quoteCard(title: String, subtitle: String, quote: Quote, prominent: Bool) -> some View {
        let change = QuotePresentation.changeFraction(for: quote)
        let changeColor = change.map { $0 > 0 ? palette.dataUp : $0 < 0 ? palette.dataDown : palette.dataFlat }
            ?? palette.accent2
        let freshness = quoteFreshness(for: quote)

        return StockMonitorSurface(padding: prominent
            ? StockMonitorTokens.Space.medium : StockMonitorTokens.Space.small) {
            VStack(alignment: .leading, spacing: StockMonitorTokens.Space.small) {
                HStack(alignment: .firstTextBaseline, spacing: StockMonitorTokens.Space.small) {
                    VStack(alignment: .leading, spacing: StockMonitorTokens.Space.xsmall) {
                        Text(title)
                            .font(.system(size: prominent ? StockMonitorTokens.TypeScale.body : StockMonitorTokens.TypeScale.footnote,
                                          weight: .semibold))
                            .foregroundStyle(palette.inkPrimary)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.system(size: StockMonitorTokens.TypeScale.caption, design: .monospaced))
                            .foregroundStyle(palette.inkMuted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: StockMonitorTokens.Space.xsmall)
                    VStack(alignment: .trailing, spacing: StockMonitorTokens.Space.xsmall) {
                        Text(ChartFormatters.price(quote.price))
                            .font(.system(size: prominent ? StockMonitorTokens.TypeScale.titleLarge : StockMonitorTokens.TypeScale.title,
                                          weight: .semibold, design: .rounded))
                            .foregroundStyle(palette.inkPrimary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(StockMonitorTokens.Scale.metricMinimum)
                        Text(QuotePresentation.signedPercentagePoints(change.map { $0 * 100 }))
                            .font(.system(size: StockMonitorTokens.TypeScale.caption, weight: .semibold))
                            .foregroundStyle(changeColor)
                            .monospacedDigit()
                    }
                }
                Label(freshness.text, systemImage: freshness.symbol)
                    .font(.system(size: StockMonitorTokens.TypeScale.caption))
                    .foregroundStyle(freshness.color)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: prominent ? 100 : 72, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private func missingWatchQuote(_ code: String) -> some View {
        HStack(spacing: StockMonitorTokens.Space.medium) {
            Image(systemName: snapshot == nil ? "clock" : "questionmark.circle")
                .foregroundStyle(palette.accent2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: StockMonitorTokens.Space.xsmall) {
                Text(code)
                    .font(.system(size: StockMonitorTokens.TypeScale.body, weight: .semibold,
                                  design: .monospaced))
                    .foregroundStyle(palette.inkPrimary)
                Text(snapshot == nil ? "尚无行情快照" : "本次快照没有该证券报价")
                    .font(.system(size: StockMonitorTokens.TypeScale.caption))
                    .foregroundStyle(palette.inkMuted)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: StockMonitorTokens.Size.minimumHitTarget,
               alignment: .leading)
        .padding(.vertical, StockMonitorTokens.Space.xsmall)
        .accessibilityElement(children: .combine)
    }

    private var dataScopeNote: some View {
        Label("公开来源轮询快照 · 不含逐笔、Level-2 或完整离线回放", systemImage: "info.circle")
            .font(.system(size: StockMonitorTokens.TypeScale.caption))
            .foregroundStyle(palette.inkMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, StockMonitorTokens.Space.small)
            .accessibilityElement(children: .combine)
    }

    private func sectionHeading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: StockMonitorTokens.Space.xsmall) {
            Text(title)
                .font(.system(size: StockMonitorTokens.TypeScale.subhead, weight: .semibold))
                .foregroundStyle(palette.inkPrimary)
            Text(detail)
                .font(.system(size: StockMonitorTokens.TypeScale.caption))
                .foregroundStyle(palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func breadthValue(label: String, count: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: StockMonitorTokens.Space.xsmall) {
            Text(label)
                .font(.system(size: StockMonitorTokens.TypeScale.caption))
                .foregroundStyle(palette.inkMuted)
            Text(String(count))
                .font(.system(size: StockMonitorTokens.TypeScale.titleLarge, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
                .monospacedDigit()
                .minimumScaleFactor(StockMonitorTokens.Scale.metricMinimum)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func sourceFreshnessLine(for status: SourceStatus) -> some View {
        let freshness = status.freshness()
        let text: String
        let color: Color
        switch freshness {
        case .fresh:
            text = status.providerTimestamp.map { "来源时间 \(ChartFormatters.time($0))" } ?? "来源时间未知"
            color = palette.inkMuted
        case .stale:
            text = status.providerTimestamp.map { "来源快照已超过 120 秒 · \(ChartFormatters.time($0))" }
                ?? "来源快照可能已过期"
            color = palette.dataDown
        case .unknown:
            text = "来源时间未知"
            color = palette.accent2
        case .failed:
            text = "扫描来源失败；已有样本可能不完整"
            color = palette.dataDown
        }
        return Label(text, systemImage: freshness == .stale ? "clock.badge.exclamationmark" : "clock")
            .font(.system(size: StockMonitorTokens.TypeScale.caption))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
    }

    private func quoteFreshness(for quote: Quote) -> (text: String, symbol: String, color: Color) {
        guard quote.timestampIsProvider else {
            return ("来源时间未知", "questionmark.circle", palette.accent2)
        }
        if QuotePresentation.freshnessState(for: quote) == .stale {
            return ("来源报价已过 120 秒窗口 · \(ChartFormatters.time(quote.timestamp))",
                    "clock.badge.exclamationmark", palette.dataDown)
        }
        return ("来源时间 \(ChartFormatters.time(quote.timestamp))", "clock", palette.inkMuted)
    }

    private var phaseTitle: String {
        switch model.state.phase {
        case .closed: "监测已停止"
        case .coldStart: "本机监测正在启动"
        case .reconciling: "正在补齐本地分钟历史"
        case .live: model.state.isMarketSession ? "前台监测中 · 交易时段" : "前台会话运行中"
        case .paused: "本机监测已暂停"
        case .failed: "本机会话异常"
        }
    }

    private var phaseColor: Color {
        switch model.state.phase {
        case .live: palette.dataUp
        case .failed: palette.dataDown
        default: palette.accent2
        }
    }
}
