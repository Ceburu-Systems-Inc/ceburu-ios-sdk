import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk
import OpenTelemetryProtocolExporterHttp
import OpenTelemetryProtocolExporterCommon

/// Internal OpenTelemetry bridge — owns the SDK's private Analytics instance.
///
/// Manages three signal pipelines over OTLP/HTTP (URLSession):
/// - **Logs**: `POST /apm/v1/logs` — durable path via ``emitBatch(_:)`` from the flush loop.
/// - **Metrics**: `POST /apm/v1/metrics` — polled every 60 s by `PeriodicMetricReaderSdk`.
/// - **Traces**: `POST /apm/v1/traces` — exported within ~5 s of `span.end()`.
///
/// All three pipelines share the same `Resource` (tenant, config, device metadata)
/// so cross-signal correlation works in the backend.
///
/// > Token rotation: call ``updateToken(_:)`` — it rebuilds all three exporters so the
/// > next export request uses the new Bearer token immediately.
actor AnalyticsBridge {

    private var logger: OpenTelemetryApi.Logger?
    private var logProcessor: BatchLogRecordProcessor?
    private var logExporter: OtlpHttpLogExporter?      // stored for direct batch export (B-2 fix)
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

    // SDK-internal health counters — visible in the collector, invisible to the app.
    private var sdkEventsEmittedCounter: LongCounterSdk?
    private var sdkEventsDroppedCounter: LongCounterSdk?
    private var sdkExportSuccessCounter: LongCounterSdk?
    private var sdkExportFailureCounter: LongCounterSdk?

    /// Builds the three OpenTelemetry signal pipelines over OTLP/HTTP.
    ///
    /// - Parameters:
    ///   - config:      SDK configuration. `collectorHost`/`collectorPort` and `useHTTPS`
    ///                  determine the OTLP endpoint URLs. `authToken` is sent as the
    ///                  `authorization: Bearer …` HTTP header on every export request.
    ///   - deviceModel: Device model string resolved by the caller (e.g. via `sysctlbyname`).
    ///   - osName:      Human-readable OS name (`"iOS"`, `"macOS"`).
    ///   - osVersion:   OS version string.
    /// - Throws: If the OTLP endpoint URL cannot be constructed.
    init(config: CeburuAnalyticsSDK.Config,
         deviceModel: String,
         osName: String,
         osVersion: String) throws {

        self.currentToken          = config.authToken
        self.metricsExportInterval = config.metricsExportInterval

        let scheme     = config.useHTTPS ? "https" : "http"
        let base       = "\(scheme)://\(config.collectorHost):\(config.collectorPort)"
        let pathPrefix = config.useStandardOTLPPaths ? "" : "/apm"

        guard
            let logsURL    = URL(string: "\(base)\(pathPrefix)/v1/logs"),
            let tracesURL  = URL(string: "\(base)\(pathPrefix)/v1/traces"),
            let metricsURL = URL(string: "\(base)\(pathPrefix)/v1/metrics")
        else {
            throw NSError(domain: "CeburuAnalyticsSDK", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid collectorHost: \(config.collectorHost)"])
        }

        self.logsEndpoint    = logsURL
        self.tracesEndpoint  = tracesURL
        self.metricsEndpoint = metricsURL

        self.resource = Resource(attributes: [
            "service.name":                   AttributeValue.string(config.serviceName),
            "service.version":                AttributeValue.string(config.serviceVersion),
            "deployment.environment.name":    AttributeValue.string(config.environment),
            "tenant.id":                      AttributeValue.string(config.tenantId),
            "application.id":                 AttributeValue.string(config.applicationId),
            "config_id":                      AttributeValue.string(config.configId),
            // X1: enduser.id is NOT a Resource attribute — Resource describes the service, not
            // the current user. Baking it here freezes it at init time and ignores setUser()
            // calls. It is injected per-event in emit() (logs) and startAppSpan() (spans).
            "service.instance.id":            AttributeValue.string(UUID().uuidString),
            "device.manufacturer":            AttributeValue.string("Apple"),
            "device.model.name":              AttributeValue.string(deviceModel),
            "os.type":                        AttributeValue.string("darwin"),
            "os.name":                        AttributeValue.string(osName),
            "os.version":                     AttributeValue.string(osVersion),
            "telemetry.sdk.name":             AttributeValue.string(CeburuAnalyticsSDK.sdkName),
            "telemetry.sdk.version":          AttributeValue.string(CeburuAnalyticsSDK.sdkVersion),
            "telemetry.sdk.language":         AttributeValue.string("swift")
        ])

        // Build pipelines using the static factory so the call is legal from an
        // actor init (which is non-isolated in Swift 6 — instance methods cannot
        // be called here, but static functions are always accessible).
        let p = Self.makePipelines(
            token:                 config.authToken,
            resource:              resource,
            logsEndpoint:          logsEndpoint,
            tracesEndpoint:        tracesEndpoint,
            metricsEndpoint:       metricsEndpoint,
            metricsExportInterval: metricsExportInterval
        )
        logExporter             = p.logExporter
        logProcessor            = p.logProcessor
        logger                  = p.logger
        metricReader            = p.metricReader
        meterSdk                = p.meterSdk
        sdkEventsEmittedCounter = p.sdkEventsEmittedCounter
        sdkEventsDroppedCounter = p.sdkEventsDroppedCounter
        sdkExportSuccessCounter = p.sdkExportSuccessCounter
        sdkExportFailureCounter = p.sdkExportFailureCounter
        spanProcessor           = p.spanProcessor
        tracer                  = p.tracer
    }

    // ── Pipeline construction ──────────────────────────────────────────────────

    // All pipeline objects bundled for pass-by-value between the static factory
    // and the actor's stored properties.
    private struct PipelineSet {
        let logExporter:            OtlpHttpLogExporter
        let logProcessor:           BatchLogRecordProcessor
        let logger:                 OpenTelemetryApi.Logger
        let metricReader:           PeriodicMetricReaderSdk
        let meterSdk:               MeterSdk
        let sdkEventsEmittedCounter: LongCounterSdk
        let sdkEventsDroppedCounter: LongCounterSdk
        let sdkExportSuccessCounter: LongCounterSdk
        let sdkExportFailureCounter: LongCounterSdk
        let spanProcessor:          BatchSpanProcessor
        let tracer:                 OpenTelemetryApi.Tracer
    }

    /// Creates all three signal pipelines and registers their providers with the
    /// global `OpenTelemetry` instance. Static so it is callable from `init` without
    /// actor isolation, and from the isolated `buildPipelines` instance method.
    private static func makePipelines(
        token:                 String,
        resource:              Resource,
        logsEndpoint:          URL,
        tracesEndpoint:        URL,
        metricsEndpoint:       URL,
        metricsExportInterval: TimeInterval
    ) -> PipelineSet {
        let otlpHeaders: [(String, String)]? = token.isEmpty
            ? nil
            : [("authorization", "Bearer \(token)")]
        let otlpConfig = OtlpConfiguration(headers: otlpHeaders)

        // ── Logs pipeline ──────────────────────────────────────────────────────
        let logExp  = OtlpHttpLogExporter(endpoint: logsEndpoint, config: otlpConfig)
        let logProc = BatchLogRecordProcessor(logRecordExporter: logExp)

        let loggerProvider = LoggerProviderBuilder()
            .with(processors: [logProc])
            .with(resource: resource)
            .build()
        OpenTelemetry.registerLoggerProvider(loggerProvider: loggerProvider)

        let loggerInst = OpenTelemetry.instance.loggerProvider
            .loggerBuilder(instrumentationScopeName: CeburuAnalyticsSDK.sdkName)
            .setInstrumentationVersion(CeburuAnalyticsSDK.sdkVersion)
            .build()

        // ── Metrics pipeline ───────────────────────────────────────────────────
        let metricExp    = OtlpHttpMetricExporter(endpoint: metricsEndpoint, config: otlpConfig)
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
        OpenTelemetry.registerMeterProvider(meterProvider: meterProvider)

        let meterSdkInst = meterProvider.get(name: CeburuAnalyticsSDK.sdkName)
        let sdkMeter     = meterProvider.get(name: "\(CeburuAnalyticsSDK.sdkName).internal")

        // ── Traces pipeline ────────────────────────────────────────────────────
        let spanExp  = OtlpHttpTraceExporter(endpoint: tracesEndpoint, config: otlpConfig)
        let spanProc = BatchSpanProcessor(spanExporter: spanExp)

        let tracerProvider = TracerProviderBuilder()
            .add(spanProcessor: spanProc)
            .with(resource: resource)
            .build()
        OpenTelemetry.registerTracerProvider(tracerProvider: tracerProvider)

        let tracerInst = OpenTelemetry.instance.tracerProvider.get(
            instrumentationName:    CeburuAnalyticsSDK.sdkName,
            instrumentationVersion: CeburuAnalyticsSDK.sdkVersion
        )

        return PipelineSet(
            logExporter:            logExp,
            logProcessor:           logProc,
            logger:                 loggerInst,
            metricReader:           metricReader,
            meterSdk:               meterSdkInst,
            sdkEventsEmittedCounter: sdkMeter.counterBuilder(name: "mobile.sdk.events.emitted")
                                        .setUnit("{event}").build(),
            sdkEventsDroppedCounter: sdkMeter.counterBuilder(name: "mobile.sdk.events.dropped")
                                        .setUnit("{event}").build(),
            sdkExportSuccessCounter: sdkMeter.counterBuilder(name: "mobile.sdk.export.success")
                                        .setUnit("{batch}").build(),
            sdkExportFailureCounter: sdkMeter.counterBuilder(name: "mobile.sdk.export.failure")
                                        .setUnit("{batch}").build(),
            spanProcessor:          spanProc,
            tracer:                 tracerInst
        )
    }

    /// Rebuilds all three pipelines with a new token. Called only from ``updateToken(_:)``.
    private func buildPipelines(token: String) {
        let p = Self.makePipelines(
            token:                 token,
            resource:              resource,
            logsEndpoint:          logsEndpoint,
            tracesEndpoint:        tracesEndpoint,
            metricsEndpoint:       metricsEndpoint,
            metricsExportInterval: metricsExportInterval
        )
        logExporter             = p.logExporter
        logProcessor            = p.logProcessor
        logger                  = p.logger
        metricReader            = p.metricReader
        meterSdk                = p.meterSdk
        sdkEventsEmittedCounter = p.sdkEventsEmittedCounter
        sdkEventsDroppedCounter = p.sdkEventsDroppedCounter
        sdkExportSuccessCounter = p.sdkExportSuccessCounter
        sdkExportFailureCounter = p.sdkExportFailureCounter
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

    // ── SDK-internal telemetry ─────────────────────────────────────────────────

    func recordEventEmitted(severity: String, type: String) {
        sdkEventsEmittedCounter?.add(value: 1, attributes: [
            "severity":   AttributeValue.string(severity),
            "event.type": AttributeValue.string(type)
        ])
    }
    func recordEventDropped()  { sdkEventsDroppedCounter?.add(value: 1, attributes: [:]) }
    func recordExportSuccess(eventCount: Int) {
        sdkExportSuccessCounter?.add(value: 1, attributes: [
            "events": AttributeValue.int(eventCount)
        ])
    }
    func recordExportFailure() { sdkExportFailureCounter?.add(value: 1, attributes: [:]) }

    // ── Token rotation ─────────────────────────────────────────────────────────

    /// Replaces the Bearer token and immediately rebuilds all three export pipelines.
    ///
    /// Unlike the previous implementation (which stored the token but never used it),
    /// this flushes any in-flight data from the old exporters before rebuilding, so
    /// no events are lost during rotation. The very next export request from each
    /// pipeline uses the new token.
    ///
    /// - Parameter token: The new Bearer token. Empty string removes the auth header.
    func updateToken(_ token: String) throws {
        guard token != currentToken else { return }
        teardownPipelines()
        currentToken = token
        buildPipelines(token: token)
    }

    // ── Batch log emit (durable flush path) ────────────────────────────────────

    /// Exports a batch of events directly to the OTLP/HTTP log endpoint and returns
    /// whether delivery was confirmed by an HTTP 2xx response.
    ///
    /// This is the durable-queue flush path. Calling code (``CeburuAnalyticsSDK/flushPersisted()``)
    /// must only call ``EncryptedStore/acknowledge(_:)`` (delete the on-disk files) after
    /// this returns `true` — ensuring events are never lost if the process dies between
    /// writing and exporting.
    ///
    /// - Parameter events: Events decoded from the on-disk queue.
    /// - Returns: `true` if the collector returned HTTP 2xx; `false` on network error or non-2xx.
    func emitBatch(_ events: [CeburuAnalyticsSDK.Event]) async -> Bool {
        guard !events.isEmpty else { return true }
        guard let bodyData = try? JSONSerialization.data(
            withJSONObject: buildOTLPLogsPayload(events)
        ) else { return false }

        // Direct URLSession call with an OTLP/JSON body: delivery is confirmed by the real HTTP
        // status code. OtlpHttpLogExporter.export() returns before the response arrives, so its
        // forceFlush() cannot prove delivery.
        var request = URLRequest(url: logsEndpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !currentToken.isEmpty {
            request.setValue("Bearer \(currentToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = bodyData

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }

    // ── Real-time log emit (logger adapter path) ────────────────────────────────

    /// Emits a single event through the OTel logger pipeline (BatchLogRecordProcessor).
    ///
    /// Used by logger adapters (``OSLogAdapter``, ``CallbackLoggerAdapter``) for real-time
    /// events that don't go through the disk queue. These are best-effort — if the process
    /// dies before the batch processor exports them, they are lost (adapter traffic is
    /// supplemental; the SDK's own durable path uses ``emitBatch(_:)``).
    func emit(_ event: CeburuAnalyticsSDK.Event) -> Bool {
        guard let logger else { return false }

        var attributes: [String: AttributeValue] = [
            "event.id":             .string(event.eventId),
            "session.id":           .string(event.sessionId),
            "telemetry.event.type": .string(event.type)
        ]
        for (key, value) in event.attributes {
            attributes[key] = .string(value)
        }

        logger.logRecordBuilder()
            .setSeverity(mapSeverity(event.severity))
            .setBody(.string(event.message))
            .setTimestamp(Date(timeIntervalSince1970: Double(event.timestampUnixMs) / 1000))
            .setAttributes(attributes)
            .emit()

        return true
    }

    // ── App-level metrics ──────────────────────────────────────────────────────

    func incrementCounter(name: String, value: Int64, attrs: [String: String], unit: String = "") {
        guard let meterSdk else { return }
        if appCounters[name] == nil {
            let b = meterSdk.counterBuilder(name: name)
            appCounters[name] = !unit.isEmpty ? b.setUnit(unit).build() : b.build()
        }
        appCounters[name]?.add(value: Int(value), attributes: attrs.mapValues { .string($0) })
    }

    func incrementUpDownCounter(name: String, value: Int64, attrs: [String: String], unit: String = "") {
        guard let meterSdk else { return }
        if appUpDownCounters[name] == nil {
            let b = meterSdk.upDownCounterBuilder(name: name)
            appUpDownCounters[name] = !unit.isEmpty ? b.setUnit(unit).build() : b.build()
        }
        appUpDownCounters[name]?.add(value: Int(value), attributes: attrs.mapValues { .string($0) })
    }

    func recordHistogram(name: String, value: Double, attrs: [String: String], unit: String = "") {
        guard let meterSdk else { return }
        if appHistograms[name] == nil {
            let b = meterSdk.histogramBuilder(name: name)
            appHistograms[name] = !unit.isEmpty ? b.setUnit(unit).build() : b.build()
        }
        appHistograms[name]?.record(value: value, attributes: attrs.mapValues { .string($0) })
    }

    func observeCounter(name: String, callback: @Sendable @escaping () -> Int64, unit: String = "") {
        guard let meterSdk else { return }
        let b = meterSdk.counterBuilder(name: name)
        let instrument = (!unit.isEmpty ? b.setUnit(unit) : b)
            .ofDoubles()
            .buildWithCallback { measurement in
                measurement.record(value: Double(callback()), attributes: [:])
            }
        observableInstruments.append(instrument)
    }

    func observeGauge(name: String, callback: @Sendable @escaping () -> Double, unit: String = "") {
        guard let meterSdk else { return }
        let b = meterSdk.gaugeBuilder(name: name)
        let instrument = (!unit.isEmpty ? b.setUnit(unit) : b)
            .buildWithCallback { measurement in
                measurement.record(value: callback(), attributes: [:])
            }
        observableInstruments.append(instrument)
    }

    // ── App-level traces ───────────────────────────────────────────────────────

    func startAppSpan(
        name:   String,
        attrs:  [String: String],
        kind:   OpenTelemetryApi.SpanKind,
        userId: String
    ) -> CeburuAnalyticsSDK.AppSpan {
        guard let tracer else { return CeburuAnalyticsSDK.AppSpan(span: nil) }
        let builder = tracer.spanBuilder(spanName: name).setSpanKind(spanKind: kind)
        attrs.forEach { k, v in _ = builder.setAttribute(key: k, value: AttributeValue.string(v)) }
        // X1: inject enduser.id per-span so it reflects the current user identity at span
        // creation time, not the frozen value from the Resource set at SDK init.
        if !userId.isEmpty {
            _ = builder.setAttribute(key: "enduser.id", value: AttributeValue.string(userId))
        }
        let span = builder.startSpan()
        return CeburuAnalyticsSDK.AppSpan(span: span)
    }

    // ── Shutdown ───────────────────────────────────────────────────────────────

    /// Flushes all three signal pipelines, closes observable instruments, and
    /// releases all pipeline references.
    func shutdown() {
        teardownPipelines()
    }

    // ── Private helpers ────────────────────────────────────────────────────────

    /// Flushes and shuts down all three pipelines. Safe to call before a rebuild.
    private func teardownPipelines() {
        observableInstruments.forEach { $0.close() }
        observableInstruments.removeAll()

        _ = logProcessor?.forceFlush()
        _ = logProcessor?.shutdown()

        _ = spanProcessor?.forceFlush()
        _ = spanProcessor?.shutdown()

        _ = metricReader?.forceFlush()
        _ = metricReader?.shutdown()

        logger               = nil
        logProcessor         = nil
        logExporter          = nil
        tracer               = nil
        spanProcessor        = nil
        meterSdk             = nil
        metricReader         = nil
        sdkEventsEmittedCounter = nil
        sdkEventsDroppedCounter = nil
        sdkExportSuccessCounter = nil
        sdkExportFailureCounter = nil

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
            var attrs: [[String: Any]] = [
                ["key": "event.id",             "value": ["stringValue": event.eventId]],
                ["key": "session.id",           "value": ["stringValue": event.sessionId]],
                ["key": "telemetry.event.type", "value": ["stringValue": event.type]]
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

    private func mapSeverity(_ severity: CeburuAnalyticsSDK.Severity) -> OpenTelemetryApi.Severity {
        switch severity {
        case .trace: return .trace
        case .debug: return .debug
        case .info:  return .info
        case .warn:  return .warn
        case .error: return .error
        case .fatal: return .fatal
        }
    }
}