import XCTest
import OpenTelemetryApi
@testable import CeburuAnalyticsSDK

/// Answers every request with 200 and a 2-byte body, so the network delegate can be checked without a network.
final class OKProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("ok".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Body sizes and protocol from `URLSessionTaskMetrics` on network spans.
final class NetworkCaptureTests: XCTestCase {

    func testSizesAndProtocol() {
        let a = NetworkMetrics(requestBodyBytes: 120, responseBodyBytes: 4096, protocolName: "h2").attributes
        XCTAssertEqual(a["http.request.body.size"], .int(120))
        XCTAssertEqual(a["http.response.body.size"], .int(4096))
        XCTAssertEqual(a["network.protocol.name"], .string("http"))
        XCTAssertEqual(a["network.protocol.version"], .string("2"))
        XCTAssertEqual(a.count, 4)
    }

    func testZeroBodyIsSentAndMissingProtocolIsLeftOut() {
        let a = NetworkMetrics(requestBodyBytes: 0, responseBodyBytes: 10, protocolName: nil).attributes
        XCTAssertEqual(a["http.request.body.size"], .int(0))
        XCTAssertEqual(a["http.response.body.size"], .int(10))
        XCTAssertNil(a["network.protocol.name"])
        XCTAssertNil(a["network.protocol.version"])
    }

    func testEmptyMetricsHaveNoAttributes() {
        XCTAssertTrue(NetworkMetrics().attributes.isEmpty)
    }

    func testProtocolParts() {
        XCTAssertTrue(NetworkMetrics.protocolParts("http/1.1")! == ("http", "1.1"))
        XCTAssertTrue(NetworkMetrics.protocolParts("H2")! == ("http", "2"))
        XCTAssertTrue(NetworkMetrics.protocolParts("h3")! == ("http", "3"))
        XCTAssertTrue(NetworkMetrics.protocolParts("h3-29")! == ("http", "3"))
        XCTAssertTrue(NetworkMetrics.protocolParts("spdy")! == ("spdy", nil))
        XCTAssertNil(NetworkMetrics.protocolParts(nil))
        XCTAssertNil(NetworkMetrics.protocolParts(" "))
    }

    /// The task delegate used by `data(for:)` has the metrics by the time the request returns.
    func testDelegateCollectsMetricsBeforeDataReturns() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OKProtocol.self]
        let session = URLSession(configuration: configuration)
        let delegate = CeburuAnalyticsSDK.NetworkTaskDelegate(targets: nil, https: true)
        var request = URLRequest(url: URL(string: "https://api.example.com/items")!)
        request.httpMethod = "POST"
        request.httpBody = Data("hello".utf8)
        _ = try await session.data(for: request, delegate: delegate)
        let metrics = try XCTUnwrap(delegate.metrics)
        XCTAssertNotNil(metrics.responseBodyBytes)
        XCTAssertNotNil(metrics.requestBodyBytes)
    }

    func testExistingTraceparentIsNeverOverwritten() {
        var request = URLRequest(url: URL(string: "https://api.example.com/x")!)
        request.setValue("00-app", forHTTPHeaderField: "traceparent")
        XCTAssertEqual(CeburuAnalyticsSDK.withTraceparent(request, header: "00-sdk").value(forHTTPHeaderField: "traceparent"), "00-app")
        let plain = URLRequest(url: URL(string: "https://api.example.com/x")!)
        XCTAssertEqual(CeburuAnalyticsSDK.withTraceparent(plain, header: "00-sdk").value(forHTTPHeaderField: "traceparent"), "00-sdk")
        XCTAssertNil(CeburuAnalyticsSDK.withTraceparent(plain, header: nil).value(forHTTPHeaderField: "traceparent"))
    }
}
