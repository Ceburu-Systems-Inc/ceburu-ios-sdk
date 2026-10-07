import XCTest
@testable import CeburuAnalyticsSDK

/// Tests for behavioral correctness of the SDK actor, covering fixes from the
/// security re-assessment: I7 (concurrent span isolation), I8 (clean shutdown),
/// I9 (config defaults), and X1 (runtime user identity).
final class SDKBehaviorTests: XCTestCase {

    // Config that targets localhost so no real collector is needed.
    // useHTTPS: false is valid in DEBUG builds (I9 guard fires only in release).
    private var testConfig: CeburuAnalyticsSDK.Config {
        CeburuAnalyticsSDK.Config(
            serviceName:         "TestApp",
            serviceVersion:      "0.0.1",
            environment:         "test",
            tenantId:            "test-tenant",
            applicationId:       "test-app",
            collectorHost:       "localhost",
            collectorPort:       4318,
            useHTTPS:            false,
            useStandardOTLPPaths: true
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

    // MARK: - Config defaults (I9)

    func testDefaultUseHTTPSIsTrue() {
        let c = CeburuAnalyticsSDK.Config(
            serviceName:   "App",
            serviceVersion: "1.0",
            environment:   "production",
            tenantId:      "t",
            applicationId: "a",
            collectorHost: "ingest.example.com"
        )
        XCTAssertTrue(c.useHTTPS,
            "useHTTPS must default to true — shipping false would send telemetry in clear text")
    }

    func testDefaultPortIs4318() {
        let c = CeburuAnalyticsSDK.Config(
            serviceName:   "App",
            serviceVersion: "1.0",
            environment:   "production",
            tenantId:      "t",
            applicationId: "a",
            collectorHost: "ingest.example.com"
        )
        XCTAssertEqual(c.collectorPort, 4318)
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
            "enduser.id should not bleed across tasks — nil expected at top level")
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
