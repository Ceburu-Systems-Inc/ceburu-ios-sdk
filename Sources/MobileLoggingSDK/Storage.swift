import Foundation
import CryptoKit
import Security

actor Storage {

    private let queueDir: URL
    private let crashDir: URL
    private let key: SymmetricKey
    private let maxBytes: Int
    private let retentionSeconds: TimeInterval

    init(
        maxBytes: Int,
        retentionHours: Int
    ) throws {
        let base =
            FileManager.default.urls(
                for:
                    .applicationSupportDirectory,
                in:
                    .userDomainMask
            )[0]

        queueDir =
            base.appendingPathComponent(
                "EnterpriseMobile/Queue",
                isDirectory: true
            )

        crashDir =
            base.appendingPathComponent(
                "EnterpriseMobile/Crashes",
                isDirectory: true
            )

        try FileManager.default
            .createDirectory(
                at: queueDir,
                withIntermediateDirectories: true
            )

        try FileManager.default
            .createDirectory(
                at: crashDir,
                withIntermediateDirectories: true
            )

        self.maxBytes =
            maxBytes

        self.retentionSeconds =
            TimeInterval(
                retentionHours * 3600
            )

        self.key =
            try KeyStore.loadOrCreate()
    }

    func enqueue(
        _ event: MobileSDK.Event
    ) throws {
        pruneOld()

        let clear =
            try JSONEncoder()
                .encode(
                    event
                )

        let sealed =
            try AES.GCM.seal(
                clear,
                using: key
            )

        guard let encrypted =
            sealed.combined
        else {
            return
        }

        let tmp =
            queueDir.appendingPathComponent(
                "\(event.timestampUnixMs)_\(event.eventId).tmp"
            )

        let final =
            queueDir.appendingPathComponent(
                "\(event.timestampUnixMs)_\(event.eventId).bin"
            )

        try encrypted.write(
            to: tmp,
            options: [.atomic]
        )

        try? FileManager.default
            .removeItem(
                at: final
            )

        try FileManager.default
            .moveItem(
                at: tmp,
                to: final
            )

        enforceQuota()
    }

    func batch(
        maxEvents: Int,
        maxBytes: Int
    ) throws -> [(URL, Data)] {
        pruneOld()

        var out: [(URL, Data)] = []
        var total = 0

        for url in queueFiles() {
            if out.count >= maxEvents {
                break
            }

            let encrypted =
                try Data(
                    contentsOf: url
                )

            let sealed =
                try AES.GCM.SealedBox(
                    combined: encrypted
                )

            let clear =
                try AES.GCM.open(
                    sealed,
                    using: key
                )

            if total + clear.count > maxBytes &&
               !out.isEmpty {
                break
            }

            out.append(
                (
                    url,
                    clear
                )
            )

            total += clear.count
        }

        return out
    }

    func acknowledge(
        _ files: [URL]
    ) {
        for file in files {
            try? FileManager.default
                .removeItem(
                    at: file
                )
        }
    }

    nonisolated func persistException(
        _ exception: NSException,
        sessionId: String
    ) {
        let obj: [String: Any] = [
            "timestamp_ms":
                Int64(
                    Date().timeIntervalSince1970 * 1000
                ),

            "session_id":
                sessionId,

            "exception_type":
                exception.name.rawValue,

            "exception_message":
                exception.reason ?? "",

            "exception_stacktrace":
                exception.callStackSymbols
                    .joined(
                        separator: "\n"
                    )
        ]

        if let data =
            try? JSONSerialization
                .data(
                    withJSONObject: obj
                ) {

            let path =
                crashDir.appendingPathComponent(
                    "\(Date().timeIntervalSince1970)_\(UUID().uuidString).json"
                )

            try? data.write(
                to: path,
                options: [.atomic]
            )
        }
    }

    func importPendingCrashes(
        sessionId: String
    ) async throws {
        let files =
            (
                try? FileManager.default
                    .contentsOfDirectory(
                        at: crashDir,
                        includingPropertiesForKeys: nil
                    )
            ) ?? []

        for file in files
        where file.pathExtension == "json" {
            do {
                let data =
                    try Data(
                        contentsOf: file
                    )

                guard let json =
                    try JSONSerialization
                        .jsonObject(
                            with: data
                        )
                        as? [String: Any]
                else {
                    continue
                }

                let event =
                    MobileSDK.Event(
                        eventId:
                            UUID().uuidString,

                        timestampUnixMs:
                            json["timestamp_ms"]
                                as? Int64
                                ?? Int64(
                                    Date().timeIntervalSince1970 * 1000
                                ),

                        severity:
                            .fatal,

                        type:
                            "crash",

                        message:
                            "Unhandled iOS exception",

                        sessionId:
                            sessionId,

                        attributes: [
                            "exception.type":
                                String(
                                    describing:
                                        json["exception_type"]
                                        ?? ""
                                ),

                            "exception.message":
                                String(
                                    describing:
                                        json["exception_message"]
                                        ?? ""
                                ),

                            "exception.stacktrace":
                                String(
                                    describing:
                                        json["exception_stacktrace"]
                                        ?? ""
                                )
                        ]
                    )

                try enqueue(event)

                try? FileManager.default
                    .removeItem(
                        at: file
                    )
            } catch {
                // Keep for a later launch.
            }
        }
    }

    private func queueFiles() -> [URL] {
        let files =
            (
                try? FileManager.default
                    .contentsOfDirectory(
                        at: queueDir,
                        includingPropertiesForKeys: nil
                    )
            ) ?? []

        return files
            .filter {
                $0.pathExtension == "bin"
            }
            .sorted {
                $0.lastPathComponent <
                    $1.lastPathComponent
            }
    }

    private func pruneOld() {
        let cutoff =
            Date()
                .addingTimeInterval(
                    -retentionSeconds
                )

        for url in queueFiles() {
            if let attrs =
                try? FileManager.default
                    .attributesOfItem(
                        atPath: url.path
                    ),

               let date =
                attrs[.creationDate]
                    as? Date,

               date < cutoff {

                try? FileManager.default
                    .removeItem(
                        at: url
                    )
            }
        }
    }

    private func enforceQuota() {
        var files =
            queueFiles()

        func size(
            _ url: URL
        ) -> Int {
            (
                (
                    try? FileManager.default
                        .attributesOfItem(
                            atPath: url.path
                        )[.size]
                )
                as? NSNumber
            )?.intValue
            ?? 0
        }

        var total =
            files.reduce(0) {
                $0 + size($1)
            }

        if total <= maxBytes {
            return
        }

        let ordered =
            files.sorted {
                severityRank($0) <
                    severityRank($1)
            }

        for file in ordered {
            if total <= maxBytes {
                break
            }

            total -=
                size(file)

            try? FileManager.default
                .removeItem(
                    at: file
                )
        }
    }

    private func severityRank(
        _ url: URL
    ) -> Int {
        do {
            let encrypted =
                try Data(
                    contentsOf: url
                )

            let sealed =
                try AES.GCM.SealedBox(
                    combined: encrypted
                )

            let clear =
                try AES.GCM.open(
                    sealed,
                    using: key
                )

            let event =
                try JSONDecoder()
                    .decode(
                        MobileSDK.Event.self,
                        from: clear
                    )

            return event.severity.rawValue
        } catch {
            return MobileSDK.Severity.info.rawValue
        }
    }
}

enum KeyStore {

    private static let service =
        "com.enterprise.mobile"

    private static let account =
        "queue-key"

    static func loadOrCreate() throws -> SymmetricKey {
        if let existing = try? load() {
            return SymmetricKey(data: existing)
        }

        var data = Data(count: 32)
        let status = data.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: "MobileSDK.Keychain", code: Int(status))
        }

        // Best-effort save; if keychain is unavailable (e.g. simulator without
        // entitlements) we proceed with an ephemeral key for this session.
        try? save(data)

        return SymmetricKey(data: data)
    }

    private static func load() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String:
                kSecClassGenericPassword,

            kSecAttrService as String:
                service,

            kSecAttrAccount as String:
                account,

            kSecReturnData as String:
                true,

            kSecMatchLimit as String:
                kSecMatchLimitOne
        ]

        var result: CFTypeRef?

        let status =
            SecItemCopyMatching(
                query as CFDictionary,
                &result
            )

        if status ==
            errSecItemNotFound {
            return nil
        }

        guard status ==
            errSecSuccess
        else {
            throw NSError(
                domain: "MobileSDK.Keychain",
                code: Int(status)
            )
        }

        return result as? Data
    }

    private static func save(
        _ data: Data
    ) throws {
        let query: [String: Any] = [
            kSecClass as String:
                kSecClassGenericPassword,

            kSecAttrService as String:
                service,

            kSecAttrAccount as String:
                account,

            kSecValueData as String:
                data,

            kSecAttrAccessible as String:
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        SecItemDelete(
            query as CFDictionary
        )

        let status =
            SecItemAdd(
                query as CFDictionary,
                nil
            )

        guard status ==
            errSecSuccess
        else {
            throw NSError(
                domain: "MobileSDK.Keychain",
                code: Int(status)
            )
        }
    }
}
