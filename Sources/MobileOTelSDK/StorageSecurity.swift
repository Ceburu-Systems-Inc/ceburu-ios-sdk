import Foundation
import CryptoKit
import Security
import Darwin

// MARK: - PII Redaction

enum Security {

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

struct RetryBackoff {
    private(set) var attempt = 0

    mutating func reset() { attempt = 0 }

    mutating func nextDelayMs() -> Int {
        attempt += 1
        let exp = min(attempt, 8)
        let base = min(300_000, 1_000 * (1 << exp))
        return base + Int.random(in: 0...1_000)
    }
}

// MARK: - Encrypted Queue

actor EncryptedStore {

    private let queueDir: URL
    let crashDir: URL
    private let key: SymmetricKey
    private let maxBytes: Int
    private let maxAgeSeconds: TimeInterval
    private var lastPruneTime: Date = .distantPast

    init(maxBytes: Int, retentionHours: Int) throws {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]

        queueDir = base.appendingPathComponent("MobileOTel/Queue", isDirectory: true)
        crashDir = base.appendingPathComponent("MobileOTel/Crashes", isDirectory: true)

        try FileManager.default.createDirectory(at: queueDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: crashDir, withIntermediateDirectories: true)

        key = try KeyStore.loadOrCreate()
        self.maxBytes = maxBytes
        self.maxAgeSeconds = TimeInterval(retentionHours * 3600)
    }

    func enqueue(_ event: MobileOTelSDK.Event) throws {
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

    func acknowledge(_ files: [URL]) {
        files.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    nonisolated func persistBreadcrumbs(_ text: String) {
        let file = crashDir.appendingPathComponent("breadcrumbs.txt")
        try? text.data(using: .utf8)?.write(to: file, options: [.atomic])
    }

    nonisolated func persistException(_ exception: NSException, sessionId: String) {
        let object: [String: Any] = [
            "timestamp_ms": Int64(Date().timeIntervalSince1970 * 1000),
            "session_id": sessionId,
            "exception_type": exception.name.rawValue,
            "exception_message": exception.reason ?? "",
            "exception_stacktrace": exception.callStackSymbols.joined(separator: "\n"),
            "breadcrumbs": MobileOTelSDK._crashBreadcrumbs
        ]

        if let data = try? JSONSerialization.data(withJSONObject: object) {
            let file = crashDir.appendingPathComponent(
                "\(Date().timeIntervalSince1970)_\(UUID().uuidString).json"
            )
            try? data.write(to: file, options: [.atomic])
        }
    }

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
                let event = MobileOTelSDK.Event(
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
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let date = attrs[.creationDate] as? Date,
               date < cutoff {
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
            let event = try JSONDecoder().decode(MobileOTelSDK.Event.self, from: clear)
            return event.severity.rawValue
        } catch {
            return MobileOTelSDK.Severity.info.rawValue
        }
    }

    // MARK: - Signal crash import (next-launch delivery)

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
                    event = MobileOTelSDK.Event(
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

    private func parseSignalCrash(data: Data, fallbackSessionId: String) -> MobileOTelSDK.Event? {
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

        return MobileOTelSDK.Event(
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

enum KeyStore {

    private static let service = "com.enterprise.mobileotel"
    private static let account = "queue-key"

    static func loadOrCreate() throws -> SymmetricKey {
        if let existing = try load() {
            return SymmetricKey(data: existing)
        }

        var data = Data(count: 32)
        let status = data.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: "MobileOTel.Keychain", code: Int(status))
        }

        try save(data)
        return SymmetricKey(data: data)
    }

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
            throw NSError(domain: "MobileOTel.Keychain", code: Int(status))
        }
        return result as? Data
    }

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
            throw NSError(domain: "MobileOTel.Keychain", code: Int(status))
        }
    }
}
