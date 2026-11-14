import SwiftUI
import StockMonitorCore

@MainActor
struct WorkbenchView: View {
    @ObservedObject var model: MonitorViewModel
    let openTab: (StockMonitorTab) -> Void

    @Environment(\.stockMonitorPalette) private var palette
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var layout: WorkbenchLayout = .board

    private var quotesByCode: [String: Quote] {
        Dictionary((model.state.latestSnapshot?.quotes ?? []).map { ($0.code, $0) },
                   uniquingKeysWith: { _, newest in newest })
    }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: StockMonitorTokens.Space.medium),
              count: horizontalSizeClass == .regular ? 2 : 1)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: StockMonitorTokens.Space.large) {
                    introPanel
                    Picker("工作台布局", selection: $layout) {
                        Text("看板").tag(WorkbenchLayout.board)
                        Text("列表").tag(WorkbenchLayout.list)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("工作台布局")

                    dashboardContent
                    quickActions
                }
                .padding(StockMonitorTokens.Space.large)
            }
            .background(palette.paper0)
            .navigationTitle("工作台")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await model.refreshNow() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .frame(minWidth: StockMonitorTokens.Size.minimumHitTarget,
                                   minHeight: StockMonitorTokens.Size.minimumHitTarget)
                    }
                    .accessibilityLabel("刷新现有行情快照")
                    .accessibilityHint("仅按当前前台会话规则请求行情；不会扩展扫描或获取 Level-2")
                }
            }
        }
        .tint(palette.accent)
        .task { await model.loadHealthDashboard() }
    }

    @ViewBuilder
    private var dashboardContent: some View {
        if layout == .board {
            LazyVGrid(columns: gridColumns, alignment: .leading,
                      spacing: StockMonitorTokens.Space.medium) {
                sessionPanel
                sourceHealthPanel
                marketPanel
                watchlistPanel(compact: true)
                holdingsPanel(compact: true)
                signalsPanel(compact: true)
            }
        } else {
            VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
                sessionPanel
                sourceHealthPanel
                marketPanel
                watchlistPanel(compact: false)
                holdingsPanel(compact: false)
                signalsPanel(compact: false)
            }
        }
    }

    private var introPanel: some View {
        StockMonitorSurface(padding: StockMonitorTokens.Space.medium) {
            VStack(alignment: .leading, spacing: StockMonitorTokens.Space.small) {
                Label("本机行情工作台", systemImage: "square.grid.2x2")
                    .font(.system(size: StockMonitorTokens.TypeScale.subhead, weight: .semibold))
                    .foregroundStyle(palette.inkPrimary)
                Text("汇总当前已加载的会话、自选、持仓和未读信号。页面切换仅读取本机状态；刷新仍受前台会话与来源限制。")
                    .font(.system(size: StockMonitorTokens.TypeScale.footnote))
                    .foregroundStyle(palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("公开轮询快照 · 不含逐笔、Level-2 或完整离线回放")
                    .font(.system(size: StockMonitorTokens.TypeScale.caption))
                    .foregroundStyle(palette.inkMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sessionPanel: some View {
        StockMonitorSurface {
            VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
                panelHeading("会话", symbol: "iphone.gen3")
                HStack(spacing: StockMonitorTokens.Space.small) {
                    Circle()
                        .fill(phaseColor)
                        .frame(width: 9, height: 9)
                        .accessibilityHidden(true)
                    Text(phaseTitle)
                        .font(.system(size: StockMonitorTokens.TypeScale.subhead, weight: .semibold))
                        .foregroundStyle(palette.inkPrimary)
                }
                Text(tradingDayDescription)
                    .font(.system(size: StockMonitorTokens.TypeScale.caption))
                    .foregroundStyle(palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let capturedAt = model.state.latestSnapshot?.capturedAt {
                    Text("本机快照采集于 \(ChartFormatters.dateTime(capturedAt))")
                        .font(.system(size: StockMonitorTokens.TypeScale.caption))
                        .foregroundStyle(palette.inkMuted)
                } else {
                    Text("尚无行情快照")
                        .font(.system(size: StockMonitorTokens.TypeScale.caption))
                        .foregroundStyle(palette.inkMuted)
                }
                if let error = model.state.lastError, !error.isEmpty {
                    Text(error)
                        .font(.system(size: StockMonitorTokens.TypeScale.caption))
                        .foregroundStyle(palette.dataDown)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }

    private var sourceHealthPanel: some View {
        StockMonitorSurface {
            VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
                HStack(alignment: .center) {
                    Label("来源与会话健康", systemImage: "heart.text.square")
                        .font(.system(size: StockMonitorTokens.TypeScale.subhead, weight: .semibold))
                        .foregroundStyle(palette.inkPrimary)
                    Spacer(minLength: StockMonitorTokens.Space.small)
                    Button {
                        Task { await model.loadHealthDashboard() }
                    } label: {
                        if model.isLoadingHealthDashboard {
                            ProgressView()
                                .frame(width: StockMonitorTokens.Size.minimumHitTarget,
                                       height: StockMonitorTokens.Size.minimumHitTarget)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .frame(width: StockMonitorTokens.Size.minimumHitTarget,
                                       height: StockMonitorTokens.Size.minimumHitTarget)
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.isLoadingHealthDashboard)
                    .accessibilityLabel("刷新本机健康统计")
                    .accessibilityHint("只读取本机 SQLite，不请求网络")
                }

                if let updatedAt = model.healthDashboardUpdatedAt {
                    Text("本地读取于 \(ChartFormatters.dateTime(updatedAt))")
                        .font(.system(size: StockMonitorTokens.TypeScale.caption))
                        .foregroundStyle(palette.inkMuted)
                }
                if let error = model.healthDashboardError {
                    StockMonitorDataStatePanel(state: .error, detail: error)
                }

                Text("最近行情 / 分钟补齐来源状态")
                    .font(.system(size: StockMonitorTokens.TypeScale.footnote, weight: .semibold))
                    .foregroundStyle(palette.inkSecondary)
                if model.state.sourceStatuses.isEmpty {
                    Text("尚无来源状态记录；此处不会把未观测到的来源推断为成功或失败。")
                        .font(.system(size: StockMonitorTokens.TypeScale.caption))
                        .foregroundStyle(palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(model.state.sourceStatuses.sorted { $0.sourceID < $1.sourceID }) { status in
                        sourceStatusRow(status)
                    }
                }

                Divider().overlay(palette.hair)
                Text("近 7 日本机采集健康")
                    .font(.system(size: StockMonitorTokens.TypeScale.footnote, weight: .semibold))
                    .foregroundStyle(palette.inkSecondary)
                if let health = model.sourceHealthSnapshot {
                    let decisionCount = health.llmEnrichedDecisions + health.ruleOrSkippedDecisions
                    sourceHealthMetricRow("P1 官方来源请求成功率", numerator: health.p1Successes,
                                          denominator: health.p1Attempts, rate: health.p1SuccessRate,
                                          target: "目标 ≥99%", passed: health.p1ThresholdPassed)
                    sourceHealthMetricRow("解析记录有效率", numerator: health.filterKept,
                                          denominator: health.filterTotal, rate: health.eventValidityRate,
                                          target: "目标 ≥80%", passed: health.eventValidityThresholdPassed)
                    sourceHealthMetricRow("LLM enrichment 占比", numerator: health.llmEnrichedDecisions,
                                          denominator: decisionCount, rate: health.llmCallShare,
                                          target: "目标 ≤50%", passed: health.llmCallShareThresholdPassed)
                    Text("仅统计本机已记录样本；P1 为 gov/CNINFO，请求、解析与 Analyst 分母按设置页口径。")
                        .font(.system(size: StockMonitorTokens.TypeScale.caption))
                        .foregroundStyle(palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                } else if model.isLoadingHealthDashboard {
                    ProgressView("读取本机统计……")
                        .font(.system(size: StockMonitorTokens.TypeScale.caption))
                } else {
                    Text("暂无健康统计；没有样本时不显示通过率。")
                        .font(.system(size: StockMonitorTokens.TypeScale.caption))
                        .foregroundStyle(palette.inkMuted)
                }

                Divider().overlay(palette.hair)
                Text("最近前台会话累计")
                    .font(.system(size: StockMonitorTokens.TypeScale.footnote, weight: .semibold))
                    .foregroundStyle(palette.inkSecondary)
                if let usage = model.latestSessionUsage {
                    sourceHealthValueRow("行情 tick", value: String(usage.tickCount))
                    sourceHealthValueRow("已记账请求", value: String(usage.requestCount))
                    let prompt = usage.promptTokenCount.map { String($0) } ?? "未知"
                    let completion = usage.completionTokenCount.map { String($0) } ?? "未知"
                    let total = usage.totalTokenCount.map { String($0) } ?? "未知"
                    sourceHealthValueRow("Provider tokens", value: "P \(prompt) · C \(completion) · 总计 \(total)")
                    Text("Token 仅在 Provider 返回 usage 时累计；请求计数只覆盖接入本机 session ledger 的操作。")
                        .font(.system(size: StockMonitorTokens.TypeScale.caption))
                        .foregroundStyle(palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                } else if model.isLoadingHealthDashboard {
                    ProgressView("读取会话计数……")
                        .font(.system(size: StockMonitorTokens.TypeScale.caption))
                } else {
                    Text("暂无已记录会话计数。")
                        .font(.system(size: StockMonitorTokens.TypeScale.caption))
                        .foregroundStyle(palette.inkMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }

    private func sourceStatusRow(_ status: SourceStatus) -> some View {
        VStack(alignment: .leading, spacing: StockMonitorTokens.Space.xsmall) {
            HStack(alignment: .firstTextBaseline) {
                Text(status.sourceID)
                    .font(.system(size: StockMonitorTokens.TypeScale.caption, weight: .semibold,
                                  design: .monospaced))
                    .foregroundStyle(palette.inkPrimary)
                    .lineLimit(1)
                Spacer(minLength: StockMonitorTokens.Space.small)
                sourceFreshnessLabel(for: status)
            }
            let returnState = status.returnedCount < status.requestedCount ? "部分返回" : "已返回"
            Text("\(returnState) \(status.returnedCount)/\(status.requestedCount) · 请求 \(status.requestCount) 次")
                .font(.system(size: StockMonitorTokens.TypeScale.caption))
                .foregroundStyle(palette.inkSecondary)
            if let timestamp = status.providerTimestamp {
                Text("来源时间 \(ChartFormatters.dateTime(timestamp))")
                    .font(.system(size: StockMonitorTokens.TypeScale.caption))
                    .foregroundStyle(palette.inkMuted)
            } else {
                Text("来源时间未知 · 本机抓取 \(ChartFormatters.dateTime(status.fetchedAt))")
                    .font(.system(size: StockMonitorTokens.TypeScale.caption))
                    .foregroundStyle(palette.accent2)
            }
            if let note = status.note, !note.isEmpty {
                Text(note)
                    .font(.system(size: StockMonitorTokens.TypeScale.caption))
                    .foregroundStyle(palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = status.error, !error.isEmpty {
                Text(error)
                    .font(.system(size: StockMonitorTokens.TypeScale.caption))
                    .foregroundStyle(palette.dataDown)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, StockMonitorTokens.Space.xsmall)
        .accessibilityElement(children: .combine)
    }

    private func sourceFreshnessLabel(for status: SourceStatus) -> some View {
        let title: String
        let color: Color
        switch status.freshness() {
        case .fresh:
            title = "新鲜"
            color = palette.dataUp
        case .stale:
            title = "已过期"
            color = palette.dataDown
        case .unknown:
            title = "时间未知"
            color = palette.accent2
        case .failed:
            title = "请求失败"
            color = palette.dataDown
        }
        return Text(title)
            .font(.system(size: StockMonitorTokens.TypeScale.caption, weight: .semibold))
            .foregroundStyle(color)
    }

    private func sourceHealthMetricRow(_ title: String, numerator: Int, denominator: Int,
                                       rate: Double, target: String, passed: Bool) -> some View {
        let metricValue = denominator == 0 ? "暂无数据" :
            "\(numerator)/\(denominator) · \(rate.formatted(.percent.precision(.fractionLength(1))))"
        return HStack(alignment: .top, spacing: StockMonitorTokens.Space.small) {
            VStack(alignment: .leading, spacing: StockMonitorTokens.Space.xsmall) {
                Text(title)
                    .font(.system(size: StockMonitorTokens.TypeScale.caption, weight: .medium))
                    .foregroundStyle(palette.inkPrimary)
                Text(target)
                    .font(.system(size: StockMonitorTokens.TypeScale.caption))
                    .foregroundStyle(palette.inkMuted)
            }
            Spacer(minLength: StockMonitorTokens.Space.small)
            Text(metricValue)
                .font(.system(size: StockMonitorTokens.TypeScale.caption, weight: .semibold))
                .foregroundStyle(denominator == 0 ? palette.inkMuted : passed ? palette.dataUp : palette.accent2)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private func sourceHealthValueRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: StockMonitorTokens.Space.small) {
            Text(title)
                .font(.system(size: StockMonitorTokens.TypeScale.caption))
                .foregroundStyle(palette.inkSecondary)
            Spacer(minLength: StockMonitorTokens.Space.small)
            Text(value)
                .font(.system(size: StockMonitorTokens.TypeScale.caption, weight: .medium,
                              design: .monospaced))
                .foregroundStyle(palette.inkPrimary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }

    private var marketPanel: some View {
        StockMonitorSurface {
            VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
                panelHeading("核心指数", symbol: "chart.xyaxis.line")
                ForEach(MarketIndex.core) { index in
                    if let quote = model.state.latestSnapshot?.indexQuotes.first(where: { $0.code == index.code }) {
                        HStack(spacing: StockMonitorTokens.Space.small) {
                            VStack(alignment: .leading, spacing: StockMonitorTokens.Space.xsmall) {
                                Text(index.name)
                                    .font(.system(size: StockMonitorTokens.TypeScale.body, weight: .medium))
                                    .foregroundStyle(palette.inkPrimary)
                                Text(index.code)
                                    .font(.system(size: StockMonitorTokens.TypeScale.caption, design: .monospaced))
                                    .foregroundStyle(palette.inkMuted)
                                freshnessLabel(for: quote)
                            }
                            Spacer(minLength: StockMonitorTokens.Space.small)
                            VStack(alignment: .trailing, spacing: StockMonitorTokens.Space.xsmall) {
                                Text(ChartFormatters.price(quote.price))
                                    .font(.system(size: StockMonitorTokens.TypeScale.body, weight: .semibold))
                                    .foregroundStyle(palette.inkPrimary)
                                    .monospacedDigit()
                                changeText(for: quote)
                            }
                        }
                        .frame(minHeight: StockMonitorTokens.Size.minimumHitTarget)
                    } else {
                        Text("\(index.name)（\(index.code)）：暂无可用报价")
                            .font(.system(size: StockMonitorTokens.TypeScale.caption))
                            .foregroundStyle(palette.inkMuted)
                            .frame(minHeight: StockMonitorTokens.Size.minimumHitTarget, alignment: .leading)
                    }
                }
                if let coverage = model.state.latestSnapshot?.marketCoverage {
                    let reportedTotal = coverage.summary.reportedTotalCount.map(String.init) ?? "未知"
                    let coverageState = coverage.summary.coverageComplete
                        ? "唯一返回数与服务端自报 total 对齐"
                        : "覆盖不完整或未知"
                    Text("扫描样本：\(coverage.status.returnedCount) 行 · 接口报告总数 \(reportedTotal) · \(coverageState)；不是交易所独立核验全集。")
                        .font(.system(size: StockMonitorTokens.TypeScale.caption))
                        .foregroundStyle(palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("扫描样本覆盖度未知；涨停、跌停及炸板统计未纳入。")
                        .font(.system(size: StockMonitorTokens.TypeScale.caption))
                        .foregroundStyle(palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func watchlistPanel(compact: Bool) -> some View {
        StockMonitorSurface {
            VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
                panelHeading("自选快览", symbol: "star")
                if model.state.watchCodes.isEmpty {
                    StockMonitorDataStatePanel(state: .empty,
                        detail: "自选为空；可从快捷入口添加沪深证券。")
                } else {
                    let visibleCodes = Array(model.state.watchCodes.prefix(compact ? 4 : 12))
                    ForEach(visibleCodes, id: \.self) { code in
                        if let quote = quotesByCode[code] {
                            watchQuoteRow(quote)
                        } else {
                            missingQuoteRow(code)
                        }
                    }
                    if model.state.watchCodes.count > visibleCodes.count {
                        Text("另有 \(model.state.watchCodes.count - visibleCodes.count) 只未在此处展开")
                            .font(.system(size: StockMonitorTokens.TypeScale.caption))
                            .foregroundStyle(palette.inkMuted)
                    }
                }
                Button {
                    openTab(.watchlist)
                } label: {
                    Label("打开自选", systemImage: "arrow.right")
                        .frame(maxWidth: .infinity, minHeight: StockMonitorTokens.Size.minimumHitTarget)
                }
                .buttonStyle(.bordered)
                .accessibilityHint("进入自选页管理代码并查看报价来源与其他字段")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func holdingsPanel(compact: Bool) -> some View {
        StockMonitorSurface {
            VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
                panelHeading("持仓", symbol: "briefcase")
                if model.state.holdings.isEmpty {
                    StockMonitorDataStatePanel(state: .empty,
                        detail: "尚未录入持仓；这里不会推测账户余额或仓位。")
                } else {
                    let visibleHoldings = Array(model.state.holdings.prefix(compact ? 4 : 12))
                    let matchedCount = model.state.holdings.filter { quotesByCode[$0.code] != nil }.count
                    Text("当前快照可匹配报价 \(matchedCount)/\(model.state.holdings.count) 只；未匹配项的收益未知。")
                        .font(.system(size: StockMonitorTokens.TypeScale.caption))
                        .foregroundStyle(matchedCount == model.state.holdings.count ? palette.inkSecondary : palette.accent2)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(visibleHoldings) { holding in
                        holdingRow(holding)
                    }
                    if model.state.holdings.count > visibleHoldings.count {
                        Text("另有 \(model.state.holdings.count - visibleHoldings.count) 只未在此处展开")
                            .font(.system(size: StockMonitorTokens.TypeScale.caption))
                            .foregroundStyle(palette.inkMuted)
                    }
                }
                Button {
                    openTab(.monitor)
                } label: {
                    Label("管理持仓与规则", systemImage: "arrow.right")
                        .frame(maxWidth: .infinity, minHeight: StockMonitorTokens.Size.minimumHitTarget)
                }
                .buttonStyle(.bordered)
                .accessibilityHint("进入监测页编辑持仓股数、成本价和规则")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func signalsPanel(compact: Bool) -> some View {
        StockMonitorSurface {
            VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
                panelHeading("未读信号", symbol: "bell.badge")
                if model.state.unreadSignals.isEmpty {
                    StockMonitorDataStatePanel(state: .empty,
                        detail: "当前没有本机未读信号；这不代表来源行情或规则覆盖完整。")
                } else {
                    let visibleSignals = Array(model.state.unreadSignals.prefix(compact ? 3 : 20))
                    ForEach(visibleSignals) { signal in
                        Button {
                            model.markSignalRead(signal.id)
                        } label: {
                            HStack(alignment: .top, spacing: StockMonitorTokens.Space.small) {
                                VStack(alignment: .leading, spacing: StockMonitorTokens.Space.xsmall) {
                                    Text(signal.title)
                                        .font(.system(size: StockMonitorTokens.TypeScale.body, weight: .semibold))
                                        .foregroundStyle(palette.inkPrimary)
                                        .multilineTextAlignment(.leading)
                                    Text("\(signal.code) · \(signal.detail)")
                                        .font(.system(size: StockMonitorTokens.TypeScale.caption))
                                        .foregroundStyle(palette.inkSecondary)
                                        .multilineTextAlignment(.leading)
                                    Text(ChartFormatters.dateTime(signal.createdAt))
                                        .font(.system(size: StockMonitorTokens.TypeScale.caption))
                                        .foregroundStyle(palette.inkMuted)
                                }
                                Spacer(minLength: StockMonitorTokens.Space.xsmall)
                                Image(systemName: "checkmark.circle")
                                    .foregroundStyle(palette.accent)
                                    .accessibilityHidden(true)
                            }
                            .frame(maxWidth: .infinity, minHeight: StockMonitorTokens.Size.minimumHitTarget,
                                   alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(signal.code)，\(signal.title)。标记为已读")
                    }
                    if model.state.unreadSignals.count > visibleSignals.count {
                        Text("另有 \(model.state.unreadSignals.count - visibleSignals.count) 条未展开")
                            .font(.system(size: StockMonitorTokens.TypeScale.caption))
                            .foregroundStyle(palette.inkMuted)
                    }
                }
                Button {
                    openTab(.monitor)
                } label: {
                    Label("查看全部监测信号", systemImage: "arrow.right")
                        .frame(maxWidth: .infinity, minHeight: StockMonitorTokens.Size.minimumHitTarget)
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var quickActions: some View {
        StockMonitorSurface(padding: StockMonitorTokens.Space.medium) {
            VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
                panelHeading("快捷入口", symbol: "arrowshape.turn.up.right")
                LazyVGrid(columns: gridColumns, spacing: StockMonitorTokens.Space.small) {
                    shortcutButton("自选管理", symbol: "star", tab: .watchlist)
                    shortcutButton("监测与持仓", symbol: "waveform.path.ecg", tab: .monitor)
                    shortcutButton("本地资讯", symbol: "text.bubble", tab: .feed)
                    shortcutButton("研究实验室", symbol: "chart.bar.xaxis", tab: .lab)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func shortcutButton(_ title: String, symbol: String, tab: StockMonitorTab) -> some View {
        Button {
            openTab(tab)
        } label: {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, minHeight: StockMonitorTokens.Size.minimumHitTarget)
        }
        .buttonStyle(.bordered)
        .accessibilityHint("关闭工作台并打开\(title)")
    }

    private func panelHeading(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: StockMonitorTokens.TypeScale.subhead, weight: .semibold))
            .foregroundStyle(palette.inkPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func watchQuoteRow(_ quote: Quote) -> some View {
        HStack(alignment: .top, spacing: StockMonitorTokens.Space.small) {
            VStack(alignment: .leading, spacing: StockMonitorTokens.Space.xsmall) {
                Text(quote.name.isEmpty ? quote.code : quote.name)
                    .font(.system(size: StockMonitorTokens.TypeScale.body, weight: .medium))
                    .foregroundStyle(palette.inkPrimary)
                    .lineLimit(1)
                Text("\(quote.code) · \(quote.sourceID)")
                    .font(.system(size: StockMonitorTokens.TypeScale.caption, design: .monospaced))
                    .foregroundStyle(palette.inkMuted)
                freshnessLabel(for: quote)
            }
            Spacer(minLength: StockMonitorTokens.Space.small)
            VStack(alignment: .trailing, spacing: StockMonitorTokens.Space.xsmall) {
                Text(ChartFormatters.price(quote.price))
                    .font(.system(size: StockMonitorTokens.TypeScale.body, weight: .semibold))
                    .foregroundStyle(palette.inkPrimary)
                    .monospacedDigit()
                changeText(for: quote)
            }
        }
        .padding(.vertical, StockMonitorTokens.Space.xsmall)
        .accessibilityElement(children: .combine)
    }

    private func missingQuoteRow(_ code: String) -> some View {
        HStack(spacing: StockMonitorTokens.Space.small) {
            Image(systemName: model.state.latestSnapshot == nil ? "clock" : "exclamationmark.circle")
                .foregroundStyle(palette.accent2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: StockMonitorTokens.Space.xsmall) {
                Text(code)
                    .font(.system(size: StockMonitorTokens.TypeScale.body, weight: .medium, design: .monospaced))
                    .foregroundStyle(palette.inkPrimary)
                Text(model.state.latestSnapshot == nil ? "尚无行情快照" : "当前快照没有该证券报价")
                    .font(.system(size: StockMonitorTokens.TypeScale.caption))
                    .foregroundStyle(palette.inkMuted)
            }
            Spacer()
        }
        .frame(minHeight: StockMonitorTokens.Size.minimumHitTarget)
        .accessibilityElement(children: .combine)
    }

    private func holdingRow(_ holding: Holding) -> some View {
        VStack(alignment: .leading, spacing: StockMonitorTokens.Space.xsmall) {
            HStack {
                Text(holding.code)
                    .font(.system(size: StockMonitorTokens.TypeScale.body, weight: .semibold, design: .monospaced))
                    .foregroundStyle(palette.inkPrimary)
                Spacer()
                if let quote = quotesByCode[holding.code] {
                    let change = holding.averageCost > 0 && quote.price.isFinite
                        ? (quote.price - holding.averageCost) / holding.averageCost * 100
                        : nil
                    Text(change.map { QuotePresentation.signedPercentagePoints($0) } ?? "收益未知")
                        .font(.system(size: StockMonitorTokens.TypeScale.body, weight: .semibold))
                        .foregroundStyle(change.map { $0 > 0 ? palette.dataUp : $0 < 0 ? palette.dataDown : palette.dataFlat } ?? palette.accent2)
                        .monospacedDigit()
                } else {
                    Text("收益未知")
                        .font(.system(size: StockMonitorTokens.TypeScale.caption, weight: .medium))
                        .foregroundStyle(palette.accent2)
                }
            }
            Text("\(holding.shares) 股 · 成本 \(ChartFormatters.price(holding.averageCost)) · 按当前报价估算，不含费用")
                .font(.system(size: StockMonitorTokens.TypeScale.caption))
                .foregroundStyle(palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let quote = quotesByCode[holding.code] {
                Text("当前快照 \(ChartFormatters.price(quote.price)) · \(quote.sourceID)")
                    .font(.system(size: StockMonitorTokens.TypeScale.caption))
                    .foregroundStyle(palette.inkMuted)
                freshnessLabel(for: quote)
            } else {
                Text("没有匹配报价；该持仓收益未计算。")
                    .font(.system(size: StockMonitorTokens.TypeScale.caption))
                    .foregroundStyle(palette.inkMuted)
            }
        }
        .padding(.vertical, StockMonitorTokens.Space.xsmall)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func changeText(for quote: Quote) -> some View {
        if let change = QuotePresentation.changeFraction(for: quote) {
            Text(QuotePresentation.signedPercentagePoints(change * 100))
                .font(.system(size: StockMonitorTokens.TypeScale.caption, weight: .semibold))
                .foregroundStyle(change > 0 ? palette.dataUp : change < 0 ? palette.dataDown : palette.dataFlat)
                .monospacedDigit()
        } else {
            Text("涨跌未知")
                .font(.system(size: StockMonitorTokens.TypeScale.caption))
                .foregroundStyle(palette.inkMuted)
        }
    }

    private func freshnessLabel(for quote: Quote) -> some View {
        let text: String
        let color: Color
        if !quote.timestampIsProvider {
            text = "来源时间未知"
            color = palette.accent2
        } else if QuotePresentation.freshnessState(for: quote) == .stale {
            text = "来源报价已过 120 秒窗口 · \(ChartFormatters.time(quote.timestamp))"
            color = palette.dataDown
        } else {
            text = "来源时间 \(ChartFormatters.time(quote.timestamp))"
            color = palette.inkMuted
        }
        return Label(text, systemImage: quote.timestampIsProvider ? "clock" : "questionmark.circle")
            .font(.system(size: StockMonitorTokens.TypeScale.caption))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
    }

    private var phaseTitle: String {
        switch model.state.phase {
        case .closed: "已停止"
        case .coldStart: "正在启动"
        case .reconciling: "正在补齐本地分钟历史"
        case .live: model.state.isMarketSession ? "前台监测中 · 交易时段" : "前台会话运行中"
        case .paused: "已暂停"
        case .failed: "会话异常"
        }
    }

    private var phaseColor: Color {
        switch model.state.phase {
        case .live: palette.dataUp
        case .failed: palette.dataDown
        default: palette.accent2
        }
    }

    private var tradingDayDescription: String {
        switch MarketClock.tradingDayStatus() {
        case .open:
            model.state.isMarketSession
                ? "交易日历已判定为开市日；当前处于市场会话。"
                : "交易日历已判定为开市日；当前不在采集时段或会话尚未开始。"
        case .closed(let reason): "交易日历：休市（\(reason)）。"
        case .unknown: "交易日状态未知；系统不会据此假定开市。"
        }
    }
}

private enum WorkbenchLayout: String, CaseIterable, Hashable, Identifiable {
    case board
    case list

    var id: String { rawValue }
}
