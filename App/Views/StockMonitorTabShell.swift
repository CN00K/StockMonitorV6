import SwiftUI
import StockMonitorCore
import UniformTypeIdentifiers

@MainActor
struct StockMonitorTabShell: View {
    @ObservedObject var model: MonitorViewModel
    @AppStorage("stockmonitor.ui.appearance") private var appearanceRawValue = StockMonitorAppearance.dusk.rawValue
    @State private var selectedTab: StockMonitorTab = .market
    @State private var isCommandPalettePresented = false
    @State private var unavailableRouteMessage: String?
    @State private var pendingStockRouteCode: String?
    @State private var isStorageWarningExpanded = false

    private var appearance: StockMonitorAppearance {
        StockMonitorAppearance(rawValue: appearanceRawValue) ?? .dusk
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            MarketOverviewView(model: model, openTab: { selectedTab = $0 })
                .tabItem { Label("市场", systemImage: "chart.xyaxis.line") }
                .tag(StockMonitorTab.market)

            WatchlistView(model: model)
                .tabItem { Label("自选", systemImage: "star") }
                .tag(StockMonitorTab.watchlist)

            MonitorView(model: model)
                .tabItem { Label("监测", systemImage: "waveform.path.ecg") }
                .tag(StockMonitorTab.monitor)

            EventFeedTabView(model: model, openMonitor: { selectedTab = .monitor })
                .tabItem { Label("资讯", systemImage: "text.bubble") }
                .tag(StockMonitorTab.feed)

            LabTabView(model: model, openMonitor: { selectedTab = .monitor })
                .tabItem { Label("实验室", systemImage: "chart.bar.xaxis") }
                .tag(StockMonitorTab.lab)

            SettingsTabView(model: model, appearanceRawValue: $appearanceRawValue,
                            openMonitor: { selectedTab = .monitor })
                .tabItem { Label("设置", systemImage: "slider.horizontal.3") }
                .tag(StockMonitorTab.settings)
        }
        .tint(appearance.palette.accent)
        .toolbarBackground(appearance.palette.paper1, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .stockMonitorAppearance(appearance)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if let warning = model.storageWarningMessage {
                    VStack(alignment: .leading, spacing: 0) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                isStorageWarningExpanded.toggle()
                            }
                        } label: {
                            HStack(spacing: StockMonitorTokens.Space.small) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                Text("仅保存在本 App · 不与其他 App 共享")
                                    .font(.system(size: 13, weight: .semibold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.9)
                                Spacer(minLength: StockMonitorTokens.Space.small)
                                Image(systemName: isStorageWarningExpanded ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 11, weight: .bold))
                            }
                            .frame(maxWidth: .infinity, minHeight: StockMonitorTokens.Size.minimumHitTarget,
                                   alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("本机私有存储提示")
                        .accessibilityValue(isStorageWarningExpanded ? "已展开" : "已收起")
                        .accessibilityHint("点按以展开或收起 App Group 降级详情。")

                        if isStorageWarningExpanded {
                            Text(warning)
                                .font(.system(size: 13))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, StockMonitorTokens.Space.large + 20)
                                .padding(.trailing, StockMonitorTokens.Space.large)
                                .padding(.bottom, StockMonitorTokens.Space.small)
                                .transition(.opacity)
                        }
                    }
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, StockMonitorTokens.Space.large)
                    .background(Color.orange.opacity(0.10))
                }
                HStack {
                    Spacer(minLength: StockMonitorTokens.Space.small)
                    Button {
                        isCommandPalettePresented = true
                    } label: {
                        Label("命令", systemImage: "command")
                            .frame(minWidth: StockMonitorTokens.Size.minimumHitTarget,
                                   minHeight: StockMonitorTokens.Size.minimumHitTarget)
                    }
                    .keyboardShortcut("k", modifiers: [.command])
                    .accessibilityLabel("打开命令面板")
                    .accessibilityHint("用键盘或点按选择标签，也可输入六位证券代码")
                    .padding(.trailing, StockMonitorTokens.Space.small)
                }
                .background(appearance.palette.paper0)
            }
        }
        .sheet(isPresented: $isCommandPalettePresented) {
            CommandPaletteView(onRoute: apply)
                .stockMonitorAppearance(appearance)
        }
        .alert("链接不可用", isPresented: unavailableRouteBinding) {
            Button("好", role: .cancel) { unavailableRouteMessage = nil }
        } message: {
            Text(unavailableRouteMessage ?? "此链接未匹配现有页面。")
        }
        .onOpenURL { url in
            guard let route = StockMonitorRoute(url: url) else {
                unavailableRouteMessage = "未识别的链接，未打开任何页面。"
                return
            }
            apply(route)
        }
        .onChange(of: model.state.phase) { _, phase in
            guard phase != .closed, phase != .coldStart,
                  let code = pendingStockRouteCode else { return }
            pendingStockRouteCode = nil
            applyStockCode(code)
        }
    }

    private var unavailableRouteBinding: Binding<Bool> {
        Binding(
            get: { unavailableRouteMessage != nil },
            set: { if !$0 { unavailableRouteMessage = nil } })
    }

    private func apply(_ route: StockMonitorRoute) {
        switch route {
        case .tab(let tab):
            pendingStockRouteCode = nil
            selectedTab = tab
        case .stock(let code):
            guard StockMonitorRoute.isSafeStockCode(code) else {
                unavailableRouteMessage = "证券代码不可用。"
                return
            }
            guard model.state.phase != .closed, model.state.phase != .coldStart else {
                pendingStockRouteCode = code
                return
            }
            applyStockCode(code)
        }
    }

    private func applyStockCode(_ code: String) {
        guard let destination = StockMonitorRoute.stock(code: code)
            .destination(forWatchCodes: model.state.watchCodes) else {
            unavailableRouteMessage = "证券代码不可用。"
            return
        }
        switch destination {
        case .monitoredStock(let code):
            model.selectedAnalystCode = code
            selectedTab = .monitor
        case .watchlistEntry(let code):
            model.codeInput = code
            selectedTab = .watchlist
        case .tab(let tab):
            selectedTab = tab
        }
    }
}

@MainActor
private struct EventFeedTabView: View {
    @ObservedObject var model: MonitorViewModel
    let openMonitor: () -> Void
    @Environment(\.stockMonitorPalette) private var palette
    @State private var submittedQuery = ""

    private enum EventKindFilter: String, CaseIterable, Identifiable {
        case all, news, announcement, dragonTiger

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: "全部类型"
            case .news: "新闻"
            case .announcement: "公告"
            case .dragonTiger: "龙虎榜"
            }
        }

        func includes(_ event: MarketEvent) -> Bool {
            switch self {
            case .all: true
            case .news: event.kind == .news
            case .announcement: event.kind == .announcement
            case .dragonTiger: event.kind == .dragonTiger
            }
        }
    }

    private enum EventFocusFilter: String, CaseIterable, Identifiable {
        case all, watchlist, highPriority

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: "全部事件"
            case .watchlist: "与自选相关"
            case .highPriority: "仅 P1–P3"
            }
        }
    }

    @State private var eventKindFilter: EventKindFilter = .all
    @State private var eventFocusFilter: EventFocusFilter = .all

    private var filteredRecentEvents: [MarketEvent] {
        let watchCodes = Set(model.state.watchCodes)
        return model.recentEvents.filter { event in
            guard eventKindFilter.includes(event) else { return false }
            switch eventFocusFilter {
            case .all:
                return true
            case .watchlist:
                return event.stockCodes.contains(where: watchCodes.contains)
            case .highPriority:
                return event.priority >= 3
            }
        }
    }

    private var emptyFilteredEventsMessage: String {
        if eventFocusFilter == .watchlist && model.state.watchCodes.isEmpty {
            return "自选列表为空；此筛选只匹配事件中已有的证券标签。"
        }
        return "当前最多 100 条本地样本没有符合这些筛选条件的事件。"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: StockMonitorTokens.Space.large) {
                    captureSection
                    if let message = model.eventMessage {
                        let dataState: DataPresentationState = model.isLoadingEvents ? .loading :
                            (message.contains("失败") ? .error : .partial)
                        StockMonitorDataStatePanel(state: dataState, detail: message)
                    }
                    if let summary = model.eventSummary { summarySection(summary) }
                    dailyReportSection
                    searchSection
                    if !submittedQuery.isEmpty { searchResultsSection }
                    recentEventsSection
                    sourceStatusesSection
                    Button("打开监测、报告与导出工具") { openMonitor() }
                        .frame(maxWidth: .infinity, minHeight: StockMonitorTokens.Size.minimumHitTarget)
                }
                .padding(StockMonitorTokens.Space.large)
            }
            .background(palette.paper0)
            .navigationTitle("资讯")
            .refreshable { model.loadRecentEvents() }
            .onAppear { model.loadRecentEvents() }
        }
        .tint(palette.accent)
    }

    private var captureSection: some View {
        StockMonitorSurface {
            VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
                Label("按需采集 · 本地保存", systemImage: "lock.shield")
                    .font(.system(size: StockMonitorTokens.TypeScale.subhead, weight: .semibold))
                    .foregroundStyle(palette.inkPrimary)
                Text("切换或下拉本页只读取本机 SQLite；只有点按采集才请求公开资讯源。启动时如已配置有效 HTTPS 模型和 Keychain 密钥，策略命中的 P1/P2 与条件 P3 可能发送给该 Provider；P4/P5 不调用。")
                    .font(.system(size: StockMonitorTokens.TypeScale.body))
                    .foregroundStyle(palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button { model.refreshEvents() } label: {
                    Label(model.isLoadingEvents ? "正在采集" : "采集近 7 天资讯",
                          systemImage: model.isLoadingEvents ? "arrow.triangle.2.circlepath" : "arrow.down.doc")
                        .frame(maxWidth: .infinity, minHeight: StockMonitorTokens.Size.minimumHitTarget)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isLoadingEvents)
                .accessibilityHint("点按后请求已配置的公开资讯源；若分级增强已配置，策略命中的事件可能发送至该 Provider")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func summarySection(_ summary: DailyEventSummary) -> some View {
        StockMonitorSurface {
            VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
                Text("今日本地摘要")
                    .font(.system(size: StockMonitorTokens.TypeScale.subhead, weight: .semibold))
                    .foregroundStyle(palette.inkPrimary)
                HStack(spacing: StockMonitorTokens.Space.medium) {
                    StockMonitorMetricCard(label: "事件", value: String(summary.eventCount), detail: "本机 SQLite")
                    StockMonitorMetricCard(label: "主题簇", value: String(summary.clusterCount), detail: "本地聚合")
                }
                if !summary.topSectors.isEmpty {
                    Text("涉及板块：\(summary.topSectors.joined(separator: "、"))")
                        .font(.system(size: StockMonitorTokens.TypeScale.footnote))
                        .foregroundStyle(palette.inkSecondary)
                }
            }
        }
    }

    private var dailyReportSection: some View {
        StockMonitorSurface {
            VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
                Text("本地事件日报 PDF")
                    .font(.system(size: StockMonitorTokens.TypeScale.subhead, weight: .semibold))
                    .foregroundStyle(palette.inkPrimary)
                Text("按上海自然日分为 00:00–12:00 与 12:00–24:00 两段；只读取本机已保存事件和最近采集状态，不会联网。没有记录不代表来源确认无事件。")
                    .font(.system(size: StockMonitorTokens.TypeScale.caption))
                    .foregroundStyle(palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Button { model.buildDailyReportPDF() } label: {
                    Label(model.isBuildingDailyReport ? "生成中……" : "生成今日 PDF 报告",
                          systemImage: model.isBuildingDailyReport ? "hourglass" : "doc.text")
                        .frame(maxWidth: .infinity, minHeight: StockMonitorTokens.Size.minimumHitTarget)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBuildingDailyReport)
                .accessibilityHint("从本机 SQLite 生成文件，不触发网络或模型请求")
                if let message = model.dailyReportMessage {
                    Text(message)
                        .font(.system(size: StockMonitorTokens.TypeScale.caption))
                        .foregroundStyle(palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("日报状态：\(message)")
                }
                if let report = model.dailyReport {
                    HStack(spacing: StockMonitorTokens.Space.medium) {
                        StockMonitorMetricCard(label: "报告事件", value: String(report.windows.reduce(0) { $0 + $1.eventCount }),
                                               detail: report.state == .noData ? "没有本机匹配记录" : "仅为本地保存样本")
                        StockMonitorMetricCard(label: "来源成功数", value: "\(report.coverage.successfulSourceCount)/\(report.coverage.sourceCount)",
                                               detail: "最近一次资讯采集状态")
                    }
                    Text("生成时间 · \(ChartFormatters.dateTime(report.generatedAt))")
                        .font(.system(size: StockMonitorTokens.TypeScale.caption))
                        .foregroundStyle(palette.inkMuted)
                    if !report.coverage.warnings.isEmpty {
                        Text("覆盖提醒：\(report.coverage.warnings.prefix(3).joined(separator: "；"))")
                            .font(.system(size: StockMonitorTokens.TypeScale.caption))
                            .foregroundStyle(palette.accent2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let url = model.dailyReportURL {
                    ShareLink(item: url) {
                        Label("分享日报 PDF", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity, minHeight: StockMonitorTokens.Size.minimumHitTarget)
                    }
                    .accessibilityHint("打开系统分享面板；文件仅包含本地日报内容")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var searchSection: some View {
        StockMonitorSurface {
            VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
                Text("搜索本地事件")
                    .font(.system(size: StockMonitorTokens.TypeScale.subhead, weight: .semibold))
                    .foregroundStyle(palette.inkPrimary)
                HStack(spacing: StockMonitorTokens.Space.small) {
                    TextField("关键词、证券代码或来源", text: $model.eventSearchText)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { submitSearch() }
                    Button("搜索", action: submitSearch)
                        .disabled(model.isSearchingEvents || model.eventSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if !submittedQuery.isEmpty, let message = model.eventSearchMessage {
                    Text("“\(submittedQuery)”：\(message)")
                        .font(.system(size: StockMonitorTokens.TypeScale.caption))
                        .foregroundStyle(palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("搜索只查本地已保存事件，不会访问网络。")
                    .font(.system(size: StockMonitorTokens.TypeScale.caption))
                    .foregroundStyle(palette.inkMuted)
            }
        }
    }

    private var searchResultsSection: some View {
        VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
            sectionHeading("搜索结果", detail: "\(model.eventSearchResults.count) 条")
            if model.isSearchingEvents {
                StockMonitorDataStatePanel(state: .loading, detail: "正在查询本地 FTS 索引。")
            } else if model.eventSearchResults.isEmpty {
                StockMonitorDataStatePanel(state: .empty, detail: model.eventSearchMessage ?? "没有匹配记录。")
            } else {
                ForEach(model.eventSearchResults) { event in LocalEventCard(event: event) }
            }
        }
    }

    private var recentEventsSection: some View {
        VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
            sectionHeading("本地近 7 天", detail: "筛出 \(filteredRecentEvents.count)/\(model.recentEvents.count) 条")
            if model.isLoadingRecentEvents && model.recentEvents.isEmpty {
                StockMonitorDataStatePanel(state: .loading, detail: "正在读取本机事件库。")
            } else if model.recentEvents.isEmpty {
                let isError = model.recentEventsMessage?.contains("失败") == true
                StockMonitorDataStatePanel(state: isError ? .error : .empty,
                    detail: model.recentEventsMessage ?? "本机暂无事件记录。")
            } else {
                if let message = model.recentEventsMessage {
                    Text(message)
                        .font(.system(size: StockMonitorTokens.TypeScale.caption))
                        .foregroundStyle(palette.inkMuted)
                }
                recentEventFilters
                if filteredRecentEvents.isEmpty {
                    StockMonitorDataStatePanel(state: .empty, detail: emptyFilteredEventsMessage)
                } else {
                    ForEach(filteredRecentEvents) { event in LocalEventCard(event: event) }
                }
            }
        }
    }

    private var recentEventFilters: some View {
        VStack(alignment: .leading, spacing: StockMonitorTokens.Space.small) {
            HStack(spacing: StockMonitorTokens.Space.small) {
                Text("类型")
                    .font(.system(size: StockMonitorTokens.TypeScale.caption, weight: .semibold))
                    .foregroundStyle(palette.inkMuted)
                    .frame(width: 34, alignment: .leading)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: StockMonitorTokens.Space.small) {
                        ForEach(EventKindFilter.allCases) { filter in
                            filterChip(filter.title, selected: eventKindFilter == filter) {
                                eventKindFilter = filter
                            }
                        }
                    }
                }
            }
            HStack(spacing: StockMonitorTokens.Space.small) {
                Text("范围")
                    .font(.system(size: StockMonitorTokens.TypeScale.caption, weight: .semibold))
                    .foregroundStyle(palette.inkMuted)
                    .frame(width: 34, alignment: .leading)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: StockMonitorTokens.Space.small) {
                        ForEach(EventFocusFilter.allCases) { filter in
                            filterChip(filter.title, selected: eventFocusFilter == filter) {
                                eventFocusFilter = filter
                            }
                        }
                    }
                }
            }
            Text("只筛选当前最多 100 条本机事件；自选相关仅匹配事件已标注证券，不会推断关联或联网。")
                .font(.system(size: StockMonitorTokens.TypeScale.caption))
                .foregroundStyle(palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(StockMonitorTokens.Space.medium)
        .background(palette.paper1, in: RoundedRectangle(cornerRadius: StockMonitorTokens.Radius.medium))
    }

    private func filterChip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: StockMonitorTokens.TypeScale.caption, weight: .semibold))
                .foregroundStyle(selected ? palette.accent : palette.inkSecondary)
                .padding(.horizontal, StockMonitorTokens.Space.medium)
                .frame(minHeight: StockMonitorTokens.Size.minimumHitTarget)
                .background(selected ? palette.accent.opacity(0.14) : palette.paper0, in: Capsule())
                .overlay(Capsule().stroke(selected ? palette.accent.opacity(0.45) : palette.inkMuted.opacity(0.2), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(selected ? "已选中" : "未选中")
    }

    private var sourceStatusesSection: some View {
        VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
            sectionHeading("最近一次逐源状态", detail: "采集结果")
            if model.eventStatuses.isEmpty {
                StockMonitorDataStatePanel(state: .empty, detail: "尚无采集状态。")
            } else {
                ForEach(model.eventStatuses) { status in
                    StockMonitorSurface {
                        VStack(alignment: .leading, spacing: StockMonitorTokens.Space.small) {
                            HStack {
                                Text(status.sourceID)
                                    .font(.system(size: StockMonitorTokens.TypeScale.footnote, weight: .semibold))
                                    .foregroundStyle(palette.inkPrimary)
                                Spacer(minLength: StockMonitorTokens.Space.small)
                                Text(status.error == nil ? "返回 \(status.returnedCount)" : "失败")
                                    .font(.system(size: StockMonitorTokens.TypeScale.caption, weight: .semibold))
                                    .foregroundStyle(status.error == nil ? palette.dataUp : palette.dataDown)
                            }
                            Text("请求成功 \(status.successfulRequestCount)/\(status.requestCount) · 有效记录 \(status.validRecordCount)/\(status.candidateRecordCount)")
                                .font(.system(size: StockMonitorTokens.TypeScale.caption))
                                .foregroundStyle(palette.inkSecondary)
                            if let detail = status.error ?? status.note {
                                Text(detail)
                                    .font(.system(size: StockMonitorTokens.TypeScale.caption))
                                    .foregroundStyle(palette.inkMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Text("采集时间 · \(ChartFormatters.dateTime(status.fetchedAt))")
                                .font(.system(size: StockMonitorTokens.TypeScale.caption))
                                .foregroundStyle(palette.inkMuted)
                        }
                    }
                }
            }
        }
    }

    private func sectionHeading(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: StockMonitorTokens.TypeScale.title, weight: .semibold))
                .foregroundStyle(palette.inkPrimary)
            Spacer(minLength: StockMonitorTokens.Space.small)
            Text(detail)
                .font(.system(size: StockMonitorTokens.TypeScale.caption))
                .foregroundStyle(palette.inkMuted)
        }
    }

    private func submitSearch() {
        submittedQuery = model.eventSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        model.searchLocalEvents()
    }
}

@MainActor
private struct LocalEventCard: View {
    let event: MarketEvent
    @Environment(\.stockMonitorPalette) private var palette

    private var kindLabel: String {
        switch event.kind {
        case .news: "新闻"
        case .announcement: "公告"
        case .dragonTiger: "龙虎榜"
        }
    }

    private var icon: String {
        switch event.kind {
        case .news: "newspaper"
        case .announcement: "doc.text"
        case .dragonTiger: "list.number"
        }
    }

    var body: some View {
        StockMonitorSurface {
            VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
                HStack(spacing: StockMonitorTokens.Space.small) {
                    Label(kindLabel, systemImage: icon)
                        .font(.system(size: StockMonitorTokens.TypeScale.caption, weight: .semibold))
                        .foregroundStyle(palette.accent)
                    Text("P\(6 - event.priority)")
                        .font(.system(size: StockMonitorTokens.TypeScale.caption, weight: .semibold))
                        .foregroundStyle(palette.inkSecondary)
                    Spacer(minLength: StockMonitorTokens.Space.small)
                    if event.duplicateCount > 1 {
                        Text("合并 \(event.duplicateCount) 条")
                            .font(.system(size: StockMonitorTokens.TypeScale.caption))
                            .foregroundStyle(palette.inkMuted)
                    }
                }
                Text(event.title)
                    .font(.system(size: StockMonitorTokens.TypeScale.subhead, weight: .semibold))
                    .foregroundStyle(palette.inkPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let body = event.body {
                    Text(body)
                        .font(.system(size: StockMonitorTokens.TypeScale.body))
                        .foregroundStyle(palette.inkSecondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !event.stockCodes.isEmpty {
                    Text("相关证券：\(event.stockCodes.joined(separator: "、"))")
                        .font(.system(size: StockMonitorTokens.TypeScale.caption))
                        .foregroundStyle(palette.inkSecondary)
                }
                if !event.sectors.isEmpty {
                    Text("板块标记：\(event.sectors.joined(separator: "、"))")
                        .font(.system(size: StockMonitorTokens.TypeScale.caption))
                        .foregroundStyle(palette.inkSecondary)
                }
                Text(event.providerTimestampVerified
                    ? "来源时间 · \(event.publishedAt.map(ChartFormatters.dateTime) ?? "未知")"
                    : "来源发布时间未验证 · 抓取时间 \(ChartFormatters.dateTime(event.fetchedAt))")
                    .font(.system(size: StockMonitorTokens.TypeScale.caption))
                    .foregroundStyle(palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Text("来源 · \(event.corroboratingSources.joined(separator: "、"))")
                    .font(.system(size: StockMonitorTokens.TypeScale.caption))
                    .foregroundStyle(palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                if let rawURL = event.url, let url = URL(string: rawURL), url.scheme?.lowercased() == "https" {
                    Link("打开原始来源", destination: url)
                        .font(.system(size: StockMonitorTokens.TypeScale.footnote, weight: .semibold))
                        .foregroundStyle(palette.accent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@MainActor
private struct LabTabView: View {
    @ObservedObject var model: MonitorViewModel
    let openMonitor: () -> Void
    @Environment(\.stockMonitorPalette) private var palette

    private var visibleCorrelationPairs: [LabCorrelationPair] {
        guard let matrix = model.localCorrelationMatrix else { return [] }
        var pairs = [LabCorrelationPair]()
        for row in matrix.seriesIDs.indices {
            for column in (row + 1)..<matrix.seriesIDs.count {
                pairs.append(LabCorrelationPair(left: matrix.seriesIDs[row], right: matrix.seriesIDs[column],
                    value: matrix.coefficients[row][column], observations: matrix.observationCounts[row][column]))
            }
        }
        pairs.sort { left, right in
            switch (left.value, right.value) {
            case let (leftValue?, rightValue?):
                if abs(leftValue) == abs(rightValue) { return left.id < right.id }
                return abs(leftValue) > abs(rightValue)
            case (nil, nil): return left.id < right.id
            case (nil, _?): return false
            case (_?, nil): return true
            }
        }
        return Array(pairs.prefix(40))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: StockMonitorTokens.Space.large) {
                    backtestControls
                    if let report = model.backtestReport { reportSection(report) }
                    bootstrapSection
                    correlationSection
                    localResearchSections
                    analystSection
                }
                .padding(StockMonitorTokens.Space.large)
            }
            .background(palette.paper0)
            .navigationTitle("实验室")
        }
        .tint(palette.accent)
        .task { await model.loadLocalResearchPanels() }
    }

    private var backtestControls: some View {
        StockMonitorSurface {
            VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
                Label("单因子分层回测 · 本机", systemImage: "chart.bar.xaxis")
                    .font(.system(size: StockMonitorTokens.TypeScale.subhead, weight: .semibold))
                    .foregroundStyle(palette.inkPrimary)
                Text("仅当前自选股与已实现的 9 个价量因子；仅读取本机 SQLite 已缓存日线，不发起网络请求。未复权、未扣交易成本、未建模 T+1/涨跌停成交、退市生存偏差或基准超额收益。")
                    .font(.system(size: StockMonitorTokens.TypeScale.body))
                    .foregroundStyle(palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("因子", selection: $model.backtestFactor) {
                    ForEach(MonitorViewModel.backtestFactors, id: \.self) { factor in
                        Text(FactorSubset.definitions[factor]?.displayName ?? factor.rawValue).tag(factor)
                    }
                }
                Picker("信号窗口", selection: $model.backtestSessions) {
                    Text("20 个交易日").tag(20)
                    Text("60 个交易日").tag(60)
                    Text("120 个交易日").tag(120)
                }
                Button { model.runBacktest() } label: {
                    Label(model.isRunningBacktest ? "读取本机日线并计算中……" : "用本机缓存运行回测",
                        systemImage: model.isRunningBacktest ? "hourglass" : "play.fill")
                        .frame(maxWidth: .infinity, minHeight: StockMonitorTokens.Size.minimumHitTarget)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isRunningBacktest || model.state.watchCodes.isEmpty)
                if let status = model.backtestSourceStatus {
                    Text("\(status.sourceID) · 返回 \(status.returnedCount) 根 · 请求 \(status.requestCount) 次 · 时间戳未确认为供应商时间")
                        .font(.system(size: StockMonitorTokens.TypeScale.caption)).foregroundStyle(palette.inkMuted)
                    if let note = status.note { Text(note).font(.system(size: StockMonitorTokens.TypeScale.caption)).foregroundStyle(palette.inkMuted) }
                    if let error = status.error { Text(error).font(.system(size: StockMonitorTokens.TypeScale.caption)).foregroundStyle(palette.dataDown) }
                }
                if let message = model.backtestMessage {
                    Text(message).font(.system(size: StockMonitorTokens.TypeScale.caption)).foregroundStyle(palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func reportSection(_ report: LocalBacktestReport) -> some View {
        VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
            sectionHeading("最近一次结果", detail: "\(report.sampleSessions) 个信号日 · \(report.icSeries.count) 日 IC")
            StockMonitorSurface {
                VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
                    Text(FactorSubset.definitions[report.factor]?.displayName ?? report.factor.rawValue)
                        .font(.system(size: StockMonitorTokens.TypeScale.subhead, weight: .semibold)).foregroundStyle(palette.inkPrimary)
                    HStack(spacing: StockMonitorTokens.Space.medium) {
                        StockMonitorMetricCard(label: "平均 Spearman IC", value: model.metric(report.meanIC), detail: "横截面相关")
                        StockMonitorMetricCard(label: "日频 ICIR", value: model.metric(report.icir), detail: "未年化")
                    }
                    ForEach(report.strata, id: \.index) { stratum in stratumSection(stratum) }
                    ForEach(Array(report.warnings.enumerated()), id: \.offset) { warning in
                        Text(warning.element).font(.system(size: StockMonitorTokens.TypeScale.caption)).foregroundStyle(palette.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Text("这是信号分层的等权横截面日收益统计，不是持仓级模拟或投资建议。换手率、基准超额、单股贡献与成交可行性未由此回测推算。")
                .font(.system(size: StockMonitorTokens.TypeScale.caption)).foregroundStyle(palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stratumSection(_ stratum: LocalBacktestStratum) -> some View {
        let metrics = LocalBacktestPerformanceAnalyzer.analyze(stratum)
        let distribution = model.backtestReport.map {
            LocalBacktestDistribution.build(report: $0, stratumIndex: stratum.index)
        }
        return VStack(alignment: .leading, spacing: StockMonitorTokens.Space.small) {
            Text(stratum.index == 1 ? "第 1 组 · 因子排序最高" : "第 \(stratum.index) 组")
                .font(.system(size: StockMonitorTokens.TypeScale.footnote, weight: .semibold)).foregroundStyle(palette.inkPrimary)
            Text("样本 \(stratum.sampleCount) · 日均收益 \(model.percent(stratum.averageDailyReturn)) · 累计收益 \(model.percent(metrics.cumulativeReturn))")
                .font(.system(size: StockMonitorTokens.TypeScale.caption)).foregroundStyle(palette.inkSecondary)
            HStack(spacing: StockMonitorTokens.Space.medium) {
                StockMonitorMetricCard(label: "年化收益", value: model.percent(metrics.annualizedReturn), detail: "252 交易日年化")
                StockMonitorMetricCard(label: "最大回撤", value: model.percent(metrics.maximumDrawdown), detail: "等权曲线")
            }
            HStack(spacing: StockMonitorTokens.Space.medium) {
                StockMonitorMetricCard(label: "Sharpe", value: model.metric(metrics.sharpeRatioZeroRiskFree), detail: "无风险利率按 0")
                StockMonitorMetricCard(label: "Calmar", value: model.metric(metrics.calmarRatio), detail: "无回撤时未知")
            }
            HStack(spacing: StockMonitorTokens.Space.medium) {
                StockMonitorMetricCard(label: "年化波动", value: model.percent(metrics.annualizedVolatility), detail: "样本标准差 × √252")
                StockMonitorMetricCard(label: "胜率", value: model.percent(metrics.winRate), detail: "按有效交易日")
            }
            HStack(spacing: StockMonitorTokens.Space.medium) {
                StockMonitorMetricCard(label: "盈亏比", value: model.metric(metrics.profitLossRatio), detail: "不具备盈亏两侧时未知")
                StockMonitorMetricCard(label: "日收益中位数", value: model.percent(metrics.returnP50), detail: "p05–p95 \(model.percent(metrics.returnP05)) / \(model.percent(metrics.returnP95))")
            }
            if !metrics.monthlyReturns.isEmpty {
                Text("按月复利（实际回测日收益）").font(.system(size: StockMonitorTokens.TypeScale.caption, weight: .semibold)).foregroundStyle(palette.inkSecondary)
                ForEach(metrics.monthlyReturns) { month in
                    HStack {
                        Text("\(month.month) · \(month.sessionCount) 日")
                        Spacer(minLength: StockMonitorTokens.Space.small)
                        Text(model.percent(month.returnFraction))
                    }
                    .font(.system(size: StockMonitorTokens.TypeScale.caption, design: .monospaced)).foregroundStyle(palette.inkSecondary)
                }
            }
            if let distribution { distributionDatasetSection(distribution) }
        }
        .padding(.top, StockMonitorTokens.Space.small)
    }

    private func distributionDatasetSection(_ dataset: LocalBacktestDistributionDataset) -> some View {
        let quantiles = dataset.quantiles
        let summary = dataset.summary
        let percentOrUnknown: (Double?) -> String = { value in
            guard let value else { return "未知" }
            return model.percent(value)
        }
        let metricOrUnknown: (Double?) -> String = { value in
            guard let value else { return "未知" }
            return model.metric(value)
        }
        let summaryRows: [(label: String, value: String, key: String)] = [
            ("基准收益 / 累计超额", "\(percentOrUnknown(summary.benchmarkReturn)) / \(percentOrUnknown(summary.excessReturn))", "benchmark"),
            ("换手率", percentOrUnknown(summary.turnover), "turnover"),
            ("持仓时长（交易日）", metricOrUnknown(summary.holdingDurationSessions), "holdingDuration"),
            ("逐股已实现贡献", summary.symbolContributions.map { rows in
                rows.isEmpty ? "0 项" : rows.map {
                    "\($0.symbol)：\(model.metric($0.realizedProfitLoss))（\(model.percent($0.contributionFraction))）"
                }.joined(separator: "；")
            } ?? "未知", "symbolContributions")
        ]
        return StockMonitorSurface(padding: StockMonitorTokens.Space.medium) {
            VStack(alignment: .leading, spacing: StockMonitorTokens.Space.small) {
                Text("分层日收益分布 · \(summary.observationCount) 个实测观测")
                    .font(.system(size: StockMonitorTokens.TypeScale.footnote, weight: .semibold))
                    .foregroundStyle(palette.inkPrimary)
                HStack(spacing: StockMonitorTokens.Space.small) {
                    StockMonitorMetricCard(label: "P05", value: percentOrUnknown(quantiles.p05), detail: "单日收益")
                    StockMonitorMetricCard(label: "P25", value: percentOrUnknown(quantiles.p25), detail: "单日收益")
                    StockMonitorMetricCard(label: "P50", value: percentOrUnknown(quantiles.p50), detail: "单日收益")
                }
                HStack(spacing: StockMonitorTokens.Space.small) {
                    StockMonitorMetricCard(label: "P75", value: percentOrUnknown(quantiles.p75), detail: "单日收益")
                    StockMonitorMetricCard(label: "P95", value: percentOrUnknown(quantiles.p95), detail: "单日收益")
                }
                Text("复合累计收益：\(percentOrUnknown(summary.cumulativeReturn)) · 基准超额日序列：\(dataset.dailyExcessReturns.count) 个对齐观测")
                    .font(.system(size: StockMonitorTokens.TypeScale.caption))
                    .foregroundStyle(palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !dataset.dailyReturns.isEmpty {
                    DisclosureGroup("逐日分层收益（\(dataset.dailyReturns.count) 个观测）") {
                        VStack(spacing: StockMonitorTokens.Space.xsmall) {
                            ForEach(dataset.dailyReturns, id: \.date) { point in
                                HStack {
                                    Text(ChartFormatters.dateTime(point.date))
                                        .foregroundStyle(palette.inkSecondary)
                                    Spacer(minLength: StockMonitorTokens.Space.small)
                                    Text(model.percent(point.value))
                                        .foregroundStyle(palette.inkPrimary)
                                }
                                .font(.system(size: StockMonitorTokens.TypeScale.caption, design: .monospaced))
                                .frame(minHeight: StockMonitorTokens.Size.minimumHitTarget)
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                    .font(.system(size: StockMonitorTokens.TypeScale.footnote, weight: .medium))
                    .tint(palette.accent)
                }
                if !dataset.dailyExcessReturns.isEmpty {
                    DisclosureGroup("逐日基准超额（\(dataset.dailyExcessReturns.count) 个已对齐观测）") {
                        VStack(spacing: StockMonitorTokens.Space.xsmall) {
                            ForEach(dataset.dailyExcessReturns, id: \.date) { point in
                                HStack {
                                    Text(ChartFormatters.dateTime(point.date))
                                        .foregroundStyle(palette.inkSecondary)
                                    Spacer(minLength: StockMonitorTokens.Space.small)
                                    Text(model.percent(point.value))
                                        .foregroundStyle(palette.inkPrimary)
                                }
                                .font(.system(size: StockMonitorTokens.TypeScale.caption, design: .monospaced))
                                .frame(minHeight: StockMonitorTokens.Size.minimumHitTarget)
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                    .font(.system(size: StockMonitorTokens.TypeScale.footnote, weight: .medium))
                    .tint(palette.accent)
                }
                if let activity = summary.symbolTradeActivity {
                    Text("来自实际成交记录的交易活动（不等同于已实现贡献）")
                        .font(.system(size: StockMonitorTokens.TypeScale.caption, weight: .semibold))
                        .foregroundStyle(palette.inkSecondary)
                    ForEach(activity, id: \.symbol) { item in
                        Text("\(item.symbol) · \(item.filledQuantity) 股 · \(item.fillCount) 笔 · 成交名义金额 \(model.metric(item.tradedNotional))")
                            .font(.system(size: StockMonitorTokens.TypeScale.caption, design: .monospaced))
                            .foregroundStyle(palette.inkSecondary)
                    }
                } else {
                    Text("成交名义金额与逐股成交活动：未知（本次分层报告未包含实际成交记录）。")
                        .font(.system(size: StockMonitorTokens.TypeScale.caption))
                        .foregroundStyle(palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("实际成交名义金额（不含费用）：\(summary.grossTradedNotional.map { ChartFormatters.unsignedCNYAmount($0) } ?? "未知")")
                    .font(.system(size: StockMonitorTokens.TypeScale.caption))
                    .foregroundStyle(palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(summaryRows.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: StockMonitorTokens.Space.xsmall) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(item.label).foregroundStyle(palette.inkMuted)
                            Spacer(minLength: StockMonitorTokens.Space.small)
                            Text(item.value).foregroundStyle(palette.inkSecondary)
                                .multilineTextAlignment(.trailing)
                        }
                        .font(.system(size: StockMonitorTokens.TypeScale.caption))
                        if let reason = summary.unavailableReasons[item.key] {
                            Text(reason)
                                .font(.system(size: StockMonitorTokens.TypeScale.caption))
                                .foregroundStyle(palette.inkMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var bootstrapSection: some View {
        StockMonitorSurface {
            VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
                Label("历史分层收益重抽样包络", systemImage: "chart.xyaxis.line")
                    .font(.system(size: StockMonitorTokens.TypeScale.subhead, weight: .semibold)).foregroundStyle(palette.inkPrimary)
                if let result = model.backtestBootstrap,
                   let lower = result.lower5Equity.last,
                   let median = result.medianEquity.last,
                   let upper = result.upper95Equity.last {
                    Text("以第 1 组 \(result.sampleReturnCount) 个历史等权日收益，固定种子进行 \(result.pathCount) 条 IID 有放回重采样；步数与样本相同。")
                        .font(.system(size: StockMonitorTokens.TypeScale.caption)).foregroundStyle(palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: StockMonitorTokens.Space.medium) {
                        StockMonitorMetricCard(label: "5% 终值", value: model.percent(lower - 1), detail: "同长度重采样")
                        StockMonitorMetricCard(label: "中位终值", value: model.percent(median - 1), detail: "不代表预测")
                    }
                    StockMonitorMetricCard(label: "95% 终值", value: model.percent(upper - 1), detail: "IID 假设")
                    StockMonitorMetricCard(label: "95% 最大回撤", value: model.percent(result.maximumDrawdown95), detail: "路径分位数")
                    ForEach(Array(result.warnings.enumerated()), id: \.offset) { warning in
                        Text(warning.element).font(.system(size: StockMonitorTokens.TypeScale.caption)).foregroundStyle(palette.inkMuted)
                    }
                } else {
                    StockMonitorDataStatePanel(state: model.backtestReport == nil ? .empty : .partial,
                        detail: "需要一次有足够有效样本的本地回测；不足时不构造包络。")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var correlationSection: some View {
        StockMonitorSurface {
            VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
                Label("自选股收益相关性", systemImage: "square.grid.3x3")
                    .font(.system(size: StockMonitorTokens.TypeScale.subhead, weight: .semibold)).foregroundStyle(palette.inkPrimary)
                Text("点按后仅读取 SQLite 中过去 540 天已缓存的未复权日线，不发网络请求。至少 20 个共同日收益才显示 Pearson 系数；公司行动和缺失行情会影响结果。")
                    .font(.system(size: StockMonitorTokens.TypeScale.caption)).foregroundStyle(palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    Task { await model.calculateLocalCorrelation() }
                } label: {
                    Label(model.isCalculatingLocalCorrelation ? "读取本地缓存中……" : "计算本地相关性",
                        systemImage: model.isCalculatingLocalCorrelation ? "hourglass" : "square.grid.3x3.fill")
                        .frame(maxWidth: .infinity, minHeight: StockMonitorTokens.Size.minimumHitTarget)
                }
                .disabled(model.isCalculatingLocalCorrelation || model.state.watchCodes.count < 2)
                if let message = model.localCorrelationMessage {
                    Text(message).font(.system(size: StockMonitorTokens.TypeScale.caption)).foregroundStyle(palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let matrix = model.localCorrelationMatrix {
                    if visibleCorrelationPairs.isEmpty {
                        StockMonitorDataStatePanel(state: .partial,
                            detail: "当前没有达到 20 个共同观测的有效配对；矩阵系数保持未知。")
                    } else {
                        Text("完整矩阵已计算；按 |相关系数| 从高到低列出最多 40 对。")
                            .font(.system(size: StockMonitorTokens.TypeScale.caption)).foregroundStyle(palette.inkMuted)
                        ForEach(Array(visibleCorrelationPairs.enumerated()), id: \.offset) { _, pair in
                            HStack(alignment: .firstTextBaseline) {
                                Text("\(pair.left) × \(pair.right)").foregroundStyle(palette.inkPrimary)
                                Spacer(minLength: StockMonitorTokens.Space.small)
                                Text(pair.value.map { model.metric($0) } ?? "未知").foregroundStyle(palette.accent)
                                Text("n=\(pair.observations)").foregroundStyle(palette.inkMuted)
                            }
                            .font(.system(size: StockMonitorTokens.TypeScale.caption, design: .monospaced))
                        }
                    }
                    ForEach(Array(matrix.warnings.enumerated()), id: \.offset) { warning in
                        Text(warning.element).font(.system(size: StockMonitorTokens.TypeScale.caption)).foregroundStyle(palette.inkMuted)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var localResearchSections: some View {
        VStack(alignment: .leading, spacing: StockMonitorTokens.Space.large) {
            sectionHeading("本地会话研究", detail: "只读已存储事件、tick、当前已加载宽度样本与基本面缓存；不会启动行情扫描或模型调用。")
            GovernanceInsightsPanel(
                rejectionCounts: model.localEventRejectionCounts,
                keywordReport: model.localEventKeywordReport,
                isLoading: model.localResearchIsLoading,
                explanation: "拒绝原因按最近 24 小时本地采集记录统计；关键词比较相邻 24 小时已存储事件，样本不足时增长率未知。",
                loadError: model.localEventAnalyticsError,
                refresh: { Task { await model.loadLocalResearchPanels() } }
            )
            StockMonitorSurface {
                VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
                    Text("会话数据缺口")
                        .font(.system(size: StockMonitorTokens.TypeScale.title, weight: .semibold))
                        .foregroundStyle(palette.inkPrimary)
                    LiveTickGapStrip(
                        records: model.localTickStatuses,
                        loadingMessage: model.localResearchIsLoading ? "正在读取本地 tick / reconcile 记录。" : nil,
                        errorMessage: model.localTickStatusError,
                        emptyMessage: "本地 SQLite 尚无 tick 或 reconcile 状态记录；缺失证券数和补齐结果未知。"
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            SentimentComponentsPanel(
                result: model.localSentimentResult,
                observations: model.localSentimentObservations,
                availabilityExplanation: model.localSentimentExplanation
            )
            FactorMatrixExposurePanel(
                matrix: model.localFactorCorrelationMatrix,
                exposures: model.localFactorExposureResults,
                explanation: model.localFactorExplanation
            )
            LocalGraphLayoutsPanel(
                sankeyLayout: model.localEventSankeyLayout,
                forceGraphLayout: model.localFactorForceGraphLayout,
                missingDataExplanation: model.localGraphExplanation
            )
        }
    }

    private var analystSection: some View {
        StockMonitorSurface {
            VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
                Label("Analyst · 用户主动分析", systemImage: "sparkle.magnifyingglass")
                    .font(.system(size: StockMonitorTokens.TypeScale.subhead, weight: .semibold)).foregroundStyle(palette.inkPrimary)
                if let result = model.analystResult {
                    Text("\(result.signal) · 置信度 \(model.percent(result.confidence))")
                        .font(.system(size: StockMonitorTokens.TypeScale.body, weight: .semibold)).foregroundStyle(palette.inkPrimary)
                    Text(result.summary).font(.system(size: StockMonitorTokens.TypeScale.body)).foregroundStyle(palette.inkSecondary)
                    Text("目标价 \(result.targetPrice.map { $0.formatted(.number.precision(.fractionLength(2))) } ?? "未知") · 止损价 \(result.stopLossPrice.map { $0.formatted(.number.precision(.fractionLength(2))) } ?? "未知")")
                        .font(.system(size: StockMonitorTokens.TypeScale.caption)).foregroundStyle(palette.inkMuted)
                } else {
                    StockMonitorDataStatePanel(state: .empty,
                        detail: model.analystConfigured ? "尚无本次分析结果。必须由你在监测页点按并确认发送上下文。" : "尚未配置模型端点、模型 ID 与 Keychain 密钥。")
                }
                Text("模型分析会把所选本地行情/事件发送到你配置的 Provider，可能产生 Provider 费用；仅在明确点按分析并确认后发送。内容不构成投资建议。")
                    .font(.system(size: StockMonitorTokens.TypeScale.caption)).foregroundStyle(palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("打开 Analyst 配置与确认流程") { openMonitor() }
                    .frame(maxWidth: .infinity, minHeight: StockMonitorTokens.Size.minimumHitTarget)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sectionHeading(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: StockMonitorTokens.TypeScale.title, weight: .semibold)).foregroundStyle(palette.inkPrimary)
            Spacer(minLength: StockMonitorTokens.Space.small)
            Text(detail).font(.system(size: StockMonitorTokens.TypeScale.caption)).foregroundStyle(palette.inkMuted)
        }
    }
}

private struct LabCorrelationPair {
    let left: String
    let right: String
    let value: Double?
    let observations: Int
    var id: String { "\(left)|\(right)" }
}

@MainActor
private struct FundamentalValueCell: View {
    @Environment(\.stockMonitorPalette) private var palette
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: StockMonitorTokens.Space.xsmall) {
            Text(label)
                .font(.system(size: StockMonitorTokens.TypeScale.caption))
                .foregroundStyle(palette.inkMuted)
            Text(value)
                .font(.system(size: StockMonitorTokens.TypeScale.body, weight: .semibold))
                .foregroundStyle(palette.inkPrimary)
                .monospacedDigit()
                .lineLimit(2)
                .minimumScaleFactor(StockMonitorTokens.Scale.metricMinimum)
        }
        .frame(maxWidth: .infinity, minHeight: StockMonitorTokens.Size.minimumHitTarget,
               alignment: .leading)
        .padding(StockMonitorTokens.Space.small)
        .background(palette.paper2, in: RoundedRectangle(cornerRadius: StockMonitorTokens.Radius.small))
        .accessibilityElement(children: .combine)
    }
}

@MainActor
private struct SettingsTabView: View {
    @ObservedObject var model: MonitorViewModel
    @Binding var appearanceRawValue: String
    let openMonitor: () -> Void
    @Environment(\.stockMonitorPalette) private var palette
    @State private var isCalendarImportPresented = false
    @State private var calendarImportMessage: String?

    private var selectedAppearance: StockMonitorAppearance {
        StockMonitorAppearance(rawValue: appearanceRawValue) ?? .dusk
    }

    private var fundamentalsSection: some View {
        StockMonitorSurface {
            VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
                Text("当前基本面快照")
                    .font(.system(size: StockMonitorTokens.TypeScale.subhead, weight: .semibold))
                    .foregroundStyle(palette.inkPrimary)
                Text("仅在点按时向 Eastmoney 请求最多 10 只自选股的公开 F10 字段。快照不是历史点时数据；PE 动态值不等于 PE-TTM，缺失字段保持未知。")
                    .font(.system(size: StockMonitorTokens.TypeScale.caption))
                    .foregroundStyle(palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Button { model.refreshFundamentalsForWatchlist() } label: {
                    Label(model.isRefreshingFundamentals ? "刷新中……" : "刷新最多 10 只自选股",
                          systemImage: model.isRefreshingFundamentals ? "hourglass" : "arrow.clockwise")
                        .frame(maxWidth: .infinity, minHeight: StockMonitorTokens.Size.minimumHitTarget)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isRefreshingFundamentals || model.state.watchCodes.isEmpty)
                .accessibilityHint("点按后才向 Eastmoney 发送证券代码；最多请求 10 只，不请求历史行情")
                if model.isRefreshingFundamentals && !model.fundamentalsSnapshots.isEmpty {
                    StockMonitorDataStatePanel(state: .loading,
                        detail: "正在刷新；下方保留的是之前抓取的快照，当前请求结束前不代表新数据。")
                }
                if model.isRefreshingFundamentals && model.fundamentalsSnapshots.isEmpty {
                    StockMonitorDataStatePanel(state: .loading, detail: model.fundamentalsMessage ?? "读取公开基本面字段。")
                } else if model.fundamentalsSnapshots.isEmpty {
                    StockMonitorDataStatePanel(state: model.fundamentalsMessage?.contains("失败") == true ? .error : .empty,
                                               detail: model.fundamentalsMessage ?? "尚无本机基本面快照；不会自动刷新。")
                } else {
                    if let message = model.fundamentalsMessage {
                        if !model.isRefreshingFundamentals &&
                            (message.contains("失败") || message.contains("部分失败")) {
                            StockMonitorDataStatePanel(state: .partial,
                                detail: "本次刷新未完整成功；下方可能包含旧缓存与本次成功响应混合的快照。")
                        }
                        Text(message)
                            .font(.system(size: StockMonitorTokens.TypeScale.caption))
                            .foregroundStyle(message.contains("失败") || message.contains("部分失败") ? palette.accent2 : palette.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(model.fundamentalsSnapshots.enumerated()), id: \.offset) { _, snapshot in
                        StockMonitorSurface(padding: StockMonitorTokens.Space.medium) {
                            VStack(alignment: .leading, spacing: StockMonitorTokens.Space.small) {
                                Text("\(snapshot.name ?? "名称未知") · \(snapshot.code ?? "代码未知")")
                                    .font(.system(size: StockMonitorTokens.TypeScale.body, weight: .semibold))
                                    .foregroundStyle(palette.inkPrimary)
                                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading,
                                          spacing: StockMonitorTokens.Space.small) {
                                    FundamentalValueCell(label: "PB 源值", value: QuotePresentation.number(snapshot.pb))
                                    FundamentalValueCell(label: "动态 PE 源值", value: QuotePresentation.number(snapshot.peDynamic))
                                    FundamentalValueCell(label: "ROE 源值", value: QuotePresentation.number(snapshot.roe))
                                    FundamentalValueCell(label: "毛利率源值", value: QuotePresentation.number(snapshot.grossMargin))
                                    FundamentalValueCell(label: "总市值源值", value: QuotePresentation.number(snapshot.totalMarketValue))
                                    FundamentalValueCell(label: "行业字段", value: snapshot.industry ?? "未知")
                                }
                                Text("\(snapshot.sourceID) · 本机抓取 \(ChartFormatters.dateTime(snapshot.fetchedAt))")
                                    .font(.system(size: StockMonitorTokens.TypeScale.caption))
                                    .foregroundStyle(palette.inkMuted)
                                if !snapshot.unavailableFields.isEmpty {
                                    Text("响应缺失字段：\(snapshot.unavailableFields.joined(separator: "、"))")
                                        .font(.system(size: StockMonitorTokens.TypeScale.caption))
                                        .foregroundStyle(palette.accent2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var notificationSection: some View {
        StockMonitorSurface {
            VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
                Text("本机通知（手动）")
                    .font(.system(size: StockMonitorTokens.TypeScale.subhead, weight: .semibold))
                    .foregroundStyle(palette.inkPrimary)
                Text("通知可能在锁屏显示未读信号标题/内容。权限只在你点按请求按钮时询问；获得权限也不会自动投递，需再次点按投递。")
                    .font(.system(size: StockMonitorTokens.TypeScale.caption))
                    .foregroundStyle(palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Button { model.requestNotificationPermission() } label: {
                    Label(model.isRequestingNotificationPermission ? "请求中……" : "请求系统通知权限",
                          systemImage: "bell.badge")
                        .frame(maxWidth: .infinity, minHeight: StockMonitorTokens.Size.minimumHitTarget)
                }
                .buttonStyle(.bordered)
                .disabled(model.isRequestingNotificationPermission)
                Button { model.deliverUnreadAlertsNow() } label: {
                    Label(model.isDeliveringAlerts ? "投递中……" : "投递当前未读信号",
                          systemImage: model.isDeliveringAlerts ? "hourglass" : "bell.and.waves.left.and.right")
                        .frame(maxWidth: .infinity, minHeight: StockMonitorTokens.Size.minimumHitTarget)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isDeliveringAlerts || model.state.unreadSignals.isEmpty ||
                          model.notificationPermissionGranted != true)
                .accessibilityHint("将当前未读告警作为本机通知提交；不会发送网络请求")
                if let granted = model.notificationPermissionGranted {
                    Text(granted ? "最近一次权限检查：已允许" : "最近一次权限检查：未允许")
                        .font(.system(size: StockMonitorTokens.TypeScale.caption))
                        .foregroundStyle(granted ? palette.dataUp : palette.accent2)
                        .accessibilityElement(children: .combine)
                }
                if let message = model.notificationMessage {
                    Text(message)
                        .font(.system(size: StockMonitorTokens.TypeScale.caption))
                        .foregroundStyle(palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("通知状态：\(message)")
                }
                Text("注意：通知的稍后提醒/标记已读操作处理器尚未接线；请勿依赖通知操作项改变应用内状态。")
                    .font(.system(size: StockMonitorTokens.TypeScale.caption))
                    .foregroundStyle(palette.accent2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var diagnosticsSection: some View {
        StockMonitorSurface {
            VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
                Text("诊断文件")
                    .font(.system(size: StockMonitorTokens.TypeScale.subhead, weight: .semibold))
                    .foregroundStyle(palette.inkPrimary)
                Text("可选生成并分享 JSON。包含 App 版本、数据源请求/返回计数和本机健康汇总；不包含股票代码、事件正文、持仓、Provider Endpoint 或 API key。")
                    .font(.system(size: StockMonitorTokens.TypeScale.caption))
                    .foregroundStyle(palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("生成诊断 JSON") { model.exportDiagnostics() }
                    .frame(maxWidth: .infinity, minHeight: StockMonitorTokens.Size.minimumHitTarget)
                    .buttonStyle(.bordered)
                if let message = model.diagnosticExportMessage {
                    Text(message)
                        .font(.system(size: StockMonitorTokens.TypeScale.caption))
                        .foregroundStyle(palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let url = model.diagnosticExportURL {
                    ShareLink(item: url) {
                        Label("分享诊断文件", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity, minHeight: StockMonitorTokens.Size.minimumHitTarget)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: StockMonitorTokens.Space.large) {
                    StockMonitorSurface {
                        VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
                            Text("外观")
                                .font(.system(size: StockMonitorTokens.TypeScale.subhead, weight: .semibold))
                                .foregroundStyle(palette.inkPrimary)
                            Picker("外观主题", selection: $appearanceRawValue) {
                                ForEach(StockMonitorAppearance.allCases) { appearance in
                                    Text(appearance.displayName).tag(appearance.rawValue)
                                }
                            }
                            .pickerStyle(.segmented)
                            .accessibilityLabel("选择外观主题")
                        }
                    }

                    StockMonitorSurface {
                        VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
                            Text("数据与会话")
                                .font(.system(size: StockMonitorTokens.TypeScale.subhead, weight: .semibold))
                                .foregroundStyle(palette.inkPrimary)
                            Label("行情仅在 App 前台会话采集", systemImage: "iphone")
                                .font(.system(size: StockMonitorTokens.TypeScale.body))
                                .foregroundStyle(palette.inkSecondary)
                            Text("自选证券：\(model.state.watchCodes.count) 只")
                                .font(.system(size: StockMonitorTokens.TypeScale.body))
                                .foregroundStyle(palette.inkSecondary)
                            Text("已记录交易日历年份：\(MarketClock.calendarYearsWithEntries.map(String.init).joined(separator: "、"))；2022–2026 为内置官方公告日期，未覆盖日期保持未知。")
                                .font(.system(size: StockMonitorTokens.TypeScale.caption))
                                .foregroundStyle(palette.inkMuted)
                                .fixedSize(horizontal: false, vertical: true)
                            Button {
                                isCalendarImportPresented = true
                            } label: {
                                Label("导入交易日历 JSON", systemImage: "calendar.badge.plus")
                                    .frame(maxWidth: .infinity, minHeight: StockMonitorTokens.Size.minimumHitTarget)
                            }
                            .buttonStyle(.bordered)
                            .tint(palette.accent)
                            .accessibilityHint("只接受 HTTPS 上交所、深交所或北交所域名的本地 JSON；仅写入明示闭市日期，其他日期仍未知")
                            Text("导入仅保存闭市日期和来源元数据，不会联网核验文件内容；请对照原交易所公告。")
                                .font(.system(size: StockMonitorTokens.TypeScale.caption))
                                .foregroundStyle(palette.inkMuted)
                                .fixedSize(horizontal: false, vertical: true)
                            if let calendarImportMessage {
                                Text(calendarImportMessage)
                                    .font(.system(size: StockMonitorTokens.TypeScale.caption))
                                    .foregroundStyle(palette.inkSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityLabel("交易日历导入结果：\(calendarImportMessage)")
                            }
                            Text("主题选择保存在本机设置中，不包含行情、持仓或 Provider 密钥。")
                                .font(.system(size: StockMonitorTokens.TypeScale.caption))
                                .foregroundStyle(palette.inkMuted)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("加密备份底层服务可选包含有行数/字节上限的分钟与日线历史；超限时会标明未包含。原始响应归档、会话账本和密钥不会迁移。App 尚无安全口令派生与文件导入/导出流程，因此目前不能在此操作备份。")
                                .font(.system(size: StockMonitorTokens.TypeScale.caption))
                                .foregroundStyle(palette.inkMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    fundamentalsSection
                    notificationSection
                    diagnosticsSection

                    Button("打开规则、持仓与 Provider 设置") { openMonitor() }
                        .frame(maxWidth: .infinity, minHeight: StockMonitorTokens.Size.minimumHitTarget)
                }
                .padding(StockMonitorTokens.Space.large)
            }
            .background(palette.paper0)
            .navigationTitle("设置")
        }
        .fileImporter(isPresented: $isCalendarImportPresented,
                      allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else {
                    calendarImportMessage = "未选择文件。"
                    return
                }
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url, options: .mappedIfSafe)
                    let payload = try MarketClock.importOfficialHolidayCalendar(from: data)
                    calendarImportMessage = "已记录 \(payload.calendarYear) 年 \(payload.closedDates.count) 个闭市日期（\(payload.sourceTitle)）；缺失日期仍为未知。请核对原公告。"
                } catch {
                    calendarImportMessage = "导入失败：\(error.localizedDescription)"
                }
            case .failure(let error):
                calendarImportMessage = "未能打开日历文件：\(error.localizedDescription)"
            }
        }
        .tint(palette.accent)
    }
}
