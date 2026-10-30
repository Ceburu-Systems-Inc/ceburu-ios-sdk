import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk
import OpenTelemetryProtocolExporterHttp
import OpenTelemetryProtocolExporterCommon

/// Internal OpenTelemetry bridge — owns the SDK's private providers (it never registers the global
/// `OpenTelemetry` instance, so a host app's own OpenTelemetry setup is left alone).
///
/// Logs go from the encrypted queue straight to `{endpoint}/v1/logs` as OTLP/JSON (``emitBatch(_:generation:)``);
/// spans and metrics use OpenTelemetry pipelines. All share one `Resource`:
/// - **Metrics**: `{endpoint}/v1/metrics` — every `metricsExportInterval` seconds.
/// - **Traces**: `{endpoint}/v1/traces` — exported within ~5 s of `span.end()`.
///
/// > Token rotation: call ``updateToken(_:)`` — it rebuilds both exporters so the
/// > next export request uses the new Bearer token immediately.
actor AnalyticsBridge {

    /// Outcome of one log batch: accepted, retry (optionally after `Retry-After` seconds), 413, other 4xx, 401/403.
    enum Export: Equatable { case sent, retry(after: TimeInterval?), tooLarge, rejected, unauthorized }

    static func outcome(status: Int, retryAfter: String?, now: Date = Date()) -> Export {
        switch status {
        case 200..<300: return .sent
        case 401, 403:  return .unauthorized
        case 413:       return .tooLarge
        case 408, 429:  return .retry(after: retryAfter.flatMap { seconds($0, now: now) })
        case 400..<500: return .rejected
        default:        return .retry(after: retryAfter.flatMap { seconds($0, now: now) })
        }
    }

    /// Retry-After as delta seconds or an HTTP date.
    static func seconds(_ value: String, now: Date) -> TimeInterval? {
        let text = value.trimmingCharacters(in: .whitespaces)
        if let delta = TimeInterval(text) { return max(0, delta) }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "GMT")
        format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return format.date(from: text).map { max(0, $0.timeIntervalSince(now)) }
    }

    static let maxInstruments = 100

    static func validInstrumentName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z][A-Za-z0-9_./-]{0,62}$"#, options: .regularExpression) != nil
    }

    // Kept so observable instruments are registered again after a token rotation rebuilds the pipelines.
    private enum Observable {
        case counter(name: String, unit: String, callback: @Sendable () -> Int64)
        case gauge(name: String, unit: String, callback: @Sendable () -> Double)
    }
    private var observables: [Observable] = []

    // While consent is withdrawn span and metric exports are dropped, not sent.
    private let gate: ConsentGate
    private var tracer: OpenTelemetryApi.Tracer?
    private var meterSdk: MeterSdk?
    private var metricReader: PeriodicMetricReaderSdk?
    private var spanProcessor: BatchSpanProcessor?     // stored so shutdown() can flush it (H-2 fix)

    // Current auth token — rebuilt into fresh OtlpConfiguration on updateToken().
    private var currentToken: String

    // Stored so pipelines can be rebuilt on token rotation.
    private let resource: Resource
    private let logsEndpoint: URL
    private let tracesEndpoint: URL
    private let metricsEndpoint: URL
    private let metricsExportInterval: TimeInterval

    // App-level metric instruments — created lazily on first use, keyed by name.
    private var appCounters:       [String: LongCounterSdk]          = [:]
    private var appUpDownCounters: [String: LongUpDownCounterSdk]    = [:]
    private var appHistograms:     [String: DoubleHistogramMeterSdk] = [:]

    // Observable instruments — keep references alive; closed on shutdown to stop callbacks.
    private var observableInstruments: [ObservableInstrumentSdk] = []

    /// Builds the three OpenTelemetry signal pipelines over OTLP/HTTP.
    ///
    /// - Parameters:
    ///   - config:      SDK configuration; `apiKey` is sent as `authorization: Bearer …`.
    ///   - endpoint:    Validated RUM endpoint without a trailing slash.
    ///   - installId:   Random per-install id (`app.installation.id`).
    ///   - deviceModel: Hardware model identifier (e.g. `iPhone15,2`).
    ///   - osName:      `"iOS"` or `"macOS"`.
    ///   - osVersion:   OS version string.
    init(config: CeburuAnalyticsSDK.Config,
         gate: ConsentGate,
         endpoint: String,
         installId: String,
         deviceModel: String,
         osName: String,
         osVersion: String) {

        self.currentToken          = config.apiKey
        self.gate                  = gate
        self.metricsExportInterval = config.metricsExportInterval
        // endpoint was validated by initialize(config:), so these URLs always parse.
        self.logsEndpoint    = URL(string: "\(endpoint)/v1/logs")!
        self.tracesEndpoint  = URL(string: "\(endpoint)/v1/traces")!
        self.metricsEndpoint = URL(string: "\(endpoint)/v1/metrics")!

        // Tenant and app come from the key at the ingest; nothing here is per launch or per user.
        self.resource = Resource(attributes: [
            "service.name":                AttributeValue.string(config.serviceName),
            "service.version":             AttributeValue.string(config.serviceVersion),
            "deployment.environment.name": AttributeValue.string(config.environment),
            "ceburu.signal":               AttributeValue.string("rum"),
            "rum.platform":                AttributeValue.string("ios"),
            "telemetry.distro.name":       AttributeValue.string(CeburuAnalyticsSDK.sdkName),
            "telemetry.distro.version":    AttributeValue.string(CeburuAnalyticsSDK.sdkVersion),
            "app.installation.id":         AttributeValue.string(installId),
            "device.manufacturer":         AttributeValue.string("Apple"),
            "device.model.identifier":     AttributeValue.string(deviceModel),
            "os.type":                     AttributeValue.string("darwin"),
            "os.name":                     AttributeValue.string(osName),
            "os.version":                  AttributeValue.string(osVersion)
        ])

        // Build pipelines using the static factory so the call is legal from an
        // actor init (which is non-isolated in Swift 6 — instance methods cannot
        // be called here, but static functions are always accessible).
        let p = Self.makePipelines(
            token:                 config.apiKey,
            gate:                  gate,
            resource:              resource,
            tracesEndpoint:        tracesEndpoint,
            metricsEndpoint:       metricsEndpoint,
            metricsExportInterval: metricsExportInterval
        )
        metricReader            = p.metricReader
        meterSdk                = p.meterSdk
        spanProcessor           = p.spanProcessor
        tracer                  = p.tracer
    }

    // ── Pipeline construction ──────────────────────────────────────────────────

    // All pipeline objects bundled for pass-by-value between the static factory
    // and the actor's stored properties.
    private struct PipelineSet {
        let metricReader:           PeriodicMetricReaderSdk
        let meterSdk:               MeterSdk
        let spanProcessor:          BatchSpanProcessor
        let tracer:                 OpenTelemetryApi.Tracer
    }

    /// Creates the span and metric pipelines on private providers. Static so it is callable from `init`
    /// without actor isolation, and from the isolated `buildPipelines` instance method.
    private static func makePipelines(
        token:                 String,
        gate:                  ConsentGate,
        resource:              Resource,
        tracesEndpoint:        URL,
        metricsEndpoint:       URL,
        metricsExportInterval: TimeInterval
    ) -> PipelineSet {
        let otlpHeaders: [(String, String)]? = token.isEmpty
            ? nil
            : [("authorization", "Bearer \(token)")]
        let otlpConfig = OtlpConfiguration(headers: otlpHeaders)

        // ── Metrics pipeline ───────────────────────────────────────────────────
        let metricExp    = GatedMetricExporter(OtlpHttpMetricExporter(endpoint: metricsEndpoint, config: otlpConfig), gate)
        let metricReader = PeriodicMetricReaderBuilder(exporter: metricExp)
            .setInterval(timeInterval: metricsExportInterval)
            .build()

        let meterProvider: MeterProviderSdk = MeterProviderSdk.builder()
            .registerMetricReader(reader: metricReader)
            .setResource(resource: resource)
            .registerView(
                selector: InstrumentSelector.builder().build(),
                view: View.builder().build()
            )
            .build()

        let meterSdkInst = meterProvider.get(name: CeburuAnalyticsSDK.sdkName)

        // ── Traces pipeline ────────────────────────────────────────────────────
        let spanExp  = GatedSpanExporter(OtlpHttpTraceExporter(endpoint: tracesEndpoint, config: otlpConfig), gate)
        let spanProc = BatchSpanProcessor(spanExporter: spanExp)

        let tracerProvider = TracerProviderBuilder()
            .add(spanProcessor: spanProc)
            .with(resource: resource)
            .build()

        let tracerInst = tracerProvider.get(
            instrumentationName:    CeburuAnalyticsSDK.sdkName,
            instrumentationVersion: CeburuAnalyticsSDK.sdkVersion
        )

        return PipelineSet(
            metricReader:           metricReader,
            meterSdk:               meterSdkInst,
            spanProcessor:          spanProc,
            tracer:                 tracerInst
        )
    }

    /// Rebuilds both pipelines with a new token. Called only from ``updateToken(_:)``.
    private func buildPipelines(token: String) {
        let p = Self.makePipelines(
            token:                 token,
            gate:                  gate,
            resource:              resource,
            tracesEndpoint:        tracesEndpoint,
            metricsEndpoint:       metricsEndpoint,
            metricsExportInterval: metricsExportInterval
        )
        metricReader            = p.metricReader
        meterSdk                = p.meterSdk
        spanProcessor           = p.spanProcessor
        tracer                  = p.tracer
    }

    // ── Metric flush ───────────────────────────────────────────────────────────

    /// Forces an immediate metric collection and export cycle.
    func flushMetrics() -> Bool {
        guard let metricReader else { return false }
        switch metricReader.forceFlush() {
        case .success: return true
        case .failure: return false
        }
    }

    // ── Consent ────────────────────────────────────────────────────────────────

    func flushSpans() { spanProcessor?.forceFlush() }

    /// Consent withdrawn: rebuilds the pipelines so no metric aggregation state or callback state outlives it.
    func resetPipelines() {
        teardownPipelines()
        buildPipelines(token: currentToken)
        for definition in observables { register(definition) }
    }

    /// After a withdrawal: buffered spans and metrics are exported through the gate now, so they are dropped.
    func dropBuffered() {
        spanProcessor?.forceFlush()
        _ = metricReader?.forceFlush()
    }

    // ── Token rotation ─────────────────────────────────────────────────────────

    /// Replaces the key and rebuilds the export pipelines; in-flight data is flushed first.
    func updateToken(_ token: String) {
        guard token != currentToken else { return }
        teardownPipelines()
        currentToken = token
        buildPipelines(token: token)
        for definition in observables { register(definition) }
    }

    // ── Batch log emit (durable flush path) ────────────────────────────────────

    /// Exports a batch of queued events to `{endpoint}/v1/logs` as OTLP/JSON and classifies the answer
    /// with ``outcome(status:retryAfter:)``; network errors retry.
    func emitBatch(_ events: [CeburuAnalyticsSDK.Event], generation: Int) async -> Export {
        guard !events.isEmpty else { return .sent }
        // Withdrawn since the batch was read: these files belong to the purged generation.
        guard gate.isGranted, gate.generation == generation else { return .sent }
        guard let bodyData = try? JSONSerialization.data(
            withJSONObject: buildOTLPLogsPayload(events)
        ) else { return .rejected }

        // Direct URLSession call: delivery is confirmed by the real HTTP status code.
        var request = URLRequest(url: logsEndpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !currentToken.isEmpty {
            request.setValue("Bearer \(currentToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = bodyData

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .retry(after: nil) }
            return Self.outcome(status: http.statusCode, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
        } catch {
            return .retry(after: nil)
        }
    }

    // ── App-level metrics ──────────────────────────────────────────────────────

    /// Few, short, redacted labels: each distinct combination is a separate series.
    /// The first 8 labels are cut to size before redaction (no sort): a large map or value costs no more than 8 short ones.
    private func labels(_ attrs: [String: String]) -> [String: AttributeValue] {
        var bounded: [String: String] = [:]
        for (k, v) in attrs {
            if bounded.count >= 8 { break }
            bounded[String(k.prefix(64))] = String(v.prefix(128))
        }
        return Security.redact(bounded).mapValues { .string($0) }
    }

    // Invalid names and names past `maxInstruments` are ignored: no unbounded instrument registry.
    private func allowed<T>(_ registry: [String: T], _ name: String) -> Bool {
        registry[name] != nil || (Self.validInstrumentName(name) && registry.count < Self.maxInstruments)
    }

    func incrementCounter(name: String, value: Int64, attrs: [String: String], unit: String = "", generation: Int) {
        guard gate.metricsEnabled, generation == gate.generation, let meterSdk, allowed(appCounters, name) else { return }
        if appCounters[name] == nil {
            let b = meterSdk.counterBuilder(name: name)
            appCounters[name] = !unit.isEmpty ? b.setUnit(unit).build() : b.build()
        }
        appCounters[name]?.add(value: Int(value), attributes: labels(attrs))
    }

    func incrementUpDownCounter(name: String, value: Int64, attrs: [String: String], unit: String = "", generation: Int) {
        guard gate.metricsEnabled, generation == gate.generation, let meterSdk, allowed(appUpDownCounters, name) else { return }
        if appUpDownCounters[name] == nil {
            let b = meterSdk.upDownCounterBuilder(name: name)
            appUpDownCounters[name] = !unit.isEmpty ? b.setUnit(unit).build() : b.build()
        }
        appUpDownCounters[name]?.add(value: Int(value), attributes: labels(attrs))
    }

    func recordHistogram(name: String, value: Double, attrs: [String: String], unit: String = "", generation: Int) {
        guard gate.metricsEnabled, generation == gate.generation, let meterSdk, allowed(appHistograms, name) else { return }
        if appHistograms[name] == nil {
            let b = meterSdk.histogramBuilder(name: name)
            appHistograms[name] = !unit.isEmpty ? b.setUnit(unit).build() : b.build()
        }
        appHistograms[name]?.record(value: value, attributes: labels(attrs))
    }

    func observeCounter(name: String, callback: @Sendable @escaping () -> Int64, unit: String = "", generation: Int) {
        guard generation == gate.generation, Self.validInstrumentName(name), observables.count < Self.maxInstruments else { return }
        let definition = Observable.counter(name: name, unit: unit, callback: callback)
        observables.append(definition)
        register(definition)
    }

    private func register(_ definition: Observable) {
        guard let meterSdk else { return }
        switch definition {
        case let .counter(name, unit, callback):
            let b = meterSdk.counterBuilder(name: name)
            observableInstruments.append((!unit.isEmpty ? b.setUnit(unit) : b)
                .ofDoubles()
                .buildWithCallback { measurement in measurement.record(value: Double(callback()), attributes: [:]) })
        case let .gauge(name, unit, callback):
            let b = meterSdk.gaugeBuilder(name: name)
            observableInstruments.append((!unit.isEmpty ? b.setUnit(unit) : b)
                .buildWithCallback { measurement in measurement.record(value: callback(), attributes: [:]) })
        }
    }

    func observeGauge(name: String, callback: @Sendable @escaping () -> Double, unit: String = "", generation: Int) {
        guard generation == gate.generation, Self.validInstrumentName(name), observables.count < Self.maxInstruments else { return }
        let definition = Observable.gauge(name: name, unit: unit, callback: callback)
        observables.append(definition)
        register(definition)
    }

    // ── App-level traces ───────────────────────────────────────────────────────

    func startAppSpan(
        name:   String,
        attrs:  [String: String],
        kind:   OpenTelemetryApi.SpanKind,
        userId: String,
        sessionId: String,
        previousSessionId: String,
        generation: Int,
        start: Date? = nil
    ) -> CeburuAnalyticsSDK.AppSpan {
        guard let tracer else { return CeburuAnalyticsSDK.AppSpan(span: nil) }
        let builder = tracer.spanBuilder(spanName: name).setSpanKind(spanKind: kind)
        if let start { _ = builder.setStartTime(time: start) }
        attrs.forEach { k, v in _ = builder.setAttribute(key: k, value: AttributeValue.string(v)) }
        _ = builder.setAttribute(key: "session.id", value: AttributeValue.string(sessionId))
        if !previousSessionId.isEmpty {
            _ = builder.setAttribute(key: "session.previous_id", value: AttributeValue.string(previousSessionId))
        }
        if !userId.isEmpty {
            _ = builder.setAttribute(key: "user.id", value: AttributeValue.string(userId))
        }
        let span = builder.startSpan()
        gate.tag(span.context.spanId.hexString, generation: generation)  // the caller's admission snapshot
        return CeburuAnalyticsSDK.AppSpan(span: span)
    }

    // ── Shutdown ───────────────────────────────────────────────────────────────

    /// Flushes both pipelines, closes observable instruments, and
    /// releases all pipeline references.
    func shutdown() {
        observables.removeAll()
        teardownPipelines()
    }

    // ── Private helpers ────────────────────────────────────────────────────────

    /// Flushes and shuts down both pipelines. Safe to call before a rebuild.
    private func teardownPipelines() {
        observableInstruments.forEach { $0.close() }
        observableInstruments.removeAll()

        _ = spanProcessor?.forceFlush()
        _ = spanProcessor?.shutdown()

        _ = metricReader?.forceFlush()
        _ = metricReader?.shutdown()

        tracer               = nil
        spanProcessor        = nil
        meterSdk             = nil
        metricReader         = nil

        // H-1: clear cached instrument objects so they are recreated against the
        // new meterSdk after a token rotation — stale instruments silently drop data.
        appCounters.removeAll()
        appUpDownCounters.removeAll()
        appHistograms.removeAll()
    }

    private func buildOTLPLogsPayload(_ events: [CeburuAnalyticsSDK.Event]) -> [String: Any] {
        let resourceAttrs: [[String: Any]] = resource.attributes.map { key, value in
            ["key": key, "value": ["stringValue": value.description]]
        }
        let logRecords: [[String: Any]] = events.map { event in
            let eventName = event.type == "crash" ? "rum.crash"
                : event.severity.rawValue >= CeburuAnalyticsSDK.Severity.error.rawValue ? "rum.error" : "rum.log"
            var attrs: [[String: Any]] = [
                ["key": "event.id",   "value": ["stringValue": event.eventId]],
                ["key": "session.id", "value": ["stringValue": event.sessionId]],
                ["key": "event.name", "value": ["stringValue": eventName]]
            ]
            for (k, v) in event.attributes {
                attrs.append(["key": k, "value": ["stringValue": v]])
            }
            let timeNs = String(event.timestampUnixMs * 1_000_000)
            var record: [String: Any] = [
                "timeUnixNano":         timeNs,
                "observedTimeUnixNano": timeNs,
                "severityNumber":       otlpSeverityNumber(event.severity),
                "severityText":         otlpSeverityText(event.severity),
                "body":                 ["stringValue": event.message],
                "attributes":           attrs
            ]
            if let t = event.traceId { record["traceId"] = t }
            if let s = event.spanId  { record["spanId"]  = s }
            return record
        }
        return [
            "resourceLogs": [[
                "resource":  ["attributes": resourceAttrs],
                "scopeLogs": [[
                    "scope":      ["name": CeburuAnalyticsSDK.sdkName,
                                   "version": CeburuAnalyticsSDK.sdkVersion],
                    "logRecords": logRecords
                ]]
            ]]
        ]
    }

    private func otlpSeverityNumber(_ s: CeburuAnalyticsSDK.Severity) -> Int {
        switch s {
        case .trace: return 1;  case .debug: return 5
        case .info:  return 9;  case .warn:  return 13
        case .error: return 17; case .fatal: return 21
        }
    }

    private func otlpSeverityText(_ s: CeburuAnalyticsSDK.Severity) -> String {
        switch s {
        case .trace: return "TRACE"; case .debug: return "DEBUG"
        case .info:  return "INFO";  case .warn:  return "WARN"
        case .error: return "ERROR"; case .fatal: return "FATAL"
        }
    }

}

/// Consent plus a generation bumped on every withdrawal, shared with the exporters and the queue. Spans are
/// tagged with the generation they started in and only the current one is exported, so a withdraw → grant
/// cannot release earlier data whichever order the background work runs in.
final class ConsentGate: @unchecked Sendable {
    private let lock = NSLock()
    private var granted: Bool
    private var current = 0
    private var spans: [String: Int] = [:]
    let metricsEnabled: Bool
    init(_ granted: Bool, metricsEnabled: Bool = false, generation: Int = 0) {
        self.granted = granted
        self.metricsEnabled = metricsEnabled
        current = generation
    }
    var isGranted: Bool {
        get { lock.lock(); defer { lock.unlock() }; return granted }
        set { lock.lock(); granted = newValue; lock.unlock() }
    }
    var generation: Int { lock.lock(); defer { lock.unlock() }; return current }

    /// Withdraws consent and returns the new generation.
    func revoke() -> Int {
        lock.lock(); defer { lock.unlock() }
        granted = false
        current += 1
        return current
    }

    func tag(_ spanId: String, generation: Int) {
        lock.lock(); defer { lock.unlock() }
        if spans.count > 10_000 { spans.removeAll() }  // spans that were never ended
        spans[spanId] = generation
    }

    /// True when the span may leave: consent granted and started in the current generation.
    func allows(_ spanId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return spans.removeValue(forKey: spanId) == current && granted
    }
}

/// Exports only spans the gate allows (reporting success for the rest). Sync API only, like the OTLP exporters.
final class GatedSpanExporter: SpanExporter {
    private let inner: SpanExporter
    private let gate: ConsentGate
    init(_ inner: SpanExporter, _ gate: ConsentGate) { self.inner = inner; self.gate = gate }

    @discardableResult func export(spans: [SpanData], explicitTimeout: TimeInterval?) -> SpanExporterResultCode {
        let allowed = spans.filter { gate.allows($0.spanId.hexString) }
        return allowed.isEmpty ? .success : inner.export(spans: allowed, explicitTimeout: explicitTimeout)
    }
    func flush(explicitTimeout: TimeInterval?) -> SpanExporterResultCode { inner.flush(explicitTimeout: explicitTimeout) }
    func shutdown(explicitTimeout: TimeInterval?) { inner.shutdown(explicitTimeout: explicitTimeout) }
}

/// Off unless `Config.exportMetrics`; drops exports (reporting success) while consent is withdrawn. The first
/// export after a withdrawal is dropped too: it can hold values recorded before it. Delta temporality, so
/// nothing recorded earlier carries over into later exports.
final class GatedMetricExporter: MetricExporter, @unchecked Sendable {
    private let inner: MetricExporter
    private let gate: ConsentGate
    private let lock = NSLock()
    private var exportedGeneration: Int
    init(_ inner: MetricExporter, _ gate: ConsentGate) { self.inner = inner; self.gate = gate; exportedGeneration = gate.generation }

    func export(metrics: [MetricData]) -> ExportResult {
        guard allowsExport() else { return .success }
        return inner.export(metrics: metrics)
    }

    private func allowsExport() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let generation = gate.generation
        if generation != exportedGeneration { exportedGeneration = generation; return false }
        return gate.metricsEnabled && gate.isGranted
    }
    func flush() -> ExportResult { inner.flush() }
    func shutdown() -> ExportResult { inner.shutdown() }
    func getAggregationTemporality(for instrument: InstrumentType) -> AggregationTemporality { .delta }
    func getDefaultAggregation(for instrument: InstrumentType) -> Aggregation { inner.getDefaultAggregation(for: instrument) }
}
