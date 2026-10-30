import Darwin
import Foundation
#if canImport(UIKit)
import UIKit
#endif
@preconcurrency import OpenTelemetryApi

/// Main entry point for the Ceburu RUM SDK for iOS.
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

    // Sent as telemetry.distro.name/version; keep sdkVersion equal to the release tag.
    static let sdkName    = "ceburu-ios-sdk"
    static let sdkVersion = "1.0.0"

    // ── Severity ───────────────────────────────────────────────────────────────

    /// Log severity levels in ascending order of criticality.
    ///
    /// ``Config/minSeverity`` uses the raw value for comparison.
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
    public struct Config: Sendable {
        /// RUM endpoint from the Ceburu RUM setup page, e.g. `https://<ingest-host>/rum`.
        /// The SDK appends `/v1/logs`, `/v1/metrics` and `/v1/traces`.
        public let endpoint:        String
        /// The app's public `cbr_mob_…` key from the RUM setup page, sent as a Bearer token.
        /// The ingest maps it to your tenant and app. Switch at runtime with ``CeburuAnalyticsSDK/updateApiKey(_:)``.
        public let apiKey:          String
        /// App name, sent as `service.name`.
        public let serviceName:     String
        /// App version (e.g. `CFBundleShortVersionString`), sent as `service.version`.
        public let serviceVersion:  String
        /// Sent as `deployment.environment.name`.
        public let environment:     String
        /// Allow an `http://` endpoint (local development only).
        public let allowInsecureEndpoint: Bool
        /// Log events below this level are dropped. Default: `.info`.
        public let minSeverity:     Severity
        /// `false` records nothing until ``CeburuAnalyticsSDK/setConsent(_:)`` is called with `true`.
        public let consentGranted:  Bool
        /// On-device encrypted queue limit; lowest severity evicted first. Default: 50 MB.
        public let queueMaxBytes:   Int
        /// Queued events older than this are discarded. Default: 72 h.
        public let retentionHours:  Int
        /// Events per export request. Default: 200.
        public let maxBatchEvents:  Int
        /// Payload per export request (the ingest accepts up to 1 MB). Default: 256 KB.
        public let maxBatchBytes:   Int
        /// Seconds between metric exports. Default: 60.
        public let metricsExportInterval: TimeInterval
        /// Sends custom metrics. Default `false`: Ceburu does not show mobile metrics yet.
        public let exportMetrics:   Bool
        /// UIKit screens, foreground/background and cold start, captured automatically. Default: `true`.
        public let autoCapture:     Bool
        /// Hosts (and their subdomains) that receive `traceparent` from ``CeburuAnalyticsSDK/data(for:session:)``,
        /// e.g. `["api.example.com"]`. Default: none.
        public let tracePropagationTargets: [String]

        public init(
            endpoint:              String,
            apiKey:                String,
            serviceName:           String,
            serviceVersion:        String       = "",
            environment:           String       = "production",
            allowInsecureEndpoint: Bool         = false,
            minSeverity:           Severity     = .info,
            consentGranted:        Bool         = true,
            queueMaxBytes:         Int          = 50 * 1024 * 1024,
            retentionHours:        Int          = 72,
            maxBatchEvents:        Int          = 200,
            maxBatchBytes:         Int          = 256 * 1024,
            metricsExportInterval: TimeInterval = 60,
            exportMetrics:         Bool         = false,
            autoCapture:           Bool         = true,
            tracePropagationTargets: [String]   = []
        ) {
            self.endpoint              = endpoint
            self.apiKey                = apiKey
            self.serviceName           = serviceName
            self.serviceVersion        = serviceVersion
            self.environment           = environment
            self.allowInsecureEndpoint = allowInsecureEndpoint
            self.minSeverity           = minSeverity
            self.consentGranted        = consentGranted
            self.queueMaxBytes         = queueMaxBytes
            self.retentionHours        = retentionHours
            self.maxBatchEvents        = maxBatchEvents
            self.maxBatchBytes         = maxBatchBytes
            self.metricsExportInterval = metricsExportInterval
            self.exportMetrics         = exportMetrics
            self.autoCapture           = autoCapture
            self.tracePropagationTargets = tracePropagationTargets
        }
    }

    // ── Span context (TaskLocal) ───────────────────────────────────────────────

    /// Task-local span context injected by ``withSpan(_:attrs:kind:_:)``.
    /// Logs emitted inside a `withSpan` closure inherit these IDs automatically.
    /// Reading from outside a `withSpan` closure returns `nil` — no span is active.
    struct SpanContext: Sendable {
        let traceId: String
        let spanId:  String
    }

    @TaskLocal static var _spanContext: SpanContext? = nil

    // ── AppSpan ────────────────────────────────────────────────────────────────

    /// Handle to an active trace span. Obtain via ``CeburuAnalyticsSDK/startSpan(name:attrs:kind:)``
    /// (legacy) or, preferably, ``CeburuAnalyticsSDK/withSpan(_:attrs:kind:_:)`` which scopes the
    /// span automatically and is safe under concurrent callers.
    ///
    /// Always call ``end()`` or ``endWithError(_:)`` exactly once — an unclosed span leaks memory
    /// and is never exported. Use `defer { span.end() }` to guarantee cleanup.
    public final class AppSpan: @unchecked Sendable {

        private let span: (any OpenTelemetryApi.Span)?

        // Exposed so withSpan() can bind the TaskLocal without accessing OTel globals.
        var spanContext: SpanContext? {
            guard let span else { return nil }
            let ctx = span.context
            guard ctx.isValid else { return nil }
            return SpanContext(traceId: ctx.traceId.hexString, spanId: ctx.spanId.hexString)
        }

        init(span: (any OpenTelemetryApi.Span)?) {
            self.span = span
        }

        /// Adds or updates a string attribute on the span. Chainable.
        ///
        /// Call before ``end()`` — attributes set after the span closes are silently ignored.
        @discardableResult
        public func setAttribute(key: String, value: String) -> AppSpan {
            if let v = Security.redact([key: value])[key] { span?.setAttribute(key: key, value: AttributeValue.string(v)) }
            return self
        }

        /// Adds or updates an integer attribute on the span. Chainable.
        @discardableResult
        public func setAttribute(key: String, value: Int64) -> AppSpan {
            setNumber(key, AttributeValue.int(Int(value)))
        }

        /// Adds or updates a floating-point attribute on the span. Chainable.
        @discardableResult
        public func setAttribute(key: String, value: Double) -> AppSpan {
            setNumber(key, AttributeValue.double(value))
        }

        // Key rules only: a dropped key is skipped, a masked key is sent as "[REDACTED]".
        private func setNumber(_ key: String, _ value: AttributeValue) -> AppSpan {
            if let masked = Security.redact([key: ""])[key] {
                span?.setAttribute(key: key, value: masked.isEmpty ? value : AttributeValue.string(masked))
            }
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
            let safeName = String(Security.redactText(String(name.prefix(256))).prefix(128))
            if attrs.isEmpty {
                span?.addEvent(name: safeName)
            } else {
                let bridgeAttrs = Security.redact(Security.bound(attrs)).mapValues { AttributeValue.string($0) }
                span?.addEvent(name: safeName, attributes: bridgeAttrs)
            }
            return self
        }

        /// Ends a network span with its HTTP status (4xx/5xx mark it failed).
        func end(status: Int) {
            span?.setAttribute(key: "http.response.status_code", value: AttributeValue.int(status))
            if status >= 400 { span?.status = Status.error(description: "HTTP \(status)") }
            span?.end()
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
        /// Records exception details as a span **event** named `"exception"` per OTel semconv —
        /// this makes the exception appear as a timed point in the trace waterfall, matching
        /// what Android's `span.recordException(throwable)` produces on the JVM side.
        /// Then sets `span.status = ERROR` and closes the span.
        ///
        /// - Parameter error: The error that caused the failure. Its redacted `localizedDescription` is recorded.
        public func endWithError(_ error: Error) {
            let message = String(Security.redactText(error.localizedDescription).prefix(1024))
            let stack = String(Security.redactText(Thread.callStackSymbols.joined(separator: "\n")).prefix(16_000))
            // OTel semconv: exceptions go on a span event, not span attributes.
            // exception.escaped = true because this error is ending the span's scope.
            span?.addEvent(name: "exception", attributes: [
                "exception.type":       AttributeValue.string(String(describing: type(of: error))),
                "exception.message":    AttributeValue.string(message),
                // Stack symbols captured at call time — closest Swift equivalent to a JVM stack trace.
                "exception.stacktrace": AttributeValue.string(stack),
                "exception.escaped":    AttributeValue.bool(true)
            ])
            span?.status = Status.error(description: message)
            span?.end()
        }
    }

    // ── Internal state ─────────────────────────────────────────────────────────

    private var config:    Config?
    private var storage:   EncryptedStore?
    private var bridge:    AnalyticsBridge?
    private var sessionId  = CeburuAnalyticsSDK.newId()
    private var previousSessionId = ""
    private var sessionStart = Date()
    private var lastActivity = Date()
    private var sessionSavedAt = Date.distantPast
    private var consent    = true
    private var authPaused = false
    private var batchEvents = 200
    private var breadcrumbs: [Breadcrumb] = []
    private var running    = false
    private var initializing = false
    private var viewId     = ""
    private var viewName   = ""
    private var appState   = "foreground"
    // Consent generation shared with the exporters and the queue; replaced on every initialize.
    private var gate       = ConsentGate(true)
    private var backoff    = RetryBackoff()
    private var adapters:  [LoggerAdapter] = []
    private var userId:    String = ""
    // I8: stored handle so shutdown() can cancel the loop immediately rather than
    // waiting for the current sleep to expire and risking a duplicate loop on re-init.
    private var flushTask: Task<Void, Never>? = nil

    nonisolated(unsafe) private static var _crashStorage:    EncryptedStore?
    nonisolated(unsafe) private static var _crashSessionId:  String = ""
    nonisolated(unsafe) static var _crashBreadcrumbs:        String = ""
    // H-3: previous uncaught-exception handler (e.g. Crashlytics, Sentry) chained after ours.
    // Must be a static so it is accessible from a @convention(c) closure without capturing context.
    nonisolated(unsafe) private static var _previousExceptionHandler: (@convention(c) (NSException) -> Void)? = nil

    private init() {}

    // ── Initialization ─────────────────────────────────────────────────────────

    /// Initializes the SDK and starts the background flush loop.
    ///
    /// Call this once — typically in `App.init` or `AppDelegate.application(_:didFinishLaunchingWithOptions:)`.
    /// Subsequent calls while the SDK is already running are silently ignored.
    ///
    /// Creates the encrypted queue, imports crashes saved by the previous launch (each keeps the
    /// session it happened in), installs the crash handlers and starts the export loop.
    ///
    /// - Parameter config: SDK configuration. See ``Config`` for field descriptions.
    /// - Throws: If `endpoint` is not an `https://` URL (or `http://` without `allowInsecureEndpoint`),
    ///           `apiKey` is empty, or the encrypted store cannot be created.
    public func initialize(config: Config) async throws {
        // Checked and set before the first await, so a concurrent call cannot interleave with this one.
        guard !running, !initializing else { return }
        initializing = true
        defer { initializing = false }

        var endpoint = config.endpoint
        while endpoint.hasSuffix("/") { endpoint.removeLast() }
        guard let url = URL(string: endpoint), let host = url.host, !host.isEmpty, url.query == nil,
              url.scheme == "https" || (url.scheme == "http" && config.allowInsecureEndpoint) else {
            throw NSError(domain: "CeburuAnalyticsSDK", code: -2, userInfo: [NSLocalizedDescriptionKey:
                "endpoint must be an https:// URL such as https://<ingest-host>/rum (http:// needs allowInsecureEndpoint)"])
        }
        guard !config.apiKey.isEmpty else {
            throw NSError(domain: "CeburuAnalyticsSDK", code: -3, userInfo: [NSLocalizedDescriptionKey: "apiKey is required"])
        }

        // Resolve device info before creating the bridge — AnalyticsBridge.init is
        // synchronous so it cannot call UIDevice itself. These values go into the
        // OTel Resource so every span and metric (not just the init log event) carries
        // device and OS context.
        #if canImport(UIKit)
        // H-5: UIDevice.current.model returns the generic string "iPhone".
        // sysctlbyname("hw.machine") returns the specific hardware model identifier
        // (e.g. "iPhone15,2"), which the Ceburu backend uses to correlate crash
        // patterns by hardware revision and distinguish capability tiers.
        var machineSize = 0
        sysctlbyname("hw.machine", nil, &machineSize, nil, 0)
        var machineBuf = [CChar](repeating: 0, count: machineSize)
        sysctlbyname("hw.machine", &machineBuf, &machineSize, nil, 0)
        let deviceModel = String(cString: machineBuf)
        let osVersion   = await UIDevice.current.systemVersion
        let osName      = "iOS"
        #else
        let deviceModel = "Mac"
        let osVersion   = ProcessInfo.processInfo.operatingSystemVersionString
        let osName      = "macOS"
        #endif

        // The consent epoch is durable: a withdrawal before the last restart still excludes everything older.
        // An unreadable marker fails closed: a fresh epoch above every queued file, and old crash records are dropped.
        let storedEpoch = EncryptedStore.loadEpoch().epoch
        let epoch = storedEpoch ?? EncryptedStore.newestQueuedEpoch() + 1
        if storedEpoch == nil { EncryptedStore.saveEpoch(epoch) }
        let gate = ConsentGate(config.consentGranted, metricsEnabled: config.exportMetrics, generation: epoch)
        let storage = try EncryptedStore(
            maxBytes:       config.queueMaxBytes,
            retentionHours: config.retentionHours,
            gate:           gate
        )
        let bridge = AnalyticsBridge(
            config:      config,
            gate:        gate,
            endpoint:    endpoint,
            installId:   storage.installId,
            deviceModel: deviceModel,
            osName:      osName,
            osVersion:   osVersion
        )

        self.config  = config
        self.storage = storage
        self.bridge  = bridge
        self.gate    = gate
        self.consent = config.consentGranted
        self.authPaused = false
        self.batchEvents = max(1, config.maxBatchEvents)
        self.running = true

        // An unexpired session from the previous launch continues.
        if let saved = await storage.loadSession(), !Self.expired(start: saved.start, last: saved.lastActivity, now: Date()) {
            sessionId = saved.id
            previousSessionId = saved.previousId
            sessionStart = saved.start
            lastActivity = saved.lastActivity
        }
        // Files left by a withdrawal whose purge never ran (the app ended first) are removed now.
        await storage.purge(before: gate.generation, crashes: storedEpoch == nil)
        if consent { await startCrashCapture() }

        // I8: store the handle so shutdown() can cancel it immediately.
        // Using do/catch on Task.sleep means a cancel() wakes the loop right away
        // instead of waiting out the full 5–30 s sleep window.
        flushTask = Task { [weak self] in
            while let self, await self.running {
                guard !Task.isCancelled else { break }
                let ns: UInt64
                switch await self.flushPersisted() {
                case .flushed:
                    await self.resetBackoff()
                    ns = 5_000_000_000
                case .empty:
                    await self.resetBackoff()
                    ns = 30_000_000_000
                case .failed(let after):
                    // Honour the server's Retry-After (capped at 1 h) when it is longer than the backoff.
                    let backoffMs = await self.nextBackoff()
                    let ms = max(backoffMs, Int(min(after ?? 0, 3600) * 1000))
                    ns = UInt64(ms) * 1_000_000
                }
                do {
                    try await Task.sleep(nanoseconds: ns)
                } catch {
                    break  // cancelled during sleep — exit immediately
                }
            }
        }

        if config.autoCapture {
            #if canImport(UIKit)
            await MainActor.run { AutoCapture.install() }
            #endif
        }

        if await storage.keychainFailed {
            await warn(
                "Keychain unavailable — event queue is memory-only; events will not survive app restart",
                attributes: ["sdk.health": "degraded", "storage.mode": "memory-only"]
            )
        }
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

    /// Sets `user.id` on all later logs and spans (never on metrics).
    ///
    /// Use an opaque, stable id — never an email or a name. Pass an empty string on logout.
    ///
    /// ```swift
    /// await CeburuAnalyticsSDK.shared.setUser("user-john-001")  // after login
    /// await CeburuAnalyticsSDK.shared.setUser("")               // on logout
    /// ```
    ///
    /// - Parameter userId: Unique identifier for the current user. Empty string clears the identity.
    public func setUser(_ userId: String) {
        self.userId = String(Security.redactText(String(userId.prefix(256))).prefix(128))
    }

    /// Switches to a new key (e.g. after a rotation on the RUM setup page) and rebuilds the
    /// export pipelines; in-flight data is flushed first.
    public func updateApiKey(_ apiKey: String) async {
        await bridge?.updateToken(apiKey)
        authPaused = false
    }

    /// Grants or withdraws consent. While withdrawn nothing is recorded or sent (logs, spans, metrics,
    /// breadcrumbs, crashes), and withdrawing also deletes everything still queued on the device.
    /// - Returns: `false` only when a withdrawal could not be stored on the device; nothing is sent in this process
    ///   either way, and queued data is deleted right away.
    @discardableResult
    public func setConsent(_ granted: Bool) async -> Bool {
        if granted {
            guard !consent || !gate.isGranted else { return true }
            consent = true
            gate.isGranted = true
            if running { await startCrashCapture() }
            return true
        }
        // Everything below runs before the first await: the new epoch is on disk (a restart before the purge
        // keeps it), and nothing admitted earlier is written or exported, even if a grant arrives meanwhile.
        let generation = gate.revoke()
        let durable = EncryptedStore.saveEpoch(generation)
        consent = false
        stopCrashCapture()
        breadcrumbs.removeAll()
        CeburuAnalyticsSDK._crashBreadcrumbs = ""
        userId = ""
        forgetSession()
        guard running else { return durable }
        await storage?.purge(before: generation, crashes: true)
        await bridge?.dropBuffered()
        await bridge?.resetPipelines()  // no metric state (cumulative counters, callbacks) outlives a withdrawal
        return durable
    }

    // ── Session ────────────────────────────────────────────────────────────────

    /// Starts a new session now. Sessions also rotate on their own after 15 minutes without
    /// events or 4 hours in total.
    ///
    /// - Returns: The new 32-hex session id.
    @discardableResult
    public func newSession() -> String {
        rotateSession()
    }

    /// The current session id; rotates after 15 min without events or 4 h in total (as the web SDK).
    private func currentSession() -> String {
        let now = Date()
        if Self.expired(start: sessionStart, last: lastActivity, now: now) { return rotateSession() }
        lastActivity = now
        if now.timeIntervalSince(sessionSavedAt) > 60 { saveSession() }
        return sessionId
    }

    static func expired(start: Date, last: Date, now: Date) -> Bool {
        now.timeIntervalSince(last) > 15 * 60 || now.timeIntervalSince(start) > 4 * 3600
    }

    private func saveSession() {
        sessionSavedAt = Date()
        let session = EncryptedStore.Session(id: sessionId, previousId: previousSessionId,
                                             start: sessionStart, lastActivity: lastActivity)
        let generation = gate.generation  // the store refuses a save scheduled before a withdrawal
        if let storage { Task { await storage.saveSession(session, generation: generation) } }
    }

    /// Consent withdrawn: the next session is not linked to this one.
    private func forgetSession() {
        rotateSession()
        previousSessionId = ""
        saveSession()
    }

    @discardableResult
    private func rotateSession() -> String {
        previousSessionId = sessionId
        sessionId = Self.newId()
        sessionStart = Date()
        lastActivity = sessionStart
        // Crashes are reported with the session they happen in.
        CeburuAnalyticsSDK._crashSessionId = sessionId
        SignalCrashHandler.sessionIdCStr = sessionId.cString(using: .utf8) ?? []
        saveSession()
        return sessionId
    }

    static func newId() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    // ── Screens, app state and network ─────────────────────────────────────────

    /// The current screen and app state, on every span and log.
    private var viewAttributes: [String: String] {
        var out = ["rum.app.state": appState]
        if !viewId.isEmpty { out["rum.view.id"] = viewId }
        if !viewName.isEmpty { out["rum.view.name"] = viewName }
        return out
    }

    /// Starts a new view: later spans, logs and errors are attributed to `name`. UIKit view controllers
    /// are captured automatically; call this for SwiftUI screens (e.g. in `.onAppear`) or to rename one.
    public func trackScreen(_ name: String) async {
        await recordScreen(name, start: Date())
    }

    func recordScreen(_ name: String, start: Date) async {
        guard running, consent else { return }
        viewId = String(Self.newId().prefix(16))
        viewName = String(Security.redactText(String(name.prefix(256))).prefix(128))
        await internalSpan("screen_view", [:], start: start)?.end()
    }

    func recordColdStart(_ start: Date) async {
        guard running, consent else { return }
        await internalSpan("app_start", ["app.start.type": "cold"], start: start)?.end()
    }

    func recordAppState(foreground: Bool) async {
        appState = foreground ? "foreground" : "background"
        guard running, consent else { return }
        await internalSpan("app_state", [:])?.end()
        // The app may be suspended or killed in the background: send what is buffered now.
        if !foreground { await bridge?.flushSpans() }
    }

    private func internalSpan(_ name: String, _ attrs: [String: String], kind: OpenTelemetryApi.SpanKind = .internal,
                              start: Date? = nil) async -> AppSpan? {
        guard consent, let bridge else { return nil }
        let generation = gate.generation
        let session = currentSession()
        return await bridge.startAppSpan(name: name, attrs: attrs.merging(viewAttributes) { a, _ in a }, kind: kind,
                                         userId: userId, sessionId: session, previousSessionId: previousSessionId,
                                         generation: generation, start: start)
    }

    /// Exact host or a subdomain of a target; never a lookalike such as `api.example.com.evil.io`.
    static func propagates(host: String, targets: [String]) -> Bool {
        let h = host.lowercased()
        return targets.contains { target in
            let t = target.lowercased().trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && (h == t || h.hasSuffix("." + t))
        }
    }

    private func startNetworkSpan(_ request: URLRequest) async -> (span: AppSpan, header: String?, targets: [String])? {
        guard running, consent, let config, let url = request.url, let host = url.host else { return nil }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.query = nil; parts?.fragment = nil; parts?.user = nil; parts?.password = nil
        let method = String((request.httpMethod ?? "GET").uppercased().prefix(16))
        let attrs = ["http.request.method": method, "server.address": String(host.prefix(255)),
                     "url.full": String(Security.redactText(parts?.string ?? "").prefix(2048))]
        guard let span = await internalSpan(method, attrs, kind: .client) else { return nil }
        let header = span.spanContext.flatMap { ctx in
            Self.propagates(host: host, targets: config.tracePropagationTargets) && (url.scheme == "https" || url.scheme == "http")
                ? "00-\(ctx.traceId)-\(ctx.spanId)-01" : nil
        }
        return (span, header, config.tracePropagationTargets)
    }

    /// `URLSession.data(for:)` recorded as a CLIENT span: method, URL without query or fragment, status and
    /// duration. Adds `traceparent` only for hosts in ``Config/tracePropagationTargets``. No bodies, headers
    /// or cookies are read. Redirects followed by URLSession are part of the same span.
    public nonisolated func data(for request: URLRequest, session: URLSession = .shared) async throws -> (Data, URLResponse) {
        guard let started = await startNetworkSpan(request) else { return try await session.data(for: request) }
        let (span, header) = (started.span, started.header)
        var outgoing = request
        var redirects: RedirectGuard?
        if let header, request.value(forHTTPHeaderField: "traceparent") == nil {
            outgoing.setValue(header, forHTTPHeaderField: "traceparent")
            redirects = RedirectGuard(targets: started.targets, https: request.url?.scheme == "https")
        }
        do {
            let (data, response) = try await session.data(for: outgoing, delegate: redirects)
            span.end(status: (response as? HTTPURLResponse)?.statusCode ?? 0)
            return (data, response)
        } catch {
            span.endWithError(error)
            throw error
        }
    }

    /// Keeps the SDK's `traceparent` only on redirect hops to allowed hosts (never an https → http downgrade).
    /// It is the task delegate of `data(for:)`, so the app's session delegate is not asked about these redirects.
    final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let targets: [String]
        let https: Bool
        init(targets: [String], https: Bool) { self.targets = targets; self.https = https }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            Self.next(request, targets: targets, https: https)
        }

        static func next(_ request: URLRequest, targets: [String], https: Bool) -> URLRequest {
            var next = request
            let host = request.url?.host ?? ""
            if !CeburuAnalyticsSDK.propagates(host: host, targets: targets) || (https && request.url?.scheme != "https") {
                next.setValue(nil, forHTTPHeaderField: "traceparent")
            }
            return next
        }
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
        guard consent else { return }
        breadcrumbs.append(Breadcrumb(category: String(category.prefix(32)),
                                      message: String(Security.redactText(String(message.prefix(512))).prefix(256))))
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
    public nonisolated func error(_ message: String, error: Error? = nil, attributes: [String: Any] = [:]) async {
        // I6: capture call stack HERE — nonisolated, so we're still on the caller's executor
        // before the actor hop. Pre-stringify to [String: String] (Sendable) before crossing.
        let stack = error != nil ? Thread.callStackSymbols : []
        let sendable = Self.stringify(Self.mergeError(attributes, error, stack: stack))
        await emitSendable(.error, message, sendable)
    }

    /// Emits a `FATAL` severity log event.
    ///
    /// Use for unrecoverable failures where the app must crash or restart. Breadcrumbs are attached
    /// automatically. Fatal events bypass the minimum-severity filter and the sample-rate gate.
    /// - Parameters:
    ///   - message:    Human-readable description of the fatal condition.
    ///   - error:      Optional `Error` — its type and `localizedDescription` are added as attributes.
    ///   - attributes: Optional key-value metadata. PII keys are automatically redacted.
    public nonisolated func fatal(_ message: String, error: Error? = nil, attributes: [String: Any] = [:]) async {
        // I6: same pattern as error() — stack captured before actor hop.
        let stack = error != nil ? Thread.callStackSymbols : []
        let sendable = Self.stringify(Self.mergeError(attributes, error, stack: stack))
        await emitSendable(.fatal, message, sendable)
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
    ///   - unit:  Optional UCUM unit for the instrument (e.g. `"{request}"`, `"ms"`). Pass once on
    ///            first call — subsequent calls with the same name reuse the existing instrument.
    public func incrementCounter(
        name:  String,
        value: Int64 = 1,
        attrs: [String: String] = [:],
        unit:  String = ""
    ) async {
        guard consent else { return }
        let generation = gate.generation  // admitted now, checked again by the bridge
        await bridge?.incrementCounter(name: name, value: value, attrs: attrs, unit: unit, generation: generation)
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
    ///   - unit:  Optional UCUM unit (e.g. `"{session}"`). Effective only on first call per name.
    public func incrementUpDownCounter(
        name:  String,
        value: Int64 = 1,
        attrs: [String: String] = [:],
        unit:  String = ""
    ) async {
        guard consent else { return }
        let generation = gate.generation  // admitted now, checked again by the bridge
        await bridge?.incrementUpDownCounter(name: name, value: value, attrs: attrs, unit: unit, generation: generation)
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
    ///   - unit:  Optional UCUM unit (e.g. `"ms"`, `"By"`). Effective only on first call per name.
    public func recordHistogram(
        name:  String,
        value: Double,
        attrs: [String: String] = [:],
        unit:  String = ""
    ) async {
        guard consent else { return }
        let generation = gate.generation  // admitted now, checked again by the bridge
        await bridge?.recordHistogram(name: name, value: value, attrs: attrs, unit: unit, generation: generation)
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
    ///   - unit:     Optional UCUM unit (e.g. `"{session}"`).
    public func observeCounter(name: String, callback: @Sendable @escaping () -> Int64, unit: String = "") async {
        guard consent else { return }
        let generation = gate.generation  // admitted now, checked again by the bridge
        await bridge?.observeCounter(name: name, callback: callback, unit: unit, generation: generation)
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
    ///   - unit:     Optional UCUM unit (e.g. `"MiBy"`, `"{thread}"`).
    public func observeGauge(name: String, callback: @Sendable @escaping () -> Double, unit: String = "") async {
        guard consent else { return }
        let generation = gate.generation  // admitted now, checked again by the bridge
        await bridge?.observeGauge(name: name, callback: callback, unit: unit, generation: generation)
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
        guard consent, let bridge else { return AppSpan(span: nil) }
        let generation = gate.generation  // admitted now; the bridge tags the span with this, not a later value
        let session = currentSession()
        let safeName = String(Security.redactText(String(name.prefix(256))).prefix(128))
        return await bridge.startAppSpan(name: safeName, attrs: Security.redact(Security.bound(attrs)).merging(viewAttributes) { a, _ in a },
                                         kind: otelKind, userId: userId, sessionId: session, previousSessionId: previousSessionId,
                                         generation: generation)
    }

    /// Starts a span, runs `body` with the span's trace/span IDs bound as a task-local,
    /// then ends the span — even if `body` throws.
    ///
    /// Logs emitted inside `body` automatically carry the correct `trace_id` and `span_id`.
    /// This is the concurrency-safe replacement for `startSpan()` / `span.end()`:
    /// the task-local is scoped to `body`'s Task, so concurrent `withSpan` calls on
    /// other Tasks never interfere with each other.
    ///
    /// ```swift
    /// try await sdk.withSpan("checkout.flow", attrs: ["screen": "cart"]) {
    ///     await sdk.info("payment started")   // carries trace_id + span_id
    ///     try await performCheckout()
    ///     await sdk.info("payment complete")  // same span
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - name:  Span name.
    ///   - attrs: Initial span attributes.
    ///   - kind:  Span kind. Defaults to `.internal`.
    ///   - body:  Work to perform inside the span's scope.
    public nonisolated func withSpan<T: Sendable>(
        _ name:  String,
        attrs:   [String: String] = [:],
        kind:    SpanKind         = .internal,
        _  body: () async throws -> T
    ) async rethrows -> T {
        let span = await startSpan(name: name, attrs: attrs, kind: kind)
        if let ctx = span.spanContext {
            return try await CeburuAnalyticsSDK.$_spanContext.withValue(ctx) {
                defer { span.end() }
                return try await body()
            }
        }
        defer { span.end() }
        return try await body()
    }

    // ── Shutdown ───────────────────────────────────────────────────────────────

    /// Stops the SDK, flushes the log queue, and tears down all signal pipelines.
    ///
    /// What this does:
    /// 1. Uninstalls all registered logger adapters, restoring the original logging chain.
    /// 2. Sets `running = false` to stop the flush loop.
    /// 3. Uninstalls the POSIX signal handler.
    /// 4. Shuts down the OTLP/HTTP bridge (flushes in-flight batches and closes the connection).
    ///
    /// After `shutdown()` the SDK can be re-initialized by calling ``initialize(config:)`` again.
    /// Normally you do not need to call this — it is provided for testing and graceful app teardown.
    /// Immediately triggers a metric collection and export cycle.
    ///
    /// Useful during development to verify observable metrics (gauge/counter) are reaching
    /// the collector without waiting for the next scheduled interval.
    /// Forces an immediate metric collection and OTLP/HTTP export.
    /// - Returns: `true` if the export was accepted by the collector, `false` if the connection was refused or timed out.
    @discardableResult
    public func flushMetrics() async -> Bool {
        return await bridge?.flushMetrics() ?? false
    }

    public func shutdown() async {
        #if canImport(UIKit)
        await MainActor.run { AutoCapture.uninstall() }
        #endif
        for adapter in adapters { await adapter.uninstall() }
        adapters.removeAll()
        running = false
        // I8: cancel the flush loop immediately so re-initialization never inherits
        // a stale loop that would start flushing alongside the new one.
        flushTask?.cancel()
        flushTask = nil
        stopCrashCapture()
        await bridge?.shutdown()
        // I8: clear all instance state so re-initialization starts from a known-clean slate.
        bridge  = nil
        storage = nil
        config  = nil
        breadcrumbs.removeAll()
        backoff = RetryBackoff()
        userId  = ""
        sessionId = Self.newId()
        previousSessionId = ""
        gate    = ConsentGate(true)
        viewId  = ""
        viewName = ""
        appState = "foreground"
    }

    // ── Private helpers ────────────────────────────────────────────────────────

    private func emit(_ severity: Severity, _ message: String, _ attributes: [String: Any]) async {
        guard running, consent, let config, let storage else { return }
        if severity.rawValue < config.minSeverity.rawValue { return }
        let generation = gate.generation

        var attrs = Security.redact(Security.bound(attributes))
        if !userId.isEmpty { attrs["user.id"] = userId }
        attrs.merge(viewAttributes) { a, _ in a }
        let session = currentSession()
        if !previousSessionId.isEmpty { attrs["session.previous_id"] = previousSessionId }

        if severity.rawValue >= Severity.error.rawValue && !breadcrumbs.isEmpty {
            attrs["session.breadcrumbs"] = Security.redactText(breadcrumbs
                .map { "\($0.category):\($0.message)" }
                .joined(separator: " | "))
        }

        // I7: read from @TaskLocal (set by withSpan{}) instead of the OTel global context
        // provider. The global provider is not safe under Swift concurrency: a concurrent
        // startSpan() on another Task overwrites the global before this emit() reads it,
        // attaching the wrong trace_id/span_id. TaskLocal is task-scoped and race-free.
        let traceId = Self._spanContext?.traceId
        let spanId  = Self._spanContext?.spanId

        let event = Event(
            eventId:         UUID().uuidString,
            timestampUnixMs: Int64(Date().timeIntervalSince1970 * 1000),
            severity:        severity,
            type:            "log",
            message:         Security.redactText(String(message.prefix(8_192))),
            sessionId:       session,
            attributes:      attrs,
            traceId:         traceId,
            spanId:          spanId
        )

        try? await storage.enqueue(event, generation: generation)
    }

    private enum FlushResult { case flushed, empty, failed(after: TimeInterval?) }

    private func flushPersisted() async -> FlushResult {
        guard consent, !authPaused, let storage, let bridge else { return .empty }
        let generation = gate.generation
        do {
            let rows = try await storage.batch(
                maxEvents:  batchEvents,
                maxBytes:   config?.maxBatchBytes ?? 256 * 1024,
                generation: generation
            )
            // Actor reentrancy: consent may have changed while the batch was read.
            if rows.isEmpty || !consent || gate.generation != generation { return .empty }

            // Decode all events first; discard any with corrupt JSON so they never block
            // the queue. Decryption failures are handled inside storage.batch() (B-4 fix).
            var validFiles:  [URL]   = []
            var validEvents: [Event] = []
            for (file, clear) in rows {
                do {
                    validEvents.append(try JSONDecoder().decode(Event.self, from: clear))
                    validFiles.append(file)
                } catch {
                    await storage.acknowledge([file])  // corrupt JSON — discard
                }
            }

            if validEvents.isEmpty { return .empty }

            // One OTLP/HTTP request per batch; files are deleted only once the ingest answered.
            switch await bridge.emitBatch(validEvents, generation: generation) {
            case .sent:
                await storage.acknowledge(validFiles)
                batchEvents = min(config?.maxBatchEvents ?? 200, batchEvents * 2)
                return .flushed
            case .unauthorized:
                // Keep the queue and stop sending until updateApiKey(_:) or the next launch.
                authPaused = true
                return .failed(after: nil)
            case .tooLarge:
                if validFiles.count == 1 { await storage.acknowledge(validFiles) } else { batchEvents = max(1, validFiles.count / 2) }
                return .failed(after: nil)
            case .rejected:
                await storage.acknowledge(validFiles)  // 400: retrying cannot succeed
                return .failed(after: nil)
            case .retry(let after):
                return .failed(after: after)
            }
        } catch {
            return .failed(after: nil)
        }
    }

    /// Imports crashes saved by the previous launch and installs the crash handlers (consent granted).
    private func startCrashCapture() async {
        guard let storage else { return }
        let generation = gate.generation
        try? await storage.importCrashRecords(sessionId: sessionId, generation: generation)
        try? await storage.importSignalCrashRecords(sessionId: sessionId, generation: generation)
        // Actor reentrancy: a withdrawal or shutdown may have run during the imports; then the handlers stay off.
        guard running, consent, gate.generation == generation, self.storage === storage else { return }
        installExceptionHandler()
        SignalCrashHandler.install(crashDir: storage.crashDir, sessionId: sessionId)
    }

    /// Removes the crash handlers and restores the ones that were installed before ours.
    private func stopCrashCapture() {
        SignalCrashHandler.uninstall()
        guard CeburuAnalyticsSDK._crashStorage != nil else { return }
        NSSetUncaughtExceptionHandler(CeburuAnalyticsSDK._previousExceptionHandler)
        CeburuAnalyticsSDK._previousExceptionHandler = nil
        CeburuAnalyticsSDK._crashStorage = nil
    }

    private func installExceptionHandler() {
        guard let storage, CeburuAnalyticsSDK._crashStorage == nil else { return }
        CeburuAnalyticsSDK._crashStorage   = storage
        CeburuAnalyticsSDK._crashSessionId = sessionId

        // H-3: preserve any existing handler (e.g. Crashlytics, Sentry).
        // Stored in a static — @convention(c) closures cannot capture stack locals.
        CeburuAnalyticsSDK._previousExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            CeburuAnalyticsSDK._crashStorage?.persistException(exception, sessionId: CeburuAnalyticsSDK._crashSessionId)
            SignalCrashHandler.exceptionAlreadyCaptured = true
            CeburuAnalyticsSDK._previousExceptionHandler?(exception)
        }
    }

    // Static so it can be called from nonisolated error()/fatal() before the actor hop:
    // flat scalars only, bounded (nested values are dropped).
    private static func stringify(_ attrs: [String: Any]) -> [String: String] {
        Security.bound(attrs)
    }

    // Thin actor-isolated bridge for the nonisolated error()/fatal() path.
    // Accepts [String: String] (Sendable) produced before the actor hop; re-uses
    // the full emit() pipeline including Security.redact() and quota enforcement.
    private func emitSendable(_ severity: Severity, _ message: String, _ attrs: [String: String]) async {
        await emit(severity, message, attrs as [String: Any])
    }

    private static func mergeError(_ attrs: [String: Any], _ error: Error?, stack: [String] = []) -> [String: Any] {
        guard let error else { return attrs }
        var out = attrs
        out["exception.type"]    = String(describing: type(of: error))
        out["exception.message"] = String(error.localizedDescription.prefix(1024))
        if !stack.isEmpty {
            out["exception.stacktrace"] = String(stack.joined(separator: "\n").prefix(16_000))
        }
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
        // Span context captured at enqueue time. nil when no span was active.
        // Optional so old on-disk events (without these keys) decode cleanly.
        let traceId:         String?
        let spanId:          String?
    }

    struct Breadcrumb: Sendable {
        let category: String
        let message:  String
    }
}