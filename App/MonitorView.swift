import SwiftUI
import StockMonitorCore

private struct LocalEventSankeyAssociation: Hashable {
    let sourceID: String
    let sectorTag: String
}

@MainActor
final class MonitorViewModel: ObservableObject {
    @Published var state = EngineViewState(phase: .closed, watchCodes: [], latestSnapshot: nil,
        unreadSignals: [], lastError: nil, isMarketSession: false)
    @Published var codeInput = ""
    @Published var holdingCodeInput = ""
    @Published var holdingSharesInput = ""
    @Published var holdingCostInput = ""
    @Published var holdingError: String?
    @Published var eventStatuses: [EventSourceStatus] = []
    @Published var eventSummary: DailyEventSummary?
    @Published var eventMessage: String?
    @Published var isLoadingEvents = false
    @Published var recentEvents: [MarketEvent] = []
    @Published var isLoadingRecentEvents = false
    @Published var recentEventsMessage: String?
    @Published var eventSearchText = ""
    @Published var eventSearchResults: [MarketEvent] = []
    @Published var isSearchingEvents = false
    @Published var eventSearchMessage: String?
    @Published var sourceHealthSnapshot: SourceHealthSnapshot?
    @Published var rawArchiveStats = RawResponseArchiveStats(responseCount: 0, byteCount: 0,
        oldestResponseAt: nil, newestResponseAt: nil)
    @Published var latestSessionUsage: MonitorSessionUsage?
    @Published var isLoadingHealthDashboard = false
    @Published var healthDashboardError: String?
    @Published var healthDashboardUpdatedAt: Date?
    @Published var fullMarketCoverage: MarketCoverageSnapshot? {
        didSet { updateLocalSentimentFromAvailableCoverage() }
    }
    @Published var isLoadingFullMarketCoverage = false
    @Published var fullMarketCoverageMessage: String?
    @Published var exportURL: URL?
    @Published var dailyReportURL: URL?
    @Published var dailyReportMessage: String?
    @Published var dailyReport: ReportModel?
    @Published var isBuildingDailyReport = false
    @Published var fundamentalsSnapshots: [EastmoneyFundamentalSnapshot] = []
    @Published var fundamentalsMessage: String?
    @Published var isRefreshingFundamentals = false
    @Published var notificationMessage: String?
    @Published var notificationPermissionGranted: Bool?
    @Published var isRequestingNotificationPermission = false
    @Published var isDeliveringAlerts = false
    @Published var diagnosticExportURL: URL?
    @Published var diagnosticExportMessage: String?
    @Published var analystEndpointText = UserDefaults.standard.string(forKey: "stockmonitor.analyst.endpoint") ?? ""
    @Published var analystModelText = UserDefaults.standard.string(forKey: "stockmonitor.analyst.model") ?? ""
    @Published var analystKeyInput = ""
    @Published var analystSettingsMessage: String?
    @Published var analystConfigured = false
    @Published var selectedAnalystCode = "" {
        didSet {
            if oldValue != selectedAnalystCode {
                analystResult = nil
                analystMessage = nil
            }
        }
    }
    @Published var showAnalysisConsent = false
    @Published var analystResult: StrategyResult?
    @Published var analystMessage: String?
    @Published var isAnalyzing = false
    @Published var backtestFactor: FactorID = .momentum20
    @Published var backtestSessions = 20
    @Published var backtestReport: LocalBacktestReport?
    @Published var backtestSourceStatus: SourceStatus?
    @Published var backtestMessage: String?
    @Published var isRunningBacktest = false
    @Published var backtestBootstrap: LocalBacktestBootstrapResult?
    @Published var localCorrelationMatrix: LocalCorrelationMatrix?
    @Published var localCorrelationMessage: String?
    @Published var isCalculatingLocalCorrelation = false
    @Published var localResearchIsLoading = false
    @Published var localEventRejectionCounts: [(reason: String, count: Int)] = []
    @Published var localEventKeywordReport: EventKeywordFrequencyReport?
    @Published var localEventAnalyticsError: String?
    @Published var localTickStatuses: [LiveTickStatusRecord] = []
    @Published var localTickStatusError: String?
    @Published var localSentimentResult: LocalMarketSentimentResult?
    @Published var localSentimentObservations: [LocalMarketSentimentComponent: LocalMarketSentimentObservation] = [:]
    @Published var localSentimentExplanation = "尚未读取当前会话的本地市场样本。"
    @Published var localFactorCorrelationMatrix: LocalFactorCorrelationMatrix?
    @Published var localFactorExposureResults: [LocalFactorExposureResult] = []
    @Published var localFactorExplanation = "尚未读取本地基本面缓存。"
    @Published var localEventSankeyLayout: SankeyLayout?
    @Published var localFactorForceGraphLayout: ForceGraphLayout?
    @Published var localGraphExplanation = "关系图只使用本地存储的事件标签和已计算因子结果；缺少输入时显示未知。"

    private let runtime: StockMonitorFunctionalRuntime
    private let engine: LiveEngine
    private let monitorStore: any MonitorStore
    private var refreshTask: Task<Void, Never>?
    private var eventRefreshTask: Task<Void, Never>?
    private var recentEventsTask: Task<Void, Never>?
    private var stoppingTask: Task<Void, Never>?
    private var settingsSaveTask: Task<Void, Never>?
    private var analystTask: Task<Void, Never>?
    private var backtestTask: Task<Void, Never>?
    private var fullMarketScanTask: Task<Void, Never>?
    private var dailyReportTask: Task<Void, Never>?
    private var fundamentalsTask: Task<Void, Never>?
    private var dailyReportOperationID: UUID?
    private var fundamentalsOperationID: UUID?
    private var pendingRuleFamilySettings: [RuleFamilySettings]?
    private var lifecycleGeneration = 0

    init() {
        let endpoint = Self.validProviderEndpoint(analystEndpointText)
        let modelID = analystModelText.trimmingCharacters(in: .whitespacesAndNewlines)
        let keyProvider: (any EventLLMAPIKeyProvider)? =
            endpoint != nil && !modelID.isEmpty && AnalystAPIKeychain.hasKey()
                ? CredentialStoreEventLLMAPIKeyProvider(store: KeychainCredentialStore())
                : nil
        let configuration = StockMonitorRuntimeConfiguration(
            appGroupIdentifier: "group.com.cn00k.stockmonitorv6",
            eventLLMEndpoint: endpoint,
            eventLLMModelID: modelID.isEmpty ? nil : modelID,
            eventLLMKeyProvider: keyProvider,
            eventPolicy: Self.loadEventPolicy())
        let runtime = FunctionalServiceFactory.makeDefault(configuration: configuration)
        self.runtime = runtime
        engine = runtime.engine
        monitorStore = runtime.store
        analystConfigured = Self.validProviderEndpoint(analystEndpointText) != nil &&
            !analystModelText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && AnalystAPIKeychain.hasKey()
    }

    private static func loadEventPolicy() -> CollectorEventPolicy {
        guard let url = Bundle.main.url(forResource: "collector", withExtension: "yaml"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return .stockAgentDefaults
        }
        return CollectorEventPolicy.parseYAML(text)
    }

    func start() {
        guard refreshTask == nil else { return }
        refreshAnalystConfigurationStatus()
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.loadHealthDashboard()
            if let stoppingTask = self.stoppingTask { await stoppingTask.value }
            guard !Task.isCancelled, generation == self.lifecycleGeneration else { return }
            let runtime = self.runtime
            let engine = self.engine
            let startTask = Task { await runtime.startMonitoring() }
            while !Task.isCancelled && generation == self.lifecycleGeneration {
                self.state = await engine.state()
                self.synchronizeSelectedCode()
                if self.state.phase == .live || self.state.phase == .failed || self.state.phase == .paused { break }
                try? await Task.sleep(for: .milliseconds(400))
            }
            await startTask.value
            while !Task.isCancelled && generation == self.lifecycleGeneration {
                self.state = await engine.state()
                self.synchronizeSelectedCode()
                try? await Task.sleep(for: .seconds(1))
            }
            if generation == self.lifecycleGeneration { self.refreshTask = nil }
        }
    }

    func stop() {
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        let task = refreshTask
        refreshTask = nil
        task?.cancel()
        eventRefreshTask?.cancel()
        eventRefreshTask = nil
        isLoadingEvents = false
        recentEventsTask?.cancel()
        recentEventsTask = nil
        isLoadingRecentEvents = false
        analystKeyInput = ""
        analystTask?.cancel()
        analystTask = nil
        isAnalyzing = false
        backtestTask?.cancel()
        backtestTask = nil
        isRunningBacktest = false
        fullMarketScanTask?.cancel()
        fullMarketScanTask = nil
        isLoadingFullMarketCoverage = false
        dailyReportTask?.cancel()
        dailyReportTask = nil
        dailyReportOperationID = nil
        isBuildingDailyReport = false
        fundamentalsTask?.cancel()
        fundamentalsTask = nil
        fundamentalsOperationID = nil
        isRefreshingFundamentals = false
        let previousStop = stoppingTask
        stoppingTask = Task { [weak self] in
            if let previousStop { await previousStop.value }
            guard let self else { return }
            await self.runtime.stopMonitoring()
            if let task { await task.value }
            self.state = await self.engine.state()
            if generation == self.lifecycleGeneration { self.stoppingTask = nil }
        }
    }

    func addCode() {
        let code = codeInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.range(of: "^[0-9]{6}$", options: .regularExpression) != nil else { return }
        codeInput = ""
        Task {
            let current = await engine.state()
            await engine.setWatchCodes(current.watchCodes + [code])
            state = await engine.state()
        }
    }

    func removeCode(_ code: String) {
        Task {
            let current = await engine.state()
            await engine.setWatchCodes(current.watchCodes.filter { $0 != code })
            state = await engine.state()
        }
    }

    func upsertHolding() {
        let code = holdingCodeInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.range(of: "^[0-9]{6}$", options: .regularExpression) != nil,
              let shares = Int64(holdingSharesInput), shares > 0,
              let cost = Double(holdingCostInput), cost.isFinite, cost > 0 else {
            holdingError = "请填写六位证券代码、正整数股数和大于 0 的成本价。"
            return
        }
        holdingError = nil
        holdingCodeInput = ""; holdingSharesInput = ""; holdingCostInput = ""
        Task {
            let current = await engine.state()
            let updated = current.holdings.filter { $0.code != code } +
                [Holding(code: code, shares: shares, averageCost: cost)]
            await engine.replaceHoldings(updated)
            state = await engine.state()
        }
    }

    func removeHolding(_ code: String) {
        Task {
            let current = await engine.state()
            await engine.replaceHoldings(current.holdings.filter { $0.code != code })
            state = await engine.state()
        }
    }

    func updateRuleFamily(_ changed: RuleFamilySettings) {
        var settings = pendingRuleFamilySettings ?? state.ruleFamilySettings
        if let index = settings.firstIndex(where: { $0.family == changed.family }) { settings[index] = changed }
        else { settings.append(changed) }
        pendingRuleFamilySettings = settings
        let previous = settingsSaveTask
        settingsSaveTask = Task {
            if let previous { await previous.value }
            await engine.replaceRuleFamilySettings(settings)
            state = await engine.state()
            if let pending = pendingRuleFamilySettings, pending == settings {
                pendingRuleFamilySettings = nil
            }
        }
    }

    func markSignalRead(_ id: UUID) {
        Task {
            await engine.markSignalRead(id)
            state = await engine.state()
        }
    }

    func refreshNow() async {
        await engine.pollNow()
        state = await engine.state()
    }

    func refreshFullMarketCoverage() {
        guard fullMarketScanTask == nil else { return }
        isLoadingFullMarketCoverage = true
        fullMarketCoverageMessage = "按需扫描公开 clist 数据，最多 60 页 / 6,000 只；当前进程缓存 15 分钟，结果可能不完整。"
        fullMarketScanTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isLoadingFullMarketCoverage = false
                self.fullMarketScanTask = nil
            }
            do {
                guard let coverage = try await self.runtime.fetchFullMarketCoverage() else {
                    self.fullMarketCoverageMessage = "扩展扫描未启用或没有可用数据源。"
                    return
                }
                guard !Task.isCancelled else { return }
                self.fullMarketCoverage = coverage
                let relativeCoverage = coverage.summary.coverageComplete
                    ? "唯一返回数与服务端 total 对齐（不代表官方全集）"
                    : "覆盖不完整或受本地上限约束"
                self.fullMarketCoverageMessage = coverage.status.requestCount == 0
                    ? "使用 15 分钟内缓存，没有额外请求。\(relativeCoverage)。"
                    : "扩展扫描返回 \(coverage.status.returnedCount) 行；服务端 total \(coverage.summary.reportedTotalCount.map(String.init) ?? "未知")；\(relativeCoverage)。"
            } catch is CancellationError {
                self.fullMarketCoverageMessage = "应用进入后台，已停止扩展扫描。"
            } catch {
                self.fullMarketCoverageMessage = "扩展扫描失败：\(error.localizedDescription)"
            }
        }
    }

    func refreshEvents() {
        guard eventRefreshTask == nil else { return }
        isLoadingEvents = true
        eventMessage = "正在前台按需采集公开资讯并保存到本机……"
        eventRefreshTask = Task { [weak self] in
            guard let self else { return }
            let capabilities = await self.runtime.capabilities
            let automaticLLMEnabled = capabilities.automaticEventLLM.enabled
            if automaticLLMEnabled {
                self.eventMessage = "正在采集并保存资讯；Keychain 密钥仍有效时，符合策略的 P1/P2 与条件 P3 事件会发送给已配置 Provider 增强。"
            }
            let since = Date().addingTimeInterval(-7 * 24 * 60 * 60)
            let report = await self.runtime.refreshEvents(since: since)
            guard !Task.isCancelled else {
                self.isLoadingEvents = false
                self.eventRefreshTask = nil
                return
            }
            self.eventStatuses = report.sourceStatuses
            self.state = await self.engine.state()
            if let error = report.storageError {
                self.eventMessage = "本地保存失败：\(error)"
            } else {
                let enrichmentNote = automaticLLMEnabled
                    ? " 符合策略的事件可能已发送至配置 Provider；用量取决于该服务返回。"
                    : " 自动事件 LLM 未装配，未向 LLM Provider 发送事件。"
                self.eventMessage = "收到 \(report.receivedCount) 条；SQLite 保存/更新 \(report.storedCount) 条逐源记录，当前去重过滤后保留 \(report.visibleCount) 条。资讯源可能延迟、限流或不可用。\(enrichmentNote)"
            }
            self.eventSummary = try? await self.runtime.dailyEventSummary()
            await self.readRecentEvents()
            await self.loadHealthDashboard()
            self.isLoadingEvents = false
            self.eventRefreshTask = nil
        }
    }

    /// Reads the recent feed from local SQLite only. Network/LLM work remains
    /// behind the separate explicit `refreshEvents()` action.
    func loadRecentEvents() {
        guard recentEventsTask == nil else { return }
        isLoadingRecentEvents = true
        recentEventsTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isLoadingRecentEvents = false
                self.recentEventsTask = nil
            }
            await self.readRecentEvents()
        }
    }

    private func readRecentEvents() async {
        let end = Date()
        do {
            try await monitorStore.open()
            let all = try await monitorStore.fetchEvents(from: end.addingTimeInterval(-7 * 24 * 60 * 60), to: end)
            recentEvents = Array(all.prefix(100))
            recentEventsMessage = all.isEmpty
                ? "本机近 7 天没有已保存事件；可点按“采集”后再查看。"
                : "本机近 7 天已保存 \(all.count) 条事件；此页最多展示最新 100 条。"
        } catch {
            recentEvents = []
            recentEventsMessage = "读取本地事件失败：\(error.localizedDescription)"
        }
    }

    func searchLocalEvents() {
        let query = eventSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isSearchingEvents else {
            if query.isEmpty { eventSearchResults = []; eventSearchMessage = "请输入至少一个关键词。" }
            return
        }
        isSearchingEvents = true
        eventSearchMessage = nil
        Task { [weak self] in
            guard let self else { return }
            defer { self.isSearchingEvents = false }
            do {
                self.eventSearchResults = try await self.monitorStore.searchEvents(matching: query, limit: 50)
                self.eventSearchMessage = self.eventSearchResults.isEmpty ? "本机近 7 天已存事件中没有匹配结果。" : "找到 \(self.eventSearchResults.count) 条本地事件。"
            } catch {
                self.eventSearchResults = []
                self.eventSearchMessage = "本地搜索失败：\(error.localizedDescription)"
            }
        }
    }

    func loadHealthDashboard() async {
        guard !isLoadingHealthDashboard else { return }
        isLoadingHealthDashboard = true
        healthDashboardError = nil
        defer { isLoadingHealthDashboard = false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(SourceHealthThresholds.rollingDays - 1), to: today) ?? today
        do {
            latestSessionUsage = try await runtime.latestSessionUsage()
            sourceHealthSnapshot = try await monitorStore.fetchSourceHealth(from: start, through: now)
            rawArchiveStats = try await monitorStore.rawArchiveStats()
            healthDashboardUpdatedAt = Date()
        } catch {
            healthDashboardError = "读取本地健康与会话数据失败：\(error.localizedDescription)"
        }
    }

    func generateDailySummary() {
        Task {
            do {
                eventSummary = try await runtime.dailyEventSummary()
                eventMessage = "日报由本机 SQLite 中今日已采集事件即时生成；不会请求后台或 LLM。"
            } catch { eventMessage = "读取本地日报失败：\(error.localizedDescription)" }
        }
    }

    func exportEvents(_ format: EventExportFormat) {
        Task {
            do {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
                let start = calendar.startOfDay(for: Date())
                let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
                exportURL = try await runtime.exportEventFile(from: start, to: end, format: format)
                eventMessage = "已从本地 SQLite 生成 \(format.rawValue.uppercased()) 文件，可通过系统分享面板导出。"
            } catch { eventMessage = "导出失败：\(error.localizedDescription)" }
        }
    }

    /// Builds a two-part Shanghai-day report exclusively from locally stored events.
    func buildDailyReportPDF() {
        guard !isBuildingDailyReport else { return }
        isBuildingDailyReport = true
        dailyReport = nil
        dailyReportURL = nil
        dailyReportMessage = "正在从本机 SQLite 生成今日事件日报；不会请求网络。"
        let operationID = UUID()
        dailyReportOperationID = operationID
        dailyReportTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.dailyReportOperationID == operationID {
                    self.isBuildingDailyReport = false
                    self.dailyReportTask = nil
                    self.dailyReportOperationID = nil
                }
            }
            do {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
                let now = Date()
                let start = calendar.startOfDay(for: now)
                guard let noon = calendar.date(byAdding: .hour, value: 12, to: start),
                      let end = calendar.date(byAdding: .day, value: 1, to: start) else {
                    self.dailyReportMessage = "无法确定上海本地日报时间范围。"
                    return
                }
                let firstHalf = ReportWindow(id: "first-half", title: "上半日（00:00–12:00）",
                                             start: start, end: noon)
                let secondHalf = ReportWindow(id: "second-half", title: "下半日（12:00–24:00）",
                                              start: noon, end: end)
                let report = try await self.runtime.buildEventReport(
                    morning: firstHalf, midday: secondHalf, generatedAt: now)
                guard !Task.isCancelled else { return }
                let filename = "stock-monitor-daily-report-\(UUID().uuidString).pdf"
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
                try await self.runtime.exportReportPDF(report, to: url)
                guard !Task.isCancelled else { return }
                self.dailyReport = report
                self.dailyReportURL = url
                let stateLabel: String
                switch report.state {
                case .data: stateLabel = "有本地记录"
                case .partial: stateLabel = "部分数据"
                case .noData: stateLabel = "无本地记录"
                }
                self.dailyReportMessage = "日报已生成（\(stateLabel)）；仅汇总本机已保存事件，来源状态和采集覆盖可能不完整。"
            } catch {
                guard !Task.isCancelled else { return }
                self.dailyReportMessage = "生成本地日报 PDF 失败：\(error.localizedDescription)"
            }
        }
    }

    /// User-initiated refresh; the runtime caps this unofficial snapshot source at ten symbols.
    func refreshFundamentalsForWatchlist() {
        guard !isRefreshingFundamentals else { return }
        let codes = Array(Set(state.watchCodes)).sorted()
        guard !codes.isEmpty else {
            fundamentalsMessage = "请先添加自选股；基本面刷新不会自行选择证券。"
            fundamentalsSnapshots = []
            return
        }
        isRefreshingFundamentals = true
        fundamentalsMessage = "将向 Eastmoney 请求最多 10 只自选股的当前 F10 快照；不是历史点时数据。"
        let operationID = UUID()
        fundamentalsOperationID = operationID
        fundamentalsTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.fundamentalsOperationID == operationID {
                    self.isRefreshingFundamentals = false
                    self.fundamentalsTask = nil
                    self.fundamentalsOperationID = nil
                }
            }
            guard let report = await self.runtime.refreshFundamentals(codes: codes) else {
                guard !Task.isCancelled else { return }
                self.fundamentalsSnapshots = []
                self.fundamentalsMessage = "基本面数据源未启用；没有刷新。"
                return
            }
            guard !Task.isCancelled else { return }
            do {
                self.fundamentalsSnapshots = try await self.runtime.latestFundamentals(codes: codes)
                guard !Task.isCancelled else { return }
                var details = "Eastmoney F10 当前快照：请求 \(report.status.requestCount) 次，返回 \(report.status.returnedCount)/\(report.status.requestedCount) 只。"
                if let error = report.status.error { details += " 部分失败：\(error)" }
                if !report.skippedCodes.isEmpty {
                    details += " 未请求（10 只上限）：\(report.skippedCodes.joined(separator: "、"))。"
                }
                details += " 时间为本机抓取时间；不代表历史点时值。"
                self.fundamentalsMessage = details
            } catch {
                guard !Task.isCancelled else { return }
                self.fundamentalsSnapshots = report.snapshots
                self.fundamentalsMessage = "刷新已结束，但读取本地快照失败：\(error.localizedDescription)"
            }
        }
    }

    func requestNotificationPermission() {
        guard !isRequestingNotificationPermission else { return }
        isRequestingNotificationPermission = true
        notificationMessage = "正在请求系统通知权限；是否允许由你在系统提示中选择。"
        Task { [weak self] in
            guard let self else { return }
            defer { self.isRequestingNotificationPermission = false }
            do {
                let granted = try await self.runtime.requestNotificationAuthorization()
                self.notificationPermissionGranted = granted
                self.notificationMessage = granted
                    ? "系统已允许通知。只有点按下方投递按钮才会提交当前未读信号。"
                    : "系统未授予通知权限；可在 iOS 设置中调整。"
            } catch {
                self.notificationMessage = "请求通知权限失败：\(error.localizedDescription)"
            }
        }
    }

    func deliverUnreadAlertsNow() {
        guard !isDeliveringAlerts else { return }
        guard notificationPermissionGranted == true else {
            notificationMessage = "请先点按“请求系统通知权限”并允许通知；当前没有发送任何通知。"
            return
        }
        isDeliveringAlerts = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isDeliveringAlerts = false }
            do {
                let delivered = try await self.runtime.deliverUnreadAlerts()
                self.state = await self.engine.state()
                self.notificationMessage = delivered
                    ? "已将当前未读信号提交给本机通知中心。"
                    : "没有可投递的未读信号，或当前平台没有通知投递能力。"
            } catch {
                self.notificationMessage = "本机通知投递失败：\(error.localizedDescription)"
            }
        }
    }

    func exportDiagnostics() {
        do {
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            let bundle = DiagnosticBundle(
                metadata: DiagnosticBundleMetadata(generatedAt: Date(), appVersion: version),
                sourceStatuses: state.sourceStatuses.map { DiagnosticSourceStatus($0) },
                healthMetrics: sourceHealthSnapshot.map { DiagnosticHealthMetrics($0) })
            let filename = "stock-monitor-diagnostics-\(UUID().uuidString).json"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            diagnosticExportURL = try DiagnosticBundleExporter.write(bundle, to: url)
            diagnosticExportMessage = "已生成诊断 JSON；仅含版本、来源状态计数与本机健康汇总，不含股票代码、事件正文、持仓、Endpoint 或密钥。分享前仍请自行检查。"
        } catch {
            diagnosticExportURL = nil
            diagnosticExportMessage = "生成诊断包失败：\(error.localizedDescription)"
        }
    }

    static let backtestFactors: [FactorID] = [
        .momentum5, .momentum20, .momentum60, .volatility20, .volatility60,
        .turnover20, .amount20, .maDeviation20, .rsi14
    ]

    private static func validProviderEndpoint(_ text: String) -> URL? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https", components.host != nil,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.lowercased().hasSuffix("/chat/completions") else { return nil }
        return components.url
    }

    private func synchronizeSelectedCode() {
        guard !state.watchCodes.contains(selectedAnalystCode) else { return }
        selectedAnalystCode = state.watchCodes.first ?? ""
        analystResult = nil
    }

    func refreshAnalystConfigurationStatus() {
        let endpointMatches = Self.validProviderEndpoint(analystEndpointText)?.absoluteString ==
            UserDefaults.standard.string(forKey: "stockmonitor.analyst.endpoint")
        let modelMatches = analystModelText.trimmingCharacters(in: .whitespacesAndNewlines) ==
            UserDefaults.standard.string(forKey: "stockmonitor.analyst.model")
        analystConfigured = endpointMatches && modelMatches && analystKeyInput.isEmpty && AnalystAPIKeychain.hasKey()
    }

    func saveAnalystProvider() {
        guard let endpoint = Self.validProviderEndpoint(analystEndpointText) else {
            analystConfigured = false
            analystSettingsMessage = "请输入不含 query 的完整 HTTPS /chat/completions 地址。"
            return
        }
        let model = analystModelText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            analystConfigured = false
            analystSettingsMessage = "请填写兼容接口使用的 model ID。"
            return
        }
        do {
            let newKey = analystKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !newKey.isEmpty { try AnalystAPIKeychain.save(newKey) }
            guard AnalystAPIKeychain.hasKey() else {
                analystConfigured = false
                analystSettingsMessage = "首次配置必须输入 API key；密钥仅保存到 iOS Keychain。"
                return
            }
            UserDefaults.standard.set(endpoint.absoluteString, forKey: "stockmonitor.analyst.endpoint")
            UserDefaults.standard.set(model, forKey: "stockmonitor.analyst.model")
            analystEndpointText = endpoint.absoluteString
            analystModelText = model
            analystKeyInput = ""
            analystConfigured = true
            analystSettingsMessage = "已配置。Endpoint 与 model 保存在本机设置；API key 仅保存在 iOS Keychain。Analyst 可立即使用；自动分级事件增强将在下次启动时按此配置装配。"
        } catch {
            analystConfigured = false
            analystSettingsMessage = error.localizedDescription
        }
    }

    func clearAnalystProvider() {
        do {
            try AnalystAPIKeychain.delete()
            UserDefaults.standard.removeObject(forKey: "stockmonitor.analyst.endpoint")
            UserDefaults.standard.removeObject(forKey: "stockmonitor.analyst.model")
            analystEndpointText = ""
            analystModelText = ""
            analystKeyInput = ""
            analystConfigured = false
            analystResult = nil
            analystSettingsMessage = "Provider 配置与 Keychain API key 已清除。"
        } catch { analystSettingsMessage = error.localizedDescription }
    }

    func requestAnalysisConsent() {
        guard analystConfigured, Self.validProviderEndpoint(analystEndpointText) != nil else {
            analystMessage = "Analyst 默认关闭；请先配置 HTTPS endpoint、model ID 和 API key。"
            return
        }
        guard state.phase == .live else {
            analystMessage = "请等待前台监测会话启动后再分析。"
            return
        }
        guard state.watchCodes.contains(selectedAnalystCode) else {
            analystMessage = "请先选择当前自选股。"
            return
        }
        guard state.latestSnapshot?.quotes.contains(where: { $0.code == selectedAnalystCode }) == true else {
            analystMessage = "该自选股尚无本地报价快照；等待前台行情后再分析。"
            return
        }
        showAnalysisConsent = true
    }

    var analysisConsentSummary: String {
        let host = Self.validProviderEndpoint(analystEndpointText)?.host ?? "配置的 HTTPS endpoint"
        let model = analystModelText.trimmingCharacters(in: .whitespacesAndNewlines)
        return "将把 \(selectedAnalystCode) 的名称、最近本地报价（含来源与时间戳）、最多 60 根已保存日线、以及最多 20 条近 7 天明确匹配该代码的事件/未读规则告警，发送给 \(host) 的模型 \(model)。流程会发起 1 个 supervisor 与 4 个 specialist 并行分析请求，再发起 1 个综合改写请求，因此所选上下文可能在这 6 次 HTTPS 请求中重复发送；不包含持仓成本或其他股票。API key 会在每次请求的 Authorization header 中发给该 endpoint 鉴权；Provider 可能按其价格收费。仅继续按钮会开始请求；取消不会发送。"
    }

    func analyzeSelectedStock() {
        guard !isAnalyzing, let endpoint = Self.validProviderEndpoint(analystEndpointText) else { return }
        let modelID = analystModelText.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey: String
        do {
            guard let stored = try AnalystAPIKeychain.load(), !stored.isEmpty else {
                analystMessage = "Keychain 中没有 API key，请先配置。"
                analystConfigured = false
                return
            }
            apiKey = stored
        } catch {
            analystMessage = error.localizedDescription
            return
        }
        let code = selectedAnalystCode
        let engine = self.engine
        let runtime = self.runtime
        let monitorStore = self.monitorStore
        isAnalyzing = true
        analystResult = nil
        analystMessage = "已确认；正在读取所选股票的本地材料并直接调用配置的模型……"
        analystTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isAnalyzing = false; self.analystTask = nil }
            do {
                let now = Date()
                let localState = await engine.state()
                guard let quote = localState.latestSnapshot?.quotes.first(where: { $0.code == code }) else {
                    self.analystMessage = "找不到该代码的本地报价快照；未发送请求。"
                    return
                }
                let historyStart = now.addingTimeInterval(-3 * 366 * 24 * 60 * 60)
                let allHistoryBars = try await engine.dailyBars(codes: [code], from: historyStart,
                    to: Self.lastCompleteDailyEnd(now: now))
                let historyBars = allHistoryBars.suffix(60)
                let eventRecords = try await monitorStore.fetchEvents(from: now.addingTimeInterval(-7 * 24 * 60 * 60), to: now)
                guard !Task.isCancelled else { return }
                var material: [(Date, AnalystEvent)] = eventRecords
                    .filter { $0.stockCodes.contains(code) }
                    .map { event in
                        let date = event.latestPublishedAt ?? event.publishedAt ?? event.fetchedAt
                        let detail = [event.body, "P\(event.priority) · \(event.sourceID)"].compactMap { $0 }
                            .joined(separator: "\n").prefix(2_000)
                        return (date, AnalystEvent(timestamp: date, title: String(event.title.prefix(500)),
                            detail: String(detail), source: event.sourceID))
                    }
                material.append(contentsOf: localState.unreadSignals.filter { $0.code == code }.map { signal in
                    (signal.createdAt, AnalystEvent(timestamp: signal.createdAt,
                        title: String("本地规则：\(signal.title)".prefix(500)),
                        detail: String(signal.detail.prefix(2_000)), source: "local-rule"))
                })
                let selectedEvents = material.sorted { $0.0 > $1.0 }.prefix(20).map { $0.1 }
                let context = AnalystContext(
                    stock: AnalystStockFacts(code: code, name: quote.name, currentPrice: quote.price,
                        previousClose: quote.previousClose, open: quote.open, high: quote.high, low: quote.low,
                        volume: quote.volume, amount: quote.amount, quoteTimestamp: quote.timestamp,
                        quoteSourceID: quote.sourceID, quoteTimestampIsProvider: quote.timestampIsProvider),
                    history: historyBars.map { AnalystPricePoint(timestamp: $0.tradeDate, open: $0.open,
                        high: $0.high, low: $0.low, close: $0.close, volume: $0.volume) },
                    events: selectedEvents)
                guard !Task.isCancelled else { return }
                let result = try await runtime.analyzeSelectedStock(context: context,
                    configuration: OnDemandAnalystConfiguration(endpoint: endpoint, modelID: modelID), apiKey: apiKey)
                guard !Task.isCancelled else { return }
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
                try? await self.monitorStore.recordSourceHealth(SourceHealthDelta(
                    day: calendar.startOfDay(for: Date()), llmEnrichedDecisions: 1))
                await self.loadHealthDashboard()
                self.analystResult = result
                self.analystMessage = "分析完成；结果仅基于提交的本地材料。"
            } catch {
                guard !Task.isCancelled else { return }
                self.analystMessage = Self.analystFailureMessage(error)
            }
        }
    }

    private static func analystFailureMessage(_ error: Error) -> String {
        guard let error = error as? OnDemandAnalystError else { return "分析失败；未显示请求内容或密钥。" }
        switch error {
        case .invalidConfiguration: return "Provider 配置无效；请检查 HTTPS endpoint 和 model ID。"
        case .invalidContext: return "本地分析材料超出安全格式/长度限制，未发送。"
        case .invalidAPIKey: return "Keychain 中的 API key 无效或为空。"
        case .network: return "Provider 网络请求失败；未显示本地数据或密钥。"
        case .httpStatus(let status): return "Provider 返回 HTTP \(status)。"
        case .invalidResponse, .validationFailed: return "Provider 返回内容未通过严格 JSON schema 验证。"
        }
    }

    func runBacktest() {
        guard !isRunningBacktest, !state.watchCodes.isEmpty,
              Self.backtestFactors.contains(backtestFactor), [20, 60, 120].contains(backtestSessions) else {
            backtestMessage = "请添加自选股并选择可用因子与 20/60/120 日窗口。"
            return
        }
        let codes = state.watchCodes
        let factor = backtestFactor
        let sessions = backtestSessions
        let runtime = self.runtime
        let now = Date()
        let to = Self.lastCompleteDailyEnd(now: now)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let calendarDays = (sessions + 61) * 2 + 30
        let fromCandidate = calendar.date(byAdding: .day, value: -calendarDays, to: to) ??
            to.addingTimeInterval(-Double(calendarDays) * 86_400)
        let from = calendar.startOfDay(for: fromCandidate)
        isRunningBacktest = true
        backtestReport = nil
        backtestBootstrap = nil
        backtestSourceStatus = nil
        backtestMessage = "仅读取本机已缓存日线，不会发起网络请求；正在本地计算……"
        backtestTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isRunningBacktest = false; self.backtestTask = nil }
            do {
                let cached = try await runtime.dailyBars(codes: codes, from: from, to: to)
                guard !Task.isCancelled else { return }
                guard !cached.isEmpty else {
                    self.backtestMessage = "所选自选股和日期范围内没有本机日线缓存；没有生成回测结果，本次未联网。"
                    return
                }
                let report = LocalBacktest.run(bars: cached, factor: factor, sampleSessions: sessions)
                self.backtestReport = report
                if let topStratum = report.strata.first {
                    let returns = LocalBacktestPerformanceAnalyzer.dailyReturns(from: topStratum.equityCurve)
                    self.backtestBootstrap = LocalBacktestBootstrap.run(returns: returns,
                        pathCount: 500, horizon: returns.count,
                        seed: UInt64(report.sampleSessions + topStratum.sampleCount))
                }
                var message = "读取本机缓存 \(cached.count) 根日线，覆盖 \(Set(cached.map(\.code)).count)/\(codes.count) 只自选股；本次未联网。"
                if let topStratum = report.strata.first {
                    let metrics = LocalBacktestPerformanceAnalyzer.analyze(topStratum)
                    message += " 最高因子组：年化收益 \(self.percent(metrics.annualizedReturn))、Sharpe \(self.metric(metrics.sharpeRatioZeroRiskFree))、最大回撤 \(self.percent(metrics.maximumDrawdown))、Calmar \(self.metric(metrics.calmarRatio))、胜率 \(self.percent(metrics.winRate))、盈亏比 \(self.metric(metrics.profitLossRatio))。"
                }
                self.backtestMessage = message
            } catch {
                guard !Task.isCancelled else { return }
                self.backtestMessage = "读取本机日线缓存失败：\(error.localizedDescription)"
            }
        }
    }

    /// Reads only the existing local daily-bar cache; this does not refresh or call any source.
    func calculateLocalCorrelation() async {
        let codes = Array(Set(state.watchCodes)).sorted()
        guard codes.count >= 2 else {
            localCorrelationMessage = "至少需要两只自选股；请先加入自选并运行一次日线回测以填充本地缓存。"
            localCorrelationMatrix = nil
            return
        }
        isCalculatingLocalCorrelation = true
        localCorrelationMessage = "正在读取本机已缓存日线；此操作不会请求网络。"
        defer { isCalculatingLocalCorrelation = false }
        let to = Date()
        let from = to.addingTimeInterval(-540.0 * 86_400)
        do {
            let bars = try await runtime.dailyBars(codes: codes, from: from, to: to)
            localCorrelationMatrix = LocalCorrelationAnalyzer.returnMatrix(bars: bars,
                minimumObservations: 20)
            localCorrelationMessage = "只读取 SQLite：\(bars.count) 根未复权日线，覆盖 \(Set(bars.map(\.code)).count)/\(codes.count) 只自选股；至少 20 个共同观测才显示系数。"
            if bars.isEmpty { localCorrelationMessage = "本地没有缓存日线。请先运行一次日线回测；本次相关性计算仍不会访问网络。" }
        } catch {
            localCorrelationMatrix = nil
            localCorrelationMessage = "读取本机日线缓存失败：\(error.localizedDescription)"
        }
    }

    /// Reads a bounded window from SQLite only; it never refreshes history or calls a provider.
    func cachedDailyBars(for code: String, limit: Int = 60) async throws -> [DailyBar] {
        guard StockMonitorRoute.isSafeStockCode(code) else { return [] }
        let safeLimit = min(max(limit, 1), 120)
        let to = Date()
        let from = to.addingTimeInterval(-3 * 366 * 24 * 60 * 60)
        let bars = try await runtime.dailyBars(codes: [code], from: from, to: to)
        return Array(bars.suffix(safeLimit))
    }

    /// Reads only local SQLite analytics and cached fundamentals. It never invokes a data source.
    func loadLocalResearchPanels() async {
        guard !localResearchIsLoading else { return }
        localResearchIsLoading = true
        defer { localResearchIsLoading = false }
        localEventAnalyticsError = nil
        localTickStatusError = nil

        let now = Date()
        do {
            try await monitorStore.open()
        } catch {
            let message = "打开本地 SQLite 失败：\(error.localizedDescription)"
            localEventAnalyticsError = message
            localTickStatusError = message
            localEventRejectionCounts = []
            localEventKeywordReport = nil
            localTickStatuses = []
            localEventSankeyLayout = nil
            localFactorForceGraphLayout = nil
            localFactorCorrelationMatrix = nil
            localFactorExposureResults = []
            localFactorExplanation = message
            localGraphExplanation = message
            updateLocalSentimentFromAvailableCoverage()
            return
        }

        do {
            let counts = try await monitorStore.eventRejectionCounts(
                from: now.addingTimeInterval(-24 * 60 * 60), to: now)
            localEventRejectionCounts = counts.map { (reason: $0.key, count: $0.value) }
                .sorted { left, right in
                    left.count == right.count ? left.reason < right.reason : left.count > right.count
                }
            localEventKeywordReport = try await monitorStore.eventKeywordFrequencyReport(
                now: now, window: 24 * 60 * 60, top: 20)
        } catch {
            localEventAnalyticsError = "读取本地治理分析失败：\(error.localizedDescription)"
            localEventRejectionCounts = []
            localEventKeywordReport = nil
        }

        do {
            localTickStatuses = try await monitorStore.fetchLiveTickStatuses(limit: 32)
        } catch {
            localTickStatusError = "读取本地 tick/reconcile 记录失败：\(error.localizedDescription)"
            localTickStatuses = []
        }

        do {
            let from = now.addingTimeInterval(-7 * 24 * 60 * 60)
            let storedEvents = try await monitorStore.fetchEvents(from: from, to: now)
            let recent = Array(storedEvents.sorted { $0.fetchedAt > $1.fetchedAt }.prefix(500))
            localEventSankeyLayout = Self.makeEventSankey(from: recent)
            let taggedCount = recent.filter { !$0.sectors.isEmpty && !$0.sourceID.isEmpty }.count
            localGraphExplanation = "Sankey 仅汇总近 7 天最多 500 条本地去重事件中的来源→板块标签关联数（每条记录按实际标签计数，不是资金流）。当前读取 \(recent.count) 条，其中 \(taggedCount) 条有来源和板块标签。因子网络只使用同一上海日期的本地缓存横截面；连线数值为 |Pearson r|，正负号见矩阵。缺少可验证输入时保持未知。"
        } catch {
            localEventSankeyLayout = nil
            localGraphExplanation = "读取本地事件图输入失败：\(error.localizedDescription)；未生成占位节点。"
        }

        do {
            let codes = Array(Set(state.watchCodes)).sorted()
            let snapshots = try await runtime.latestFundamentals(codes: codes)
            let research = Self.makeFactorResearch(from: snapshots)
            localFactorCorrelationMatrix = research.matrix
            localFactorExposureResults = research.exposures
            localFactorExplanation = research.explanation
            localFactorForceGraphLayout = research.matrix.flatMap { Self.makeFactorForceGraph(from: $0) }
        } catch {
            localFactorCorrelationMatrix = nil
            localFactorExposureResults = []
            localFactorForceGraphLayout = nil
            localFactorExplanation = "读取本地基本面缓存失败：\(error.localizedDescription)；没有发起网络请求。"
        }

        updateLocalSentimentFromAvailableCoverage()
    }

    private func updateLocalSentimentFromAvailableCoverage() {
        var observations: [LocalMarketSentimentComponent: LocalMarketSentimentObservation] = [:]
        guard let coverage = fullMarketCoverage else {
            localSentimentObservations = observations
            localSentimentResult = LocalMarketSentiment.score(observations)
            localSentimentExplanation = "本次应用会话尚无已加载的 clist 市场扫描样本；本面板不会自动扫描。六项成分均保持未知。"
            return
        }

        let summary = coverage.summary
        let validBreadthCount = summary.up + summary.flat + summary.down
        if validBreadthCount > 0 {
            let score = Double(summary.up - summary.down) / Double(validBreadthCount)
            observations[.advancingDecliningBreadth] = LocalMarketSentimentObservation(
                score: score,
                metadata: LocalMarketSentimentMetadata(
                    provenance: "\(coverage.status.sourceID) · 返回样本涨跌计数",
                    sampleDescription: "有效涨跌字段 \(validBreadthCount) 条；服务端报告总数 \(summary.reportedTotalCount.map(String.init) ?? "未知")",
                    sampleCount: validBreadthCount,
                    measuredAt: coverage.status.fetchedAt))
        }
        localSentimentObservations = observations
        localSentimentResult = LocalMarketSentiment.score(observations)
        if validBreadthCount > 0 {
            localSentimentExplanation = "只对 clist 已返回样本的有效涨跌家数计算净宽度 (\(summary.up)−\(summary.down))/\(validBreadthCount)；不代表全市场完整覆盖或未来走势。涨跌停、炸板、收益分布、资金流和市场参与度没有经验证输入时均保持未知；不会触发扫描。来源：\(coverage.status.sourceID)，返回 \(coverage.status.returnedCount) 行。"
        } else {
            localSentimentExplanation = "clist 扫描没有提供可用的涨跌家数（0 条有效变化字段）；净宽度分数未知。涨跌停、炸板、收益分布、资金流和市场参与度也保持未知；不会触发扫描。来源：\(coverage.status.sourceID)。"
        }
    }

    private static func makeFactorResearch(from snapshots: [EastmoneyFundamentalSnapshot]) -> (
        matrix: LocalFactorCorrelationMatrix?,
        exposures: [LocalFactorExposureResult],
        explanation: String
    ) {
        let factors: [FactorID] = [.pb, .roe, .grossMargin, .totalMarketValue]
        let latestDate = snapshots.map(\.fetchedAt).max()
        guard let latestDate else {
            let emptyExposures = factors.map {
                LocalFactorExposureAnalyzer.exposure($0, observations: [], weights: nil)
            }
            return (nil, emptyExposures,
                "自选股没有本地缓存的 Eastmoney F10 基本面快照；未联网刷新。PE-TTM、PS、股息率及历史点时字段不由现有映射提供，保持未知。")
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        var latestByCode: [String: EastmoneyFundamentalSnapshot] = [:]
        for snapshot in snapshots {
            guard let code = snapshot.code else { continue }
            if latestByCode[code].map({ $0.fetchedAt < snapshot.fetchedAt }) ?? true {
                latestByCode[code] = snapshot
            }
        }
        let sameDay = latestByCode.values
            .filter { calendar.isDate($0.fetchedAt, inSameDayAs: latestDate) }
            .sorted { ($0.code ?? "") < ($1.code ?? "") }
        let symbolObservations = sameDay.compactMap { snapshot -> LocalFactorSymbolObservation? in
            guard let code = snapshot.code else { return nil }
            let raw = snapshot.factorObservation
            let values = factors.reduce(into: [FactorID: Double]()) { result, factor in
                if let value = FactorSubset.value(for: factor, observations: [raw]), value.isFinite {
                    result[factor] = value
                }
            }
            let provenance = "\(snapshot.sourceID) · 本地抓取 \(localResearchDate(snapshot.fetchedAt))"
            return LocalFactorSymbolObservation(symbol: code, date: snapshot.fetchedAt,
                                                values: values, provenance: provenance)
        }
        let observations = symbolObservations.map {
            LocalFactorObservation(date: $0.date, values: $0.values, provenance: $0.provenance)
        }
        let matrix = observations.isEmpty ? nil : LocalFactorExposureAnalyzer.correlationMatrix(
            factors, observations: observations, method: .pearson, minimumObservations: 3)
        let exposures = factors.map {
            LocalFactorExposureAnalyzer.exposure($0, observations: symbolObservations, weights: nil)
        }
        let explanation = "只读 SQLite 中自选股的本地基本面快照；\(symbolObservations.count) 只取同一上海自然日 \(localResearchDate(latestDate)) 的记录。当前可语义映射字段仅市净率、ROE、毛利率、总市值；PE-TTM 等不匹配/缺失字段不推断。相关矩阵是当前横截面 Pearson（至少 3 个有效配对），不是时间序列；没有明确市值权重时不计算组合加权暴露。抓取时间不是供应商时间戳，数据可能过期。"
        return (matrix, exposures, explanation)
    }

    private static func localResearchDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private static func makeEventSankey(from events: [MarketEvent]) -> SankeyLayout? {
        var counts: [LocalEventSankeyAssociation: Int] = [:]
        for event in events where !event.sourceID.isEmpty {
            for sector in event.sectors.prefix(8) where !sector.isEmpty {
                counts[LocalEventSankeyAssociation(sourceID: event.sourceID, sectorTag: sector), default: 0] += 1
            }
        }
        guard !counts.isEmpty else { return nil }

        var sourceTotals: [String: Int] = [:]
        var sectorTotals: [String: Int] = [:]
        for (association, count) in counts {
            sourceTotals[association.sourceID, default: 0] += count
            sectorTotals[association.sectorTag, default: 0] += count
        }
        let topSources = Set(sourceTotals.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }.prefix(8).map(\.key))
        let topSectors = Set(sectorTotals.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }.prefix(8).map(\.key))
        let selected = counts.filter { topSources.contains($0.key.sourceID) && topSectors.contains($0.key.sectorTag) }
            .sorted {
                if $0.value != $1.value { return $0.value > $1.value }
                if $0.key.sourceID != $1.key.sourceID { return $0.key.sourceID < $1.key.sourceID }
                return $0.key.sectorTag < $1.key.sectorTag
            }
            .prefix(32)
        guard !selected.isEmpty else { return nil }
        let sourceIDs = Set(selected.map { "来源：\($0.key.sourceID)" })
        let sectorIDs = Set(selected.map { "板块：\($0.key.sectorTag)" })
        let nodes = (sourceIDs.union(sectorIDs)).sorted().map { GraphLayoutNodeInput(id: $0) }
        let links = selected.map {
            GraphLayoutLinkInput(sourceID: "来源：\($0.key.sourceID)",
                                 targetID: "板块：\($0.key.sectorTag)", value: Double($0.value))
        }
        return GraphLayoutAlgorithms.sankey(nodes: nodes, links: links,
            width: Double(StockMonitorTokens.Size.skeletonTwoThirds * 2),
            height: Double(StockMonitorTokens.Size.heroSkeletonHeight),
            nodeWidth: Double(StockMonitorTokens.Size.minimumHitTarget / 3),
            nodePadding: Double(StockMonitorTokens.Space.small))
    }

    private static func makeFactorForceGraph(from matrix: LocalFactorCorrelationMatrix) -> ForceGraphLayout? {
        var links: [GraphLayoutLinkInput] = []
        guard matrix.cells.count == matrix.factors.count else { return nil }
        for row in matrix.factors.indices {
            guard row < matrix.cells.count else { continue }
            for column in (row + 1)..<matrix.factors.count where column < matrix.cells[row].count {
                let cell = matrix.cells[row][column]
                guard cell.sampleCount >= 3, let coefficient = cell.coefficient,
                      coefficient.isFinite, (-1...1).contains(coefficient) else { continue }
                let source = FactorSubset.definitions[cell.left]?.displayName ?? cell.left.rawValue
                let target = FactorSubset.definitions[cell.right]?.displayName ?? cell.right.rawValue
                links.append(GraphLayoutLinkInput(sourceID: source, targetID: target,
                                                  value: abs(coefficient)))
            }
        }
        guard !links.isEmpty else { return nil }
        let nodeIDs = Set(links.flatMap { [$0.sourceID, $0.targetID] })
        let nodes = nodeIDs.sorted().map { GraphLayoutNodeInput(id: $0) }
        return GraphLayoutAlgorithms.forceGraph(nodes: nodes, links: links,
            width: Double(StockMonitorTokens.Size.skeletonTwoThirds * 2),
            height: Double(StockMonitorTokens.Size.heroSkeletonHeight), iterations: 48)
    }

    private static func lastCompleteDailyEnd(now: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let start = calendar.startOfDay(for: now)
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        if (parts.hour ?? 0) > 15 || ((parts.hour ?? 0) == 15 && (parts.minute ?? 0) >= 5) {
            return calendar.date(byAdding: .second, value: 86_399, to: start) ?? now
        }
        return start.addingTimeInterval(-1)
    }

    func metric(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "n/a" }
        return value.formatted(.number.precision(.fractionLength(3)))
    }

    func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "n/a" }
        return value.formatted(.percent.precision(.fractionLength(2)))
    }
}

struct MonitorView: View {
    @ObservedObject var model: MonitorViewModel

    private enum SignalLevelFilter: String, CaseIterable, Identifiable {
        case all, urgent, warning, info

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "全部"
            case .urgent: return "紧急"
            case .warning: return "警告"
            case .info: return "提示"
            }
        }

        var alertLevel: AlertLevel? {
            switch self {
            case .all: return nil
            case .urgent: return .urgent
            case .warning: return .warning
            case .info: return .info
            }
        }
    }

    @State private var selectedSignalLevel: SignalLevelFilter = .all

    private var visibleUnreadSignals: [AlertSignal] {
        guard let level = selectedSignalLevel.alertLevel else {
            return model.state.unreadSignals
        }
        return model.state.unreadSignals.filter { $0.level == level }
    }

    private var quotesByCode: [String: Quote] {
        Dictionary((model.state.latestSnapshot?.quotes ?? []).map { ($0.code, $0) }, uniquingKeysWith: { _, new in new })
    }
    private var indicesByCode: [String: Quote] {
        Dictionary((model.state.latestSnapshot?.indexQuotes ?? []).map { ($0.code, $0) }, uniquingKeysWith: { _, new in new })
    }

    var body: some View {
        NavigationStack {
            List {
                sessionSection
                indexSection
                watchlistSection
                dataHealthSection
                backtestSection
                eventsSection
                eventHealthSection
                analystSection
                holdingsSection
                rulesSection
                signalsSection
            }
            .navigationTitle("股票监测")
            .refreshable { await model.refreshNow() }
            .alert("发送所选股票本地数据？", isPresented: $model.showAnalysisConsent) {
                Button("发送并分析", role: .destructive) { model.analyzeSelectedStock() }
                Button("取消", role: .cancel) { }
            } message: {
                Text(model.analysisConsentSummary)
            }
        }
    }

    private var sessionSection: some View {
        Section("会话状态") {
            Label("监测仅在 App 开启时运行", systemImage: "info.circle.fill")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
            switch MarketClock.tradingDayStatus() {
            case .open:
                Text("交易日历：官方核实覆盖的交易日；仅在规定时段采集。")
                    .font(.caption).foregroundStyle(.secondary)
            case .closed(let reason):
                Text("交易日历：休市（\(reason)），Live Loop 暂停。")
                    .font(.caption).foregroundStyle(.secondary)
            case .unknown:
                Text("交易日历：此日期未知；不会假定开市，Live Loop 暂停。")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Circle().fill(statusColor).frame(width: 9, height: 9)
                Text(statusTitle).font(.headline)
                Spacer()
                if model.state.isMarketSession { Text("交易时段").font(.caption).foregroundStyle(.secondary) }
            }
            if let capturedAt = model.state.latestSnapshot?.capturedAt {
                Text("最近快照：\(capturedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(model.state.limitPriceStatus)
                .font(.caption).foregroundStyle(.orange)
            if let error = model.state.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var indexSection: some View {
        Section("主要指数") {
            ForEach(MarketIndex.core) { index in
                if let quote = indicesByCode[index.code] {
                    quoteRow(quote, fallbackName: index.name, showRemove: false)
                } else {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(index.name).font(.headline)
                            Text(index.code).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("等待行情").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var watchlistSection: some View {
        Section("自选股") {
            HStack {
                TextField("输入 6 位股票代码", text: $model.codeInput)
                    .keyboardType(.numberPad)
                    .textInputAutocapitalization(.never)
                Button("添加") { model.addCode() }
                    .disabled(model.codeInput.count != 6)
            }
            if model.state.watchCodes.isEmpty {
                Text("添加代码后，行情只会在前台交易时段轮询。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.state.watchCodes, id: \.self) { code in
                    if let quote = quotesByCode[code] {
                        quoteRow(quote, fallbackName: code, showRemove: true)
                    } else {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(code).font(.headline)
                                Text("暂无可用快照").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) { model.removeCode(code) } label: {
                                Image(systemName: "minus.circle")
                            }
                        }
                    }
                }
            }
        }
    }

    private var dataHealthSection: some View {
        Section("数据来源与补齐") {
            if model.state.sourceStatuses.isEmpty {
                Text("尚无来源响应记录").foregroundStyle(.secondary)
            } else {
                ForEach(model.state.sourceStatuses, id: \.id) { status in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(status.sourceID).font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(freshnessLabel(status.freshness()))
                                .font(.caption).foregroundStyle(freshnessColor(status.freshness()))
                        }
                        Text("返回 \(status.returnedCount)/\(status.requestedCount) · 请求 \(status.requestCount) · 拉取 \(status.fetchedAt.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                        if let note = status.note { Text(note).font(.caption2).foregroundStyle(.secondary) }
                        if let error = status.error { Text(error).font(.caption2).foregroundStyle(.red) }
                    }
                }
            }
            if let report = model.state.reconcileReport {
                Text("分钟 bars：\(report.barCount) 条 · 覆盖 \(report.reconciledCodes.count)/\(report.requestedCodes.count) 只 · 请求 \(report.requestCount) 次")
                    .font(.caption)
                ForEach(report.warnings, id: \.self) { warning in
                    Text(warning).font(.caption2).foregroundStyle(.orange)
                }
                if !report.skippedCodes.isEmpty {
                    Text("未补齐：\(report.skippedCodes.joined(separator: ", "))")
                        .font(.caption2).foregroundStyle(.red)
                }
            }
        }
    }

    private var backtestSection: some View {
        Section("单因子分层回测 · 本机") {
            Text("仅当前自选股；没有可用成分股清单时不扩展 universe。只提供日线 OHLCV/成交额/换手率可算的 9 个因子；仅读取本机 SQLite 已缓存日线，不发起网络请求。")
                .font(.caption).foregroundStyle(.secondary)
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
            Button {
                model.runBacktest()
            } label: {
                Label(model.isRunningBacktest ? "读取本机日线并计算中……" : "用本机缓存运行回测",
                      systemImage: model.isRunningBacktest ? "hourglass" : "chart.bar.xaxis")
            }
            .disabled(model.isRunningBacktest || model.state.watchCodes.isEmpty)
            if let status = model.backtestSourceStatus {
                Text("\(status.sourceID) · bars \(status.returnedCount) · 请求 \(status.requestCount) · 来源时间未单独确认")
                    .font(.caption)
                if let note = status.note { Text(note).font(.caption2).foregroundStyle(.secondary) }
                if let error = status.error { Text(error).font(.caption2).foregroundStyle(.orange) }
            }
            if let message = model.backtestMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            if let report = model.backtestReport {
                Text("\(FactorSubset.definitions[report.factor]?.displayName ?? report.factor.rawValue) · \(report.sampleSessions) 个信号日 · \(report.icSeries.count) 日 IC")
                    .font(.subheadline.weight(.semibold))
                Text("平均 Spearman IC：\(model.metric(report.meanIC)) · 日频 ICIR（未年化）：\(model.metric(report.icir))")
                    .font(.caption)
                ForEach(report.strata, id: \.index) { stratum in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stratum.index == 1 ? "第 1 组（因子排序最高）" : "第 \(stratum.index) 组")
                            .font(.caption.weight(.semibold))
                        Text("样本 \(stratum.sampleCount) · 日均收益 \(model.percent(stratum.averageDailyReturn)) · 累计 \(model.percent(stratum.cumulativeReturn)) · Equity 点数 \(stratum.equityCurve.count)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                ForEach(Array(report.warnings.enumerated()), id: \.offset) { item in
                    Text(item.element).font(.caption2).foregroundStyle(.orange)
                }
            }
        }
    }

    private var eventsSection: some View {
        Section("资讯 · 当日小结 · 导出") {
            HStack {
                TextField("搜索本机事件标题、正文、代码或板块", text: $model.eventSearchText)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit { model.searchLocalEvents() }
                Button(model.isSearchingEvents ? "搜索中" : "搜索") { model.searchLocalEvents() }
                    .disabled(model.isSearchingEvents || model.eventSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let message = model.eventSearchMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.eventSearchResults) { event in
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.title).font(.subheadline.weight(.semibold))
                    Text("\(event.sourceID) · P\(6 - event.priority) · \(event.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2).foregroundStyle(.secondary)
                    if let body = event.body { Text(body).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                    if !event.stockCodes.isEmpty || !event.sectors.isEmpty {
                        Text((event.stockCodes + event.sectors).joined(separator: " · "))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Button {
                model.refreshEvents()
            } label: {
                if model.isLoadingEvents {
                    Label("前台采集中……", systemImage: "arrow.triangle.2.circlepath")
                } else {
                    Label("采集公开资讯（近 7 天）", systemImage: "arrow.clockwise")
                }
            }
            .disabled(model.isLoadingEvents)
            Button("生成当日本地小结") { model.generateDailySummary() }
            Menu("导出今日事件") {
                Button("CSV") { model.exportEvents(.csv) }
                Button("JSON") { model.exportEvents(.json) }
            }
            if let exportURL = model.exportURL {
                ShareLink(item: exportURL) { Label("分享导出文件", systemImage: "square.and.arrow.up") }
            }
            if let message = model.eventMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            if let summary = model.eventSummary {
                Text("今日 \(summary.eventCount) 条原始/合并事件 · \(summary.clusterCount) 个主题簇")
                    .font(.subheadline.weight(.semibold))
                if !summary.topSectors.isEmpty {
                    Text("相关板块：\(summary.topSectors.joined(separator: "、"))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(summary.clusters.prefix(8)) { cluster in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(cluster.headline).font(.subheadline.weight(.semibold))
                        Text("\(cluster.eventCount) 条 · P\(6 - cluster.priority) · \(cluster.sourceIDs.joined(separator: ", "))")
                            .font(.caption).foregroundStyle(.secondary)
                        if !cluster.sectors.isEmpty {
                            Text(cluster.sectors.joined(separator: "、")).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !model.eventStatuses.isEmpty {
                ForEach(model.eventStatuses) { status in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(status.sourceID) · \(status.freshness().rawValue) · \(status.returnedCount)/\(status.requestedCount)")
                            .font(.caption.weight(.semibold))
                        if let note = status.note { Text(note).font(.caption2).foregroundStyle(.secondary) }
                        if let error = status.error { Text(error).font(.caption2).foregroundStyle(.orange) }
                    }
                }
            }
            Text("采集只由此按钮触发，数据留在本机；雪球和工信部当前标记不可用，不做登录或反爬绕过。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var eventHealthSection: some View {
        Section("7 日本机采集健康") {
            Button("刷新健康与归档用量") { Task { await model.loadHealthDashboard() } }
            if let health = model.sourceHealthSnapshot {
                let p1Count = health.p1Attempts
                let validityCount = health.filterTotal
                let decisionCount = health.llmEnrichedDecisions + health.ruleOrSkippedDecisions
                HStack {
                    Text("P1 官方来源请求成功率")
                    Spacer()
                    Text(p1Count == 0 ? "暂无数据" : "\(health.p1Successes)/\(p1Count) · \(health.p1SuccessRate.formatted(.percent.precision(.fractionLength(1))))")
                        .foregroundStyle(p1Count == 0 ? Color.secondary : health.p1ThresholdPassed ? Color.green : Color.orange)
                }.font(.caption)
                HStack {
                    Text("解析记录有效率")
                    Spacer()
                    Text(validityCount == 0 ? "暂无数据" : "\(health.filterKept)/\(validityCount) · \(health.eventValidityRate.formatted(.percent.precision(.fractionLength(1))))")
                        .foregroundStyle(validityCount == 0 ? Color.secondary : health.eventValidityThresholdPassed ? Color.green : Color.orange)
                }.font(.caption)
                HStack {
                    Text("LLM enrichment 占比")
                    Spacer()
                    Text(decisionCount == 0 ? "暂无数据" : "\(health.llmEnrichedDecisions)/\(decisionCount) · \(health.llmCallShare.formatted(.percent.precision(.fractionLength(1))))")
                        .foregroundStyle(decisionCount == 0 ? Color.secondary : health.llmCallShareThresholdPassed ? Color.green : Color.orange)
                }.font(.caption)
                Text("阈值：P1 ≥99% · 解析有效率 ≥80% · LLM 占比 ≤50%。P1 分母为 gov/CNINFO 请求数；有效率为成功解析事件记录/源端候选记录；LLM 占比按成功用户触发 Analyst run 与本地处理/跳过的去重可见事件计数。")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("暂无健康计数；点击采集公开资讯后开始累计。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("原始响应归档：\(model.rawArchiveStats.responseCount) 条 · \(ByteCountFormatStyle(style: .file).format(Int64(model.rawArchiveStats.byteCount))) / 10 MiB；保留最近 7 天，单条最多 512 KB。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var analystSection: some View {
        Section("按需 Analyst · 需配置 Provider") {
            Text("默认关闭。只有点击“请求分析”并在下一步确认后，才会把所选股票的本地材料直接发给配置的 HTTPS 模型；不经过自建后台。结果不是投资建议。")
                .font(.caption).foregroundStyle(.secondary)
            TextField("OpenAI-compatible HTTPS /chat/completions URL", text: $model.analystEndpointText)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .keyboardType(.URL)
                .onChange(of: model.analystEndpointText) { _, _ in model.refreshAnalystConfigurationStatus() }
            TextField("Model ID", text: $model.analystModelText)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .onChange(of: model.analystModelText) { _, _ in model.refreshAnalystConfigurationStatus() }
            SecureField("API key（保存后清空）", text: $model.analystKeyInput)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .onChange(of: model.analystKeyInput) { _, _ in model.refreshAnalystConfigurationStatus() }
            HStack {
                Button("保存 Provider") { model.saveAnalystProvider() }
                Spacer()
                Button("清除配置与密钥", role: .destructive) { model.clearAnalystProvider() }
            }
            Text(model.analystConfigured ? "Provider 已配置；密钥存于 iOS Keychain，未配置任何后台调用。" : "尚未配置；Analyst 保持关闭。")
                .font(.caption).foregroundStyle(model.analystConfigured ? Color.green : Color.secondary)
            if let message = model.analystSettingsMessage {
                Text(message).font(.caption2).foregroundStyle(.secondary)
            }
            Picker("所选自选股", selection: $model.selectedAnalystCode) {
                if model.state.watchCodes.isEmpty { Text("无自选股").tag("") }
                ForEach(model.state.watchCodes, id: \.self) { code in Text(code).tag(code) }
            }
            Button {
                model.requestAnalysisConsent()
            } label: {
                Label(model.isAnalyzing ? "分析中……" : "请求分析（下一步确认发送）",
                      systemImage: model.isAnalyzing ? "hourglass" : "sparkles")
            }
            .disabled(!model.analystConfigured || model.isAnalyzing || model.selectedAnalystCode.isEmpty)
            if let message = model.analystMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            if let result = model.analystResult {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(result.signal) · 信心 \(model.percent(result.confidence))")
                        .font(.headline)
                    Text("目标价：\(result.targetPrice.map { String(format: "%.2f", $0) } ?? "未提供") · 止损参考：\(result.stopLossPrice.map { String(format: "%.2f", $0) } ?? "未提供")")
                        .font(.caption)
                    HStack(spacing: 8) {
                        analystScore("技术", result.scores.technical)
                        analystScore("基本面", result.scores.fundamental)
                    }
                    HStack(spacing: 8) {
                        analystScore("情绪", result.scores.sentiment)
                        analystScore("风险", result.scores.risk)
                    }
                    analystNarrative("摘要", result.summary)
                    analystNarrative("技术面", result.technical)
                    analystNarrative("基本面", result.fundamental)
                    analystNarrative("情绪面", result.sentiment)
                    Text("非投资建议；模型输出可能不准确。请独立核对行情与原始资料。")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder
    private func analystScore(_ title: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(title) \(value, format: .number.precision(.fractionLength(0)))")
                .font(.caption2)
            ProgressView(value: value, total: 100)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func analystNarrative(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold))
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var holdingsSection: some View {
        Section("持仓与成本价") {
            HStack {
                TextField("六位代码", text: $model.holdingCodeInput).keyboardType(.numberPad)
                TextField("股数", text: $model.holdingSharesInput).keyboardType(.numberPad)
                TextField("成本价", text: $model.holdingCostInput).keyboardType(.decimalPad)
            }
            Button("保存 / 更新持仓成本") { model.upsertHolding() }
            if let error = model.holdingError { Text(error).font(.caption).foregroundStyle(.red) }
            if model.state.holdings.isEmpty {
                Text("尚未录入持仓；浮盈/浮亏规则需要这里的股数与成本价。").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(model.state.holdings) { holding in
                    HStack {
                        Text(holding.code)
                        Spacer()
                        Text("\(holding.shares) 股 · 成本 \(holding.averageCost, format: .number.precision(.fractionLength(2)))")
                            .font(.caption).foregroundStyle(.secondary)
                        Button(role: .destructive) { model.removeHolding(holding.code) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    private var rulesSection: some View {
        Section("监测规则 · 14 类") {
            Text("阈值、确认次数、冷却、盘中限制与静默时间保存在本机。涨跌停信号未启用。")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(model.state.ruleFamilySettings) { setting in
                RuleFamilySettingsEditor(setting: setting, watchCodes: model.state.watchCodes,
                    onUpdate: model.updateRuleFamily)
            }
            if !model.state.watchRules.isEmpty {
                ForEach(model.state.watchRules) { rule in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(rule.title).font(.subheadline.weight(.semibold))
                        Text("\(rule.code) · \(rule.detail) · 连续 \(rule.sustainedTicks) 次")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var signalsSection: some View {
        Section("未读信号 · \(model.state.unreadSignals.count)") {
            if model.state.unreadSignals.isEmpty {
                Text("暂无信号").foregroundStyle(.secondary)
            } else {
                Picker("信号级别", selection: $selectedSignalLevel) {
                    ForEach(SignalLevelFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityHint("只筛选当前本地未读信号，不读取或请求其他数据")

                if visibleUnreadSignals.isEmpty {
                    Text("该级别暂无未读信号").foregroundStyle(.secondary)
                } else {
                    ForEach(visibleUnreadSignals) { signal in
                        Button { model.markSignalRead(signal.id) } label: {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(signal.title).font(.headline).foregroundStyle(.primary)
                                    Text("\(signal.code) · \(signal.detail)")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(signal.createdAt.formatted(date: .omitted, time: .shortened))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("已读").font(.caption).foregroundStyle(.blue)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func quoteRow(_ quote: Quote, fallbackName: String, showRemove: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(quote.name.isEmpty ? fallbackName : quote.name).font(.headline)
                HStack(spacing: 5) {
                    Text(quote.code)
                    Text("· \(quote.sourceID)")
                    Text("· \(quote.timestampIsProvider ? quote.timestamp.formatted(date: .omitted, time: .shortened) : "來源時間未知")")
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(quote.price, format: .number.precision(.fractionLength(2)))
                    .foregroundStyle(quote.changePercent >= 0 ? .red : .green)
                Text("\(quote.changePercent, format: .number.precision(.fractionLength(2)))%")
                    .font(.caption).foregroundStyle(quote.changePercent >= 0 ? .red : .green)
            }
            if showRemove {
                Button(role: .destructive) { model.removeCode(quote.code) } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var statusTitle: String {
        switch model.state.phase {
        case .closed: return "未启动"
        case .coldStart: return "恢复本地会话中"
        case .reconciling: return "补齐可用分钟数据中"
        case .live:
            if model.state.isReconciling {
                return model.state.isMarketSession ? "前台监测中 · 补齐中" : "会话已打开 · 补齐中（非交易时段）"
            }
            return model.state.isMarketSession ? "前台监测中" : "会话已打开 · 非交易时段"
        case .paused: return "已暂停"
        case .failed: return "监测启动失败"
        }
    }

    private var statusColor: Color {
        switch model.state.phase {
        case .live: return .green
        case .failed: return .red
        case .coldStart, .reconciling: return .orange
        case .closed, .paused: return .gray
        }
    }

    private func freshnessLabel(_ freshness: SourceFreshness) -> String {
        switch freshness {
        case .fresh: return "来源时间较新"
        case .stale: return "来源时间偏旧"
        case .unknown: return "时间未知"
        case .failed: return "请求失败"
        }
    }

    private func freshnessColor(_ freshness: SourceFreshness) -> Color {
        switch freshness {
        case .fresh: return .green
        case .stale, .unknown: return .orange
        case .failed: return .red
        }
    }
}

private struct RuleFamilySettingsEditor: View {
    let setting: RuleFamilySettings
    let watchCodes: [String]
    let onUpdate: (RuleFamilySettings) -> Void
    @State private var thresholdText: String
    @State private var quietStartText: String
    @State private var quietEndText: String
    @State private var quietError: String?

    init(setting: RuleFamilySettings, watchCodes: [String], onUpdate: @escaping (RuleFamilySettings) -> Void) {
        self.setting = setting; self.watchCodes = watchCodes; self.onUpdate = onUpdate
        let displayedThreshold = setting.family == .majorWatchlistEvent
            ? Double(6 - setting.minimumPriority) : setting.threshold
        _thresholdText = State(initialValue: displayedThreshold == 0 ? "" : String(displayedThreshold))
        _quietStartText = State(initialValue: Self.clockText(setting.quietStartMinute))
        _quietEndText = State(initialValue: Self.clockText(setting.quietEndMinute))
    }

    var body: some View {
        DisclosureGroup {
            Toggle("启用", isOn: Binding(get: { setting.enabled }, set: { value in var next = setting; next.enabled = value; onUpdate(next) }))
            if setting.family == .absolutePrice {
                if watchCodes.isEmpty { Text("先添加自选股，再为每只股票填写高/低价。").font(.caption).foregroundStyle(.secondary) }
                ForEach(watchCodes, id: \.self) { code in
                    AbsolutePriceRuleEditor(setting: setting, code: code, onUpdate: onUpdate)
                }
            } else if setting.family == .movingAverageCross {
                Stepper("短窗口：\(setting.shortWindowBars) 分钟", value: Binding(
                    get: { setting.shortWindowBars },
                    set: { value in var next = setting; next.shortWindowBars = min(value, next.longWindowBars - 1); onUpdate(next) }
                ), in: 1...60)
                Stepper("长窗口：\(setting.longWindowBars) 分钟", value: Binding(
                    get: { setting.longWindowBars },
                    set: { value in var next = setting; next.longWindowBars = max(value, next.shortWindowBars + 1); onUpdate(next) }
                ), in: 2...120)
            } else if setting.family != .sessionBreakout {
                HStack {
                    TextField(setting.family.thresholdLabel, text: $thresholdText).keyboardType(.decimalPad)
                    Button("保存阈值") { saveThreshold() }.buttonStyle(.borderless)
                }
            } else {
                Text("阈值来自本地首次观察到的盘中高点/低点，不推断未观察时段。").font(.caption).foregroundStyle(.secondary)
            }
            if setting.family == .minuteVolumeSurge {
                Stepper("基准完整分钟数：\(setting.baselineBars)", value: binding(\.baselineBars), in: 1...20)
            }
            if setting.family == .relativeStrength {
                Stepper("相对收益窗口：\(Int(setting.windowSeconds / 60)) 分钟",
                    value: timeWindowBinding(in: 5...120), in: 5...120)
            }
            if [.dailyChange, .absolutePrice, .minuteVolumeSurge, .minutePriceSpeed,
                .movingAverageCross, .vwapDeviation, .relativeStrength].contains(setting.family) {
                Stepper("连续确认：\(setting.confirmations) 次", value: binding(\.confirmations), in: 1...20)
            }
            Stepper("冷却：\(Int(setting.cooldownSeconds / 60)) 分钟", value: Binding(
                get: { Int(setting.cooldownSeconds / 60) },
                set: { value in var next = setting; next.cooldownSeconds = TimeInterval(value * 60); onUpdate(next) }
            ), in: 0...240)
            Toggle("仅交易时段", isOn: Binding(get: { setting.sessionOnly }, set: { value in var next = setting; next.sessionOnly = value; onUpdate(next) }))
            HStack {
                TextField("静默开始 HH:mm", text: $quietStartText).keyboardType(.numbersAndPunctuation)
                TextField("结束 HH:mm", text: $quietEndText).keyboardType(.numbersAndPunctuation)
                Button("保存") { saveQuietHours() }.buttonStyle(.borderless)
            }
            if let quietError { Text(quietError).font(.caption).foregroundStyle(.red) }
            if setting.family == .majorWatchlistEvent {
                Text("最低优先级 P\(6 - setting.minimumPriority)；只接受明确匹配自选代码的 P1–P3 事件。").font(.caption).foregroundStyle(.secondary)
            }
            if setting.family == .sectorEventCluster {
                Text("当前：\(setting.minimumIndependentEvents) 个独立事件 / \(setting.minimumSources) 个来源 / \(Int(setting.windowSeconds / 60)) 分钟内含至少一条 P1–P3。").font(.caption).foregroundStyle(.secondary)
                Stepper("最低来源数：\(setting.minimumSources)", value: binding(\.minimumSources), in: 1...10)
                Stepper("聚类时间窗：\(Int(setting.windowSeconds / 60)) 分钟",
                    value: timeWindowBinding(in: 5...240), in: 5...240)
            }
        } label: {
            HStack { Text(setting.family.title); Spacer(); Text(setting.enabled ? "开启" : "关闭").font(.caption).foregroundStyle(setting.enabled ? .green : .secondary) }
        }
        .onChange(of: setting) { _, updated in
            let displayed = updated.family == .majorWatchlistEvent
                ? Double(6 - updated.minimumPriority) : updated.threshold
            thresholdText = displayed == 0 ? "" : String(displayed)
            quietStartText = Self.clockText(updated.quietStartMinute)
            quietEndText = Self.clockText(updated.quietEndMinute)
        }
    }

    private func binding(_ keyPath: WritableKeyPath<RuleFamilySettings, Int>) -> Binding<Int> {
        Binding(get: { setting[keyPath: keyPath] }, set: { value in var next = setting; next[keyPath: keyPath] = value; onUpdate(next) })
    }

    private func timeWindowBinding(in range: ClosedRange<Int>) -> Binding<Int> {
        Binding(get: { Int(setting.windowSeconds / 60) }, set: { minutes in
            var next = setting
            next.windowSeconds = TimeInterval(min(range.upperBound, max(range.lowerBound, minutes)) * 60)
            onUpdate(next)
        })
    }

    private func saveThreshold() {
        guard let value = Double(thresholdText), value.isFinite, value >= 0 else { return }
        var next = setting
        next.threshold = value
        if setting.family == .majorWatchlistEvent {
            let pTier = min(5, max(1, Int(value.rounded())))
            next.minimumPriority = 6 - pTier
            next.threshold = Double(next.minimumPriority)
        }
        if setting.family == .sectorEventCluster { next.minimumIndependentEvents = min(100, max(1, Int(value.rounded()))) }
        onUpdate(next)
    }

    private func saveQuietHours() {
        guard let start = Self.parseClock(quietStartText), let end = Self.parseClock(quietEndText) else {
            if quietStartText.isEmpty && quietEndText.isEmpty {
                var next = setting; next.quietStartMinute = nil; next.quietEndMinute = nil; onUpdate(next); quietError = nil
            } else { quietError = "请使用有效的 HH:mm，或两栏都留空以关闭静默。" }
            return
        }
        var next = setting; next.quietStartMinute = start; next.quietEndMinute = end; onUpdate(next); quietError = nil
    }

    private static func parseClock(_ text: String) -> Int? {
        guard !text.isEmpty else { return nil }
        let parts = text.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), (0...23).contains(h), (0...59).contains(m) else { return nil }
        return h * 60 + m
    }

    private static func clockText(_ value: Int?) -> String {
        guard let value else { return "" }
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}

private struct AbsolutePriceRuleEditor: View {
    let setting: RuleFamilySettings
    let code: String
    let onUpdate: (RuleFamilySettings) -> Void
    @State private var highText: String
    @State private var lowText: String
    @State private var error: String?

    init(setting: RuleFamilySettings, code: String, onUpdate: @escaping (RuleFamilySettings) -> Void) {
        self.setting = setting; self.code = code; self.onUpdate = onUpdate
        _highText = State(initialValue: setting.absoluteHighByCode[code].map { String($0) } ?? "")
        _lowText = State(initialValue: setting.absoluteLowByCode[code].map { String($0) } ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(code).font(.caption)
                TextField("高价", text: $highText).keyboardType(.decimalPad)
                TextField("低价", text: $lowText).keyboardType(.decimalPad)
                Button("保存") {
                    let high = highText.isEmpty ? nil : Double(highText)
                    let low = lowText.isEmpty ? nil : Double(lowText)
                    let validHigh = highText.isEmpty || high.map { $0.isFinite && $0 > 0 } == true
                    let validLow = lowText.isEmpty || low.map { $0.isFinite && $0 > 0 } == true
                    guard validHigh, validLow else {
                        error = "高价/低价须为正数，留空可清除该方向。"
                        return
                    }
                    var next = setting
                    next.setAbsoluteHigh(high, for: code)
                    next.setAbsoluteLow(low, for: code)
                    onUpdate(next)
                    error = nil
                }.buttonStyle(.borderless)
            }
            if let error { Text(error).font(.caption2).foregroundStyle(.red) }
        }
        .onChange(of: setting) { _, updated in
            highText = updated.absoluteHighByCode[code].map { String($0) } ?? ""
            lowText = updated.absoluteLowByCode[code].map { String($0) } ?? ""
        }
    }
}
