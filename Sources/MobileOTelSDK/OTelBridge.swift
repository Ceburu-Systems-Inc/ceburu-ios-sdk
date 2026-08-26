import Foundation
import GRPC
import NIO
import OpenTelemetryApi
import OpenTelemetrySdk
import OpenTelemetryProtocolExporterGrpc

actor OTelBridge {

    private var logger: OpenTelemetryApi.Logger?
    private var processor: BatchLogRecordProcessor?
    private var group: MultiThreadedEventLoopGroup?
    private var connection: ClientConnection?

    init(config: MobileOTelSDK.Config) throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        let connection = ClientConnection.insecure(group: group)
            .connect(host: config.collectorHost, port: config.collectorPort)

        // Production must replace insecure() with TLS-secured gRPC.

        let exporter = OtlpLogExporter(channel: connection)

        let processor = BatchLogRecordProcessor(logRecordExporter: exporter)

        let resource = Resource(attributes: [
            "service.name": AttributeValue.string(config.serviceName),
            "service.version": AttributeValue.string(config.serviceVersion),
            "deployment.environment.name": AttributeValue.string(config.environment),
            "tenant.id": AttributeValue.string(config.tenantId),
            "application.id": AttributeValue.string(config.applicationId)
        ])

        let provider = LoggerProviderBuilder()
            .with(processors: [processor])
            .with(resource: resource)
            .build()

        OpenTelemetry.registerLoggerProvider(loggerProvider: provider)

        self.processor = processor
        self.logger = OpenTelemetry.instance.loggerProvider
            .loggerBuilder(instrumentationScopeName: "enterprise.mobile.sdk")
            .setInstrumentationVersion("1.0.2")
            .build()
        self.group = group
        self.connection = connection
    }

    func emit(_ event: MobileOTelSDK.Event) -> Bool {
        guard let logger else { return false }

        var attributes: [String: AttributeValue] = [
            "event.id": .string(event.eventId),
            "session.id": .string(event.sessionId),
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

    func shutdown() {
        processor?.forceFlush()
        processor?.shutdown()
        try? connection?.close().wait()
        try? group?.syncShutdownGracefully()
        logger = nil
        processor = nil
    }

    private func mapSeverity(_ severity: MobileOTelSDK.Severity) -> OpenTelemetryApi.Severity {
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
