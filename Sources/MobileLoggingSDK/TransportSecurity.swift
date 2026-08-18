import Foundation
import CryptoKit

// Privacy helper. Network transport is handled by the host app's OpenTelemetry SDK.
enum Security {

    static func redact(_ input: [String: String]) -> [String: String] {
        var out: [String: String] = [:]

        for (key, value) in input {
            let k = key.lowercased()

            if k.contains("password") || k.contains("authorization") ||
               k.contains("cookie")  || k.contains("secret") {
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
