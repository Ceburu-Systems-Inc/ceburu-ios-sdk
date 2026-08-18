import Foundation
import UIKit
import OpenTelemetryApi

private nonisolated(unsafe) var _exceptionStorage: Storage?
private nonisolated(unsafe) var _exceptionSessionId: String = ""

public actor MobileSDK {

    public static let shared = MobileSDK()

    public enum Severity: Int, Codable, Sendable {
        case trace, debug, info, warn, error, fatal
    }

    public struct Config: Sendable {
        public let serviceName: String
        public let serviceVersion: String
        public let environment: String
        public let tenantId: String
        public let applicationId: String
        public let queueMaxBytes: Int
        public let retentionHours: Int
        public let maxBatchEvents: Int
        public let maxBatchBytes: Int

        public init(
            serviceName: String,
            serviceVersion: String,
            environment: String,
            tenantId: String,
            applicationId: String,
            queueMaxBytes: Int = 50 * 1024 * 1024,
            retentionHours: Int = 72,
            maxBatchEvents: Int = 200,
            maxBatchBytes: Int = 512 * 1024
        ) {
            self.serviceName = serviceName
            self.serviceVersion = serviceVersion
            self.environment = environment
            self.tenantId = tenantId
            self.applicationId = applicationId
            self.queueMaxBytes = queueMaxBytes
            self.retentionHours = retentionHours
            self.maxBatchEvents = maxBatchEvents
            self.maxBatchBytes = maxBatchBytes
        }
    }

    private var config: Config?
    private var storage: Storage?
    private var bridge: OTelBridge?
    private var running = false
    private var sessionId = UUID().uuidString
    private var breadcrumbs: [String] = []
    private var enabled = true
    private var minSeverity: Severity = .info
    private var sampleRate = 1.0
    private var failureCount = 0

    private init() {}

    /// The host app supplies its already-configured OpenTelemetry LoggerProvider.
    public func initialize(
        config: Config,
        loggerProvider: LoggerProvider
    ) async throws {
        guard !running else { return }

        let storage = try Storage(
            maxBytes: config.queueMaxBytes,
            retentionHours: config.retentionHours
        )

        self.config = config
        self.storage = storage
        self.bridge = OTelBridge(loggerProvider: loggerProvider)
        self.running = true

        try? await storage.importPendingCrashes(sessionId: sessionId)
        installExceptionHandler()

        Task { [weak self] in
            while let self, await self.running {
                let ok = await self.flushPersisted()
                if ok {
                    await self.resetBackoff()
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                } else {
                    let delay = await self.nextBackoff()
                    try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
                }
            }
        }

        await info(
            "Mobile SDK initialized",
            attributes: [
                "service.name": config.serviceName,
                "service.version": config.serviceVersion,
                "deployment.environment.name": config.environment,
                "telemetry.tenant.id": config.tenantId,
                "telemetry.application.id": config.applicationId,
                "device.model.identifier": UIDevice.current.model,
                "os.name": "iOS",
                "os.version": UIDevice.current.systemVersion
            ]
        )
    }

    public func installLoggerAdapter(_ adapter: LoggerAdapter) async {
        await adapter.install()
    }

    public func breadcrumb(category: String, message: String) {
        breadcrumbs.append("\(category):\(message)")
        if breadcrumbs.count > 50 {
            breadcrumbs.removeFirst(breadcrumbs.count - 50)
        }
    }

    public func newSession() { sessionId = UUID().uuidString }
    public func shutdown() { running = false }

    public func debug(_ message: String, attributes: [String: String] = [:]) async {
        await emit(.debug, message, attributes)
    }

    public func info(_ message: String, attributes: [String: String] = [:]) async {
        await emit(.info, message, attributes)
    }

    public func warn(_ message: String, attributes: [String: String] = [:]) async {
        await emit(.warn, message, attributes)
    }

    public func error(_ message: String, attributes: [String: String] = [:]) async {
        await emit(.error, message, attributes)
    }

    public func fatal(_ message: String, attributes: [String: String] = [:]) async {
        await emit(.fatal, message, attributes)
    }

    private func emit(
        _ severity: Severity,
        _ message: String,
        _ attributes: [String: String]
    ) async {
        guard running,
              enabled,
              severity.rawValue >= minSeverity.rawValue,
              let config,
              let storage
        else { return }

        if severity.rawValue < Severity.error.rawValue &&
           Double.random(in: 0...1) > sampleRate { return }

        var attrs = Security.redact(attributes)
        attrs["service.name"] = config.serviceName
        attrs["service.version"] = config.serviceVersion
        attrs["deployment.environment.name"] = config.environment
        attrs["telemetry.tenant.id"] = config.tenantId
        attrs["telemetry.application.id"] = config.applicationId

        if severity.rawValue >= Severity.error.rawValue {
            attrs["telemetry.breadcrumbs"] = breadcrumbs.joined(separator: " | ")
        }

        try? await storage.enqueue(
            Event(
                eventId: UUID().uuidString,
                timestampUnixMs: Int64(Date().timeIntervalSince1970 * 1000),
                severity: severity,
                type: "log",
                message: message,
                sessionId: sessionId,
                attributes: attrs
            )
        )
    }

    private func flushPersisted() async -> Bool {
        guard let config, let storage, let bridge else { return true }
        do {
            let rows = try await storage.batch(
                maxEvents: config.maxBatchEvents,
                maxBytes: config.maxBatchBytes
            )
            for (url, data) in rows {
                let event = try JSONDecoder().decode(Event.self, from: data)
                guard await bridge.emit(event) else { return false }
                await storage.acknowledge([url])
            }
            return true
        } catch {
            return false
        }
    }

    private func installExceptionHandler() {
        guard let storage else { return }
        _exceptionStorage = storage
        _exceptionSessionId = sessionId
        NSSetUncaughtExceptionHandler { exception in
            _exceptionStorage?.persistException(exception, sessionId: _exceptionSessionId)
        }
    }

    private func resetBackoff() { failureCount = 0 }

    private func nextBackoff() -> Int {
        failureCount += 1
        let exp = min(failureCount, 8)
        return min(300_000, 1_000 * (1 << exp)) + Int.random(in: 0...1_000)
    }

    struct Event: Codable, Sendable {
        let eventId: String
        let timestampUnixMs: Int64
        let severity: Severity
        let type: String
        let message: String
        let sessionId: String
        let attributes: [String: String]
    }
}
