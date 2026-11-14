import XCTest
@testable import StockMonitorCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class MarketCoverageSourcesTests: XCTestCase {
    func testLocalLimitsClassifyBoardsAndPreserveIPOAndUnknown() {
        let source = LocalDailyLimitSource()
        let base = Quote(code: "600000", name: "浦发银行", timestamp: Date(), price: 11, previousClose: 10,
                         open: 10, high: 10, low: 10, volume: 1)
        XCTAssertEqual(source.limit(for: base).availability, .computed)
        XCTAssertEqual(source.limit(for: base).pair, LimitPair(up: 11, down: 9))
        XCTAssertTrue(source.limit(for: base).note.contains("假设非上市前5日"))
        XCTAssertEqual(source.limit(for: base, listingSessionIndex: 5).availability, .unavailable)
        XCTAssertNil(source.limit(for: base, listingSessionIndex: 5).pair)
        XCTAssertTrue(source.limit(for: base, listingSessionIndex: 5).note.contains("无价格"))
        XCTAssertEqual(source.limit(code: "688001", previousClose: 10).pair, LimitPair(up: 12, down: 8))
        XCTAssertEqual(source.limit(code: "300001", previousClose: 10).pair, LimitPair(up: 12, down: 8))
        XCTAssertEqual(source.limit(code: "000001", previousClose: 10).pair, LimitPair(up: 11, down: 9))
        XCTAssertEqual(source.limit(code: "830001", previousClose: 10).pair, LimitPair(up: 13, down: 7))
        XCTAssertEqual(source.limit(code: "600001", name: "ST示例", previousClose: 10).pair, LimitPair(up: 11, down: 9))
        XCTAssertTrue(source.limit(code: "000001", name: "*ST示例", previousClose: 10).note.contains("2026规则10%"))
        XCTAssertEqual(source.limit(code: "920001", previousClose: 10, listingSessionIndex: 1).availability, .unavailable)
        XCTAssertTrue(source.limit(code: "920001", previousClose: 10, listingSessionIndex: 1).note.contains("北交所上市首日"))
        XCTAssertEqual(source.limit(code: "920001", previousClose: 10, listingSessionIndex: 2).pair, LimitPair(up: 13, down: 7))
        XCTAssertEqual(source.limit(code: "600001", name: "退市整理示例", previousClose: 10).availability, .unavailable)
        XCTAssertNil(source.limit(code: "600001", name: "退市整理示例", previousClose: 10).pair)
        XCTAssertEqual(source.limit(code: "600001", previousClose: 0.03).pair, LimitPair(up: 0.04, down: 0.02))
        XCTAssertEqual(source.limit(code: "999999", previousClose: 10).availability, .unavailable)
        XCTAssertEqual(source.limit(code: "600001", previousClose: 0).availability, .unavailable)
    }

    func testScanParsesFixtureWithoutFillingMissingValuesAndAggregatesF62() async throws {
        let data = try fixture("eastmoney-scan-firstpage.json")
        let session = mockedSession(data: data, status: 200, contentType: "application/json")
        let budget = RequestBudget(policies: ["127.0.0.1": .init(requestsPerSecond: 100, maximumPerSession: 10)])
        let source = EastmoneyMarketScanSource(session: session, budget: budget, baseURL: URL(string: "http://127.0.0.1/clist")!)
        let result = try await source.fetch(pageSize: 100, topN: 2)
        XCTAssertEqual(result.quotes.count, 5)
        XCTAssertEqual(result.topByPercent.first?.code, "300528")
        XCTAssertEqual(result.summary.up, 5)
        XCTAssertEqual(result.summary.down, 0)
        XCTAssertEqual(try XCTUnwrap(result.summary.amount), 5_496_350_254.44, accuracy: 0.1)
        let expectedMainNetFlow: Double = 224_442_764 + 137_741_436 + 409_659_143 + 50_368_192 + 2_767_671
        XCTAssertEqual(try XCTUnwrap(result.summary.mainNetFlow), expectedMainNetFlow, accuracy: 0.1)
        XCTAssertNil(result.summary.limitUp)
        XCTAssertNil(result.summary.brokenSeal)
        XCTAssertEqual(result.reportedTotalCount, 5_929)
        XCTAssertEqual(result.summary.reportedTotalCount, 5_929)
        XCTAssertEqual(result.uniqueReturnedCount, 5)
        XCTAssertEqual(result.summary.uniqueReturnedCount, 5)
        XCTAssertTrue(result.coverageIncomplete)
        XCTAssertFalse(result.coverageComplete)
        XCTAssertEqual(try XCTUnwrap(result.summary.sampleCoverageFraction), 5.0 / 5_929.0, accuracy: 1e-12)
        XCTAssertEqual(result.quotes.first?.changePercent, 20.01)
        XCTAssertEqual(result.quotes.first?.turnover, 16.3)
        XCTAssertEqual(result.quotes.first?.volumeRatio, 1.92)
        XCTAssertEqual(result.quotes.first?.pe, -133.36)
        XCTAssertNil(result.quotes.first?.totalMarketValue)
        XCTAssertEqual(result.status.requestCount, 1)
        XCTAssertTrue(result.status.note?.contains("f62") == true)
        let distribution = try XCTUnwrap(MarketScanDistribution.summarize(quotes: result.quotes))
        XCTAssertEqual(result.summary.changeBuckets, distribution.buckets)
        XCTAssertEqual(result.summary.changeBuckets?.reduce(0) { $0 + $1.count }, 5)
        XCTAssertEqual(distribution.sampleCount, 5)
        XCTAssertEqual(distribution.buckets.reduce(0) { $0 + $1.count }, 5)
        XCTAssertGreaterThan(distribution.meanPercentPoints, 0)
    }

    func testDistributionUsesPercentagePointsAndExcludesNonFiniteChanges() throws {
        let values: [Double?] = [-6, -4, -2, -0.5, 0, 0.5, 2, 4, 6, nil, .nan]
        let quotes = values.enumerated().map { scanQuote("code-\($0.offset)", change: $0.element) }
        let distribution = try XCTUnwrap(MarketScanDistribution.summarize(quotes: quotes))

        XCTAssertEqual(distribution.sampleCount, 9)
        XCTAssertEqual(distribution.meanPercentPoints, 0, accuracy: 1e-12)
        XCTAssertEqual(distribution.medianPercentPoints, 0, accuracy: 1e-12)
        XCTAssertEqual(distribution.buckets.map(\.count), Array(repeating: 1, count: 9))
        XCTAssertNil(MarketScanDistribution.summarize(quotes: [scanQuote("missing", change: nil)]))
    }

    func testUniverseUsesReportedTotalAndKeepsUniqueCoverageCounts() async throws {
        let data = try fixture("eastmoney-scan-firstpage.json")
        let session = mockedSession(data: data, status: 200, contentType: "application/json")
        let budget = RequestBudget(policies: ["127.0.0.1": .init(requestsPerSecond: 100, maximumPerSession: 10)])
        let source = EastmoneyMarketScanSource(session: session, budget: budget,
            maximumPages: 2, maximumSecurities: 10, baseURL: URL(string: "http://127.0.0.1/clist")!)

        let result = try await source.fetchUniverse(pageSize: 5, topN: 5)

        XCTAssertEqual(result.status.requestCount, 1)
        XCTAssertEqual(result.status.returnedCount, 5)
        XCTAssertEqual(result.quotes.count, 5)
        XCTAssertEqual(result.summary.up + result.summary.flat + result.summary.down, 5)
        XCTAssertEqual(result.summary.reportedTotalCount, 5_929)
        XCTAssertEqual(try XCTUnwrap(result.summary.sampleCoverageFraction), 5.0 / 5_929.0, accuracy: 1e-12)
        XCTAssertTrue(result.status.note?.contains("Partial/incomplete coverage") == true)
        XCTAssertEqual(result.duplicateRowCount, 0)
    }

    func testUniverseExposesTruncationWhenReportedTotalExceedsSecurityCap() async throws {
        let data = try fixture("eastmoney-scan-firstpage.json")
        MockURLProtocol.lastRequestURL = nil
        let session = mockedSession(data: data, status: 200, contentType: "application/json")
        let budget = RequestBudget(policies: ["127.0.0.1": .init(requestsPerSecond: 100, maximumPerSession: 10)])
        let source = EastmoneyMarketScanSource(session: session, budget: budget,
            maximumPages: 60, maximumSecurities: 100, baseURL: URL(string: "http://127.0.0.1/clist")!)

        let result = try await source.fetchUniverse(pageSize: 5, topN: 1)

        let requestURL = try XCTUnwrap(MockURLProtocol.lastRequestURL)
        let query = Dictionary(uniqueKeysWithValues: try XCTUnwrap(
            URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?.queryItems)
            .map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["pz"], "100")
        XCTAssertEqual(result.reportedTotalCount, 5_929)
        XCTAssertEqual(result.uniqueReturnedCount, 5)
        XCTAssertTrue(result.truncated)
        XCTAssertTrue(result.coverageIncomplete)
        XCTAssertFalse(result.coverageComplete)
        XCTAssertEqual(result.summary.sampleCoverageFraction ?? 0, 5.0 / 5_929.0, accuracy: 1e-12)
    }

    func testUniverseDerivesPageCountFromProviderTotalAndUsesHundredRowPages() async throws {
        let session = mockedSession(data: Data(), status: 200, contentType: "application/json")
        MockURLProtocol.pagePayloads = [
            1: try scanPage(total: 250, indices: 1...100),
            2: try scanPage(total: 250, indices: 101...200),
            3: try scanPage(total: 250, indices: 201...250)
        ]
        let budget = RequestBudget(policies: ["127.0.0.1": .init(requestsPerSecond: 100, maximumPerSession: 10)])
        let source = EastmoneyMarketScanSource(session: session, budget: budget,
            maximumPages: 10, maximumSecurities: 1_000, baseURL: URL(string: "http://127.0.0.1/clist")!)

        let result = try await source.fetchUniverse(pageSize: 10, topN: 5)
        let queries = try MockURLProtocol.lastRequestURLs.map { url -> [String: String] in
            Dictionary(uniqueKeysWithValues: try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
                .map { ($0.name, $0.value ?? "") })
        }

        XCTAssertEqual(queries.compactMap { $0["pn"] }, ["1", "2", "3"])
        XCTAssertTrue(queries.allSatisfy { $0["pz"] == "100" })
        XCTAssertEqual(result.status.requestCount, 3)
        XCTAssertEqual(result.uniqueReturnedCount, 250)
        XCTAssertEqual(result.reportedTotalCount, 250)
        XCTAssertTrue(result.coverageComplete, "Complete means aligned to clist's reported total, not an exchange-verified universe")
        XCTAssertFalse(result.truncated)
        XCTAssertEqual(result.coverageFraction, 1)
    }

    func testDuplicateRowsAreDeduplicatedAndPreventCompleteCoverage() async throws {
        let session = mockedSession(data: Data(), status: 200, contentType: "application/json")
        MockURLProtocol.pagePayloads = [
            1: try scanPage(total: 200, indices: 1...100),
            2: try scanPage(total: 200, indices: 91...190)
        ]
        let budget = RequestBudget(policies: ["127.0.0.1": .init(requestsPerSecond: 100, maximumPerSession: 10)])
        let source = EastmoneyMarketScanSource(session: session, budget: budget,
            maximumPages: 2, maximumSecurities: 200, baseURL: URL(string: "http://127.0.0.1/clist")!)

        let result = try await source.fetchUniverse()

        XCTAssertEqual(result.status.requestCount, 2)
        XCTAssertEqual(result.uniqueReturnedCount, 190)
        XCTAssertEqual(result.duplicateRowCount, 10)
        XCTAssertFalse(result.coverageComplete)
        XCTAssertTrue(result.coverageIncomplete)
        XCTAssertEqual(result.coverageFraction ?? 0, 0.95, accuracy: 1e-12)
    }

    func testMissingProviderTotalStopsAfterOnePageAndKeepsCoverageUnknown() async throws {
        let session = mockedSession(data: Data(), status: 200, contentType: "application/json")
        MockURLProtocol.pagePayloads = [
            1: try scanPage(total: nil, indices: 1...100),
            2: try scanPage(total: 200, indices: 101...200)
        ]
        let budget = RequestBudget(policies: ["127.0.0.1": .init(requestsPerSecond: 100, maximumPerSession: 10)])
        let source = EastmoneyMarketScanSource(session: session, budget: budget,
            maximumPages: 60, maximumSecurities: 6_000, baseURL: URL(string: "http://127.0.0.1/clist")!)

        let result = try await source.fetchUniverse()

        XCTAssertEqual(result.status.requestCount, 1)
        XCTAssertEqual(MockURLProtocol.lastRequestURLs.count, 1)
        XCTAssertNil(result.reportedTotalCount)
        XCTAssertNil(result.coverageFraction)
        XCTAssertTrue(result.coverageIncomplete)
        XCTAssertFalse(result.coverageComplete)
    }

    func testExactSecurityCapDoesNotReturnRemainderOfLastPage() async throws {
        let session = mockedSession(data: Data(), status: 200, contentType: "application/json")
        MockURLProtocol.pagePayloads = [
            1: try scanPage(total: 200, indices: 1...100),
            2: try scanPage(total: 200, indices: 101...200)
        ]
        let budget = RequestBudget(policies: ["127.0.0.1": .init(requestsPerSecond: 100, maximumPerSession: 10)])
        let source = EastmoneyMarketScanSource(session: session, budget: budget,
            maximumPages: 60, maximumSecurities: 150, baseURL: URL(string: "http://127.0.0.1/clist")!)

        let result = try await source.fetchUniverse()

        XCTAssertEqual(result.quotes.count, 150)
        XCTAssertEqual(result.uniqueReturnedCount, 150)
        XCTAssertTrue(result.truncated)
        XCTAssertFalse(result.coverageComplete)
        XCTAssertEqual(result.coverageFraction ?? 0, 0.75, accuracy: 1e-12)
    }

    func testScanRejectsHTMLAndNon2xx() async {
        let html = Data("<html>challenge</html>".utf8)
        let session = mockedSession(data: html, status: 200, contentType: "text/html")
        let budget = RequestBudget(policies: ["127.0.0.1": .init(requestsPerSecond: 100, maximumPerSession: 10)])
        let source = EastmoneyMarketScanSource(session: session, budget: budget, baseURL: URL(string: "http://127.0.0.1/clist")!)
        do { _ = try await source.fetch(); XCTFail("expected HTML challenge rejection") }
        catch QuoteSourceError.responseFailure(statusCode: 200, kind: .htmlChallenge) { }
        catch { XCTFail("wrong error: \(error)") }
    }

    func testLimitUpDataNullIsUnknownNotZero() async throws {
        let data = try fixture("eastmoney-limit-up-pool-20261113.json")
        let session = mockedSession(data: data, status: 200, contentType: "application/json")
        let budget = RequestBudget(policies: ["127.0.0.1": .init(requestsPerSecond: 100, maximumPerSession: 10)])
        let source = EastmoneyLimitUpPoolSource(session: session, budget: budget, baseURL: URL(string: "http://127.0.0.1/pool")!)
        let outcome = try await source.fetch(date: "20261113")
        XCTAssertEqual(outcome.availability, .unknown)
        XCTAssertNil(outcome.rawCount)
        XCTAssertTrue(outcome.note.contains("unknown"))
        XCTAssertEqual(outcome.status.requestCount, 1)
    }

    func testProvidedUTRequestUsesPublicContractAndRc206RemainsUnknown() async throws {
        let data = try fixture("eastmoney-limit-up-pool-ut-rc206-20261113.json")
        MockURLProtocol.lastRequestURL = nil
        let session = mockedSession(data: data, status: 200, contentType: "application/json")
        let budget = RequestBudget(policies: ["127.0.0.1": .init(requestsPerSecond: 100, maximumPerSession: 10)])
        let source = EastmoneyLimitUpPoolSource(session: session, budget: budget,
            baseURL: URL(string: "http://127.0.0.1/pool")!)

        let outcome = try await source.fetch(date: "20261113")

        let requestURL = try XCTUnwrap(MockURLProtocol.lastRequestURL)
        let query = Dictionary(uniqueKeysWithValues: try XCTUnwrap(
            URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?.queryItems)
            .map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["ut"], EastmoneyLimitUpPoolSource.requestUT)
        XCTAssertEqual(query["dpt"], "wzttz")
        XCTAssertEqual(query["Pageindex"], "0")
        XCTAssertEqual(query["pagesize"], "100")
        XCTAssertEqual(query["date"], "20261113")
        XCTAssertEqual(outcome.availability, .unknown)
        XCTAssertNil(outcome.rawCount)
        XCTAssertNil(outcome.boards)
        XCTAssertNil(outcome.openTimes)
        XCTAssertNil(outcome.fdAmount)
        XCTAssertEqual(outcome.status.returnedCount, 0)
    }

    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Fixtures/").appendingPathComponent(name)
        return try Data(contentsOf: url)
    }

    private func scanPage(total: Int?, indices: ClosedRange<Int>) throws -> Data {
        let rows: [[String: Any]] = indices.map { index in
            ["f12": String(format: "%06d", index), "f14": "fixture-\(index)", "f3": 100, "f6": 1_000]
        }
        var response: [String: Any] = ["diff": rows]
        if let total { response["total"] = total }
        return try JSONSerialization.data(withJSONObject: ["data": response])
    }

    private func mockedSession(data: Data, status: Int, contentType: String) -> URLSession {
        MockURLProtocol.payload = data
        MockURLProtocol.status = status
        MockURLProtocol.contentType = contentType
        MockURLProtocol.pagePayloads = [:]
        MockURLProtocol.lastRequestURL = nil
        MockURLProtocol.lastRequestURLs = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func scanQuote(_ code: String, change: Double?) -> EastmoneyScanQuote {
        EastmoneyScanQuote(code: code, name: code, market: nil, price: nil,
            changePercent: change, change: nil, volume: nil, amount: nil,
            turnover: nil, pe: nil, volumeRatio: nil, totalMarketValue: nil,
            mainNetFlow: nil, providerTimestamp: nil, raw: [:])
    }
}

private final class MockURLProtocol: URLProtocol {
    static var payload = Data()
    static var status = 200
    static var contentType = "application/json"
    static var lastRequestURL: URL?
    static var lastRequestURLs: [URL] = []
    static var pagePayloads: [Int: Data] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequestURL = request.url
        if let url = request.url { Self.lastRequestURLs.append(url) }
        let page = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first(where: { $0.name == "pn" })?.value.flatMap(Int.init)
        let payload = page.flatMap { Self.pagePayloads[$0] } ?? Self.payload
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status,
            httpVersion: nil, headerFields: ["Content-Type": Self.contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
