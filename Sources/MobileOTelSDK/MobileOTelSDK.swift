import Foundation
import UIKit

public actor MobileOTelSDK {

    public static let shared = MobileOTelSDK()

    public enum Severity: Int, Codable, Sendable {
        case trace, debug, info, warn, error, fatal
    }

    public struct Config: Sendable {
        public let serviceName: String
        public let serviceVersion: String
        public let environment: String
        public let tenantId: String
        public let applicationId: String
        public let collectorHost: String
        public let collectorPort: Int
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
            collectorHost: String,
            collectorPort: Int = 4317,
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
            self.collectorHost = collectorHost
            self.collectorPort = collectorPort
            self.queueMaxBytes = queueMaxBytes
            self.retentionHours = retentionHours
            self.maxBatchEvents = maxBatchEvents
            self.maxBatchBytes = maxBatchBytes
        }
    }

    private var config: Config?
    private var storage: EncryptedStore?
    private var bridge: OTelBridge?
    private var sessionId = UUID().uuidString
    private var breadcrumbs: [Breadcrumb] = []
    private var policy = Policy()
    private var running = false
    private var backoff = RetryBackoff()
    private var adapters: [LoggerAdapter] = []

    // C function pointers cannot capture context — use globals for crash handler.
    nonisolated(unsafe) private static var _crashStorage: EncryptedStore?
    nonisolated(unsafe) private static var _crashSessionId: String = ""
    nonisolated(unsafe) static var _crashBreadcrumbs: String = ""

    private init() {}

    public func initialize(config: Config) async throws {
        guard !running else { return }

        let storage = try EncryptedStore(
            maxBytes: config.queueMaxBytes,
            retentionHours: config.retentionHours
        )

        let bridge = try OTelBridge(config: config)

        self.config = config
        self.storage = storage
        self.bridge = bridge
        self.policy.maxBatchEvents = config.maxBatchEvents
        self.policy.maxBatchBytes = config.maxBatchBytes
        self.running = true

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

        await info(
            "Mobile SDK initialized",
            attributes: [
                "service.name": config.serviceName,
                "service.version": config.serviceVersion,
                "deployment.environment.name": config.environment,
                "tenant.id": config.tenantId,
                "application.id": config.applicationId,
                "device.manufacturer": "Apple",
                "device.model": UIDevice.current.model,
                "os.name": "iOS",
                "os.version": UIDevice.current.systemVersion
            ]
        )
    }

    public func installLoggerAdapter(_ adapter: LoggerAdapter) async {
        await adapter.install()
        adapters.append(adapter)
    }

    public func breadcrumb(category: String, message: String) {
        breadcrumbs.append(Breadcrumb(category: category, message: message))
        if breadcrumbs.count > 50 {
            breadcrumbs.removeFirst(breadcrumbs.count - 50)
        }
        let serialized = breadcrumbs
            .map { "\($0.category):\($0.message)" }
            .joined(separator: " | ")
        MobileOTelSDK._crashBreadcrumbs = serialized
        storage?.persistBreadcrumbs(serialized)
    }

    @discardableResult
    public func newSession() -> String {
        sessionId = UUID().uuidString
        return sessionId
    }

    public func debug(_ message: String, attributes: [String: String] = [:]) async {
        await emit(.debug, message, attributes)
    }

    public func info(_ message: String, attributes: [String: String] = [:]) async {
        await emit(.info, message, attributes)
    }

    public func warn(_ message: String, attributes: [String: String] = [:]) async {
        await emit(.warn, message, attributes)
    }

    public func error(_ message: String, error: Error? = nil, attributes: [String: String] = [:]) async {
        await emit(.error, message, mergeError(attributes, error))
    }

    public func fatal(_ message: String, error: Error? = nil, attributes: [String: String] = [:]) async {
        await emit(.fatal, message, mergeError(attributes, error))
    }

    public func shutdown() async {
        for adapter in adapters { await adapter.uninstall() }
        adapters.removeAll()
        running = false
        SignalCrashHandler.uninstall()
        await bridge?.shutdown()
        bridge = nil
    }

    private func emit(_ severity: Severity, _ message: String, _ attributes: [String: String]) async {
        guard running, let config, let storage else { return }

        if !policy.enabled { return }
        if severity.rawValue < policy.minSeverity.rawValue { return }

        if severity.rawValue < Severity.error.rawValue &&
           Double.random(in: 0...1) > policy.sampleRate {
            return
        }

        var attrs = Security.redact(attributes)

        attrs["service.name"] = config.serviceName
        attrs["service.version"] = config.serviceVersion
        attrs["deployment.environment.name"] = config.environment
        attrs["tenant.id"] = config.tenantId
        attrs["application.id"] = config.applicationId

        if severity.rawValue >= Severity.error.rawValue && !breadcrumbs.isEmpty {
            attrs["session.breadcrumbs"] = breadcrumbs
                .map { "\($0.category):\($0.message)" }
                .joined(separator: " | ")
        }

        let event = Event(
            eventId: UUID().uuidString,
            timestampUnixMs: Int64(Date().timeIntervalSince1970 * 1000),
            severity: severity,
            type: "log",
            message: message,
            sessionId: sessionId,
            attributes: attrs
        )

        try? await storage.enqueue(event)
    }

    private enum FlushResult { case flushed, empty, failed }

    private func flushPersisted() async -> FlushResult {
        guard let storage, let bridge else { return .empty }

        do {
            let rows = try await storage.batch(
                maxEvents: policy.maxBatchEvents,
                maxBytes: policy.maxBatchBytes
            )

            if rows.isEmpty { return .empty }

            for (file, clear) in rows {
                let event = try JSONDecoder().decode(Event.self, from: clear)
                let ok = await bridge.emit(event)
                if !ok { return .failed }
                await storage.acknowledge([file])
            }

            return .flushed
        } catch {
            return .failed
        }
    }

    private func installExceptionHandler() {
        guard let storage else { return }
        MobileOTelSDK._crashStorage = storage
        MobileOTelSDK._crashSessionId = sessionId

        NSSetUncaughtExceptionHandler { exception in
            MobileOTelSDK._crashStorage?.persistException(exception, sessionId: MobileOTelSDK._crashSessionId)
            // Tell the signal handler that this crash is already captured, so SIGABRT
            // (which the runtime raises immediately after) does not write a second record.
            SignalCrashHandler.exceptionAlreadyCaptured = true
        }
    }

    private func mergeError(_ attrs: [String: String], _ error: Error?) -> [String: String] {
        guard let error else { return attrs }
        var out = attrs
        out["exception.type"]    = String(describing: type(of: error))
        out["exception.message"] = error.localizedDescription
        return out
    }

    private func resetBackoff() { backoff.reset() }
    private func nextBackoff() -> Int { backoff.nextDelayMs() }

    struct Event: Codable, Sendable {
        let eventId: String
        let timestampUnixMs: Int64
        let severity: Severity
        let type: String
        let message: String
        let sessionId: String
        let attributes: [String: String]
    }

    struct Policy: Sendable {
        var enabled = true
        var minSeverity: Severity = .info
        var sampleRate = 1.0
        var maxBatchEvents = 200
        var maxBatchBytes = 512 * 1024
    }

    struct Breadcrumb: Sendable {
        let category: String
        let message: String
    }
}
