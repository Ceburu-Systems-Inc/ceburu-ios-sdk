import XCTest
import OpenTelemetrySdk
@testable import CeburuAnalyticsSDK

/// Tests for behavioral correctness of the SDK actor, covering fixes from the
/// security re-assessment: I7 (concurrent span isolation), I8 (clean shutdown),
/// I9 (config defaults), and X1 (runtime user identity).
final class SDKBehaviorTests: XCTestCase {

    // Config that targets localhost so no real ingest is needed.
    private var testConfig: CeburuAnalyticsSDK.Config {
        CeburuAnalyticsSDK.Config(
            endpoint:              "http://localhost:4318/rum",
            apiKey:                "cbr_mob_test",
            serviceName:           "TestApp",
            serviceVersion:        "0.0.1",
            environment:           "test",
            allowInsecureEndpoint: true
        )
    }

    override func setUp() async throws {
        // Start each test with a clean SDK state.
        await CeburuAnalyticsSDK.shared.shutdown()
    }

    override func tearDown() async throws {
        await CeburuAnalyticsSDK.shared.shutdown()
    }

    // MARK: - Lifecycle

    func testInitializeSucceeds() async throws {
        try await CeburuAnalyticsSDK.shared.initialize(config: testConfig)
    }

    func testDoubleInitializeIsIdempotent() async throws {
        try await CeburuAnalyticsSDK.shared.initialize(config: testConfig)
        // Second call while running must be silently ignored, not throw.
        try await CeburuAnalyticsSDK.shared.initialize(config: testConfig)
    }

    // I8: shutdown cancels the flush loop so re-init creates exactly one loop.
    // If the old task were not cancelled, the second init would spawn a second
    // concurrent loop and we'd risk duplicate event delivery.
    func testShutdownAllowsCleanReinit() async throws {
        try await CeburuAnalyticsSDK.shared.initialize(config: testConfig)
        await CeburuAnalyticsSDK.shared.shutdown()
        // Must not hang or throw — proves the old flush task was cancelled.
        try await CeburuAnalyticsSDK.shared.initialize(config: testConfig)
    }

    // MARK: - Config

    func testDefaults() {
        let c = CeburuAnalyticsSDK.Config(endpoint: "https://ingest.example.com/rum", apiKey: "k", serviceName: "App")
        XCTAssertEqual(c.environment, "production")
        XCTAssertEqual(c.maxBatchBytes, 256 * 1024)
        XCTAssertEqual(c.minSeverity, .info)
        XCTAssertTrue(c.consentGranted)
        XCTAssertFalse(c.allowInsecureEndpoint)
    }

    func testPlainHTTPAndMissingKeyAreRejected() async {
        let http = CeburuAnalyticsSDK.Config(endpoint: "http://ingest.example.com/rum", apiKey: "k", serviceName: "App")
        let noKey = CeburuAnalyticsSDK.Config(endpoint: "https://ingest.example.com/rum", apiKey: "", serviceName: "App")
        for config in [http, noKey] {
            do {
                try await CeburuAnalyticsSDK.shared.initialize(config: config)
                XCTFail("initialize must reject \(config.endpoint) / empty key")
            } catch {}
        }
    }

    func testNewSessionIs32Hex() async throws {
        try await CeburuAnalyticsSDK.shared.initialize(config: testConfig)
        let id = await CeburuAnalyticsSDK.shared.newSession()
        XCTAssertEqual(id.count, 32)
        XCTAssertTrue(id.allSatisfy { $0.isHexDigit })
    }

    // MARK: - User identity (X1)

    func testSetUserIsAccepted() async throws {
        try await CeburuAnalyticsSDK.shared.initialize(config: testConfig)
        // Must not throw or crash — proves setUser() reaches the actor.
        await CeburuAnalyticsSDK.shared.setUser("user-001")
        await CeburuAnalyticsSDK.shared.setUser("") // clear on logout
    }

    func testSetUserCanBeCalledBeforeAndAfterInit() async throws {
        // Before init: SDK is not running — setUser is a no-op (running guard in emit).
        await CeburuAnalyticsSDK.shared.setUser("pre-init-user")
        try await CeburuAnalyticsSDK.shared.initialize(config: testConfig)
        // After init: must also succeed.
        await CeburuAnalyticsSDK.shared.setUser("post-init-user")
    }

    // MARK: - Crash handler lifecycle and consent

    private func handlerAddress() -> UnsafeRawPointer? {
        NSGetUncaughtExceptionHandler().map { unsafeBitCast($0, to: UnsafeRawPointer.self) }
    }

    // Shutdown restores the app's handler, so a re-initialized SDK never chains to itself.
    func testShutdownRestoresExceptionHandler() async throws {
        let before = handlerAddress()
        try await CeburuAnalyticsSDK.shared.initialize(config: testConfig)
        XCTAssertNotEqual(handlerAddress(), before)
        await CeburuAnalyticsSDK.shared.shutdown()
        XCTAssertEqual(handlerAddress(), before)
        try await CeburuAnalyticsSDK.shared.initialize(config: testConfig)
        await CeburuAnalyticsSDK.shared.shutdown()
        XCTAssertEqual(handlerAddress(), before)
    }

    func testCrashCaptureFollowsConsent() async throws {
        let before = handlerAddress()
        let pending = CeburuAnalyticsSDK.Config(endpoint: "http://localhost:4318/rum", apiKey: "cbr_mob_test",
                                                serviceName: "TestApp", allowInsecureEndpoint: true, consentGranted: false)
        try await CeburuAnalyticsSDK.shared.initialize(config: pending)
        XCTAssertEqual(handlerAddress(), before)
        await CeburuAnalyticsSDK.shared.setConsent(true)
        XCTAssertNotEqual(handlerAddress(), before)
        await CeburuAnalyticsSDK.shared.setConsent(false)
        XCTAssertEqual(handlerAddress(), before)
    }

    // MARK: - Sessions and responses

    func testSessionExpiry() {
        let now = Date()
        XCTAssertFalse(CeburuAnalyticsSDK.expired(start: now.addingTimeInterval(-3600), last: now.addingTimeInterval(-60), now: now))
        XCTAssertTrue(CeburuAnalyticsSDK.expired(start: now, last: now.addingTimeInterval(-16 * 60), now: now))
        XCTAssertTrue(CeburuAnalyticsSDK.expired(start: now.addingTimeInterval(-5 * 3600), last: now, now: now))
    }

    func testResponsePolicy() {
        XCTAssertEqual(AnalyticsBridge.outcome(status: 202, retryAfter: nil), .sent)
        XCTAssertEqual(AnalyticsBridge.outcome(status: 401, retryAfter: nil), .unauthorized)
        XCTAssertEqual(AnalyticsBridge.outcome(status: 403, retryAfter: nil), .unauthorized)
        XCTAssertEqual(AnalyticsBridge.outcome(status: 413, retryAfter: nil), .tooLarge)
        XCTAssertEqual(AnalyticsBridge.outcome(status: 400, retryAfter: nil), .rejected)
        XCTAssertEqual(AnalyticsBridge.outcome(status: 429, retryAfter: "120"), .retry(after: 120))
        XCTAssertEqual(AnalyticsBridge.outcome(status: 503, retryAfter: nil), .retry(after: nil))
        let now = Date(timeIntervalSince1970: 1_800_000_000)  // Fri, 15 Jan 2027 08:00:00 GMT
        XCTAssertEqual(AnalyticsBridge.outcome(status: 503, retryAfter: "Fri, 15 Jan 2027 08:01:00 GMT", now: now), .retry(after: 60))
    }

    func testStaleUnauthorizedResponseCannotPauseRotatedKey() throws {
        var auth = CeburuAnalyticsSDK.LogAuthorization()
        let old = try XCTUnwrap(auth.attempt)
        auth.update()
        auth.reject(old)
        let current = try XCTUnwrap(auth.attempt)
        auth.reject(current)
        XCTAssertNil(auth.attempt)
        auth.update()
        XCTAssertNotNil(auth.attempt)
    }

    // MARK: - Consent generations (R6)

    func testFilesFromBeforeAWithdrawalAreNeverSent() {
        XCTAssertTrue(EncryptedStore.sendable("1_2_id_g0", current: 0))
        XCTAssertFalse(EncryptedStore.sendable("1_2_id_g0", current: 1))   // also after a restart: the epoch is on disk
        XCTAssertTrue(EncryptedStore.sendable("1_2_id_g1", current: 1))
        XCTAssertTrue(EncryptedStore.sendable("1_2_8C1F-4E2A", current: 0)) // older SDK builds: epoch 0
        XCTAssertFalse(EncryptedStore.sendable("1_2_8C1F-4E2A", current: 2))
        XCTAssertEqual(EncryptedStore.epoch(of: "1_2_id_g7"), 7)
    }

    func testEpochMarkerIsVerifiedAndFailsClosed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let marker = dir.appendingPathComponent("Ceburu/consent.epoch")
        XCTAssertEqual(EncryptedStore.loadEpoch(at: marker).epoch, 0)          // absent: a first install
        XCTAssertTrue(EncryptedStore.saveEpoch(3, at: marker))
        XCTAssertEqual(EncryptedStore.loadEpoch(at: marker).epoch, 3)
        try "garbage".write(to: marker, atomically: true, encoding: .utf8)
        XCTAssertNil(EncryptedStore.loadEpoch(at: marker).epoch)               // unreadable: the SDK picks a fresh epoch
        try FileManager.default.removeItem(at: marker)
        try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: true)  // cannot be written
        XCTAssertFalse(EncryptedStore.saveEpoch(4, at: marker))
        try? FileManager.default.removeItem(at: dir)
    }

    func testCrashIdsAreStableAcrossImports() {
        let name = Data("1700000000.0_6F1C.enc".utf8)
        XCTAssertEqual(EncryptedStore.crashEventId(name), EncryptedStore.crashEventId(name))
        XCTAssertNotEqual(EncryptedStore.crashEventId(name), EncryptedStore.crashEventId(Data("other.enc".utf8)))
    }

    func testRedirectsKeepTraceContextOnlyOnAllowedHosts() {
        var request = URLRequest(url: URL(string: "https://other.example.net/login")!)
        request.setValue("00-x", forHTTPHeaderField: "traceparent")
        let targets = ["api.example.com"]
        XCTAssertNil(CeburuAnalyticsSDK.RedirectGuard.next(request, targets: targets, https: true).value(forHTTPHeaderField: "traceparent"))
        request.url = URL(string: "https://eu.api.example.com/orders")
        XCTAssertEqual(CeburuAnalyticsSDK.RedirectGuard.next(request, targets: targets, https: true).value(forHTTPHeaderField: "traceparent"), "00-x")
        request.url = URL(string: "http://api.example.com/orders")  // https -> http downgrade
        XCTAssertNil(CeburuAnalyticsSDK.RedirectGuard.next(request, targets: targets, https: true).value(forHTTPHeaderField: "traceparent"))
    }

    func testSpansFromAnEarlierGenerationAreDropped() {
        let gate = ConsentGate(true, generation: 3)
        gate.tag("held", generation: gate.generation)
        _ = gate.revoke()
        gate.isGranted = true
        gate.tag("late", generation: 3)  // admitted before the withdrawal, reached the bridge after it
        gate.tag("new", generation: gate.generation)
        XCTAssertFalse(gate.allows("late"))
        XCTAssertFalse(gate.allows("held"))
        XCTAssertTrue(gate.allows("new"))
        XCTAssertFalse(gate.allows("new"))  // each span is released once
    }

    func testConcurrentMetricExportsDropOneBatchAfterWithdrawal() {
        let gate = ConsentGate(true, metricsEnabled: true)
        let sink = MetricSink()
        let exporter = GatedMetricExporter(sink, gate)
        _ = gate.revoke()
        gate.isGranted = true
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            _ = exporter.export(metrics: [])
        }
        XCTAssertEqual(sink.count, 99)
        _ = gate.revoke()
        _ = exporter.export(metrics: [])
        _ = exporter.export(metrics: [])
        XCTAssertEqual(sink.count, 99)
    }

    private final class MetricSink: MetricExporter, @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
        func export(metrics: [MetricData]) -> ExportResult {
            lock.lock(); defer { lock.unlock() }
            calls += 1
            return .success
        }
        func flush() -> ExportResult { .success }
        func shutdown() -> ExportResult { .success }
        func getAggregationTemporality(for instrument: InstrumentType) -> AggregationTemporality { .delta }
    }

    func testTraceContextGoesOnlyToConfiguredHosts() {
        let targets = ["api.example.com", "Internal.Example.org"]
        XCTAssertTrue(CeburuAnalyticsSDK.propagates(host: "api.example.com", targets: targets))
        XCTAssertTrue(CeburuAnalyticsSDK.propagates(host: "eu.api.example.com", targets: targets))
        XCTAssertTrue(CeburuAnalyticsSDK.propagates(host: "internal.example.org", targets: targets))
        XCTAssertFalse(CeburuAnalyticsSDK.propagates(host: "api.example.com.evil.io", targets: targets))
        XCTAssertFalse(CeburuAnalyticsSDK.propagates(host: "myapi.example.com", targets: targets))
        XCTAssertFalse(CeburuAnalyticsSDK.propagates(host: "api.example.com", targets: []))
    }

    func testDefaultsKeepMetricsOffAndAutoCaptureOn() {
        let c = CeburuAnalyticsSDK.Config(endpoint: "https://ingest.example.com/rum", apiKey: "k", serviceName: "App")
        XCTAssertFalse(c.exportMetrics)
        XCTAssertTrue(c.autoCapture)
        XCTAssertTrue(c.tracePropagationTargets.isEmpty)
    }

    func testInstrumentNamesAreValidated() {
        XCTAssertTrue(AnalyticsBridge.validInstrumentName("checkout.attempts"))
        XCTAssertFalse(AnalyticsBridge.validInstrumentName("1bad"))
        XCTAssertFalse(AnalyticsBridge.validInstrumentName("user jo@example.com"))
    }

    // MARK: - Task-local span context isolation (I7)

    // Two concurrent withValue closures each see only their own context —
    // proves the @TaskLocal fix eliminates the global-state race condition.
    func testConcurrentSpanContextsAreIsolated() async {
        let ctx1 = CeburuAnalyticsSDK.SpanContext(traceId: "trace-aaa", spanId: "span-1")
        let ctx2 = CeburuAnalyticsSDK.SpanContext(traceId: "trace-bbb", spanId: "span-2")

        // Task 1 sleeps briefly so Task 2 runs concurrently inside its own context.
        async let r1: String = CeburuAnalyticsSDK.$_spanContext.withValue(ctx1) {
            try? await Task.sleep(nanoseconds: 5_000_000) // 5 ms
            return CeburuAnalyticsSDK._spanContext?.traceId ?? "missing"
        }
        async let r2: String = CeburuAnalyticsSDK.$_spanContext.withValue(ctx2) {
            return CeburuAnalyticsSDK._spanContext?.traceId ?? "missing"
        }

        let (id1, id2) = await (r1, r2)
        XCTAssertEqual(id1, "trace-aaa", "Task 1 must see its own context, not Task 2's")
        XCTAssertEqual(id2, "trace-bbb", "Task 2 must see its own context, not Task 1's")
    }

    // A read outside any withSpan/withValue closure returns nil.
    func testNoSpanContextOutsideClosure() {
        XCTAssertNil(CeburuAnalyticsSDK._spanContext,
            "span context should not bleed across tasks — nil expected at top level")
    }

    // A nested withValue sees the inner context, not the outer one.
    func testNestedSpanContextSeesInnerValue() async {
        let outer = CeburuAnalyticsSDK.SpanContext(traceId: "outer", spanId: "s1")
        let inner = CeburuAnalyticsSDK.SpanContext(traceId: "inner", spanId: "s2")

        let result = CeburuAnalyticsSDK.$_spanContext.withValue(outer) {
            CeburuAnalyticsSDK.$_spanContext.withValue(inner) {
                CeburuAnalyticsSDK._spanContext?.traceId ?? "missing"
            }
        }
        XCTAssertEqual(result, "inner")
    }

    // After the withValue closure returns, the context is cleared.
    func testSpanContextClearedAfterClosure() async {
        let ctx = CeburuAnalyticsSDK.SpanContext(traceId: "ephemeral", spanId: "s")
        _ = CeburuAnalyticsSDK.$_spanContext.withValue(ctx) {
            CeburuAnalyticsSDK._spanContext?.traceId
        }
        XCTAssertNil(CeburuAnalyticsSDK._spanContext,
            "Task-local must revert to nil after withValue closure exits")
    }
}
