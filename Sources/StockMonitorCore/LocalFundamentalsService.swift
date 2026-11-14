import Foundation

public protocol MarketFundamentalsProviding: Sendable {
    func fetch(code: String) async throws -> EastmoneyFundamentalSnapshot
}

extension EastmoneyFundamentalsSource: MarketFundamentalsProviding {}

public struct FundamentalsRefreshReport: Sendable, Equatable {
    public let snapshots: [EastmoneyFundamentalSnapshot]
    public let requestedCodes: [String]
    public let skippedCodes: [String]
    public let status: SourceStatus

    public init(snapshots: [EastmoneyFundamentalSnapshot], requestedCodes: [String],
                skippedCodes: [String], status: SourceStatus) {
        self.snapshots = snapshots
        self.requestedCodes = requestedCodes
        self.skippedCodes = skippedCodes
        self.status = status
    }
}

/// Explicit, bounded fetch-and-cache service for current Eastmoney F10 fields.
/// It never runs on a timer and never fabricates historical point-in-time values.
public struct LocalFundamentalsService: Sendable {
    private let source: any MarketFundamentalsProviding
    private let store: SQLiteMonitorStore
    private let maximumCodes: Int

    public init(source: any MarketFundamentalsProviding, store: SQLiteMonitorStore,
                maximumCodes: Int = 10) {
        self.source = source
        self.store = store
        self.maximumCodes = min(50, max(1, maximumCodes))
    }

    public func refresh(codes: [String]) async -> FundamentalsRefreshReport {
        let validCodes = Array(Set(codes.filter(Self.isSixDigitCode))).sorted()
        let selected = Array(validCodes.prefix(maximumCodes))
        let skipped = Array(validCodes.dropFirst(selected.count))
        var snapshots: [EastmoneyFundamentalSnapshot] = []
        var errors: [String] = []
        var requestAttempts = 0
        for code in selected {
            guard !Task.isCancelled else { break }
            requestAttempts += 1
            do {
                let fetched = try await source.fetch(code: code)
                if let returnedCode = fetched.code, returnedCode != code {
                    errors.append("\(code): response identified as \(returnedCode)")
                    continue
                }
                snapshots.append(Self.withCode(fetched, code: code))
            } catch is CancellationError {
                break
            } catch {
                errors.append("\(code): \(error.localizedDescription)")
            }
        }

        do {
            try await store.open()
            try await store.upsertFundamentalSnapshots(snapshots)
        } catch {
            errors.append("local SQLite: \(error.localizedDescription)")
        }
        let noteParts = [
            "Unofficial current Eastmoney F10 snapshot; unsupported fields remain nil and are not suitable as historical point-in-time fundamentals.",
            skipped.isEmpty ? nil : "Capped at \(maximumCodes) codes; remaining symbols were not queried.",
            Task.isCancelled ? "Refresh cancelled." : nil
        ].compactMap { $0 }
        let status = SourceStatus(sourceID: "eastmoney-fundamentals", fetchedAt: Date(),
            providerTimestamp: snapshots.map(\.fetchedAt).max(), requestedCount: validCodes.count,
            returnedCount: snapshots.count, requestCount: requestAttempts,
            error: errors.isEmpty ? nil : errors.joined(separator: "; "), note: noteParts.joined(separator: " "))
        return FundamentalsRefreshReport(snapshots: snapshots, requestedCodes: validCodes,
            skippedCodes: skipped, status: status)
    }

    public func latest(codes: [String]) async throws -> [EastmoneyFundamentalSnapshot] {
        try await store.open()
        return try await store.latestFundamentalSnapshots(codes: codes)
    }

    public func latestFactorObservations(codes: [String]) async throws -> [String: FactorObservation] {
        let snapshots = try await latest(codes: codes)
        return Dictionary(uniqueKeysWithValues: snapshots.compactMap { snapshot in
            guard let code = snapshot.code else { return nil }
            return (code, snapshot.factorObservation)
        })
    }

    private static func withCode(_ value: EastmoneyFundamentalSnapshot, code: String) -> EastmoneyFundamentalSnapshot {
        EastmoneyFundamentalSnapshot(code: code, name: value.name, peDynamic: value.peDynamic,
            pb: value.pb, totalMarketValue: value.totalMarketValue,
            floatMarketValue: value.floatMarketValue, roe: value.roe,
            grossMargin: value.grossMargin, netMargin: value.netMargin,
            netProfit: value.netProfit, industry: value.industry,
            unavailableFields: value.unavailableFields, sourceID: value.sourceID,
            fetchedAt: value.fetchedAt)
    }

    private static func isSixDigitCode(_ code: String) -> Bool {
        code.range(of: "^[0-9]{6}$", options: .regularExpression) != nil
    }
}
