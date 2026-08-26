# MobileOTelSDK — iOS

Enterprise-grade OpenTelemetry logging SDK for iOS. Captures log events from your app, encrypts them on-device, and delivers them to your assigned OTel Collector endpoint via gRPC.

---

## Requirements

- iOS 15+
- Swift 5.9+
- Xcode 15+

---

## Installation

Add the SDK via Swift Package Manager in Xcode:

1. **File → Add Package Dependencies**
2. Enter the repository URL provided by your account team
3. Select **MobileOTelSDK** as the library to add to your target

---

## Quick Start

### Step 1 — Initialize the SDK at app startup

In your `AppDelegate` or `App` entry point:

```swift
import MobileOTelSDK

@main
struct MyApp: App {
    init() {
        Task {
            try? await MobileOTelSDK.shared.initialize(
                config: MobileOTelSDK.Config(
                    serviceName:    "MyApp",
                    serviceVersion: "1.0.2",
                    environment:    "production",
                    tenantId:       "<your-tenant-id>",        // provided by account team
                    applicationId:  "<your-application-id>",   // provided by account team
                    collectorHost:  "<your-collector-host>",    // provided by account team
                    collectorPort:  4317
                )
            )
        }
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
```

> **Note:** `collectorHost`, `tenantId`, and `applicationId` are provided by your account team. Do not hardcode placeholder values in production builds.

### Step 2 — Connect your existing logger (one-time setup)

Choose the adapter that matches the logger your app already uses:

---

## Adapter Selection Guide

| Your current logger | Adapter to use |
|---|---|
| Custom app logger class / singleton | `CallbackLoggerAdapter` |
| Apple `os.log` / `Logger` | `OSLogAdapter` |
| SwiftyBeaver | Write a custom `LoggerAdapter` (see below) |
| CocoaLumberjack | Write a custom `LoggerAdapter` (see below) |
| No existing logger | Call `MobileOTelSDK.shared` directly |

---

## Option A — Custom app logger (most common)

If your app already has its own logger class, add one line inside each logging method. No changes needed anywhere else in your app.

```swift
import MobileOTelSDK

// Your existing logger — edit this class once
class AppLogger {

    static func debug(_ message: String) {
        print("[DEBUG] \(message)")
        CallbackLoggerAdapter.shared.forward(level: "DEBUG", message: message)
    }

    static func info(_ message: String) {
        print("[INFO] \(message)")
        CallbackLoggerAdapter.shared.forward(level: "INFO", message: message)
    }

    static func warn(_ message: String) {
        print("[WARN] \(message)")
        CallbackLoggerAdapter.shared.forward(level: "WARN", message: message)
    }

    static func error(_ message: String, error: Error? = nil) {
        print("[ERROR] \(message)")
        CallbackLoggerAdapter.shared.forward(level: "ERROR", message: message, error: error)
    }
}
```

Register the adapter after SDK initialization:

```swift
await MobileOTelSDK.shared.installLoggerAdapter(CallbackLoggerAdapter.shared)
```

All existing `AppLogger.warn("...")` calls throughout your app now automatically deliver to the OTel Collector — no other changes needed.

---

## Option B — Apple os.log / Logger

If your app uses Apple's `Logger` framework, replace your `Logger` instance with `OSLogAdapter`. It logs to both the system console (Xcode / Console.app) and the OTel Collector.

```swift
import MobileOTelSDK

// Replace this:
// let log = Logger(subsystem: "com.myapp", category: "payments")

// With this:
let log = OSLogAdapter(subsystem: "com.myapp", category: "payments")

// Register once at startup:
await MobileOTelSDK.shared.installLoggerAdapter(log)
```

Then use `log` exactly as before — same method names, same call sites:

```swift
log.info("Payment initiated", attributes: ["amount": "99.00", "currency": "USD"])
log.warning("Retry attempt 2")
log.error("Payment declined", attributes: ["code": "ERR_402"])
```

---

## Option C — SwiftyBeaver

Create a custom destination that forwards to the SDK. Write this once in your project:

```swift
import SwiftyBeaver
import MobileOTelSDK

final class MobileSDKDestination: BaseDestination {
    override func send(
        _ level: SwiftyBeaver.Level,
        msg: String,
        thread: String,
        file: String,
        function: String,
        line: Int,
        context: Any? = nil
    ) -> String? {
        MobileLogSink.logSync(level: level.description, message: msg)
        return super.send(level, msg: msg, thread: thread, file: file, function: function, line: line, context: context)
    }
}
```

Register at startup:

```swift
SwiftyBeaver.addDestination(MobileSDKDestination())
```

All existing `SwiftyBeaver.warn("...")` calls now also go to the OTel Collector.

---

## Option D — CocoaLumberjack

Create a custom logger that forwards to the SDK. Write this once in your project:

```swift
import CocoaLumberjack
import MobileOTelSDK

final class MobileSDKLogger: DDAbstractLogger {
    override func log(message logMessage: DDLogMessage) {
        let level: String
        switch logMessage.flag {
        case .error:   level = "ERROR"
        case .warning: level = "WARN"
        case .info:    level = "INFO"
        case .debug:   level = "DEBUG"
        default:       level = "TRACE"
        }
        MobileLogSink.logSync(level: level, message: logMessage.message)
    }
}
```

Register at startup:

```swift
DDLog.add(MobileSDKLogger())
```

---

## Option E — No existing logger

If your app does not use a logging framework, call the SDK directly:

```swift
await MobileOTelSDK.shared.debug("User opened payment screen")
await MobileOTelSDK.shared.info("Order placed", attributes: ["order_id": "ORD-123"])
await MobileOTelSDK.shared.warn("Network slow", attributes: ["latency_ms": "3200"])
await MobileOTelSDK.shared.error("Checkout failed", attributes: ["code": "ERR_500"])
```

---

## Config Reference

| Parameter | Type | Default | Description |
|---|---|---|---|
| `serviceName` | `String` | required | Your app name as it appears in the collector |
| `serviceVersion` | `String` | required | App version string (e.g. `"2.1.0"`) |
| `environment` | `String` | required | `"production"`, `"staging"`, etc. |
| `tenantId` | `String` | required | Provided by your account team |
| `applicationId` | `String` | required | Provided by your account team |
| `collectorHost` | `String` | required | OTel Collector host — provided by your account team |
| `collectorPort` | `Int` | `4317` | OTel Collector gRPC port |
| `queueMaxBytes` | `Int` | `52428800` (50 MB) | Maximum on-device queue size |
| `retentionHours` | `Int` | `72` | How long events are kept if delivery fails |

---

## Advanced Features

### Breadcrumbs

Record UI navigation or user actions. Breadcrumbs are automatically attached to any `error` or `fatal` event that follows, giving you context around failures.

```swift
await MobileOTelSDK.shared.breadcrumb(category: "ui", message: "Opened checkout screen")
await MobileOTelSDK.shared.breadcrumb(category: "network", message: "Payment API called")
// If an error fires next, these two breadcrumbs are included automatically
await MobileOTelSDK.shared.error("Payment declined")
```

### Sessions

A session ID is generated automatically at SDK init. Start a new session whenever the user logs in or a new workflow begins:

```swift
await MobileOTelSDK.shared.newSession()
```

### Attributes

Pass key/value metadata with any log call:

```swift
await MobileOTelSDK.shared.info(
    "User action",
    attributes: [
        "screen":    "checkout",
        "action":    "tap_pay",
        "cart_size": "3"
    ]
)
```

---

## PII / Secret Handling

The SDK automatically redacts sensitive data in attributes before sending:

| Key pattern | Behaviour |
|---|---|
| Contains `password`, `authorization`, `cookie`, `secret` | Dropped entirely |
| Contains `token`, `card` | Replaced with `[REDACTED]` |
| Contains `email`, `phone` | Replaced with SHA-256 hash |
| Everything else | Sent as-is |

---

## Offline Behaviour

Events are encrypted with AES-GCM and stored on-device when the collector is unreachable. On reconnection the SDK flushes the queue automatically using exponential backoff. If the queue reaches its size limit, the lowest-severity events are evicted first to preserve errors and fatals.

---

## Crash Reporting

Unhandled exceptions are captured and persisted to disk immediately at crash time. On the next app launch the SDK imports the crash record and delivers it to the collector as a `fatal` severity event with the full stack trace attached.

No additional setup is required — crash handling is enabled automatically on `initialize()`.

---

## Security Notes

- The on-device queue is encrypted with AES-GCM using a key stored in the iOS Keychain
- The Keychain key is protected with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
- Do not embed `collectorHost`, `tenantId`, or `applicationId` as hardcoded strings in production — load them from your remote config or backend at runtime
- gRPC transport must use TLS in production — your account team's collector endpoint enforces this
