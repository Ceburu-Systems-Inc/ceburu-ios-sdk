# CeburuAnalyticsSDK — iOS

Enterprise-grade OpenTelemetry logging SDK for iOS. Captures log events from your app, encrypts them on-device, and delivers them to your assigned Ceburu Collector endpoint via OTLP/HTTP.

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
3. Select version `3.1.0` (or **Up to Next Major Version** from `3.1.0`)
4. Select **CeburuAnalyticsSDK** as the library to add to your target

---

## Initialization

Initialize the SDK once in your `AppDelegate` or `App` entry point before any logging calls.

```swift
import CeburuAnalyticsSDK

@main
struct MyApp: App {
    init() {
        Task {
            try? await CeburuAnalyticsSDK.shared.initialize(
                config: CeburuAnalyticsSDK.Config(
                    // ── Required ──────────────────────────────────────────────
                    serviceName:    "MyApp",
                    serviceVersion: "x.x.x",
                    environment:    "production",
                    tenantId:       "<your-tenant-id>",        // provided by account team
                    applicationId:  "<your-application-id>",   // provided by account team
                    configId:       "<your-config-id>",        // provided by account team
                    collectorHost:  "<your-collector-host>",   // provided by account team
                    userId:         "<user-id>",               // unique per user; update at login/logout
                    authToken:      "<your-customer-token>",   // Bearer token for collector auth

                    // ── Optional ──────────────────────────────────────────────
                    collectorPort:         4318,     // OTLP/HTTP port (default: 4318)
                    useHTTPS:              true,     // must be true in production
                    queueMaxBytes:         52428800, // 50 MB on-device queue limit
                    retentionHours:        72,       // hours to retain events if delivery fails
                    maxBatchEvents:        200,      // max events per export batch
                    maxBatchBytes:         524288,   // 512 KB max payload per batch
                    metricsExportInterval: 60        // seconds between metric exports (default: 60)
                )
            )
        }
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
```

> **Note:** `collectorHost`, `tenantId`, `applicationId`, and `configId` are provided by your account team. Do not hardcode placeholder values in production builds.

### Config Reference

| Parameter | Required | Default | Description |
|---|---|---|---|
| `serviceName` | **Required** | — | App name in collector |
| `serviceVersion` | **Required** | — | App version string |
| `environment` | **Required** | — | `"production"`, `"staging"`, etc. |
| `tenantId` | **Required** | — | Tenant identifier (from account team) |
| `applicationId` | **Required** | — | Bundle ID (from account team) |
| `configId` | **Required** | `""` | Ceburu configuration ID — routes signals to the correct tenant index on the edge. Provided by account team. |
| `collectorHost` | **Required** | — | OTLP/HTTP collector host (from account team) |
| `userId` | **Required** | `""` | Unique per user; update at login/logout with `setUser()` |
| `authToken` | **Required** | `""` | Customer-provided Bearer token |
| `collectorPort` | Optional | `4318` | OTLP/HTTP port |
| `useHTTPS` | Optional | `true` | Use HTTPS — must be `true` in production |
| `queueMaxBytes` | Optional | `52428800` (50 MB) | On-device queue size limit |
| `retentionHours` | Optional | `72` | Hours to retain events if delivery fails |
| `maxBatchEvents` | Optional | `200` | Max events per export batch |
| `maxBatchBytes` | Optional | `524288` (512 KB) | Max payload size per batch |
| `metricsExportInterval` | Optional | `60` | Seconds between metric exports. Set to `10` during development for faster feedback |

---

## Logs

The SDK exports log events to `/apm/v1/logs` within ~2 seconds via OTLP/HTTP.

### Step 1 — Connect your existing logger (one-time setup)

Choose the adapter that matches the logger your app already uses:

| Your current logger | Adapter to use |
|---|---|
| Custom app logger class / singleton | `CallbackLoggerAdapter` |
| Apple `os.log` / `Logger` | `OSLogAdapter` |
| SwiftyBeaver | Write a custom `LoggerAdapter` (see below) |
| CocoaLumberjack | Write a custom `LoggerAdapter` (see below) |
| No existing logger | Call `CeburuAnalyticsSDK.shared` directly |

---

### Option A — Custom app logger (most common)

If your app already has its own logger class, add one line inside each logging method. No changes needed anywhere else in your app.

```swift
import CeburuAnalyticsSDK

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
await CeburuAnalyticsSDK.shared.installLoggerAdapter(CallbackLoggerAdapter.shared)
```

All existing `AppLogger.warn("...")` calls throughout your app now automatically deliver to the Ceburu Collector — no other changes needed.

---

### Option B — Apple os.log / Logger

If your app uses Apple's `Logger` framework, replace your `Logger` instance with `OSLogAdapter`. It logs to both the system console (Xcode / Console.app) and the Ceburu Collector.

```swift
import CeburuAnalyticsSDK

// Replace this:
// let log = Logger(subsystem: "com.myapp", category: "payments")

// With this:
let log = OSLogAdapter(subsystem: "com.myapp", category: "payments")

// Register once at startup:
await CeburuAnalyticsSDK.shared.installLoggerAdapter(log)
```

Then use `log` exactly as before — same method names, same call sites:

```swift
log.info("Payment initiated", attributes: ["amount": "99.00", "currency": "USD"])
log.warning("Retry attempt 2")
log.error("Payment declined", attributes: ["code": "ERR_402"])
```

---

### Option C — SwiftyBeaver

Create a custom destination that forwards to the SDK. Write this once in your project:

```swift
import SwiftyBeaver
import CeburuAnalyticsSDK

final class CeburuDestination: BaseDestination {
    override func send(
        _ level: SwiftyBeaver.Level,
        msg: String,
        thread: String,
        file: String,
        function: String,
        line: Int,
        context: Any? = nil
    ) -> String? {
        CallbackLoggerAdapter.shared.forward(level: level.description, message: msg)
        return super.send(level, msg: msg, thread: thread, file: file,
                          function: function, line: line, context: context)
    }
}
```

Register at startup:

```swift
SwiftyBeaver.addDestination(CeburuDestination())
```

All existing `SwiftyBeaver.warn("...")` calls now also go to the Ceburu Collector.

---

### Option D — CocoaLumberjack

Create a custom logger that forwards to the SDK. Write this once in your project:

```swift
import CocoaLumberjack
import CeburuAnalyticsSDK

final class CeburuLumberjackLogger: DDAbstractLogger {
    override func log(message logMessage: DDLogMessage) {
        let level: String
        switch logMessage.flag {
        case .error:   level = "ERROR"
        case .warning: level = "WARN"
        case .info:    level = "INFO"
        case .debug:   level = "DEBUG"
        default:       level = "TRACE"
        }
        CallbackLoggerAdapter.shared.forward(level: level, message: logMessage.message)
    }
}
```

Register at startup:

```swift
DDLog.add(CeburuLumberjackLogger())
```

---

### Option E — No existing logger

If your app does not use a logging framework, call the SDK directly:

```swift
await CeburuAnalyticsSDK.shared.debug("User opened payment screen")
await CeburuAnalyticsSDK.shared.info("Order placed", attributes: ["order_id": "ORD-123"])
await CeburuAnalyticsSDK.shared.warn("Network slow", attributes: ["latency_ms": 1542])
await CeburuAnalyticsSDK.shared.error("Checkout failed", attributes: ["code": "ERR_500"])
```

---

### Breadcrumbs

Record UI navigation or user actions. Breadcrumbs are automatically attached to any `error` or `fatal` event that follows, giving you context around failures.

```swift
await CeburuAnalyticsSDK.shared.breadcrumb(category: "ui", message: "Opened checkout screen")
await CeburuAnalyticsSDK.shared.breadcrumb(category: "network", message: "Payment API called")
// If an error fires next, these two breadcrumbs are included automatically
await CeburuAnalyticsSDK.shared.error("Payment declined")
```

### Sessions

A session ID is generated automatically at SDK init. Start a new session whenever the user logs in or a new workflow begins:

```swift
await CeburuAnalyticsSDK.shared.newSession()
```

### Attributes

Pass key/value metadata with any log call. Values can be `String`, `Int`, `Double`, or `Bool` — non-string values are automatically stringified before export:

```swift
await CeburuAnalyticsSDK.shared.info(
    "User action",
    attributes: [
        "screen":     "checkout",
        "action":     "tap_pay",
        "cart_size":  3,          // Int accepted directly
        "latency_ms": 1542,
        "retried":    true        // Bool accepted directly
    ]
)
```

### PII / Secret Handling

The SDK automatically redacts sensitive data in attributes before writing to disk or sending to the collector:

| Key pattern | Behaviour |
|---|---|
| Contains `password`, `authorization`, `cookie`, `secret` | Dropped entirely |
| Contains `token`, `card` | Replaced with `[REDACTED]` |
| Contains `email`, `phone` | Replaced with SHA-256 hash |
| Everything else | Sent as-is |

### Offline Behaviour

Events are encrypted with AES-256-GCM and stored on-device when the collector is unreachable. On reconnection the SDK flushes the queue automatically using exponential backoff. Events older than `retentionHours` are discarded. If the queue reaches `queueMaxBytes`, the lowest-severity events are evicted first — FATAL and ERROR events survive storage pressure longer than routine INFO/DEBUG events.

### Crash Reporting

Unhandled exceptions (`NSException`) and POSIX signals (SIGABRT, SIGSEGV, SIGILL, SIGBUS, SIGTRAP) are captured and persisted to disk immediately at crash time using AES-256-GCM encryption. On the next app launch the SDK imports the crash record and delivers it to the collector as a `FATAL` severity event with the full stack trace and breadcrumb trail attached.

The crash event in the collector contains:

| Attribute | Value |
|---|---|
| `severity` | `FATAL` |
| `telemetry.event.type` | `crash` |
| `exception.type` | Signal name (e.g. `SIGABRT`) or exception class |
| `exception.message` | Human-readable description |
| `exception.stacktrace` | Full symbolicated stack trace |
| `crash.session.id` | Session ID from the crashed run |
| `session.breadcrumbs` | Pipe-separated breadcrumb trail at crash time |

No additional setup is required — crash handling is enabled automatically on `initialize()`.

---

## Log-Trace Correlation

When a log event is emitted while an active OTel span is in context, the SDK automatically captures the span's `trace_id` and `span_id` and attaches them to the log record. When exported, these IDs link the log to its corresponding trace in the backend.

No additional setup is required. To emit a correlated log:

```swift
let span = await CeburuAnalyticsSDK.shared.startSpan(
    "checkout.verified",
    attrs: ["order.id": "ORD-456"]
)

// This log is emitted while the span is active.
// trace_id and span_id are captured and attached automatically.
await CeburuAnalyticsSDK.shared.info("Payment validated", attributes: ["amount": "49.99"])

span.end()
```

In the collector, the log record will include:

```
Attributes:
    -> trace_id: Str(4bf92f3577b34da6a3ce929d0e0e4736)
    -> span_id:  Str(00f067aa0ba902b7)
```

Use these to navigate from a log entry directly to its trace in your observability platform.

---

## User Identity

Each user is identified through the `userId` config field. It appears as `enduser.id` on every telemetry signal (logs, metrics, traces) emitted during that session.

> **Note:** Multiple users share the same `tenantId`. Each must have a distinct `userId` so their events can be distinguished in the collector.

### Setting userId at Initialization

Pass `userId` in the Config at initialization (see [Initialization](#initialization)).

### Updating userId at Runtime

Call `setUser()` on login, account switch, or logout. The new identity is propagated to both log events and trace spans immediately:

```swift
await CeburuAnalyticsSDK.shared.setUser("user-john-001")  // after login — logs AND spans carry enduser.id
await CeburuAnalyticsSDK.shared.setUser("")               // on logout — clears enduser.id
```

### Output — enduser.id in Resource Attributes

All three signals carry `enduser.id` as a resource attribute alongside `tenant.id`:

```
Resource attributes:
     -> tenant.id:     Str(tenant-acme)
     -> config_id:     Str(cfg-prod-001)
     -> enduser.id:    Str(user-john-001)
     -> service.name:  Str(MyApp)
```

---

## Metrics

App-level metrics are exported every `metricsExportInterval` seconds (default: 60) to `/apm/v1/metrics` — a separate endpoint from logs and traces.

### Counter — Monotonically Increasing

```swift
await CeburuAnalyticsSDK.shared.incrementCounter(
    "checkout.attempts",
    value: 1,
    attrs: ["screen": "cart"]
)
```

### UpDownCounter — Bidirectional

```swift
await CeburuAnalyticsSDK.shared.incrementUpDownCounter("active.downloads", value: +1)
await CeburuAnalyticsSDK.shared.incrementUpDownCounter("active.downloads", value: -1)
```

### Histogram — Value Distribution

```swift
await CeburuAnalyticsSDK.shared.recordHistogram(
    "api.response.ms",
    value: 142.0,
    attrs: ["endpoint": "/checkout"]
)
```

### Observable Gauge / Counter — Polled Every `metricsExportInterval` s

Register once at startup; the SDK polls the callback automatically:

```swift
await CeburuAnalyticsSDK.shared.observeGauge(name: "memory.used.mb", unit: "MiBy") {
    let info = mach_task_basic_info()
    // ... return resident memory in MB
    return memoryMB
}
await CeburuAnalyticsSDK.shared.observeCounter(name: "app.sessions.total", unit: "{session}") {
    Int64(sessionCount)
}
```

### Force Flush

Force an immediate metric export outside the normal interval — useful before app backgrounding or in tests:

```swift
let ok = await CeburuAnalyticsSDK.shared.flushMetrics()
// ok == true  → metrics delivered to collector
// ok == false → collector unreachable (check host / port)
```

### Expected Collector Output

```
ResourceMetrics #0
Resource attributes:
     -> tenant.id: Str(tenant-acme)    -> enduser.id: Str(user-john-001)
Metric #0  Name: checkout.attempts  DataType: Sum  IsMonotonic: true  Value: 3
Metric #1  Name: active.downloads   DataType: Sum  IsMonotonic: false  Value: 2
Metric #2  Name: api.response.ms    DataType: Histogram  Count: 5  Sum: 612.0
Metric #3  Name: memory.used.mb     DataType: Gauge  Value: 271.0
Metric #4  Name: app.sessions.total DataType: Sum  IsMonotonic: true  Value: 1
```

### SDK-Internal Health Metrics

The SDK automatically reports its own health counters alongside your app metrics. These require no setup and are visible in the same collector output:

| Metric | Attributes | Meaning |
|---|---|---|
| `mobile.sdk.events.emitted` | `severity`, `event.type` | Events successfully queued to on-device storage |
| `mobile.sdk.events.dropped` | _(none)_ | Events rejected by policy, severity filter, or sample rate |
| `mobile.sdk.export.success` | `events` (batch count) | Batches successfully delivered to the log processor |
| `mobile.sdk.export.failure` | _(none)_ | Delivery failures — events remain in queue for retry |

Use `mobile.sdk.events.dropped` and `mobile.sdk.export.failure` to alert on SDK health in production without any app-side instrumentation.

---

## Distributed Tracing

Traces are exported to `/apm/v1/traces` within seconds of `span.end()` — independently of logs and metrics.

### Start and End a Span

```swift
let span = await CeburuAnalyticsSDK.shared.startSpan(
    "payment.flow",
    attrs: ["cart.id": "cart-123"]
)
span.setAttribute(key: "order.id", value: "ORD-456")
span.setAttribute(key: "amount.usd", value: "99.99")
span.end()

// On failure:
span.endWithError(PaymentError.declined)   // records status=ERROR + exception stack trace
```

### SpanKind

```swift
// CLIENT — outgoing network call
let span = await CeburuAnalyticsSDK.shared.startSpan(
    "outgoing.http.call",
    attrs: ["http.method": "GET", "http.url": "https://api.example.com"],
    kind: .client
)
```

### Span Events

```swift
span.addEvent(name: "cart.validated")
span.addEvent(name: "payment.initiated", attrs: ["gateway": "stripe", "amount": "99.99"])
span.addEvent(name: "payment.confirmed", attrs: ["transaction.id": "txn_001"])
```

### Expected Collector Output

```
ResourceSpans #0
Resource attributes:
     -> tenant.id: Str(tenant-acme)    -> enduser.id: Str(user-john-001)
Span #0
    Name: payment.flow    Kind: Internal    Status: Unset
    Attributes:
         -> cart.id:    Str(cart-123)
         -> order.id:   Str(ORD-456)
         -> amount.usd: Str(99.99)
```

---

## Authentication & Token Rotation

Every export request carries a Bearer token in the `Authorization` HTTP header. The token is customer-provided — never hardcode it; load from a secure remote config at startup.

### Setting the Token

Pass `authToken` in the Config at initialization (see [Initialization](#initialization)).

### Token Rotation

Call `updateAuthToken()` to swap the token at runtime. It takes effect on the very next export batch — all three pipelines (logs, metrics, traces) are rebuilt immediately with the new token:

```swift
try? await CeburuAnalyticsSDK.shared.updateAuthToken("new-token-xyz")
```

---

## Telemetry Signal Endpoints — Three Separate API Calls

One SDK action can produce up to three separate HTTP POST requests, each to its own endpoint:

| Signal | Endpoint | Timing |
|---|---|---|
| Logs | `POST /apm/v1/logs` | Within ~2 s |
| Metrics | `POST /apm/v1/metrics` | Every `metricsExportInterval` s (default 60) |
| Traces | `POST /apm/v1/traces` | Within ~5 s of `span.end()` |

All three carry the same `tenant.id`, `config_id`, and `enduser.id` resource attributes, enabling cross-signal correlation in the backend.

---

## Security Notes

- The on-device event queue is encrypted with AES-256-GCM using a key stored in the iOS Keychain
- The Keychain key is protected with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
- Crash records are encrypted with AES-256-GCM at crash time using a key derived from the app bundle ID
- All endpoints must use HTTPS in production — `useHTTPS: false` is for local development only
- Do not embed `collectorHost`, `tenantId`, `applicationId`, or `configId` as hardcoded strings in production — load them from your remote config or backend at runtime

---

## Local Testing

For local development with a Docker collector, point the SDK at your Mac's loopback address from the simulator:

```swift
try? await CeburuAnalyticsSDK.shared.initialize(
    config: CeburuAnalyticsSDK.Config(
        // ...
        collectorHost: "localhost",  // simulator reaches the Mac on localhost
        collectorPort: 4318,         // standard OTLP/HTTP port
        useHTTPS:      false,        // dev only — must be true in production
        // ...
    )
)
```

> **Note:** The iOS Simulator shares the Mac's network stack, so `localhost` resolves to the Mac. On a physical device, use your Mac's LAN IP address instead (e.g. `192.168.1.10`).

Add to your app's `Info.plist` to allow plain-text local traffic:

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
</dict>
```

Or use `network_security_config.xml` equivalent (see Apple's ATS documentation for domain-level exceptions).
