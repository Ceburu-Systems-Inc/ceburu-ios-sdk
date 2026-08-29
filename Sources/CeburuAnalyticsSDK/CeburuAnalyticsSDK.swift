import Foundation
#if canImport(UIKit)
import UIKit
#endif
@preconcurrency import OpenTelemetryApi

/// Main entry point for the Ceburu Analytics SDK.
///
/// `CeburuAnalyticsSDK` is a Swift `actor` — all public methods are isolated to its executor.
/// Call `await` on every method (except fire-and-forget helpers noted below).
///
/// **Lifecycle**
/// 1. Call ``initialize(config:)`` once in your `App.init` or `AppDelegate.application(_:didFinishLaunchingWithOptions:)`.
/// 2. Optionally install a logger adapter so your existing logging calls are captured automatically.
/// 3. Call ``shutdown()`` only if you need a clean teardown (e.g., during testing).
public actor CeburuAnalyticsSDK {

    /// The singleton instance. Use this everywhere — do not create additional instances.
    public static let shared = CeburuAnalyticsSDK()

    // ── Severity ───────────────────────────────────────────────────────────────

    /// Log severity levels in ascending order of criticality.
    ///
    /// The SDK's minimum-severity filter (`policy.minSeverity`) uses the raw value for comparison.
    /// Events below the threshold are discarded before being written to disk.
    ///
    /// | Level | When to use |
    /// |-------|-------------|
    /// | `trace` | Verbose diagnostic output — usually suppressed in production |
    /// | `debug` | Developer-facing detail useful during active development |
    /// | `info` | Normal operational events the team wants in the log stream |
    /// | `warn` | Recoverable anomaly — the app continued but something was unexpected |
    /// | `error` | Failure in one operation — the app is still running |
    /// | `fatal` | Unrecoverable failure — app is about to crash or must restart |
    public enum Severity: Int, Codable, Sendable {
        case trace, debug, info, warn, error, fatal
    }

    // ── SpanKind ───────────────────────────────────────────────────────────────

    /// Relationship between a span and its callers/callees.
    ///
    /// - ``internal``: default; operation stays within the same service.
    /// - ``client``:   outgoing synchronous call (HTTP request, gRPC call).
    /// - ``server``:   incoming synchronous call handled by this service.
    /// - ``producer``: outgoing async message sent to a broker.
    /// - ``consumer``: incoming async message received from a broker.
    public enum SpanKind: Sendable {
        case `internal`, client, server, producer, consumer
    }

    // ── Config ─────────────────────────────────────────────────────────────────

    /// SDK configuration. Pass one instance to ``initialize(config:)`` at startup.
    ///
    /// Required fields (`serviceName` through `collectorHost`) must be non-empty strings.
    /// Optional fields have production-safe defaults.
    public struct Config: Sendable {
        /// Your app name as it appears in the collector (e.g. `"PaymentsApp"`).
        public let serviceName:     String
        /// App version string (e.g. `"2.1.0"`). Included on every telemetry record.
        public let serviceVersion:  String
        /// Deployment environment — `"production"`, `"staging"`, or `"development"`.
        public let environment:     String
        /// Tenant identifier. Provided by your account team. Shared across users of the same tenant.
        public let tenantId:        String
        /// Application bundle identifier. Provided by your account team.
        public let applicationId:   String
        /// gRPC collector host. Provided by your account team (e.g. `"collector.ceburu.io"`).
        public let collectorHost:   String
        /// gRPC collector port. Defaults to `4317` (standard OTLP/gRPC port).
        public let collectorPort:   Int
        /// Maximum on-device encrypted queue size in bytes. Oldest events are evicted when full.
        /// Default: 50 MB.
        public let queueMaxBytes:   Int
        /// How many hours to retain events when the collector is unreachable.
        /// Events older than this are pruned on the next flush cycle. Default: 72 h.
        public let retentionHours:  Int
        /// Maximum number of events per export batch. Default: 200.
        public let maxBatchEvents:  Int
        /// Maximum payload size per export batch in bytes. Default: 512 KB.
        public let maxBatchBytes:   Int
        /// Initial user identity. Applied before the first log event so `user.id` appears
        /// even on the "SDK initialized" event. Update at runtime with ``CeburuAnalyticsSDK/setUser(_:)``.
        public let userId:          String
        /// Customer-provided Bearer token. Applied as the `authorization` gRPC metadata header.
        /// Rotate at runtime with ``CeburuAnalyticsSDK/updateAuthToken(_:)``.
        public let authToken:       String
        /// How often (in seconds) observable metrics are polled and exported.
        /// Default: 60 s. Reduce to 10 s during development for faster feedback.
        public let metricsExportInterval: TimeInterval

        /// Creates an SDK configuration.
        ///
        /// - Parameters:
        ///   - serviceName:           App name as it should appear in the collector.
        ///   - serviceVersion:        App version string (e.g. `"2.1.0"`).
        ///   - environment:           Deployment tier — `"production"`, `"staging"`, etc.
        ///   - tenantId:              Tenant identifier (from account team).
        ///   - applicationId:         Bundle identifier (from account team).
        ///   - collectorHost:         gRPC collector host (from account team).
        ///   - collectorPort:         gRPC port. Defaults to `4317`.
        ///   - queueMaxBytes:         On-device queue limit. Defaults to 50 MB.
        ///   - retentionHours:        Offline retention window. Defaults to 72 h.
        ///   - maxBatchEvents:        Events per export batch. Defaults to 200.
        ///   - maxBatchBytes:         Payload limit per batch. Defaults to 512 KB.
        ///   - userId:                Initial user identity. Defaults to empty (no `user.id` attribute).
        ///   - authToken:             Bearer token. Defaults to empty (no auth header).
        ///   - metricsExportInterval: Metric poll interval in seconds. Defaults to 60 s.
        public init(
            serviceName:           String,
            serviceVersion:        String,
            environment:           String,
            tenantId:              String,
            applicationId:         String,
            collectorHost:         String,
            collectorPort:         Int          = 4317,
            queueMaxBytes:         Int          = 50 * 1024 * 1024,
            retentionHours:        Int          = 72,
            maxBatchEvents:        Int          = 200,
            maxBatchBytes:         Int          = 512 * 1024,
            userId:                String       = "",
            authToken:             String       = "",
            metricsExportInterval: TimeInterval = 60
        ) {
            self.serviceName           = serviceName
            self.serviceVersion        = serviceVersion
            self.environment           = environment
            self.tenantId              = tenantId
            self.applicationId         = applicationId
            self.collectorHost         = collectorHost
            self.collectorPort         = collectorPort
            self.queueMaxBytes         = queueMaxBytes
            self.retentionHours        = retentionHours
            self.maxBatchEvents        = maxBatchEvents
            self.maxBatchBytes         = maxBatchBytes
            self.userId                = userId
            self.authToken             = authToken
            self.metricsExportInterval = metricsExportInterval
        }
    }

    // ── AppSpan ────────────────────────────────────────────────────────────────

    /// Handle to an active trace span. Obtain via ``CeburuAnalyticsSDK/startSpan(name:attrs:kind:)``.
    ///
    /// Always call ``end()`` or ``endWithError(_:)`` exactly once — an unclosed span leaks memory
    /// and is never exported. Use `defer { span.end() }` to guarantee cleanup.
    public final class AppSpan: @unchecked Sendable {

        private let span: (any OpenTelemetryApi.Span)?

        init(span: (any OpenTelemetryApi.Span)?) {
            self.span = span
        }

        /// Adds or updates a string attribute on the span. Chainable.
        ///
        /// Call before ``end()`` — attributes set after the span closes are silently ignored.
        @discardableResult
        public func setAttribute(key: String, value: String) -> AppSpan {
            span?.setAttribute(key: key, value: AttributeValue.string(value))
            return self
        }

        /// Adds or updates an integer attribute on the span. Chainable.
        @discardableResult
        public func setAttribute(key: String, value: Int64) -> AppSpan {
            span?.setAttribute(key: key, value: AttributeValue.int(Int(value)))
            return self
        }

        /// Adds or updates a floating-point attribute on the span. Chainable.
        @discardableResult
        public func setAttribute(key: String, value: Double) -> AppSpan {
            span?.setAttribute(key: key, value: AttributeValue.double(value))
            return self
        }

        /// Adds a named event (annotation) at the current timestamp. Chainable.
        ///
        /// Events are time-stamped points of interest within the span lifetime — e.g.
        /// `"cart.validated"` or `"payment.initiated"`. They appear in the trace waterfall.
        ///
        /// - Parameters:
        ///   - name:  Short identifier for the event (e.g. `"payment.initiated"`).
        ///   - attrs: Optional key-value metadata attached to this event only.
        @discardableResult
        public func addEvent(name: String, attrs: [String: String] = [:]) -> AppSpan {
            if attrs.isEmpty {
                span?.addEvent(name: name)
            } else {
                let bridgeAttrs = attrs.reduce(into: [String: AttributeValue]()) { $0[$1.key] = .string($1.value) }
                span?.addEvent(name: name, attributes: bridgeAttrs)
            }
            return self
        }

        /// Marks the span successful and ends it. Call exactly once.
        ///
        /// After this call the span is immutable and queued for export. Further attribute
        /// mutations or `addEvent` calls on this handle are silently ignored.
        public func end() {
            span?.end()
        }

        /// Records an error, marks the span status as `ERROR`, and ends it. Call exactly once.
        ///
        /// Sets `exception.message` and `span.status = ERROR` before closing the span.
        /// Use this instead of ``end()`` whenever the operation failed.
        ///
        /// - Parameter error: The error that caused the failure. Its `localizedDescription` is recorded.
        public func endWithError(_ error: Error) {
            span?.setAttribute(key: SemanticAttributes.exceptionMessage.rawValue,
                               value: AttributeValue.string(error.localizedDescription))
            span?.status = Status.error(description: error.localizedDescription)
            span?.end()
        }
    }

    // ── Internal state ─────────────────────────────────────────────────────────

    private var config:    Config?
    private var storage:   EncryptedStore?
    private var bridge:    AnalyticsBridge?
    private var sessionId  = UUID().uuidString
    private var breadcrumbs: [Breadcrumb] = []
    private var policy     = Policy()
    private var running    = false
    private var backoff    = RetryBackoff()
    private var adapters:  [LoggerAdapter] = []
    private var userId:    String = ""

    nonisolated(unsafe) private static var _crashStorage:    EncryptedStore?
    nonisolated(unsafe) private static var _crashSessionId:  String = ""
    nonisolated(unsafe) static var _crashBreadcrumbs:        String = ""

    private init() {}

    // ── Initialization ─────────────────────────────────────────────────────────

    /// Initializes the SDK and starts the background flush loop.
    ///
    /// Call this once — typically in `App.init` or `AppDelegate.application(_:didFinishLaunchingWithOptions:)`.
    /// Subsequent calls while the SDK is already running are silently ignored.
    ///
    /// What this does:
    /// 1. Creates the encrypted on-device queue and crash directory.
    /// 2. Builds the three OpenTelemetry signal pipelines (logs, metrics, traces) over gRPC.
    /// 3. Imports any crash records persisted during a previous session and re-queues them as `fatal` events.
    /// 4. Installs `NSSetUncaughtExceptionHandler` and the POSIX signal handler for crash reporting.
    /// 5. Starts a background `Task` that flushes the queue with exponential backoff on failure.
    /// 6. Emits an `"Mobile SDK initialized"` info event with device and config metadata.
    ///
    /// - Parameter config: SDK configuration. See ``Config`` for field descriptions.
    /// - Throws: If the encrypted store or the gRPC bridge cannot be created
    ///           (e.g. Keychain unavailable, invalid host).
    public func initialize(config: Config) async throws {
        guard !running else { return }

        let storage = try EncryptedStore(
            maxBytes:       config.queueMaxBytes,
            retentionHours: config.retentionHours
        )
        let bridge = try AnalyticsBridge(config: config)

        self.config  = config
        self.storage = storage
        self.bridge  = bridge
        self.policy.maxBatchEvents = config.maxBatchEvents
        self.policy.maxBatchBytes  = config.maxBatchBytes
        self.running = true

        // Apply userId from Config before the first log event so user.id appears
        // on the very first emitted event (including "SDK initialized" below).
        if !config.userId.isEmpty { self.userId = config.userId }

        try await storage.importCrashRecords(sessionId: sessionId)
        try await storage.importSignalCrashRecords(sessionId: sessionId)

        installExceptionHandler()
        SignalCrashHandler.install(crashDir: storage.crashDir, sessionId: sessionId)

        Task { [weak self] in
            while let self, await self.running {
                switch await self.flushPersisted() {
                case .flushed:
                    await self.resetBackoff()
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                case .empty:
                    await self.resetBackoff()
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                case .failed:
                    let ms = await self.nextBackoff()
                    try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
                }
            }
        }

        #if canImport(UIKit)
        let deviceModel = await UIDevice.current.model
        let osVersion   = await UIDevice.current.systemVersion
        let osName      = "iOS"
        #else
        let deviceModel = "Mac"
        let osVersion   = ProcessInfo.processInfo.operatingSystemVersionString
        let osName      = "macOS"
        #endif

        await info(
            "Mobile SDK initialized",
            attributes: [
                "service.name":                config.serviceName,
                "service.version":             config.serviceVersion,
                "deployment.environment.name": config.environment,
                "tenant.id":                   config.tenantId,
                "application.id":              config.applicationId,
                "device.manufacturer":         "Apple",
                "device.model":                deviceModel,
                "os.name":                     osName,
                "os.version":                  osVersion
            ]
        )
    }

    // ── Logger adapters ────────────────────────────────────────────────────────

    /// Installs a logger adapter so your existing logger routes into the SDK automatically.
    ///
    /// Call once after ``initialize(config:)``. The adapter's ``LoggerAdapter/install()`` method
    /// is called immediately. On ``shutdown()``, all installed adapters are uninstalled so the
    /// original logging chain is fully restored.
    ///
    /// ```swift
    /// await CeburuAnalyticsSDK.shared.installLoggerAdapter(CallbackLoggerAdapter.shared)
    /// ```
    ///
    /// - Parameter adapter: The adapter to install. See ``CallbackLoggerAdapter`` and ``OSLogAdapter``.
    public func installLoggerAdapter(_ adapter: LoggerAdapter) async {
        await adapter.install()
        adapters.append(adapter)
    }

    // ── User identity ──────────────────────────────────────────────────────────

    /// Sets `user.id` on all subsequent log, metric, and trace events.
    ///
    /// Call this after login so every telemetry record identifies the current user.
    /// Pass an empty string on logout to stop attaching `user.id`.
    ///
    /// ```swift
    /// await CeburuAnalyticsSDK.shared.setUser("user-john-001")  // after login
    /// await CeburuAnalyticsSDK.shared.setUser("")               // on logout
    /// ```
    ///
    /// - Parameter userId: Unique identifier for the current user. Empty string clears the identity.
    public func setUser(_ userId: String) {
        self.userId = userId
    }

    /// Stores a new Bearer token for authenticating gRPC export requests.
    ///
    /// The token is applied to gRPC `CallOptions` on the next connection — not mid-stream.
    /// This is a known limitation of iOS gRPC: `CallOptions` are set at connection time,
    /// so the new token takes effect when the current connection is recycled.
    ///
    /// - Parameter token: The replacement Bearer token. Pass an empty string to remove auth.
    public func updateAuthToken(_ token: String) async {
        await bridge?.updateToken(token)
    }

    // ── Session ────────────────────────────────────────────────────────────────

    /// Generates a new session ID and attaches it to all subsequent events.
    ///
    /// A session ID is created automatically at ``initialize(config:)``. Call `newSession()`
    /// at login, logout, or the start of a new workflow to group events into a distinct session.
    ///
    /// - Returns: The new session ID (a UUID string). Discard if you don't need it.
    @discardableResult
    public func newSession() -> String {
        sessionId = UUID().uuidString
        return sessionId
    }

    // ── Breadcrumbs ────────────────────────────────────────────────────────────

    /// Records a UI or network event as a breadcrumb.
    ///
    /// The last 50 breadcrumbs are kept in memory. When an `error` or `fatal` event fires,
    /// the current breadcrumb trail is automatically attached as `session.breadcrumbs` so you
    /// have context around what the user did leading up to the failure.
    ///
    /// Breadcrumbs are also persisted to disk so they survive a crash and are included
    /// in the next-launch crash report.
    ///
    /// ```swift
    /// await CeburuAnalyticsSDK.shared.breadcrumb(category: "ui", message: "Opened checkout screen")
    /// await CeburuAnalyticsSDK.shared.breadcrumb(category: "network", message: "POST /payments")
    /// ```
    ///
    /// - Parameters:
    ///   - category: Short label for the breadcrumb type — `"ui"`, `"network"`, `"auth"`, etc.
    ///   - message:  Human-readable description of what happened.
    public func breadcrumb(category: String, message: String) {
        breadcrumbs.append(Breadcrumb(category: category, message: message))
        if breadcrumbs.count > 50 { breadcrumbs.removeFirst(breadcrumbs.count - 50) }
        let serialized = breadcrumbs
            .map { "\($0.category):\($0.message)" }
            .joined(separator: " | ")
        CeburuAnalyticsSDK._crashBreadcrumbs = serialized
        storage?.persistBreadcrumbs(serialized)
    }

    // ── Logging ────────────────────────────────────────────────────────────────

    /// Emits a `TRACE` severity log event.
    ///
    /// Use for verbose diagnostic output that is usually suppressed in production.
    /// - Parameters:
    ///   - message:    Human-readable description of the event.
    ///   - attributes: Optional key-value metadata. PII keys are automatically redacted.
    public func trace(_ message: String, attributes: [String: Any] = [:]) async {
        await emit(.trace, message, attributes)
    }

    /// Emits a `DEBUG` severity log event.
    ///
    /// Use for developer-facing detail that helps during active development.
    /// - Parameters:
    ///   - message:    Human-readable description of the event.
    ///   - attributes: Optional key-value metadata. PII keys are automatically redacted.
    public func debug(_ message: String, attributes: [String: Any] = [:]) async {
        await emit(.debug, message, attributes)
    }

    /// Emits an `INFO` severity log event.
    ///
    /// Use for normal operational events the team wants in the log stream (e.g. order placed, screen viewed).
    /// - Parameters:
    ///   - message:    Human-readable description of the event.
    ///   - attributes: Optional key-value metadata. PII keys are automatically redacted.
    public func info(_ message: String, attributes: [String: Any] = [:]) async {
        await emit(.info, message, attributes)
    }

    /// Emits a `WARN` severity log event.
    ///
    /// Use for recoverable anomalies where the app continued but something was unexpected
    /// (e.g. slow network, retried request, degraded-mode fallback).
    /// - Parameters:
    ///   - message:    Human-readable description of the anomaly.
    ///   - attributes: Optional key-value metadata. PII keys are automatically redacted.
    public func warn(_ message: String, attributes: [String: Any] = [:]) async {
        await emit(.warn, message, attributes)
    }

    /// Emits an `ERROR` severity log event.
    ///
    /// Use when an operation failed but the app is still running. The current breadcrumb
    /// trail is automatically attached as `session.breadcrumbs`.
    /// - Parameters:
    ///   - message:    Human-readable description of what failed.
    ///   - error:      Optional `Error` — its type and `localizedDescription` are added as attributes.
    ///   - attributes: Optional key-value metadata. PII keys are automatically redacted.
    public func error(_ message: String, error: Error? = nil, attributes: [String: Any] = [:]) async {
        await emit(.error, message, mergeError(attributes, error))
    }

    /// Emits a `FATAL` severity log event.
    ///
    /// Use for unrecoverable failures where the app must crash or restart. Breadcrumbs are attached
    /// automatically. Fatal events bypass the minimum-severity filter and the sample-rate gate.
    /// - Parameters:
    ///   - message:    Human-readable description of the fatal condition.
    ///   - error:      Optional `Error` — its type and `localizedDescription` are added as attributes.
    ///   - attributes: Optional key-value metadata. PII keys are automatically redacted.
    public func fatal(_ message: String, error: Error? = nil, attributes: [String: Any] = [:]) async {
        await emit(.fatal, message, mergeError(attributes, error))
    }

    // ── Metrics ────────────────────────────────────────────────────────────────

    /// Increments a named counter by `value` (default 1).
    ///
    /// Counters are monotonically increasing — they never decrease.
    /// The instrument is created lazily on first use and lives until ``shutdown()``.
    /// Use for counting discrete events: button taps, API calls, page views.
    ///
    /// ```swift
    /// await CeburuAnalyticsSDK.shared.incrementCounter(
    ///     name: "checkout.attempts", value: 1, attrs: ["screen": "cart"]
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - name:  Instrument name (e.g. `"checkout.attempts"`). Consistent across calls.
    ///   - value: Amount to add. Must be ≥ 0.
    ///   - attrs: Attributes attached to this data point only (not to the instrument definition).
    public func incrementCounter(
        name:  String,
        value: Int64 = 1,
        attrs: [String: String] = [:]
    ) async {
        await bridge?.incrementCounter(name: name, value: value, attrs: attrs)
    }

    /// Increments (or decrements) a named up-down counter.
    ///
    /// Unlike regular counters, up-down counters can go negative.
    /// The instrument is created lazily on first use.
    /// Use for values that rise and fall: active sessions, cart item count, open file handles.
    ///
    /// ```swift
    /// await CeburuAnalyticsSDK.shared.incrementUpDownCounter("active.downloads", value: +1)
    /// await CeburuAnalyticsSDK.shared.incrementUpDownCounter("active.downloads", value: -1)
    /// ```
    ///
    /// - Parameters:
    ///   - name:  Instrument name. Consistent across add and subtract calls.
    ///   - value: Delta — positive to add, negative to subtract.
    ///   - attrs: Attributes attached to this data point only.
    public func incrementUpDownCounter(
        name:  String,
        value: Int64 = 1,
        attrs: [String: String] = [:]
    ) async {
        await bridge?.incrementUpDownCounter(name: name, value: value, attrs: attrs)
    }

    /// Records a measurement into a named histogram.
    ///
    /// Histograms capture the statistical distribution of a value over time (min, max, sum, count,
    /// and bucket counts). The instrument is created lazily on first use.
    /// Use for durations (ms), sizes (bytes), or any continuous value.
    ///
    /// ```swift
    /// await CeburuAnalyticsSDK.shared.recordHistogram(
    ///     name: "api.response.ms", value: 142.0, attrs: ["endpoint": "/checkout"]
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - name:  Instrument name (e.g. `"api.response.ms"`). Consistent across calls.
    ///   - value: Measured value (must be ≥ 0 for histograms).
    ///   - attrs: Attributes attached to this data point only.
    public func recordHistogram(
        name:  String,
        value: Double,
        attrs: [String: String] = [:]
    ) async {
        await bridge?.recordHistogram(name: name, value: value, attrs: attrs)
    }

    /// Registers a callback polled every 60 s and reported as a cumulative counter.
    ///
    /// Register once — typically in `App.init` after ``initialize(config:)``.
    /// The callback is called on the metrics export thread; it must be cheap and non-blocking.
    /// The instrument stays alive until ``shutdown()``.
    ///
    /// ```swift
    /// await CeburuAnalyticsSDK.shared.observeCounter("app.sessions.total") { sessionCount }
    /// ```
    ///
    /// - Parameters:
    ///   - name:     Instrument name (e.g. `"app.sessions.total"`).
    ///   - callback: Returns the current cumulative count. Called every 60 s.
    public func observeCounter(name: String, callback: @Sendable @escaping () -> Int64) async {
        await bridge?.observeCounter(name: name, callback: callback)
    }

    /// Registers a callback polled every 60 s and reported as a gauge (point-in-time value).
    ///
    /// Register once — typically in `App.init` after ``initialize(config:)``.
    /// The callback is called on the metrics export thread; it must be cheap and non-blocking.
    /// Use for system state sampled on demand: memory usage, battery level, thread count.
    ///
    /// ```swift
    /// await CeburuAnalyticsSDK.shared.observeGauge("memory.used.mb") {
    ///     Double(ProcessInfo.processInfo.physicalMemory) / 1_048_576
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - name:     Instrument name (e.g. `"memory.used.mb"`).
    ///   - callback: Returns the current value. Called every 60 s.
    public func observeGauge(name: String, callback: @Sendable @escaping () -> Double) async {
        await bridge?.observeGauge(name: name, callback: callback)
    }

    // ── Traces ─────────────────────────────────────────────────────────────────

    /// Starts a trace span and returns an ``AppSpan`` handle.
    ///
    /// Always call ``AppSpan/end()`` or ``AppSpan/endWithError(_:)`` when the operation finishes.
    /// An unclosed span is never exported and leaks memory. Use `defer { span.end() }` for safety.
    ///
    /// ```swift
    /// let span = await CeburuAnalyticsSDK.shared.startSpan(
    ///     name: "outgoing.http.call",
    ///     attrs: ["http.method": "GET", "http.url": "https://api.example.com"],
    ///     kind: .client
    /// )
    /// defer { span.end() }
    /// ```
    ///
    /// - Parameters:
    ///   - name:  Span name — a short verb-noun pair (e.g. `"payment.flow"`, `"outgoing.http.call"`).
    ///   - attrs: Initial span attributes set at span start time.
    ///   - kind:  Relationship to callers/callees. Defaults to `.internal`.
    /// - Returns: An ``AppSpan`` handle. Never nil — an inert no-op span is returned if the bridge is unavailable.
    public func startSpan(
        name:  String,
        attrs: [String: String] = [:],
        kind:  SpanKind         = .internal
    ) async -> AppSpan {
        let otelKind: OpenTelemetryApi.SpanKind = {
            switch kind {
            case .client:   return .client
            case .server:   return .server
            case .producer: return .producer
            case .consumer: return .consumer
            case .internal: return .internal
            }
        }()
        return await bridge?.startAppSpan(name: name, attrs: attrs, kind: otelKind) ?? AppSpan(span: nil)
    }

    // ── Shutdown ───────────────────────────────────────────────────────────────

    /// Stops the SDK, flushes the log queue, and tears down all signal pipelines.
    ///
    /// What this does:
    /// 1. Uninstalls all registered logger adapters, restoring the original logging chain.
    /// 2. Sets `running = false` to stop the flush loop.
    /// 3. Uninstalls the POSIX signal handler.
    /// 4. Shuts down the gRPC bridge (flushes in-flight batches and closes the connection).
    ///
    /// After `shutdown()` the SDK can be re-initialized by calling ``initialize(config:)`` again.
    /// Normally you do not need to call this — it is provided for testing and graceful app teardown.
    /// Immediately triggers a metric collection and export cycle.
    ///
    /// Useful during development to verify observable metrics (gauge/counter) are reaching
    /// the collector without waiting for the next scheduled interval.
    /// Forces an immediate metric collection and gRPC export.
    /// - Returns: `true` if the export was accepted by the collector, `false` if the connection was refused or timed out.
    @discardableResult
    public func flushMetrics() async -> Bool {
        return await bridge?.flushMetrics() ?? false
    }

    public func shutdown() async {
        for adapter in adapters { await adapter.uninstall() }
        adapters.removeAll()
        running = false
        SignalCrashHandler.uninstall()
        await bridge?.shutdown()
        bridge = nil
    }

    // ── Private helpers ────────────────────────────────────────────────────────

    private func emit(_ severity: Severity, _ message: String, _ attributes: [String: Any]) async {
        guard running, let config, let storage else { return }
        if !policy.enabled {
            await bridge?.recordEventDropped()
            return
        }
        if severity.rawValue < policy.minSeverity.rawValue {
            await bridge?.recordEventDropped()
            return
        }
        if severity.rawValue < Severity.error.rawValue &&
           Double.random(in: 0...1) > policy.sampleRate {
            await bridge?.recordEventDropped()
            return
        }

        var attrs = Security.redact(stringify(attributes))
        attrs["service.name"]                = config.serviceName
        attrs["service.version"]             = config.serviceVersion
        attrs["deployment.environment.name"] = config.environment
        attrs["tenant.id"]                   = config.tenantId
        attrs["application.id"]              = config.applicationId

        // Inject user identity when set — links every event to the current user.
        if !userId.isEmpty { attrs["user.id"] = userId }

        if severity.rawValue >= Severity.error.rawValue && !breadcrumbs.isEmpty {
            attrs["session.breadcrumbs"] = breadcrumbs
                .map { "\($0.category):\($0.message)" }
                .joined(separator: " | ")
        }

        let event = Event(
            eventId:         UUID().uuidString,
            timestampUnixMs: Int64(Date().timeIntervalSince1970 * 1000),
            severity:        severity,
            type:            "log",
            message:         message,
            sessionId:       sessionId,
            attributes:      attrs
        )

        do {
            try await storage.enqueue(event)
            await bridge?.recordEventEmitted(
                severity: String(describing: severity).uppercased(),
                type: event.type
            )
        } catch {
            await bridge?.recordEventDropped()
        }
    }

    private enum FlushResult { case flushed, empty, failed }

    private func flushPersisted() async -> FlushResult {
        guard let storage, let bridge else { return .empty }
        do {
            let rows = try await storage.batch(
                maxEvents: policy.maxBatchEvents,
                maxBytes:  policy.maxBatchBytes
            )
            if rows.isEmpty { return .empty }
            var successCount = 0
            for (file, clear) in rows {
                let event: Event
                do {
                    event = try JSONDecoder().decode(Event.self, from: clear)
                } catch {
                    // Corrupt or undecodable event — acknowledge (delete) it so it never
                    // blocks the queue again. Count as dropped, not as an export failure.
                    await storage.acknowledge([file])
                    continue
                }
                let ok = await bridge.emit(event)
                if ok {
                    successCount += 1
                    await storage.acknowledge([file])
                } else {
                    if successCount > 0 { await bridge.recordExportSuccess(eventCount: successCount) }
                    await bridge.recordExportFailure()
                    return .failed
                }
            }
            await bridge.recordExportSuccess(eventCount: successCount)
            return .flushed
        } catch {
            return .failed
        }
    }

    private func installExceptionHandler() {
        guard let storage else { return }
        CeburuAnalyticsSDK._crashStorage   = storage
        CeburuAnalyticsSDK._crashSessionId = sessionId

        NSSetUncaughtExceptionHandler { exception in
            CeburuAnalyticsSDK._crashStorage?.persistException(exception, sessionId: CeburuAnalyticsSDK._crashSessionId)
            SignalCrashHandler.exceptionAlreadyCaptured = true
        }
    }

    private func stringify(_ attrs: [String: Any]) -> [String: String] {
        attrs.mapValues { v in (v as? String) ?? "\(v)" }
    }

    private func mergeError(_ attrs: [String: Any], _ error: Error?) -> [String: Any] {
        guard let error else { return attrs }
        var out = attrs
        out["exception.type"]    = String(describing: type(of: error))
        out["exception.message"] = error.localizedDescription
        return out
    }

    private func resetBackoff() { backoff.reset() }
    private func nextBackoff()  -> Int { backoff.nextDelayMs() }

    // ── Internal types ─────────────────────────────────────────────────────────

    struct Event: Codable, Sendable {
        let eventId:         String
        let timestampUnixMs: Int64
        let severity:        Severity
        let type:            String
        let message:         String
        let sessionId:       String
        let attributes:      [String: String]
    }

    struct Policy: Sendable {
        var enabled        = true
        var minSeverity:   Severity = .info
        var sampleRate     = 1.0
        var maxBatchEvents = 200
        var maxBatchBytes  = 512 * 1024
    }

    struct Breadcrumb: Sendable {
        let category: String
        let message:  String
    }
}
