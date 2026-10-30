# Ceburu RUM SDK for iOS

Real user monitoring for iOS apps. Sends logs, errors, crashes and spans to Ceburu over OTLP, with an
encrypted log queue, sessions and redaction. Custom metrics are off by default. It works alongside
[`@ceburu/rum-web`](https://github.com/Ceburu-Systems-Inc/ceburu-rum-web) and the
[Android SDK](https://github.com/Ceburu-Systems-Inc/ceburu-android-sdk); all three share one data contract.

- iOS 15+, Xcode 16+ (Swift 6 toolchain), Swift Package Manager, Apache-2.0.
- Built on [OpenTelemetry Swift](https://github.com/open-telemetry/opentelemetry-swift) with private providers — it
  never registers the global `OpenTelemetry` instance, so your app's own OpenTelemetry setup is untouched.
- Ships a `PrivacyInfo.xcprivacy` privacy manifest.

## 1. Before you start

In Ceburu, add an **iOS** app on the Real User Monitoring setup page. It gives you:

| You get | Used as |
| --- | --- |
| RUM endpoint, `https://<ingest-host>/rum` | `endpoint` |
| App key, `cbr_mob_…` (public, safe to ship in the app) | `apiKey` |

The key only writes RUM data for that app; it cannot read data or log a user in. It can be extracted from the app.
Keep your application's normal login separate. Key rotation uses the grace period selected on the setup page;
distribute the replacement through an app update or your own configuration service.

## 2. Install

**Beta for evaluation: 1.0.0-beta.1.** Pin the beta explicitly after its Git tag is published.
Device delivery and overhead validation remain open; this is not a production-certified release.

Xcode: **File → Add Package Dependencies…** → `https://github.com/Ceburu-Systems-Inc/ceburu-ios-sdk`,
**Exact Version** `1.0.0-beta.1`, product `CeburuAnalyticsSDK`. Or in `Package.swift`:

```swift
.package(url: "https://github.com/Ceburu-Systems-Inc/ceburu-ios-sdk.git", exact: "1.0.0-beta.1")
// target dependency:
.product(name: "CeburuAnalyticsSDK", package: "ceburu-ios-sdk")
```

## 3. Initialize

```swift
import SwiftUI
import CeburuAnalyticsSDK

@main
struct ShopApp: App {
    init() {
        Task {
            do {
                try await CeburuAnalyticsSDK.shared.initialize(config: .init(
                    endpoint:       "https://<ingest-host>/rum",
                    apiKey:         "<cbr_mob_ key>",
                    serviceName:    "shop-ios",
                    consentGranted: false
                ))
            } catch {
                // Monitoring is optional; let the app continue if initialization fails.
                print("Ceburu monitoring could not start")
            }
        }
    }
    var body: some Scene { WindowGroup { ContentView() } }
}
```

Initialize once. The example waits for your app's consent decision; after initialization completes, call
`await CeburuAnalyticsSDK.shared.setConsent(true)` when permission is granted. If omitted, `consentGranted`
defaults to `true`. Only endpoint, key and service name are required. Configuration and storage errors can throw;
catch them without interrupting your app. Supply `serviceVersion` to compare your app releases.

<details>
<summary>All options and defaults</summary>

| Option | Default | Notes |
| --- | --- | --- |
| `endpoint` | required | `https://`; `http://` only with `allowInsecureEndpoint: true` (local development). |
| `apiKey` | required | The app's `cbr_mob_…` key. Switch at runtime with `updateApiKey(_:)`. |
| `serviceName` | required | Becomes `service.name`. |
| `serviceVersion` | `""` | Becomes `service.version`. |
| `environment` | `production` | Becomes `deployment.environment.name`. |
| `minSeverity` | `.info` | Log events below it are dropped. |
| `consentGranted` | `true` | `false` records nothing until `setConsent(true)`. |
| `autoCapture` | `true` | UIKit screens (view controllers of your app), foreground/background and cold start. |
| `tracePropagationTargets` | none | Hosts (and subdomains) that get `traceparent` from `rum.data(for:)`. |
| `exportMetrics` | `false` | Custom metrics are not sent until Ceburu shows mobile metrics. |
| `queueMaxBytes` / `retentionHours` | 50 MB / 72 h | Log queue limits; lowest severity is evicted first. |
| `maxBatchEvents` / `maxBatchBytes` | 200 / 256 KB | Per request (the endpoint accepts up to 1 MB). |
| `metricsExportInterval` | 60 s | |

</details>

## 4. Use

UIKit screen appearances, foreground/background transitions, cold start and crash capture work with consent.
Add calls for your own events, SwiftUI screens and network requests. Warm starts, hangs and automatic SwiftUI
screen names are not implemented. Network requests are captured only when made through `data(for:)` below.

<details>
<summary>Optional events and API reference</summary>

```swift
let rum = CeburuAnalyticsSDK.shared
await rum.info("Checkout opened", attributes: ["cart.items": 3])
await rum.breadcrumb(category: "navigation", message: "Opened payment screen")
await rum.error("Payment failed", error: error, attributes: ["payment.method": "card"])

await rum.setUser("u-123")        // an opaque id, never an email; "" on logout
await rum.setConsent(false)       // stops collection, deletes queue, breadcrumbs, user and session
await rum.trackScreen("Checkout") // SwiftUI screens; UIKit view controllers are captured automatically
let (data, response) = try await rum.data(for: request)  // URLSession call as a network span; traceparent only on
                                                        // hops to tracePropagationTargets, checked on every redirect

try await rum.withSpan("checkout.submit", attrs: ["screen": "cart"]) {
    await rum.info("Order placed")   // carries the span's trace and span id
    try await placeOrder()
}

await rum.incrementCounter(name: "checkout.completed")
await rum.recordHistogram(name: "checkout.duration", value: ms, unit: "ms")
```

Metrics calls are optional and do not export while `exportMetrics` is `false`; keep this default until the
mobile metrics consumer is available. Trace linking also needs an instrumented backend that accepts trace context.

| API | Notes |
| --- | --- |
| `trace/debug/info/warn(_:attributes:)`, `error/fatal(_:error:attributes:)` | Logs; errors carry `exception.*` and breadcrumbs. |
| `breadcrumb(category:message:)` | Last 50, attached to the next error, fatal or crash. |
| `withSpan(_:attrs:kind:_:)` / `startSpan(name:attrs:kind:)` | Prefer `withSpan`; it is task-local and concurrency-safe. |
| `incrementCounter`, `incrementUpDownCounter`, `recordHistogram`, `observeCounter`, `observeGauge` | Keep attribute values few and fixed — no user, session or URL values. |
| `setUser`, `setConsent`, `newSession`, `updateApiKey` | |
| `installLoggerAdapter(CallbackLoggerAdapter.shared)` / `OSLogAdapter` | Forward an existing logger. |
| `flushMetrics()`, `shutdown()` | |

Uncaught `NSException` records are encrypted. Fatal signals use a minimal binary record in the app's private
storage, not the encrypted log format. Both are imported on the next launch as `rum.crash` events.

</details>

To stop all collection, call `await rum.setConsent(false)`; `autoCapture: false` only disables lifecycle/screen
capture. Withdrawal clears queued data and identity; it cannot recall requests already sent. The returned
Boolean reports whether the consent marker was persisted. A failed write triggers immediate cleanup.
`setUser` while withdrawn only presets identity for the next grant; it does not grant consent.

## 5. What is sent

OTLP/HTTP to `{endpoint}/v1/logs` (JSON), `/v1/traces` and `/v1/metrics` (protobuf) with `Authorization: Bearer <apiKey>`.

- **Resource:** `service.name`, `service.version`, `deployment.environment.name`, `ceburu.signal=rum`,
  `rum.platform=ios`, `telemetry.distro.name/version`, `app.installation.id` (random per install, reset on reinstall —
  not the IDFV or IDFA), `device.manufacturer`, `device.model.identifier` (e.g. `iPhone15,2`), `os.name`, `os.version`.
- **Every log and span:** `session.id` (rotates after 15 min without events or after 4 h), `session.previous_id`,
  `user.id` after `setUser`. Logs also carry `event.name` (`rum.log`, `rum.error`, `rum.crash`) and the trace context
  inside `withSpan`.
- The ingest adds your tenant, the app id and the caller IP (`client.address`); the app never sends a tenant.

**Privacy.** Attribute keys containing `password`, `authorization`, `cookie` or `secret` are dropped; `token`, `card`,
`email`, `phone` are masked. Messages, stack traces and string values are scanned for emails, bearer tokens, JWTs,
card numbers and `key=value` secrets, including breadcrumbs and span attributes, events and errors. Without consent
nothing is recorded or sent (logs, spans, metrics, breadcrumbs, crashes) and the crash handlers are removed;
withdrawing it also deletes the queue. The privacy manifest declares crash data, performance data, other diagnostic
data, a user ID (only sent after `setUser`) and a device ID (the installation id), linked to the user because of
`setUser` and never used for tracking.

Redaction is a safeguard, not a guarantee that arbitrary custom text contains no personal data. Use opaque
user IDs and avoid private content in events. Complete your app's privacy declaration for its actual use
of the SDK, including Ceburu as the telemetry recipient.

**Delivery.** The encrypted log queue survives restarts and offline periods (AES-GCM, key in the Keychain;
without Keychain access it is memory-only and crashes are not saved). Traces and metrics have no durable
offline queue. The log sender retries network errors, 408, 429 and 5xx with backoff and `Retry-After` support.
401/403 pause it until key replacement or the next launch; 413 splits batches; 400 drops the rejected batch.
Device overhead and startup behavior still need measurement; do not assume zero impact.

## 6. Troubleshooting

| Symptom | Check |
| --- | --- |
| `initialize` throws | The error says which option is wrong. |
| Data stops after a key rotation | The old key expired; ship the new key or call `updateApiKey(_:)`. |
| Nothing arrives | `consentGranted: false` without `setConsent(true)`, or `minSeverity` above your log level. |
| Crash frames show addresses only | Expected for stripped release builds until dSYM upload is available. |

## 7. Development and release

```sh
swift build && swift test                                   # macOS
xcodebuild -scheme CeburuAnalyticsSDK -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

CI runs `swift build`, `swift test` and an iOS simulator build on macOS for pull requests and main.
After CI and device smoke tests pass, set `sdkVersion` in `CeburuAnalyticsSDK.swift`, update
[CHANGELOG](CHANGELOG.md), and push the matching plain tag `X.Y.Z` (no `v` for this repository).
The release workflow repeats CI, verifies the tag and creates a GitHub source release. Customers use the
repository URL and version in Swift Package Manager; no Maven, App Store upload or Apple signing key is needed.

The workflow uses GitHub's automatic `GITHUB_TOKEN` with release write permission; no publishing secret is
needed. A pushed tag is already visible to Swift Package Manager even if release CI fails, so wait for green
main CI before tagging. Do not move a version tag after customers have used it.

Licensed under the [Apache License 2.0](LICENSE).
