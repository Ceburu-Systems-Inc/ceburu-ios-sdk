import Foundation
import OpenTelemetryApi

/// What a network span records from the last transaction of `URLSessionTaskMetrics`: request and response
/// body sizes and the protocol.
struct NetworkMetrics: Equatable, Sendable {
    var requestBodyBytes: Int64?
    var responseBodyBytes: Int64?
    /// ALPN name from URLSession: `http/1.1`, `h2`, `h3`.
    var protocolName: String?

    init(requestBodyBytes: Int64? = nil, responseBodyBytes: Int64? = nil, protocolName: String? = nil) {
        self.requestBodyBytes = requestBodyBytes
        self.responseBodyBytes = responseBodyBytes
        self.protocolName = protocolName
    }

    init(_ t: URLSessionTaskTransactionMetrics) {
        self.init(requestBodyBytes: t.countOfRequestBodyBytesSent,
                  responseBodyBytes: t.countOfResponseBodyBytesReceived,
                  protocolName: t.networkProtocolName)
    }

    /// Span attributes, following OpenTelemetry: `h2` is sent as `network.protocol.name` `http` with
    /// `network.protocol.version` `2`.
    var attributes: [String: AttributeValue] {
        var out: [String: AttributeValue] = [:]
        if let requestBodyBytes { out["http.request.body.size"] = .int(Int(requestBodyBytes)) }
        if let responseBodyBytes { out["http.response.body.size"] = .int(Int(responseBodyBytes)) }
        if let (name, version) = Self.protocolParts(protocolName) {
            out["network.protocol.name"] = .string(name)
            if let version { out["network.protocol.version"] = .string(version) }
        }
        return out
    }

    /// OpenTelemetry form of the ALPN name: `h2` → (`http`, `2`), `http/1.1` → (`http`, `1.1`), `h3` → (`http`, `3`).
    static func protocolParts(_ alpn: String?) -> (String, String?)? {
        guard let raw = alpn?.lowercased().trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        switch raw {
        case "h2", "h2c": return ("http", "2")
        case "h3":        return ("http", "3")
        default:
            if raw.hasPrefix("h3-") { return ("http", "3") }
            let parts = raw.split(separator: "/", maxSplits: 1).map(String.init)
            return (parts[0], parts.count > 1 ? parts[1] : nil)
        }
    }
}
