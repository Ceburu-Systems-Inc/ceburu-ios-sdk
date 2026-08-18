import Foundation
import os

/**
 One-time logging bridge.

 Existing application code should continue using its current logger.
 A framework-specific adapter forwards records into MobileLogSink.

 Important:
 Apple Unified Logging (Logger / os_log) does not provide a general supported
 API for an embedded third-party SDK to subscribe to every log emitted by the
 host process in real time.

 Therefore the enterprise-safe design is:
 existing logger -> one-time bridge/adapter -> MobileLogSink -> MobileSDK

 This avoids relying on unsupported log scraping.
 */
public protocol LoggerAdapter: Sendable {
    func install() async
}

/**
 Framework-neutral sink.
 Any Swift/Objective-C logging framework adapter can forward here.
 */
public enum MobileLogSink {

    public static func log(
        level: String,
        message: String,
        error: Error? = nil,
        attributes: [String: String] = [:]
    ) async {
        switch level.uppercased() {

        case "TRACE", "DEBUG":
            await MobileSDK.shared.debug(
                message,
                attributes: attributes
            )

        case "INFO":
            await MobileSDK.shared.info(
                message,
                attributes: attributes
            )

        case "WARN", "WARNING":
            await MobileSDK.shared.warn(
                message,
                attributes: attributes
            )

        case "ERROR":
            var attrs = attributes

            if let error {
                attrs["exception.type"] =
                    String(
                        describing:
                            type(of: error)
                    )

                attrs["exception.message"] =
                    error.localizedDescription
            }

            await MobileSDK.shared.error(
                message,
                attributes: attrs
            )

        case "FATAL", "CRITICAL":
            var attrs = attributes

            if let error {
                attrs["exception.type"] =
                    String(
                        describing:
                            type(of: error)
                    )

                attrs["exception.message"] =
                    error.localizedDescription
            }

            await MobileSDK.shared.fatal(
                message,
                attributes: attrs
            )

        default:
            await MobileSDK.shared.info(
                message,
                attributes: attributes
            )
        }
    }
}

/**
 Generic callback bridge for SwiftyBeaver, CocoaLumberjack,
 custom enterprise loggers, Objective-C log wrappers, etc.

 The framework-specific integration calls `forward(...)`.
 */
public final class CallbackLoggerAdapter:
    LoggerAdapter,
    @unchecked Sendable {

    public init() {}

    public func install() async {
        // No-op. Framework hook forwards into forward(...).
    }

    public func forward(
        level: String,
        message: String,
        error: Error? = nil,
        attributes: [String: String] = [:]
    ) async {
        await MobileLogSink.log(
            level: level,
            message: message,
            error: error,
            attributes: attributes
        )
    }
}
