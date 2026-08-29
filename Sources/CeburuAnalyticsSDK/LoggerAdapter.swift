import Foundation
import os

// MARK: - LoggerAdapter Protocol

/// Extension point for bridging an existing logging framework into the SDK.
///
/// Implement this protocol to intercept log output from a third-party or custom logger
/// and forward it to ``CeburuAnalyticsSDK`` without changing the host app's logging call sites.
///
/// The SDK ships two ready-made adapters:
/// - ``CallbackLoggerAdapter`` — manual forwarding via `forward()` (for any custom logger class).
/// - ``OSLogAdapter`` — drop-in replacement for Apple's `os.Logger` / `Logger`.
///
/// Register an adapter with:
/// ```swift
/// await CeburuAnalyticsSDK.shared.installLoggerAdapter(CallbackLoggerAdapter.shared)
/// ```
///
/// On ``CeburuAnalyticsSDK/shutdown()``, all installed adapters are automatically uninstalled
/// so the original logging chain is fully restored.
public protocol LoggerAdapter: Sendable {

    /// Called by ``CeburuAnalyticsSDK/installLoggerAdapter(_:)`` immediately after registration.
    ///
    /// Use this to hook into the target logging framework — for example, register a handler
    /// on the system log, or attach a listener to a custom logger singleton.
    func install() async

    /// Called by ``CeburuAnalyticsSDK/shutdown()`` to undo whatever ``install()`` did.
    ///
    /// Default implementation is a no-op for adapters that do not need cleanup.
    func uninstall() async
}

// MARK: - MobileLogSink

/// Routes a log record described by a level string to the correct ``CeburuAnalyticsSDK`` method.
///
/// Use `MobileLogSink` from any adapter or custom logging bridge when you have the level
/// as a plain string (e.g. from a JSON log entry, a CocoaLumberjack flag, or a third-party callback).
///
/// Level mapping (case-insensitive):
///
/// | Input string | SDK method called |
/// |---|---|
/// | `"TRACE"`, `"DEBUG"` | ``CeburuAnalyticsSDK/debug(_:attributes:)`` |
/// | `"INFO"` | ``CeburuAnalyticsSDK/info(_:attributes:)`` |
/// | `"WARN"`, `"WARNING"` | ``CeburuAnalyticsSDK/warn(_:attributes:)`` |
/// | `"ERROR"` | ``CeburuAnalyticsSDK/error(_:error:attributes:)`` |
/// | `"FATAL"`, `"CRITICAL"` | ``CeburuAnalyticsSDK/fatal(_:error:attributes:)`` |
/// | anything else | ``CeburuAnalyticsSDK/info(_:attributes:)`` |
public enum MobileLogSink {

    /// Async entry point — use from async contexts (e.g. Swift Concurrency tasks).
    ///
    /// Awaits the underlying SDK actor call, so it respects back-pressure from the actor queue.
    ///
    /// - Parameters:
    ///   - level:      Log level string. Case-insensitive (e.g. `"WARN"`, `"error"`).
    ///   - message:    Human-readable log message.
    ///   - error:      Optional `Error` — its type and description are appended as attributes.
    ///   - attributes: Optional key-value metadata. PII keys are automatically redacted.
    public static func log(
        level: String,
        message: String,
        error: Error? = nil,
        attributes: [String: Any] = [:]
    ) async {
        let attrs = attributes.mapValues { "\($0)" }
        await route(level: level, message: message, error: error, attributes: attrs)
    }

    /// Sync entry point — call this from any existing synchronous logger callback.
    ///
    /// Internally creates a detached `Task` that schedules the SDK call on its actor executor.
    /// Returns immediately — suitable for use inside `DDLogMessage` handlers, `os_log` callbacks,
    /// or any other synchronous context. The `Task` holds no references that outlive the event.
    ///
    /// - Parameters:
    ///   - level:      Log level string. Case-insensitive.
    ///   - message:    Human-readable log message.
    ///   - error:      Optional `Error` appended as exception attributes.
    ///   - attributes: Optional key-value metadata. PII keys are automatically redacted.
    public static func logSync(
        level: String,
        message: String,
        error: Error? = nil,
        attributes: [String: Any] = [:]
    ) {
        // Convert to [String: String] before Task capture — [String: Any] is not Sendable.
        let attrs = attributes.mapValues { "\($0)" }
        Task { await route(level: level, message: message, error: error, attributes: attrs) }
    }

    private static func route(
        level: String,
        message: String,
        error: Error?,
        attributes: [String: String]
    ) async {
        switch level.uppercased() {
        case "TRACE", "DEBUG":
            await CeburuAnalyticsSDK.shared.debug(message, attributes: attributes)

        case "INFO":
            await CeburuAnalyticsSDK.shared.info(message, attributes: attributes)

        case "WARN", "WARNING":
            await CeburuAnalyticsSDK.shared.warn(message, attributes: attributes)

        case "ERROR":
            await CeburuAnalyticsSDK.shared.error(message, error: error, attributes: attributes)

        case "FATAL", "CRITICAL":
            await CeburuAnalyticsSDK.shared.fatal(message, error: error, attributes: attributes)

        default:
            await CeburuAnalyticsSDK.shared.info(message, attributes: attributes)
        }
    }
}

// MARK: - CallbackLoggerAdapter

/// Adapter for manually forwarding log records from any custom logging framework.
///
/// Use this when your app has a custom logger class or singleton. Install the adapter once,
/// then call ``forward(level:message:error:attributes:)`` from each method of your existing logger.
/// No changes are needed anywhere else in your app.
///
/// ```swift
/// // In App.init or AppDelegate, after SDK initialization:
/// await CeburuAnalyticsSDK.shared.installLoggerAdapter(CallbackLoggerAdapter.shared)
///
/// // In your existing logger class:
/// static func warn(_ message: String) {
///     print("[WARN] \(message)")
///     CallbackLoggerAdapter.shared.forward(level: "WARN", message: message)
/// }
/// ```
public final class CallbackLoggerAdapter: LoggerAdapter, @unchecked Sendable {

    /// Shared instance — use this unless you need multiple independent adapters.
    public static let shared = CallbackLoggerAdapter()
    public init() {}

    /// No-op — this adapter does not hook into any framework automatically.
    /// Forwarding is done manually via ``forward(level:message:error:attributes:)``.
    public func install() async {}

    /// No-op — no framework hook was established in ``install()``.
    public func uninstall() async {}

    /// Forwards a log record from your custom logger into ``CeburuAnalyticsSDK``.
    ///
    /// Safe to call from synchronous contexts — uses ``MobileLogSink/logSync(level:message:error:attributes:)``
    /// internally. The level string is mapped to the appropriate SDK severity via ``MobileLogSink``.
    ///
    /// - Parameters:
    ///   - level:      Log level string (e.g. `"WARN"`, `"error"`). Case-insensitive.
    ///   - message:    Human-readable log message.
    ///   - error:      Optional `Error` — its type and `localizedDescription` are attached automatically.
    ///   - attributes: Optional key-value metadata. PII keys are automatically redacted.
    public func forward(
        level: String,
        message: String,
        error: Error? = nil,
        attributes: [String: Any] = [:]
    ) {
        MobileLogSink.logSync(level: level, message: message, error: error, attributes: attributes)
    }
}

// MARK: - OSLogAdapter

/// Drop-in replacement for Apple's `os.Logger` / `Logger` that mirrors output to the Ceburu collector.
///
/// Replace your `Logger` instance with `OSLogAdapter` — it logs to both the system console
/// (visible in Xcode and Console.app) and the Analytics collector. All existing call sites
/// continue to work unchanged.
///
/// ```swift
/// // Replace this:
/// // let log = Logger(subsystem: "com.myapp", category: "payments")
///
/// // With this:
/// let log = OSLogAdapter(subsystem: "com.myapp", category: "payments")
///
/// // Register once after SDK initialization:
/// await CeburuAnalyticsSDK.shared.installLoggerAdapter(log)
///
/// // Use exactly as before:
/// log.info("Payment initiated", attributes: ["amount": "99.00"])
/// log.error("Checkout failed", attributes: ["code": "ERR_500"])
/// ```
public final class OSLogAdapter: LoggerAdapter, @unchecked Sendable {

    private let osLogger: os.Logger

    /// Creates an adapter that wraps an `os.Logger` with the given subsystem and category.
    ///
    /// - Parameters:
    ///   - subsystem: Reverse-DNS identifier for your app or library (e.g. `"com.myapp.payments"`).
    ///   - category:  Short label grouping related log messages (e.g. `"payments"`, `"auth"`).
    public init(subsystem: String, category: String) {
        self.osLogger = os.Logger(subsystem: subsystem, category: category)
    }

    /// No-op — `OSLogAdapter` does not need framework-level registration.
    public func install() async {}

    /// No-op — no registration was performed in ``install()``.
    public func uninstall() async {}

    /// Logs at `DEBUG` level — written to the system console and the collector.
    ///
    /// - Parameters:
    ///   - message:    Human-readable log message.
    ///   - attributes: Optional key-value metadata forwarded to the collector. PII keys are redacted.
    public func debug(_ message: String, attributes: [String: Any] = [:]) {
        osLogger.debug("\(message, privacy: .public)")
        MobileLogSink.logSync(level: "DEBUG", message: message, attributes: attributes)
    }

    /// Logs at `INFO` level — written to the system console and the collector.
    ///
    /// - Parameters:
    ///   - message:    Human-readable log message.
    ///   - attributes: Optional key-value metadata forwarded to the collector. PII keys are redacted.
    public func info(_ message: String, attributes: [String: Any] = [:]) {
        osLogger.info("\(message, privacy: .public)")
        MobileLogSink.logSync(level: "INFO", message: message, attributes: attributes)
    }

    /// Logs at `WARN` level — written to the system console and the collector.
    ///
    /// - Parameters:
    ///   - message:    Human-readable log message.
    ///   - attributes: Optional key-value metadata forwarded to the collector. PII keys are redacted.
    public func warning(_ message: String, attributes: [String: Any] = [:]) {
        osLogger.warning("\(message, privacy: .public)")
        MobileLogSink.logSync(level: "WARN", message: message, attributes: attributes)
    }

    /// Logs at `ERROR` level — written to the system console and the collector.
    ///
    /// Breadcrumbs accumulated before this call are automatically attached as `session.breadcrumbs`.
    ///
    /// - Parameters:
    ///   - message:    Human-readable description of the error.
    ///   - attributes: Optional key-value metadata forwarded to the collector. PII keys are redacted.
    public func error(_ message: String, attributes: [String: Any] = [:]) {
        osLogger.error("\(message, privacy: .public)")
        MobileLogSink.logSync(level: "ERROR", message: message, attributes: attributes)
    }

    /// Logs at `FATAL` level — written to the system console and the collector.
    ///
    /// Use for conditions where the app must crash or restart. Breadcrumbs are attached automatically.
    ///
    /// - Parameters:
    ///   - message:    Human-readable description of the fatal condition.
    ///   - attributes: Optional key-value metadata forwarded to the collector. PII keys are redacted.
    public func critical(_ message: String, attributes: [String: Any] = [:]) {
        osLogger.critical("\(message, privacy: .public)")
        MobileLogSink.logSync(level: "FATAL", message: message, attributes: attributes)
    }
}
