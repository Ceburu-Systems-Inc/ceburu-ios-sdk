import Foundation
import CryptoKit
import Security
import Darwin

// MARK: - PII Redaction

/// Redaction before anything is written to disk or sent.
///
/// Attribute keys (case-insensitive): `password`, `authorization`, `cookie`, `secret`, `credential` → dropped;
/// `token`, `api_key`, `card`, `email`, `phone` → `[REDACTED]`. Every other value, messages and stack traces
/// also go through ``redactText(_:)`` (the same patterns as the web and Android SDKs).
enum Security {

    static func redact(_ input: [String: String]) -> [String: String] {
        var out: [String: String] = [:]

        for (key, value) in input {
            let k = key.lowercased()

            if k.contains("password") ||
               k.contains("authorization") ||
               k.contains("credential") ||
               k.contains("cookie") ||
               k.contains("secret") {
                continue
            }

            if k.contains("token") || k.contains("api_key") || k.contains("apikey") || k.contains("card") ||
               k.contains("email") || k.contains("phone") {
                out[key] = "[REDACTED]"
                continue
            }

            out[key] = redactText(value)
        }

        return out
    }

    // NSRegularExpression is documented as thread-safe for matching.
    nonisolated(unsafe) private static let patterns: [NSRegularExpression] = [
        #"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]+"#,
        #"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#,
        #"(?<![A-Za-z0-9._%+-])[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,  // one scan per run
        #"\b(?:\d[ -]?){13,19}\b"#
    ].map { try! NSRegularExpression(pattern: $0) }
    nonisolated(unsafe) private static let secretPair = try! NSRegularExpression(
        pattern: #"(?i)\b(password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key|session[_-]?id|sid|key)(\s*[=:]\s*)[^&\s"'<>,;]+"#)

    static let maxAttributes = 64

    /// Flat scalars only (nested values cannot be redacted field by field and are dropped), at most
    /// ``maxAttributes`` keys, bounded strings. Runs before anything crosses an actor or is queued.
    static func bound(_ input: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        var inspected = 0
        for (key, value) in input {  // no sort: caller-thread work stays bounded by the retained count
            inspected += 1
            if out.count >= maxAttributes || inspected > 4 * maxAttributes { break }
            let text: String
            switch value {
            case let v as String: text = v
            case let v as Bool:   text = v ? "true" : "false"
            case let v as Int:    text = String(v)
            case let v as Int64:  text = String(v)
            case let v as Double: text = String(v)
            case let v as Float:  text = String(v)
            default: continue
            }
            out[String(key.prefix(128))] = String(text.prefix(key == "exception.stacktrace" ? 16_000 : 4_096))
        }
        return out
    }

    /// Replaces emails, bearer tokens, JWTs, card-like numbers and `key=value` secrets with `[REDACTED]`.
    static func redactText(_ text: String) -> String {
        var out = text
        for re in patterns {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "[REDACTED]")
        }
        return secretPair.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                                   withTemplate: "$1$2[REDACTED]")
    }
}

// MARK: - Retry Backoff

/// Exponential backoff with jitter for flush-loop retries.
///
/// On each `nextDelayMs()` call the delay doubles (capped at ~4 minutes), with up to 1 s of
/// random jitter to prevent thundering-herd reconnections when multiple instances restart
/// simultaneously. Call `reset()` after a successful flush to start from the minimum delay.
struct RetryBackoff {
    private(set) var attempt = 0

    /// Resets the backoff counter. Call after a successful export.
    mutating func reset() { attempt = 0 }

    /// Returns the next delay in milliseconds and advances the attempt counter.
    ///
    /// Delay schedule: 2 s, 4 s, 8 s, … up to 256 s, plus 0–1 s of jitter.
    mutating func nextDelayMs() -> Int {
        attempt += 1
        let exp = min(attempt, 8)
        let base = min(300_000, 1_000 * (1 << exp))
        return base + Int.random(in: 0...1_000)
    }
}

// MARK: - Encrypted Queue

/// AES-256-GCM encrypted on-device event queue backed by the filesystem.
///
/// Each event is individually encrypted and written as a `.bin` file named
/// `<timestampMs>_<severity>_<eventId>.bin` (severity in the name, so eviction never decrypts). Files are ordered by name (timestamp) on read,
/// so the queue is naturally FIFO. Crash records are stored as AES-256-GCM `.enc` files in a
/// separate `Ceburu/Crashes` directory.
///
/// **Encryption**: AES-GCM with a 256-bit key generated once per install and stored
/// in the iOS Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
///
/// **Quota enforcement**: When the total queue size exceeds `maxBytes`, lowest-severity
/// events are evicted first to preserve recent errors and fatals.
///
/// **Retention**: Events older than `retentionHours` are pruned at most once per minute
/// during normal operation.
actor EncryptedStore {

    private let queueDir: URL
    let crashDir: URL
    private let key: SymmetricKey
    private let maxBytes: Int
    private let maxAgeSeconds: TimeInterval
    private var lastPruneTime: Date = .distantPast
    // Running queue size (nil = recount once), so enqueue does not stat every file.
    private var queuedBytes: Int? = nil
    private let sessionFile: URL
    /// Random per-install id (`app.installation.id`), reset when the app is reinstalled. Never a device id.
    let installId: String

    // Set when the Keychain is unavailable at init time: events are held in RAM, never written to disk.
    private(set) var keychainFailed = false
    private var memoryQueue: [(url: URL, data: Data, generation: Int)] = []
    private var memoryBytes = 0
    private static let memoryQueueCap = 500
    private static let memoryBytesCap = 4 * 1024 * 1024

    // Consent epoch shared with the exporters; queue and session files carry the epoch they were written in
    // and only the current one is ever sent (see ``sendable``). The epoch survives restarts (``saveEpoch``).
    private let gate: ConsentGate

    // X2: random crash key loaded from Keychain in init(), cached here so
    // nonisolated crash-time callers (persistBreadcrumbs/persistException)
    // can read it without Keychain access or actor hops.
    nonisolated(unsafe) private static var _crashKey: SymmetricKey? = nil

    /// Creates the encrypted store, initialising the queue and crash directories
    /// and loading (or generating) the AES key from the Keychain.
    ///
    /// - Parameters:
    ///   - maxBytes:       Maximum total size of the on-device queue in bytes.
    ///   - retentionHours: Events older than this are pruned during the next flush cycle.
    /// - Throws: If the directories cannot be created or the Keychain operation fails.
    init(maxBytes: Int, retentionHours: Int, gate: ConsentGate) throws {
        self.gate = gate
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]

        queueDir = base.appendingPathComponent("Ceburu/Queue", isDirectory: true)
        crashDir = base.appendingPathComponent("Ceburu/Crashes", isDirectory: true)

        try FileManager.default.createDirectory(at: queueDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: crashDir, withIntermediateDirectories: true)

        let idFile = base.appendingPathComponent("Ceburu/install.id")
        if let saved = try? String(contentsOf: idFile, encoding: .utf8), saved.count == 32 {
            installId = saved
        } else {
            let fresh = CeburuAnalyticsSDK.newId()
            try? fresh.write(to: idFile, atomically: true, encoding: .utf8)
            installId = fresh
        }

        // I5: if Keychain is unavailable, fall back to memory-only mode instead of
        // writing events to disk with a predictable derivable key.
        var didFailKeychain = false
        let loadedKey: SymmetricKey
        do {
            loadedKey = try KeyStore.loadOrCreate()
        } catch {
            // Random key used to satisfy the `let key` property; never touches disk in this mode.
            var raw = Data(count: 32)
            _ = raw.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
            loadedKey = SymmetricKey(data: raw)
            didFailKeychain = true
            // Clean up any stale queue files encrypted with the now-inaccessible key.
            if let stale = try? FileManager.default.contentsOfDirectory(
                at: queueDir, includingPropertiesForKeys: nil
            ) {
                for f in stale where f.pathExtension == "bin" { try? FileManager.default.removeItem(at: f) }
            }
        }
        key = loadedKey
        keychainFailed = didFailKeychain
        self.maxBytes = maxBytes
        self.maxAgeSeconds = TimeInterval(retentionHours * 3600)

        // Load (or generate) the random crash key now, so crash-time callers need no Keychain access.
        // Without it nothing is written for crashes: never encrypt under a derivable key.
        Self._crashKey = didFailKeychain ? nil : try? KeyStore.loadOrCreateCrashKey()
        sessionFile = base.appendingPathComponent("Ceburu/session.enc")
    }

    /// Encrypts and enqueues a single event.
    ///
    /// The event is serialized to JSON, encrypted with AES-256-GCM, and written
    /// atomically (via a `.tmp` file rename) to avoid partial writes. After writing,
    /// the queue size quota is enforced by evicting low-severity events if needed.
    ///
    /// - Parameter event: The event to persist.
    /// - Throws: If JSON encoding, AES encryption, or the filesystem write fails.
    func enqueue(_ event: CeburuAnalyticsSDK.Event, generation: Int) throws {
        guard generation == gate.generation else { return }  // admitted before a withdrawal
        if keychainFailed {
            let data = try JSONEncoder().encode(event)
            let url  = URL(string: "memory://\(event.eventId)")!
            memoryQueue.append((url: url, data: data, generation: generation))
            memoryBytes += data.count
            while memoryQueue.count > Self.memoryQueueCap || memoryBytes > Self.memoryBytesCap {
                memoryBytes -= memoryQueue.removeFirst().data.count
            }
            return
        }

        pruneOld()

        let clear = try JSONEncoder().encode(event)
        let sealed = try AES.GCM.seal(clear, using: key)
        guard let encrypted = sealed.combined else { return }

        let name = "\(event.timestampUnixMs)_\(event.severity.rawValue)_\(event.eventId)_g\(generation)"
        let tmp = queueDir.appendingPathComponent("\(name).tmp")
        let final = queueDir.appendingPathComponent("\(name).bin")

        let current = queuedBytes ?? queueFiles().reduce(0) { $0 + size($1) }
        try encrypted.write(to: tmp, options: [.atomic])
        try? FileManager.default.removeItem(at: final)
        try FileManager.default.moveItem(at: tmp, to: final)

        let total = current + encrypted.count
        queuedBytes = total
        if total > maxBytes { enforceQuota() }
    }

    /// Reads and decrypts a batch of events up to the given limits.
    ///
    /// Events are returned in timestamp order (oldest first). Reading stops when
    /// either `maxEvents` files have been read or adding the next file would exceed
    /// `maxBytes` (unless the batch is still empty, in which case one oversized
    /// event is always returned to prevent starvation).
    ///
    /// - Parameters:
    ///   - maxEvents: Maximum number of events in the returned batch.
    ///   - maxBytes:  Maximum total cleartext size of the returned batch.
    /// - Returns: Array of `(fileURL, cleartext Data)` pairs ready for export.
    /// - Throws: If a file cannot be read or decrypted (corrupted files are skipped).
    func batch(maxEvents: Int, maxBytes: Int, generation: Int) throws -> [(URL, Data)] {
        if keychainFailed {
            var result: [(URL, Data)] = []
            var total = 0
            for item in memoryQueue where item.generation == generation {
                if result.count >= maxEvents { break }
                if total + item.data.count > maxBytes && !result.isEmpty { break }
                result.append((item.url, item.data))
                total += item.data.count
            }
            return result
        }

        pruneOld()

        var result: [(URL, Data)] = []
        var total = 0

        for url in queueFiles() {
            if result.count >= maxEvents { break }
            if !Self.sendable(url.deletingPathExtension().lastPathComponent, current: generation) { continue }

            // Skip and delete any file that fails to decrypt rather than throwing.
            // A single corrupt file previously caused batch() to throw on every call,
            // blocking the queue permanently. Treating it as a discard keeps the queue draining.
            let clear: Data
            do {
                let encrypted = try Data(contentsOf: url)
                let sealed    = try AES.GCM.SealedBox(combined: encrypted)
                clear         = try AES.GCM.open(sealed, using: key)
            } catch {
                try? FileManager.default.removeItem(at: url)
                continue
            }

            if total + clear.count > maxBytes && !result.isEmpty { break }

            result.append((url, clear))
            total += clear.count
        }

        return result
    }

    /// Deletes successfully exported event files from the queue directory.
    ///
    /// Call this after each event in a batch is confirmed delivered to the collector.
    /// Errors are silently swallowed — a failed delete just means the event is retried
    /// on the next flush cycle (idempotent delivery).
    ///
    /// - Parameter files: File URLs previously returned by ``batch(maxEvents:maxBytes:generation:)``.
    func acknowledge(_ files: [URL]) {
        if keychainFailed {
            let toRemove = Set(files.map { $0.absoluteString })
            memoryQueue.removeAll { toRemove.contains($0.url.absoluteString) }
            memoryBytes = memoryQueue.reduce(0) { $0 + $1.data.count }
            return
        }
        files.forEach { try? FileManager.default.removeItem(at: $0) }
        queuedBytes = nil
    }

    /// Deletes every queued event written before epoch `generation` (after a withdrawal and at start) and, after a
    /// withdrawal, the crash records and breadcrumbs.
    func purge(before generation: Int, crashes: Bool) {
        memoryQueue.removeAll { $0.generation < generation }
        memoryBytes = memoryQueue.reduce(0) { $0 + $1.data.count }
        for file in (try? FileManager.default.contentsOfDirectory(at: queueDir, includingPropertiesForKeys: nil)) ?? [] {
            if (Self.epoch(of: file.deletingPathExtension().lastPathComponent) ?? 0) < generation {
                try? FileManager.default.removeItem(at: file)
            }
        }
        if crashes {
            for file in (try? FileManager.default.contentsOfDirectory(at: crashDir, includingPropertiesForKeys: nil)) ?? [] {
                try? FileManager.default.removeItem(at: file)
            }
        }
        queuedBytes = nil
    }

    /// Epoch in a queue file name (`…_g<epoch>`); nil for files of SDK builds before epochs (treated as 0).
    static func epoch(of name: String) -> Int? {
        guard let last = name.split(separator: "_").last, last.hasPrefix("g") else { return nil }
        return Int(last.dropFirst())
    }

    static func sendable(_ name: String, current: Int) -> Bool {
        (epoch(of: name) ?? 0) == current
    }

    // MARK: - Consent epoch (durable)

    static var epochFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ceburu/consent.epoch")
    }

    /// The persisted consent epoch and when it was last bumped (the last withdrawal).
    /// `epoch` is 0 when no marker exists and nil when one exists but cannot be read (the caller fails closed).
    static func loadEpoch(at file: URL = epochFile) -> (epoch: Int?, revokedAt: Date) {
        let revokedAt = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date
        guard FileManager.default.fileExists(atPath: file.path) else { return (0, .distantPast) }
        let epoch = (try? String(contentsOf: file, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return (epoch.flatMap { $0 >= 0 ? $0 : nil }, revokedAt ?? .distantPast)
    }

    /// Written synchronously when consent is withdrawn, before any purge, then read back: true only when stored.
    @discardableResult
    static func saveEpoch(_ epoch: Int, at file: URL = epochFile) -> Bool {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try String(epoch).write(to: file, atomically: true, encoding: .utf8)
        } catch {
            return false
        }
        return loadEpoch(at: file).epoch == epoch
    }

    /// Highest epoch among queued files, for recovering from an unreadable marker.
    static func newestQueuedEpoch() -> Int {
        let queue = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ceburu/Queue", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: queue, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { epoch(of: $0.deletingPathExtension().lastPathComponent) }.max() ?? 0
    }

    /// Stable id for one crash record (file name or raw bytes): importing it twice yields the same event id.
    static func crashEventId(_ bytes: Data) -> String {
        String(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined().prefix(32))
    }

    /// Crash files and breadcrumbs written before the last withdrawal (also one interrupted before its purge).
    private func recordedBeforeRevocation(_ file: URL) -> Bool {
        let modified = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date ?? .distantPast
        return modified <= Self.loadEpoch().revokedAt
    }

    /// Session state kept across launches so an unexpired session continues.
    struct Session: Codable, Sendable {
        let id: String
        let previousId: String
        let start: Date
        let lastActivity: Date
        var epoch: Int? = nil
    }

    func loadSession() -> Session? {
        guard !keychainFailed, let encrypted = try? Data(contentsOf: sessionFile),
              let sealed = try? AES.GCM.SealedBox(combined: encrypted),
              let clear = try? AES.GCM.open(sealed, using: key) else { return nil }
        guard let session = try? JSONDecoder().decode(Session.self, from: clear),
              (session.epoch ?? 0) == gate.generation else { return nil }  // saved before the last withdrawal
        return session
    }

    /// Ignored when `generation` is older than the current epoch: a save scheduled before a withdrawal cannot restore it.
    func saveSession(_ session: Session, generation: Int) {
        guard generation == gate.generation else { return }
        var session = session
        session.epoch = generation
        guard !keychainFailed, let clear = try? JSONEncoder().encode(session),
              let encrypted = try? AES.GCM.seal(clear, using: key).combined else { return }
        try? encrypted.write(to: sessionFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Persists the current breadcrumb trail to disk so it survives a crash.
    ///
    /// `nonisolated` so it can be called synchronously from the signal-handler trampoline
    /// and from `NSSetUncaughtExceptionHandler` without awaiting the actor.
    ///
    /// - Parameter text: Serialized breadcrumb string (pipe-separated `"category:message"` pairs).
    nonisolated func persistBreadcrumbs(_ text: String) {
        guard let key = EncryptedStore.crashKey(), let plain = text.data(using: .utf8) else { return }
        let file = crashDir.appendingPathComponent("breadcrumbs.enc")
        if let sealed = try? AES.GCM.seal(plain, using: key),
           let encrypted = sealed.combined {
            try? encrypted.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    /// Persists an `NSException` to disk for next-launch delivery.
    ///
    /// Called from `NSSetUncaughtExceptionHandler` — a safe (non-signal) synchronous callback.
    /// Encrypted with the Keychain crash key; written with first-unlock protection so a crash
    /// while the device is locked is not lost.
    ///
    /// - Parameters:
    ///   - exception: The uncaught Objective-C exception.
    ///   - sessionId: The session ID active at crash time, read from the `nonisolated(unsafe)` static.
    nonisolated func persistException(_ exception: NSException, sessionId: String) {
        let object: [String: Any] = [
            "timestamp_ms": Int64(Date().timeIntervalSince1970 * 1000),
            "session_id": sessionId,
            "exception_type": exception.name.rawValue,
            "exception_message": String(Security.redactText(exception.reason ?? "").prefix(1024)),
            "exception_stacktrace": String(Security.redactText(exception.callStackSymbols.joined(separator: "\n")).prefix(16_000)),
            "breadcrumbs": CeburuAnalyticsSDK._crashBreadcrumbs
        ]

        guard let key = EncryptedStore.crashKey(),
              let plain = try? JSONSerialization.data(withJSONObject: object),
              let sealed = try? AES.GCM.seal(plain, using: key),
              let encrypted = sealed.combined else { return }

        let file = crashDir.appendingPathComponent(
            "\(Date().timeIntervalSince1970)_\(UUID().uuidString).enc"
        )
        try? encrypted.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Crash-record key: the random Keychain key; nil (no crash writes) when the Keychain is unavailable.
    nonisolated static func crashKey() -> SymmetricKey? { _crashKey }

    nonisolated static func derivedCrashKey() -> SymmetricKey {
        let seed = "ceburu.crash.v1:\(Bundle.main.bundleIdentifier ?? "unknown")"
        return SymmetricKey(data: SHA256.hash(data: Data(seed.utf8)))
    }

    /// Opens a crash file: the Keychain key, or the derived key for files written by earlier versions (read only).
    nonisolated static func openCrash(_ encrypted: Data) -> Data? {
        guard let sealed = try? AES.GCM.SealedBox(combined: encrypted) else { return nil }
        return crashKey().flatMap { try? AES.GCM.open(sealed, using: $0) } ?? (try? AES.GCM.open(sealed, using: derivedCrashKey()))
    }

    /// Imports crash records persisted by `NSSetUncaughtExceptionHandler` during a previous session.
    ///
    /// Called once in ``CeburuAnalyticsSDK/initialize(config:)`` before the flush loop starts.
    /// Each `.enc` file is decrypted (AES-256-GCM), decoded, converted to a `fatal`-severity `Event`, enqueued for
    /// delivery, and then deleted. Files that cannot be parsed are silently skipped and left
    /// for the next launch.
    ///
    /// Each crash keeps the session it happened in; `sessionId` is only the fallback for old files.
    func importCrashRecords(sessionId: String, generation: Int) async throws {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: crashDir, includingPropertiesForKeys: nil
        )) ?? []

        for file in files where file.pathExtension == "enc" {
            if recordedBeforeRevocation(file) { try? FileManager.default.removeItem(at: file); continue }
            do {
                let encrypted = try Data(contentsOf: file)
                guard let data = EncryptedStore.openCrash(encrypted),
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }

                let crashSessionId = json["session_id"] as? String ?? sessionId
                let breadcrumbs = json["breadcrumbs"] as? String ?? ""
                var attributes: [String: String] = [
                    "exception.type":       String(describing: json["exception_type"] ?? ""),
                    "exception.message":    String(describing: json["exception_message"] ?? ""),
                    "exception.stacktrace": String(describing: json["exception_stacktrace"] ?? "")
                ]
                if !breadcrumbs.isEmpty { attributes["session.breadcrumbs"] = breadcrumbs }
                attributes = Security.redact(attributes)  // files from earlier versions were not redacted
                let event = CeburuAnalyticsSDK.Event(
                    eventId: Self.crashEventId(Data(file.lastPathComponent.utf8)),  // stable across retried imports
                    timestampUnixMs: json["timestamp_ms"] as? Int64
                        ?? Int64(Date().timeIntervalSince1970 * 1000),
                    severity: .fatal,
                    type: "crash",
                    message: "Unhandled iOS exception",
                    sessionId: crashSessionId,
                    attributes: attributes,
                    traceId: nil,
                    spanId: nil
                )

                try enqueue(event, generation: generation)
                try? FileManager.default.removeItem(at: file)
            } catch {
                // Keep for a later launch.
            }
        }
    }

    private func queueFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: queueDir, includingPropertiesForKeys: nil
        )) ?? []
        return files
            .filter { $0.pathExtension == "bin" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func pruneOld() {
        let now = Date()
        guard now.timeIntervalSince(lastPruneTime) >= 60 else { return }
        lastPruneTime = now
        let cutoff = now.addingTimeInterval(-maxAgeSeconds)
        for url in queueFiles() {
            // Parse event timestamp from filename ("{timestampMs}_{eventId}.bin") rather
            // than using the file's creation date, which can be wrong on restored devices.
            let stem = url.deletingPathExtension().lastPathComponent
            let tsMs = Int64(stem.split(separator: "_").first ?? "") ?? 0
            let eventDate = Date(timeIntervalSince1970: Double(tsMs) / 1000)
            if eventDate < cutoff {
                try? FileManager.default.removeItem(at: url)
                queuedBytes = nil
            }
        }
    }

    // Evicts lowest-severity events first (oldest first within a severity) when the queue exceeds maxBytes.
    private func enforceQuota() {
        let files = queueFiles()
        var total = files.reduce(0) { $0 + size($1) }
        defer { queuedBytes = total }
        if total <= maxBytes { return }

        let ordered = files.sorted { (severityRank($0), $0.lastPathComponent) < (severityRank($1), $1.lastPathComponent) }
        for file in ordered {
            if total <= maxBytes { break }
            let bytes = size(file)
            if (try? FileManager.default.removeItem(at: file)) != nil { total -= bytes }
        }
    }

    private func size(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? 0
    }

    // Severity from the file name "<ts>_<severity>_<id>.bin"; unknown names rank as info.
    private func severityRank(_ url: URL) -> Int {
        let parts = url.deletingPathExtension().lastPathComponent.split(separator: "_")
        return parts.count >= 3 ? Int(parts[1]) ?? CeburuAnalyticsSDK.Severity.info.rawValue
                                : CeburuAnalyticsSDK.Severity.info.rawValue
    }

    // MARK: - Signal crash import (next-launch delivery)

    /// Imports crash records written by ``SignalCrashHandler`` during a previous session.
    ///
    /// Called once in ``CeburuAnalyticsSDK/initialize(config:)`` alongside ``importCrashRecords(sessionId:)``.
    /// Each `.sigseg` binary file is parsed, symbolicated via `dladdr`, and converted to a
    /// `fatal`-severity `Event`. Any breadcrumbs saved before the crash are re-attached.
    /// Files that cannot be parsed are deleted immediately to avoid repeated failed imports.
    ///
    /// - Parameter sessionId: The current session ID — used as the delivery session for imported crashes.
    func importSignalCrashRecords(sessionId: String, generation: Int) async throws {
        let breadcrumbsFile = crashDir.appendingPathComponent("breadcrumbs.enc")
        let stale = recordedBeforeRevocation(breadcrumbsFile)
        let savedBreadcrumbs: String = {
            guard !stale, let encrypted = try? Data(contentsOf: breadcrumbsFile),
                  let plain     = EncryptedStore.openCrash(encrypted)
            else { return "" }
            return Security.redactText(String(decoding: plain, as: UTF8.self))
        }()

        let files = (try? FileManager.default.contentsOfDirectory(
            at: crashDir, includingPropertiesForKeys: nil
        )) ?? []

        var importedAny = false
        for file in files where file.pathExtension == "sigseg" {
            if recordedBeforeRevocation(file) { try? FileManager.default.removeItem(at: file); continue }
            do {
                let data = try Data(contentsOf: file)
                guard var event = parseSignalCrash(data: data, fallbackSessionId: sessionId, eventId: Self.crashEventId(data))
                else { try? FileManager.default.removeItem(at: file); continue }
                if !savedBreadcrumbs.isEmpty {
                    var attrs = event.attributes
                    attrs["session.breadcrumbs"] = savedBreadcrumbs
                    event = CeburuAnalyticsSDK.Event(
                        eventId: event.eventId,
                        timestampUnixMs: event.timestampUnixMs,
                        severity: event.severity,
                        type: event.type,
                        message: event.message,
                        sessionId: event.sessionId,
                        attributes: attrs,
                        traceId: nil,
                        spanId: nil
                    )
                }
                try enqueue(event, generation: generation)
                try? FileManager.default.removeItem(at: file)
                importedAny = true
            } catch {
                // Keep for a later launch
            }
        }

        if importedAny {
            try? FileManager.default.removeItem(at: breadcrumbsFile)  // breadcrumbs.enc
        }
    }

    /// Parses the binary `.sigseg` crash file written by ``SignalCrashHandler``.
    ///
    /// File format (all values little-endian):
    /// ```
    /// magic       UInt32   0x4D534947 ("MSIG")
    /// signal      Int32
    /// timestampMs Int64
    /// aslrSlide   Int64    ASLR slide of main executable at crash time
    /// sessionLen  UInt16   (includes null terminator)
    /// sessionId   [CChar]  (sessionLen bytes, null-terminated)
    /// frameCount  UInt16
    /// frames      [UInt64] (frameCount raw PC addresses)
    /// ```
    ///
    /// Frame addresses are ASLR-adjusted then symbolicated using `dladdr` — safe in normal context.
    /// The adjustment converts saved crash-time PCs to the equivalent addresses in the current launch,
    /// so `dladdr` can resolve symbol names despite ASLR relocating the binary on each launch.
    ///
    /// - Parameters:
    ///   - data:              Raw file contents.
    ///   - fallbackSessionId: Used when the file's session field is empty or unreadable.
    /// - Returns: A `fatal`-severity `Event`, or `nil` if the file is corrupt or truncated.
    private func parseSignalCrash(data: Data, fallbackSessionId: String, eventId: String) -> CeburuAnalyticsSDK.Event? {
        var offset = 0

        func read<T: FixedWidthInteger>(_: T.Type) -> T? {
            let size = MemoryLayout<T>.size
            guard offset + size <= data.count else { return nil }
            defer { offset += size }
            return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
        }

        guard let magic: UInt32 = read(UInt32.self) else { return nil }
        let isPerFrame = magic == 0x4D534948
        guard isPerFrame || magic == 0x4D534947 else { return nil }

        guard let sig: Int32  = read(Int32.self)  else { return nil }
        guard let tsMs: Int64 = read(Int64.self)  else { return nil }

        // v1 only: single global slide field (removed in v2).
        let legacySlide: Int64 = isPerFrame ? 0 : (read(Int64.self) ?? 0)

        guard let sessionLen: UInt16 = read(UInt16.self) else { return nil }

        let slen = Int(sessionLen)
        guard slen > 0, offset + slen <= data.count else { return nil }
        let sessionId = String(bytes: data[offset..<(offset + slen - 1)], encoding: .utf8)
            ?? fallbackSessionId
        offset += slen

        guard let frameCount: UInt16 = read(UInt16.self) else { return nil }

        typealias SlideFunc  = @convention(c) (UInt32) -> Int
        typealias CountFunc  = @convention(c) () -> UInt32
        typealias HeaderFunc = @convention(c) (UInt32) -> UnsafeRawPointer?

        var stackLines: [String] = []

        if isPerFrame {
            // v2: build preferredBase → currentBase lookup for all images in this launch.
            var imageMap: [UInt64: UInt64] = [:]
            let dyldHandle = dlopen(nil, RTLD_LAZY)
            if let slideSym  = dlsym(dyldHandle, "_dyld_get_image_vmaddr_slide"),
               let countSym  = dlsym(dyldHandle, "_dyld_image_count"),
               let headerSym = dlsym(dyldHandle, "_dyld_get_image_header") {
                let slideFunc  = unsafeBitCast(slideSym,  to: SlideFunc.self)
                let countFunc  = unsafeBitCast(countSym,  to: CountFunc.self)
                let headerFunc = unsafeBitCast(headerSym, to: HeaderFunc.self)
                let imgCount   = Int(countFunc())
                for j in 0..<imgCount {
                    if let hdr = headerFunc(UInt32(j)) {
                        let curBase       = UInt64(UInt(bitPattern: hdr))
                        let curSlide      = Int64(slideFunc(UInt32(j)))
                        let preferredBase = curBase &- UInt64(bitPattern: curSlide)
                        imageMap[preferredBase] = curBase
                    }
                }
            }
            for i in 0..<min(Int(frameCount), 32) {
                guard let addrRel: UInt64       = read(UInt64.self) else { break }
                guard let preferredBase: UInt64 = read(UInt64.self) else { break }
                if preferredBase == 0 {
                    stackLines.append("#\(i)  0x\(String(addrRel, radix: 16))")
                    continue
                }
                // If the image was loaded in this launch, use its current base; otherwise
                // fall back to preferredBase (slide = 0), which is wrong but still useful.
                let curBase = imageMap[preferredBase] ?? preferredBase
                let adjustedAddr = addrRel &+ curBase
                var info = Dl_info()
                if dladdr(UnsafeRawPointer(bitPattern: UInt(adjustedAddr)), &info) != 0 {
                    let sym = info.dli_sname.map { String(cString: $0) } ?? "<unknown>"
                    let lib = info.dli_fname
                        .map { URL(fileURLWithPath: String(cString: $0)).lastPathComponent } ?? "<unknown>"
                    let off = adjustedAddr - UInt64(UInt(bitPattern: info.dli_saddr))
                    stackLines.append("#\(i)  \(lib)  \(sym) + \(off)")
                } else {
                    stackLines.append("#\(i)  0x\(String(adjustedAddr, radix: 16))")
                }
            }
        } else {
            // v1: single global slide — adjust all frames by the same delta.
            var currentSlide: Int64 = 0
            if let sym = dlsym(dlopen(nil, RTLD_LAZY), "_dyld_get_image_vmaddr_slide") {
                currentSlide = Int64(unsafeBitCast(sym, to: SlideFunc.self)(0))
            }
            for i in 0..<min(Int(frameCount), 32) {
                guard let addr: UInt64 = read(UInt64.self) else { break }
                let adjustedAddr = addr &- UInt64(bitPattern: legacySlide) &+ UInt64(bitPattern: currentSlide)
                var info = Dl_info()
                if dladdr(UnsafeRawPointer(bitPattern: UInt(adjustedAddr)), &info) != 0 {
                    let sym = info.dli_sname.map { String(cString: $0) } ?? "<unknown>"
                    let lib = info.dli_fname
                        .map { URL(fileURLWithPath: String(cString: $0)).lastPathComponent } ?? "<unknown>"
                    let off = adjustedAddr - UInt64(UInt(bitPattern: info.dli_saddr))
                    stackLines.append("#\(i)  \(lib)  \(sym) + \(off)")
                } else {
                    stackLines.append("#\(i)  0x\(String(adjustedAddr, radix: 16))")
                }
            }
        }

        return CeburuAnalyticsSDK.Event(
            eventId: eventId,
            timestampUnixMs: tsMs,
            severity: .fatal,
            type: "crash",
            message: "Unhandled signal: \(signalName(sig))",
            sessionId: sessionId,
            attributes: [
                "exception.type":       signalName(sig),
                "exception.message":    signalDescription(sig),
                "exception.stacktrace": stackLines.joined(separator: "\n")
            ],
            traceId: nil,
            spanId: nil
        )
    }

    private func signalName(_ sig: Int32) -> String {
        switch sig {
        case SIGABRT: return "SIGABRT"
        case SIGSEGV: return "SIGSEGV"
        case SIGBUS:  return "SIGBUS"
        case SIGILL:  return "SIGILL"
        case SIGFPE:  return "SIGFPE"
        case SIGTRAP: return "SIGTRAP"
        default:      return "SIG\(sig)"
        }
    }

    private func signalDescription(_ sig: Int32) -> String {
        switch sig {
        case SIGABRT: return "Abort — fatalError(), preconditionFailure(), or assertion failure"
        case SIGSEGV: return "Segmentation fault — null pointer or invalid memory access"
        case SIGBUS:  return "Bus error — misaligned memory access"
        case SIGILL:  return "Illegal instruction"
        case SIGFPE:  return "Arithmetic exception — division by zero"
        case SIGTRAP: return "Trap — force-unwrap nil, out-of-range index, or explicit __builtin_trap()"
        default:      return "Signal \(sig) received"
        }
    }
}

// MARK: - Keychain Key Storage

/// Manages the AES-256 queue encryption key in the iOS Keychain.
///
/// The key is generated once on first launch using `SecRandomCopyBytes` and stored
/// with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — it is device-bound and
/// cannot be extracted via iCloud backup or device-to-device transfer.
/// On subsequent launches, the key is loaded from the Keychain.
enum KeyStore {

    private static let service = "com.ceburu.analytics"
    private static let account = "queue-key"
    private static let crashAccount = "crash-key"

    /// Loads the existing AES key from the Keychain, or generates and stores a new one.
    ///
    /// - Returns: The 256-bit `SymmetricKey` for AES-GCM encryption/decryption.
    /// - Throws: `NSError(domain: "Ceburu.Keychain", ...)` if the Keychain operation fails.
    /// Throws when the Keychain is unavailable; the store then keeps events in memory only,
    /// never on disk under a derivable key.
    static func loadOrCreate() throws -> SymmetricKey {
        if let existing = try load() {
            return SymmetricKey(data: existing)
        }

        var data = Data(count: 32)
        let status = data.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: "Ceburu.Keychain", code: Int(status))
        }

        try save(data)
        return SymmetricKey(data: data)
    }

    // X2: separate Keychain slot for the crash-record key so it can be rotated
    // independently from the event-queue key.
    /// Loads the crash-record AES key from the Keychain, or generates and stores a new one.
    ///
    /// - Returns: The 256-bit `SymmetricKey` used to encrypt crash `.enc` files.
    /// - Throws: `NSError(domain: "Ceburu.Keychain", ...)` if the Keychain operation fails.
    static func loadOrCreateCrashKey() throws -> SymmetricKey {
        if let existing = try loadForAccount(crashAccount) {
            return SymmetricKey(data: existing)
        }

        var data = Data(count: 32)
        let status = data.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: "Ceburu.Keychain", code: Int(status))
        }

        try saveForAccount(crashAccount, data: data)
        return SymmetricKey(data: data)
    }

    /// Attempts to load the key from the Keychain. Returns `nil` if not found.
    ///
    /// - Throws: If the Keychain query returns an error other than `errSecItemNotFound`.
    private static func load() throws -> Data? {
        try loadForAccount(account)
    }

    private static func loadForAccount(_ acct: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: acct,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw NSError(domain: "Ceburu.Keychain", code: Int(status))
        }
        return result as? Data
    }

    /// Saves key material to the Keychain, replacing any existing item.
    ///
    /// Uses `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so the key is available
    /// after the first unlock (covers background crash imports on next launch) but is
    /// never migrated to another device.
    ///
    /// - Parameter data: 32-byte raw key material.
    /// - Throws: If `SecItemAdd` returns an error.
    private static func save(_ data: Data) throws {
        try saveForAccount(account, data: data)
    }

    private static func saveForAccount(_ acct: String, data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: acct,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        SecItemDelete(query as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: "Ceburu.Keychain", code: Int(status))
        }
    }
}