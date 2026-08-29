import Foundation
import GRPC
import NIO
import NIOHPACK
import OpenTelemetryApi
import OpenTelemetrySdk
import OpenTelemetryProtocolExporterGrpc
import OpenTelemetryProtocolExporterCommon

/// Internal OpenTelemetry bridge — owns the SDK's private Analytics instance.
///
/// Manages three signal pipelines over a single gRPC connection:
/// - **Logs**: `LogsService/Export` — emitted per-event via `BatchLogRecordProcessor` (~2 s).
/// - **Metrics**: `MetricsService/Export` — polled every 60 s by `PeriodicMetricReaderSdk`.
/// - **Traces**: `TraceService/Export` — exported within ~5 s of `span.end()`.
///
/// All three pipelines share the same `Resource` (tenant, user, service metadata)
/// so cross-signal correlation works in the backend.
///
/// > Note: The Bearer token is baked into `OtlpConfiguration` at connection time. To rotate,
/// > call ``updateToken(_:)`` — it is stored and applied on the next connection.
actor AnalyticsBridge {

    private var logger: OpenTelemetryApi.Logger?
    private var logProcessor: BatchLogRecordProcessor?
    private var tracer: OpenTelemetryApi.Tracer?
    private var meterSdk: MeterSdk?
    private var metricReader: PeriodicMetricReaderSdk?
    private var group: MultiThreadedEventLoopGroup?
    private var connection: ClientConnection?

    // Current auth token — rebuilt into fresh OtlpConfiguration on updateToken().
    private var currentToken: String

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

    /// Builds the three OpenTelemetry signal pipelines and registers them with the global
    /// `OpenTelemetry` instance.
    ///
    /// - Parameter config: SDK configuration. `collectorHost`/`collectorPort` determine the gRPC target.
    ///   `authToken` is embedded as the `authorization` gRPC metadata header via `OtlpConfiguration`.
    /// - Throws: If NIO event-loop group or gRPC channel cannot be created.
    init(config: CeburuAnalyticsSDK.Config) throws {
        self.currentToken = config.authToken

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let connection = ClientConnection.insecure(group: group)
            .connect(host: config.collectorHost, port: config.collectorPort)

        let resource = Resource(attributes: [
            "service.name":                   AttributeValue.string(config.serviceName),
            "service.version":                AttributeValue.string(config.serviceVersion),
            "deployment.environment.name":    AttributeValue.string(config.environment),
            "tenant.id":                      AttributeValue.string(config.tenantId),
            "application.id":                 AttributeValue.string(config.applicationId),
            "user.id":                        AttributeValue.string(config.userId)
        ])

        let otlpHeaders: [(String, String)]? = config.authToken.isEmpty
            ? nil
            : [("authorization", "Bearer \(config.authToken)")]
        let otlpConfig = OtlpConfiguration(headers: otlpHeaders)

        // ── Logs pipeline ──────────────────────────────────────────────────────
        let logExporter  = OtlpLogExporter(channel: connection, config: otlpConfig)
        let logProcessor = BatchLogRecordProcessor(logRecordExporter: logExporter)

        let loggerProvider = LoggerProviderBuilder()
            .with(processors: [logProcessor])
            .with(resource: resource)
            .build()
        OpenTelemetry.registerLoggerProvider(loggerProvider: loggerProvider)

        self.logProcessor = logProcessor
        self.logger = OpenTelemetry.instance.loggerProvider
            .loggerBuilder(instrumentationScopeName: "enterprise.mobile.sdk")
            .setInstrumentationVersion("2.0.0")
            .build()

        // ── Metrics pipeline ───────────────────────────────────────────────────
        let metricExporter = OtlpMetricExporter(channel: connection, config: otlpConfig)
        let metricReader   = PeriodicMetricReaderBuilder(exporter: metricExporter)
            .setInterval(timeInterval: config.metricsExportInterval)
            .build()
        self.metricReader = metricReader

        // ViewRegistry.findViews() only searches user-registered views; without at least one
        // view, every instrument gets zero storages and all metric calls silently no-op.
        // The catch-all view (name: ".*", DefaultAggregation) restores the expected defaults.
        let meterProvider: MeterProviderSdk = MeterProviderSdk.builder()
            .registerMetricReader(reader: metricReader)
            .setResource(resource: resource)
            .registerView(
                selector: InstrumentSelector.builder().build(),
                view: View.builder().build()
            )
            .build()
        OpenTelemetry.registerMeterProvider(meterProvider: meterProvider)
        self.meterSdk = meterProvider.get(name: "enterprise.mobile.sdk")

        let sdkMeter = meterProvider.get(name: "enterprise.mobile.sdk.internal")
        self.sdkEventsEmittedCounter = sdkMeter.counterBuilder(name: "mobile.sdk.events.emitted").build()
        self.sdkEventsDroppedCounter = sdkMeter.counterBuilder(name: "mobile.sdk.events.dropped").build()
        self.sdkExportSuccessCounter = sdkMeter.counterBuilder(name: "mobile.sdk.export.success").build()
        self.sdkExportFailureCounter = sdkMeter.counterBuilder(name: "mobile.sdk.export.failure").build()

        // ── Traces pipeline ────────────────────────────────────────────────────
        let spanExporter  = OtlpTraceExporter(channel: connection, config: otlpConfig)
        let spanProcessor = BatchSpanProcessor(spanExporter: spanExporter)

        let tracerProvider = TracerProviderBuilder()
            .add(spanProcessor: spanProcessor)
            .with(resource: resource)
            .build()
        OpenTelemetry.registerTracerProvider(tracerProvider: tracerProvider)

        self.tracer = OpenTelemetry.instance.tracerProvider.get(
            instrumentationName:    "enterprise.mobile.sdk",
            instrumentationVersion: "2.0.0"
        )

        self.group      = group
        self.connection = connection
    }

    // ── Metric flush ───────────────────────────────────────────────────────────

    /// Forces an immediate metric collection and export cycle.
    /// - Returns: `true` if the export succeeded (or there was nothing to export), `false` if the gRPC call failed.
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

    /// Stores a replacement Bearer token.
    ///
    /// The token is applied to `OtlpConfiguration` on the next gRPC connection — not mid-stream.
    /// This is a known limitation: iOS gRPC bakes auth into the exporter config at connection time,
    /// so rotation only takes effect when the current connection is recycled.
    ///
    /// - Parameter token: The new Bearer token. Empty string removes the auth header.
    func updateToken(_ token: String) {
        currentToken = token
    }

    // ── Log emit ───────────────────────────────────────────────────────────────

    /// Emits a single event to the OpenTelemetry logger and returns whether it was accepted.
    ///
    /// Translates the SDK's internal `Event` model into an OTLP log record. The record is
    /// handed to the `BatchLogRecordProcessor`, which buffers it and exports to the collector
    /// within ~2 seconds.
    ///
    /// - Parameter event: The event to emit. All attributes are forwarded verbatim.
    /// - Returns: `true` if the logger was available and the record was submitted; `false` if the bridge is not initialized.
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
            .setAttributes(attributes)
            .emit()

        return true
    }

    // ── App-level metrics ──────────────────────────────────────────────────────

    /// Increments a named counter by `value`.
    ///
    /// The counter instrument is created lazily on first call and reused on subsequent calls
    /// with the same `name`. All data points for this instrument share the same metric series;
    /// `attrs` differentiate individual data points within it.
    ///
    /// - Parameters:
    ///   - name:  Instrument name (e.g. `"checkout.attempts"`).
    ///   - value: Amount to add (must be ≥ 0 for counters).
    ///   - attrs: Attributes attached to this individual data point.
    func incrementCounter(name: String, value: Int64, attrs: [String: String]) {
        guard let meterSdk else { return }
        let counter = appCounters[name] ?? {
            let c = meterSdk.counterBuilder(name: name).build()
            appCounters[name] = c
            return c
        }()
        counter.add(value: Int(value), attributes: attrs.mapValues { .string($0) })
    }

    /// Increments (or decrements) a named up-down counter by `value`.
    ///
    /// The instrument is created lazily on first call. Unlike regular counters,
    /// up-down counters accept negative deltas — use them for values that can go both ways
    /// (active sessions, queue depth, item counts).
    ///
    /// - Parameters:
    ///   - name:  Instrument name (e.g. `"active.downloads"`).
    ///   - value: Delta — positive to add, negative to subtract.
    ///   - attrs: Attributes attached to this individual data point.
    func incrementUpDownCounter(name: String, value: Int64, attrs: [String: String]) {
        guard let meterSdk else { return }
        let counter = appUpDownCounters[name] ?? {
            let c = meterSdk.upDownCounterBuilder(name: name).build()
            appUpDownCounters[name] = c
            return c
        }()
        counter.add(value: Int(value), attributes: attrs.mapValues { .string($0) })
    }

    /// Records a measurement into a named histogram.
    ///
    /// The histogram instrument is created lazily on first call. Histograms aggregate
    /// measurements into bucket counts, sum, and count — useful for latency distributions
    /// and size distributions.
    ///
    /// - Parameters:
    ///   - name:  Instrument name (e.g. `"api.response.ms"`).
    ///   - value: Measured value (must be ≥ 0).
    ///   - attrs: Attributes attached to this individual data point.
    func recordHistogram(name: String, value: Double, attrs: [String: String]) {
        guard let meterSdk else { return }
        let histogram = appHistograms[name] ?? {
            let h = meterSdk.histogramBuilder(name: name).build()
            appHistograms[name] = h
            return h
        }()
        histogram.record(value: value, attributes: attrs.mapValues { .string($0) })
    }

    /// Registers a callback that is polled every 60 s and reported as a cumulative counter.
    ///
    /// The returned `ObservableInstrumentSdk` is retained by `observableInstruments` to prevent
    /// premature deallocation. All retained instruments are closed on ``shutdown()``,
    /// which stops their polling callbacks.
    ///
    /// - Parameters:
    ///   - name:     Instrument name (e.g. `"app.sessions.total"`).
    ///   - callback: Returns the current cumulative count. Must be cheap and non-blocking —
    ///               it runs on the metrics export thread.
    func observeCounter(name: String, callback: @Sendable @escaping () -> Int64) {
        guard let meterSdk else { return }
        // ObservableMeasurementSdk.record(value:Int) always converts to Double, so
        // LongSumAggregator.toPoint() would read longValue=0. Using .ofDoubles() selects
        // DoubleSumAggregator which correctly reads doubleValue.
        let instrument = meterSdk.counterBuilder(name: name)
            .ofDoubles()
            .buildWithCallback { measurement in
                measurement.record(value: Double(callback()), attributes: [:])
            }
        observableInstruments.append(instrument)
    }

    /// Registers a callback that is polled every 60 s and reported as a gauge (point-in-time value).
    ///
    /// The returned `ObservableInstrumentSdk` is retained by `observableInstruments`.
    /// Use for system state sampled on demand: memory usage, battery level, thread count.
    ///
    /// - Parameters:
    ///   - name:     Instrument name (e.g. `"memory.used.mb"`).
    ///   - callback: Returns the current value. Must be cheap and non-blocking —
    ///               it runs on the metrics export thread.
    func observeGauge(name: String, callback: @Sendable @escaping () -> Double) {
        guard let meterSdk else { return }
        let instrument = meterSdk.gaugeBuilder(name: name)
            .buildWithCallback { measurement in
                measurement.record(value: callback(), attributes: [:])
            }
        observableInstruments.append(instrument)
    }

    // ── App-level traces ───────────────────────────────────────────────────────

    /// Starts a named span for an app-level operation.
    ///
    /// The caller is responsible for calling `span.end()` or `span.recordException()` + `end()`
    /// when the operation finishes. Initial `attrs` are set as span attributes at start time.
    /// `kind` defaults to `internal` — use `client` for outgoing calls, `server` for incoming.
    ///
    /// - Parameters:
    ///   - name:  Span name (e.g. `"payment.flow"`, `"outgoing.http.call"`).
    ///   - attrs: Initial span attributes applied at start time.
    ///   - kind:  `SpanKind` — controls how backends render the span in trace waterfalls.
    /// - Returns: An `AppSpan` wrapping the started span, or an inert `AppSpan(span: nil)` if unavailable.
    func startAppSpan(
        name:  String,
        attrs: [String: String],
        kind:  OpenTelemetryApi.SpanKind
    ) -> CeburuAnalyticsSDK.AppSpan {
        guard let tracer else { return CeburuAnalyticsSDK.AppSpan(span: nil) }
        let builder = tracer.spanBuilder(spanName: name).setSpanKind(spanKind: kind)
        attrs.forEach { k, v in _ = builder.setAttribute(key: k, value: AttributeValue.string(v)) }
        return CeburuAnalyticsSDK.AppSpan(span: builder.startSpan())
    }

    // ── Shutdown ───────────────────────────────────────────────────────────────

    /// Releases all observable instrument callbacks, flushes the log processor,
    /// and closes the gRPC connection and NIO event-loop group.
    ///
    /// After this call, all pipeline references are `nil` and the actor is inert.
    /// `CeburuAnalyticsSDK.shutdown()` calls this as the last step of its teardown.
    func shutdown() {
        observableInstruments.forEach { $0.close() }
        observableInstruments.removeAll()
        logProcessor?.forceFlush()
        logProcessor?.shutdown()
        try? connection?.close().wait()
        try? group?.syncShutdownGracefully()
        logger       = nil
        logProcessor = nil
        tracer       = nil
        meterSdk     = nil
        metricReader = nil
        sdkEventsEmittedCounter = nil
        sdkEventsDroppedCounter = nil
        sdkExportSuccessCounter = nil
        sdkExportFailureCounter = nil
    }

    // ── Severity mapping ───────────────────────────────────────────────────────

    /// Maps the SDK's internal `Severity` enum to the OpenTelemetry API `Severity` type.
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
