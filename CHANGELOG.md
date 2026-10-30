# Changelog

All notable changes to the Ceburu RUM SDK for iOS (`ceburu-ios-sdk`, Swift package `CeburuAnalyticsSDK`). The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).
The wire contract (attribute names) is part of the public API.

## [1.0.0-beta.1] - 2026-10-30

### Fixed
- Synchronize metric exporter state for Swift 6 concurrency checks.
- Ignore stale unauthorized responses after key replacement; keep pausing for a refused current key.

### Added (SDK and ingest review, 2026-10-29)
- Automatic capture (`Config.autoCapture`, on by default): `screen_view` for UIKit view controllers of the app's
  bundle, `app_state` on foreground/background, `app_start` for cold starts; `rum.view.*` and `rum.app.state` on
  every span and log; `trackScreen(_:)` for SwiftUI.
- `data(for:session:)`: URLSession calls as CLIENT spans; `traceparent` only for `Config.tracePropagationTargets`,
  removed on a redirect to another host or an https → http downgrade (task delegate); an app's own header is kept.
- Metric labels are cut to size before redaction (no sort) and not built when metrics are off; e-mail redaction is linear.
- `setConsent` returns `false` (discardable) only when a withdrawal could not be stored (the marker is read back); an
  unreadable marker fails closed. Metric calls carry the admitted generation, and imported crashes keep a stable
  event id across retried imports.
- Consent epochs shared by the queue and the exporters and written to disk on withdrawal: nothing admitted before a
  withdrawal is written or sent after it (spans carry the generation they were admitted in), including across actor
  reentrancy, a rapid new grant and a restart before the purge; crash records and breadcrumbs older than the last
  withdrawal are not imported; crash handlers are not reinstalled by a crash import that a withdrawal or shutdown
  interrupted. Withdrawal clears breadcrumbs, user and session, and rebuilds the pipelines (no metric state survives).
  Concurrent `initialize` calls cannot interleave.
- Bounds before queueing (64 flat scalar attributes, nested values dropped), memory-only queue capped at 4 MB,
  redacted `setUser`, breadcrumbs, span and event names; metric names validated, at most 100 instruments and
  8 redacted labels; observable instruments re-registered after `updateApiKey`; HTTP-date `Retry-After`.
- `Config.exportMetrics` (default `false`) and delta temporality for metrics.

First public release (earlier 3.x builds were internal and are not supported).

### Added
- Sends to the Ceburu RUM endpoint (`https://<ingest-host>/rum` + `/v1/logs|metrics|traces`) with a public `cbr_mob_…` key.
- RUM resource: `ceburu.signal=rum`, `rum.platform=ios`, `telemetry.distro.name/version`, `app.installation.id`
  (random per install), `device.model.identifier`, OS fields.
- Sessions on every log and span: `session.id` (32 hex) rotating after 15 min idle or 4 h, `session.previous_id`;
  an unexpired session continues across launches.
- `setConsent(_:)` and `Config.consentGranted`: without consent no log, span, metric, breadcrumb or crash is
  recorded or sent and the crash handlers are removed; withdrawing deletes queued events and drops buffered spans
  and metrics.
- `event.name` on log records: `rum.log`, `rum.error`, `rum.crash`.
- Free-text redaction of messages, stack traces, string attributes, breadcrumbs and span attributes, events and
  errors; stack traces capped at 16,000 characters.
- `PrivacyInfo.xcprivacy` privacy manifest, Apache-2.0 `LICENSE`/`NOTICE`, CI.

### Changed
- `Config`: `endpoint` + `apiKey` replace `collectorHost`, `collectorPort`, `useHTTPS`, `useStandardOTLPPaths`,
  `tenantId`, `applicationId`, `configId`, `userId` and `authToken` (the ingest derives tenant and app from the key).
  `updateAuthToken` is now `updateApiKey`.
- `user.id` replaces `enduser.id`.
- The SDK no longer registers the global `OpenTelemetry` providers, so an app's own OpenTelemetry setup is untouched.
- Responses are classified: 401/403 pause sending (queue kept) until `updateApiKey(_:)`; 413 halves the batch (a
  single oversized event is dropped); 400 drops the batch; network errors, 408, 429 and 5xx retry with backoff and
  honour `Retry-After`. Default batch size is 256 KB.
- Logs are sent as OTLP/JSON straight from the queue; the unused OpenTelemetry log pipeline was removed.
- Crashes keep the session they happened in, are encrypted only with the Keychain crash key, and are written with
  first-unlock protection so a crash on a locked device is not lost. Without a Keychain the queue is memory-only and
  crashes are not saved (the derived key is kept only to read files from earlier builds).
- `shutdown()` restores the exception handler that was installed before the SDK.
- Queue eviction reads severity from the file name instead of decrypting every file.

### Removed
- SDK self-telemetry counters (`mobile.sdk.*`), the per-launch `service.instance.id`, the start-up log event,
  `email`/`phone` hashing (now masked).

### Known limitations
- Release-build crash frames are not symbolicated server-side yet (no dSYM upload); MetricKit is not used yet.
- Automatic screens are UIKit view controllers of the app's bundle (SwiftUI: `trackScreen`); `screen_view` marks the
  moment a screen appears, not time on screen. Cold start is process start → first screen (≤ 30 s, prewarm skipped), not
  first frame; hangs and MetricKit are not used. Network needs the `data(for:)` wrapper. Not yet compiled on Apple
  toolchains: build and test on macOS before release.
