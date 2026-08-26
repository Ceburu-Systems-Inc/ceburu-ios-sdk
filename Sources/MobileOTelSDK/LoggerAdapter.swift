import Foundation
import os

// MARK: - LoggerAdapter Protocol

public protocol LoggerAdapter: Sendable {
    func install() async
    func uninstall() async
}

// MARK: - MobileLogSink

public enum MobileLogSink {

    /// Async entry point — use from async contexts.
    public static func log(
        level: String,
        message: String,
        error: Error? = nil,
        attributes: [String: String] = [:]
    ) async {
        await route(level: level, message: message, error: error, attributes: attributes)
    }

    /// Sync entry point — call this from any existing synchronous logger callback.
    /// Internally schedules on the SDK actor; returns immediately.
    public static func logSync(
        level: String,
        message: String,
        error: Error? = nil,
        attributes: [String: String] = [:]
    ) {
        Task { await route(level: level, message: message, error: error, attributes: attributes) }
    }

    private static func route(
        level: String,
        message: String,
        error: Error?,
        attributes: [String: String]
    ) async {
        switch level.uppercased() {
        case "TRACE", "DEBUG":
            await MobileOTelSDK.shared.debug(message, attributes: attributes)

        case "INFO":
            await MobileOTelSDK.shared.info(message, attributes: attributes)

        case "WARN", "WARNING":
            await MobileOTelSDK.shared.warn(message, attributes: attributes)

        case "ERROR":
            await MobileOTelSDK.shared.error(message, error: error, attributes: attributes)

        case "FATAL", "CRITICAL":
            await MobileOTelSDK.shared.fatal(message, error: error, attributes: attributes)

        default:
            await MobileOTelSDK.shared.info(message, attributes: attributes)
        }
    }
}

// MARK: - CallbackLoggerAdapter

/// Use this when your app has a custom logger class or singleton.
/// Add one call to `forward()` inside each method of your existing logger.
public final class CallbackLoggerAdapter: LoggerAdapter, @unchecked Sendable {

    public static let shared = CallbackLoggerAdapter()
    public init() {}

    public func install() async {}
    public func uninstall() async {}

    /// Call this from your existing logger. Safe to call from synchronous contexts.
    public func forward(
        level: String,
        message: String,
        error: Error? = nil,
        attributes: [String: String] = [:]
    ) {
        MobileLogSink.logSync(level: level, message: message, error: error, attributes: attributes)
    }
}

// MARK: - OSLogAdapter

/// Use this when your app uses Apple's os.log / Logger framework.
/// Replace your Logger instance with OSLogAdapter — it logs to both
/// the system console and the OTel collector.
public final class OSLogAdapter: LoggerAdapter, @unchecked Sendable {

    private let osLogger: os.Logger

    public init(subsystem: String, category: String) {
        self.osLogger = os.Logger(subsystem: subsystem, category: category)
    }

    public func install() async {}
    public func uninstall() async {}

    public func debug(_ message: String, attributes: [String: String] = [:]) {
        osLogger.debug("\(message, privacy: .public)")
        MobileLogSink.logSync(level: "DEBUG", message: message, attributes: attributes)
    }

    public func info(_ message: String, attributes: [String: String] = [:]) {
        osLogger.info("\(message, privacy: .public)")
        MobileLogSink.logSync(level: "INFO", message: message, attributes: attributes)
    }

    public func warning(_ message: String, attributes: [String: String] = [:]) {
        osLogger.warning("\(message, privacy: .public)")
        MobileLogSink.logSync(level: "WARN", message: message, attributes: attributes)
    }

    public func error(_ message: String, attributes: [String: String] = [:]) {
        osLogger.error("\(message, privacy: .public)")
        MobileLogSink.logSync(level: "ERROR", message: message, attributes: attributes)
    }

    public func critical(_ message: String, attributes: [String: String] = [:]) {
        osLogger.critical("\(message, privacy: .public)")
        MobileLogSink.logSync(level: "FATAL", message: message, attributes: attributes)
    }
}
