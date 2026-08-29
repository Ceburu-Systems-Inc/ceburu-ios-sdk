import Foundation
import CryptoKit
import Security
import Darwin

// MARK: - PII Redaction

/// Attribute sanitizer — redacts or hashes PII before events are written to disk or exported.
///
/// Redaction rules applied in order (key matching is case-insensitive):
///
/// | Key contains | Action |
/// |---|---|
/// | `password`, `authorization`, `cookie`, `secret` | Dropped entirely — not written |
/// | `token`, `card` | Value replaced with `[REDACTED]` |
/// | `email`, `phone` | Value replaced with its SHA-256 hex digest |
/// | anything else | Passed through unchanged |
enum Security {

    /// Returns a copy of `input` with PII values redacted or hashed.
    ///
    /// - Parameter input: Raw attribute dictionary from the caller.
    /// - Returns: Sanitized dictionary safe to write to disk and export to the collector.
    static func redact(_ input: [String: String]) -> [String: String] {
        var out: [String: String] = [:]

        for (key, value) in input {
            let k = key.lowercased()

            if k.contains("password") ||
               k.contains("authorization") ||
               k.contains("cookie") ||
               k.contains("secret") {
                continue
            }

            if k.contains("token") || k.contains("card") {
                out[key] = "[REDACTED]"
                continue
            }

            if k.contains("email") || k.contains("phone") {
                let digest = SHA256.hash(data: Data(value.utf8))
                out[key] = digest.map { String(format: "%02x", $0) }.joined()
                continue
            }

            out[key] = value
        }

        return out
    }
}

// MARK: - Retry Backoff

/// Exponential backoff with jitter for flush-loop retries.
///
/// On each `nextDelayMs()` call the delay doubles (capped at 5 minutes), with ±1 s of
/// random jitter to prevent thundering-herd reconnections when multiple instances restart
/// simultaneously. Call `reset()` after a successful flush to start from the minimum delay.
struct RetryBackoff {
    private(set) var attempt = 0

    /// Resets the backoff counter. Call after a successful export.
    mutating func reset() { attempt = 0 }

    /// Returns the next delay in milliseconds and advances the attempt counter.
    ///
    /// Delay schedule: 2 s, 4 s, 8 s, … up to 5 min (300 s), plus 0–1 s of jitter.
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
/// `<timestampMs>_<eventId>.bin`. Files are ordered by name (timestamp) on read,
/// so the queue is naturally FIFO. Crash records are stored as `.json` files in a
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

    /// Creates the encrypted store, initialising the queue and crash directories
    /// and loading (or generating) the AES key from the Keychain.
    ///
    /// - Parameters:
    ///   - maxBytes:       Maximum total size of the on-device queue in bytes.
    ///   - retentionHours: Events older than this are pruned during the next flush cycle.
    /// - Throws: If the directories cannot be created or the Keychain operation fails.
    init(maxBytes: Int, retentionHours: Int) throws {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]

        queueDir = base.appendingPathComponent("Ceburu/Queue", isDirectory: true)
        crashDir = base.appendingPathComponent("Ceburu/Crashes", isDirectory: true)

        try FileManager.default.createDirectory(at: queueDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: crashDir, withIntermediateDirectories: true)

        key = try KeyStore.loadOrCreate()
        self.maxBytes = maxBytes
        self.maxAgeSeconds = TimeInterval(retentionHours * 3600)
    }

    /// Encrypts and enqueues a single event.
    ///
    /// The event is serialized to JSON, encrypted with AES-256-GCM, and written
    /// atomically (via a `.tmp` file rename) to avoid partial writes. After writing,
    /// the queue size quota is enforced by evicting low-severity events if needed.
    ///
    /// - Parameter event: The event to persist.
    /// - Throws: If JSON encoding, AES encryption, or the filesystem write fails.
    func enqueue(_ event: CeburuAnalyticsSDK.Event) throws {
        pruneOld()

        let clear = try JSONEncoder().encode(event)
        let sealed = try AES.GCM.seal(clear, using: key)
        guard let encrypted = sealed.combined else { return }

        let tmp = queueDir.appendingPathComponent(
            "\(event.timestampUnixMs)_\(event.eventId).tmp"
        )
        let final = queueDir.appendingPathComponent(
            "\(event.timestampUnixMs)_\(event.eventId).bin"
        )

        try encrypted.write(to: tmp, options: [.atomic])
        try? FileManager.default.removeItem(at: final)
        try FileManager.default.moveItem(at: tmp, to: final)

        enforceQuota()
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
    func batch(maxEvents: Int, maxBytes: Int) throws -> [(URL, Data)] {
        pruneOld()

        var result: [(URL, Data)] = []
        var total = 0

        for url in queueFiles() {
            if result.count >= maxEvents { break }

            let encrypted = try Data(contentsOf: url)
            let sealed = try AES.GCM.SealedBox(combined: encrypted)
            let clear = try AES.GCM.open(sealed, using: key)

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
    /// - Parameter files: File URLs previously returned by ``batch(maxEvents:maxBytes:)``.
    func acknowledge(_ files: [URL]) {
        files.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    /// Persists the current breadcrumb trail to disk so it survives a crash.
    ///
    /// `nonisolated` so it can be called synchronously from the signal-handler trampoline
    /// and from `NSSetUncaughtExceptionHandler` without awaiting the actor.
    ///
    /// - Parameter text: Serialized breadcrumb string (pipe-separated `"category:message"` pairs).
    nonisolated func persistBreadcrumbs(_ text: String) {
        let file = crashDir.appendingPathComponent("breadcrumbs.txt")
        try? text.data(using: .utf8)?.write(to: file, options: [.atomic])
    }

    /// Persists an `NSException` to disk for next-launch delivery.
    ///
    /// Called from `NSSetUncaughtExceptionHandler` — a synchronous C callback that fires
    /// on the crashing thread. Uses only Foundation JSON serialization (no async).
    /// `nonisolated` to avoid actor-isolation overhead at crash time.
    ///
    /// - Parameters:
    ///   - exception: The uncaught Objective-C exception.
    ///   - sessionId: The session ID active at crash time, read from the `nonisolated(unsafe)` static.
    nonisolated func persistException(_ exception: NSException, sessionId: String) {
        let object: [String: Any] = [
            "timestamp_ms": Int64(Date().timeIntervalSince1970 * 1000),
            "session_id": sessionId,
            "exception_type": exception.name.rawValue,
            "exception_message": exception.reason ?? "",
            "exception_stacktrace": exception.callStackSymbols.joined(separator: "\n"),
            "breadcrumbs": CeburuAnalyticsSDK._crashBreadcrumbs
        ]

        if let data = try? JSONSerialization.data(withJSONObject: object) {
            let file = crashDir.appendingPathComponent(
                "\(Date().timeIntervalSince1970)_\(UUID().uuidString).json"
            )
            try? data.write(to: file, options: [.atomic])
        }
    }

    /// Imports crash records persisted by `NSSetUncaughtExceptionHandler` during a previous session.
    ///
    /// Called once in ``CeburuAnalyticsSDK/initialize(config:)`` before the flush loop starts.
    /// Each `.json` file is decoded, converted to a `fatal`-severity `Event`, enqueued for
    /// delivery, and then deleted. Files that cannot be parsed are silently skipped and left
    /// for the next launch.
    ///
    /// - Parameter sessionId: The current session ID — used as the delivery session for imported crashes.
    func importCrashRecords(sessionId: String) async throws {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: crashDir, includingPropertiesForKeys: nil
        )) ?? []

        for file in files where file.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: file)
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }

                let crashSessionId = json["session_id"] as? String ?? sessionId
                let breadcrumbs = json["breadcrumbs"] as? String ?? ""
                var attributes: [String: String] = [
                    "exception.type":       String(describing: json["exception_type"] ?? ""),
                    "exception.message":    String(describing: json["exception_message"] ?? ""),
                    "exception.stacktrace": String(describing: json["exception_stacktrace"] ?? ""),
                    "crash.session.id":     crashSessionId
                ]
                if !breadcrumbs.isEmpty { attributes["session.breadcrumbs"] = breadcrumbs }
                let event = CeburuAnalyticsSDK.Event(
                    eventId: UUID().uuidString,
                    timestampUnixMs: json["timestamp_ms"] as? Int64
                        ?? Int64(Date().timeIntervalSince1970 * 1000),
                    severity: .fatal,
                    type: "crash",
                    message: "Unhandled iOS exception",
                    sessionId: sessionId,
                    attributes: attributes
                )

                try enqueue(event)
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
            }
        }
    }

    // Evicts lowest-severity events first when the queue exceeds maxBytes.
    private func enforceQuota() {
        let files = queueFiles()

        func size(_ url: URL) -> Int {
            ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? 0
        }

        var total = files.reduce(0) { $0 + size($1) }
        if total <= maxBytes { return }

        let ordered = files.sorted { severityRank($0) < severityRank($1) }
        for file in ordered {
            if total <= maxBytes { break }
            total -= size(file)
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func severityRank(_ url: URL) -> Int {
        do {
            let encrypted = try Data(contentsOf: url)
            let sealed = try AES.GCM.SealedBox(combined: encrypted)
            let clear = try AES.GCM.open(sealed, using: key)
            let event = try JSONDecoder().decode(CeburuAnalyticsSDK.Event.self, from: clear)
            return event.severity.rawValue
        } catch {
            return CeburuAnalyticsSDK.Severity.info.rawValue
        }
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
    func importSignalCrashRecords(sessionId: String) async throws {
        let breadcrumbsFile = crashDir.appendingPathComponent("breadcrumbs.txt")
        let savedBreadcrumbs = (try? String(contentsOf: breadcrumbsFile, encoding: .utf8)) ?? ""

        let files = (try? FileManager.default.contentsOfDirectory(
            at: crashDir, includingPropertiesForKeys: nil
        )) ?? []

        var importedAny = false
        for file in files where file.pathExtension == "sigseg" {
            do {
                let data = try Data(contentsOf: file)
                guard var event = parseSignalCrash(data: data, fallbackSessionId: sessionId)
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
                        attributes: attrs
                    )
                }
                try enqueue(event)
                try? FileManager.default.removeItem(at: file)
                importedAny = true
            } catch {
                // Keep for a later launch
            }
        }

        if importedAny {
            try? FileManager.default.removeItem(at: breadcrumbsFile)
        }
    }

    /// Parses the binary `.sigseg` crash file written by ``SignalCrashHandler``.
    ///
    /// File format (all values little-endian):
    /// ```
    /// magic       UInt32   0x4D534947 ("MSIG")
    /// signal      Int32
    /// timestampMs Int64
    /// sessionLen  UInt16   (includes null terminator)
    /// sessionId   [CChar]  (sessionLen bytes, null-terminated)
    /// frameCount  UInt16
    /// frames      [UInt64] (frameCount raw PC addresses)
    /// ```
    ///
    /// Frame addresses are symbolicated using `dladdr` — safe to call in this normal (non-signal) context.
    ///
    /// - Parameters:
    ///   - data:              Raw file contents.
    ///   - fallbackSessionId: Used when the file's session field is empty or unreadable.
    /// - Returns: A `fatal`-severity `Event`, or `nil` if the file is corrupt or truncated.
    private func parseSignalCrash(data: Data, fallbackSessionId: String) -> CeburuAnalyticsSDK.Event? {
        var offset = 0

        func read<T: FixedWidthInteger>(_: T.Type) -> T? {
            let size = MemoryLayout<T>.size
            guard offset + size <= data.count else { return nil }
            defer { offset += size }
            return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
        }

        guard let magic: UInt32 = read(UInt32.self), magic == 0x4D534947 else { return nil }
        guard let sig: Int32    = read(Int32.self)                        else { return nil }
        guard let tsMs: Int64   = read(Int64.self)                        else { return nil }
        guard let sessionLen: UInt16 = read(UInt16.self)                  else { return nil }

        let slen = Int(sessionLen)
        guard slen > 0, offset + slen <= data.count else { return nil }
        // sessionIdCStr includes null terminator — strip it
        let sessionId = String(bytes: data[offset..<(offset + slen - 1)], encoding: .utf8)
            ?? fallbackSessionId
        offset += slen

        guard let frameCount: UInt16 = read(UInt16.self) else { return nil }

        // Symbolicate addresses using dladdr — safe in normal (non-signal) context.
        var stackLines: [String] = []
        for i in 0..<min(Int(frameCount), 32) {
            guard let addr: UInt64 = read(UInt64.self) else { break }
            var info = Dl_info()
            if dladdr(UnsafeRawPointer(bitPattern: UInt(addr)), &info) != 0 {
                let sym = info.dli_sname.map { String(cString: $0) } ?? "<unknown>"
                let lib = info.dli_fname
                    .map { URL(fileURLWithPath: String(cString: $0)).lastPathComponent } ?? "<unknown>"
                let off = addr - UInt64(UInt(bitPattern: info.dli_saddr))
                stackLines.append("#\(i)  \(lib)  \(sym) + \(off)")
            } else {
                stackLines.append("#\(i)  0x\(String(addr, radix: 16))")
            }
        }

        return CeburuAnalyticsSDK.Event(
            eventId: UUID().uuidString,
            timestampUnixMs: tsMs,
            severity: .fatal,
            type: "crash",
            message: "Unhandled signal: \(signalName(sig))",
            sessionId: sessionId,
            attributes: [
                "exception.type":       signalName(sig),
                "exception.message":    signalDescription(sig),
                "exception.stacktrace": stackLines.joined(separator: "\n")
            ]
        )
    }

    private func signalName(_ sig: Int32) -> String {
        switch sig {
        case SIGABRT: return "SIGABRT"
        case SIGSEGV: return "SIGSEGV"
        case SIGBUS:  return "SIGBUS"
        case SIGILL:  return "SIGILL"
        case SIGFPE:  return "SIGFPE"
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

    /// Loads the existing AES key from the Keychain, or generates and stores a new one.
    ///
    /// - Returns: The 256-bit `SymmetricKey` for AES-GCM encryption/decryption.
    /// - Throws: `NSError(domain: "Ceburu.Keychain", ...)` if the Keychain operation fails.
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

    /// Attempts to load the key from the Keychain. Returns `nil` if not found.
    ///
    /// - Throws: If the Keychain query returns an error other than `errSecItemNotFound`.
    private static func load() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
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
