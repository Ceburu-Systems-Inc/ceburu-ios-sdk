import Foundation
import OpenTelemetryApi

// Maps persisted events to the OpenTelemetry Logs API supplied by the host app.
actor OTelBridge {

    private let logger: OpenTelemetryApi.Logger

    init(loggerProvider: LoggerProvider) {
        self.logger = loggerProvider
            .loggerBuilder(instrumentationScopeName: "enterprise.mobile.sdk")
            .build()
    }

    func emit(_ event: MobileSDK.Event) -> Bool {
        var attrs: [String: AttributeValue] = [
            "event.id":              .string(event.eventId),
            "session.id":            .string(event.sessionId),
            "telemetry.event.type":  .string(event.type)
        ]

        for (key, value) in event.attributes {
            attrs[key] = .string(value)
        }

        logger.logRecordBuilder()
            .setSeverity(map(event.severity))
            .setBody(.string(event.message))
            .setAttributes(attrs)
            .emit()

        return true
    }

    private func map(_ severity: MobileSDK.Severity) -> OpenTelemetryApi.Severity {
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
