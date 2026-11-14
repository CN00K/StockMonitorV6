import Foundation
import XCTest
@testable import StockMonitorCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class ConditionalHTTPResponseCacheTests: XCTestCase {
    override func tearDown() {
        MockConditionalURLProtocol.reset()
        super.tearDown()
    }

    func testConditionalHeadersAnd304ReuseCachedBody() async throws {
        let url = URL(string: "https://fixture.invalid/quote?symbol=600000")!
        let body = Data("cached-body".utf8)
        let cache = ConditionalHTTPResponseCache(maximumBodyBytes: 1024, maximumTotalBytes: 2048)
        var calls = 0
        MockConditionalURLProtocol.handler = { request in
            calls += 1
            if calls == 1 {
                return (200, ["ETag": "\"v1\"", "Last-Modified": "Wed, 01 Jan 2025 00:00:00 GMT"], body)
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "\"v1\"")
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-Modified-Since"), "Wed, 01 Jan 2025 00:00:00 GMT")
            return (304, [:], Data())
        }
        let session = makeSession()
        let first = try await cache.fetch(URLRequest(url: url), using: session)
        let second = try await cache.fetch(URLRequest(url: url), using: session)
        XCTAssertEqual(first.data, body)
        XCTAssertEqual(second.data, body)
        XCTAssertTrue(second.reused304)
        XCTAssertEqual(second.response.statusCode, 200)
    }

    func test304WithoutCachedBodyIsAnError() async throws {
        MockConditionalURLProtocol.handler = { _ in (304, [:], Data()) }
        let cache = ConditionalHTTPResponseCache()
        do {
            _ = try await cache.fetch(URLRequest(url: URL(string: "https://fixture.invalid/miss")!), using: makeSession())
            XCTFail("A 304 without a cached body must fail")
        } catch let error as QuoteSourceError {
            XCTAssertEqual(error.localizedDescription, QuoteSourceError.conditionalResponseWithoutCachedBody.localizedDescription)
        }
    }

    func testPerBodyAndTotalCapsEvictLeastRecentlyUsedEntry() async throws {
        MockConditionalURLProtocol.handler = { request in
            let body = Data((request.url?.path ?? "").utf8)
            return (200, ["ETag": request.url?.lastPathComponent ?? "tag"], body)
        }
        let cache = ConditionalHTTPResponseCache(maximumBodyBytes: 4, maximumTotalBytes: 8)
        let session = makeSession()
        for path in ["/aaa", "/bbb", "/ccc"] {
            _ = try await cache.fetch(URLRequest(url: URL(string: "https://fixture.invalid\(path)")!), using: session)
        }
        let entryCount = await cache.entryCount()
        let storedBytes = await cache.storedByteCount()
        XCTAssertEqual(entryCount, 2)
        XCTAssertEqual(storedBytes, 8)

        let oversized = ConditionalHTTPResponseCache(maximumBodyBytes: 3, maximumTotalBytes: 8)
        _ = try await oversized.fetch(URLRequest(url: URL(string: "https://fixture.invalid/long")!), using: session)
        let oversizedCount = await oversized.entryCount()
        let oversizedBytes = await oversized.storedByteCount()
        XCTAssertEqual(oversizedCount, 0)
        XCTAssertEqual(oversizedBytes, 0)
    }

    func testNormalResponseIsReturnedAndStored() async throws {
        let body = Data("normal".utf8)
        MockConditionalURLProtocol.handler = { _ in (200, ["ETag": "normal"], body) }
        let cache = ConditionalHTTPResponseCache()
        let result = try await cache.fetch(URLRequest(url: URL(string: "https://fixture.invalid/normal")!), using: makeSession())
        XCTAssertEqual(result.data, body)
        XCTAssertFalse(result.reused304)
        let entryCount = await cache.entryCount()
        let storedBytes = await cache.storedByteCount()
        XCTAssertEqual(entryCount, 1)
        XCTAssertEqual(storedBytes, body.count)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockConditionalURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class MockConditionalURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) -> (status: Int, headers: [String: String], body: Data)
    private static let lock = NSLock()
    private static var currentHandler: Handler?

    static var handler: Handler? {
        get { lock.lock(); defer { lock.unlock() }; return currentHandler }
        set { lock.lock(); currentHandler = newValue; lock.unlock() }
    }

    static func reset() { handler = nil }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        let result = handler(request)
        guard let response = HTTPURLResponse(url: url, statusCode: result.status,
                                             httpVersion: nil, headerFields: result.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !result.body.isEmpty { client?.urlProtocol(self, didLoad: result.body) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
