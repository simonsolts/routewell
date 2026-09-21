import Darwin
import Foundation

/// The scheme a router endpoint was reached with. Plain HTTP is allowed but
/// callers must acknowledge it (see `RouterProfile.plainHTTPAcknowledged`).
public enum EndpointScheme: String, Sendable, Codable, Equatable {
    case http, https
}

/// Every error `RouterEndpoint.parse` can produce. No case carries the raw
/// input: UI strings must not echo attacker- or typo-controlled text back
/// verbatim unless it came from the user's own settings field.
public enum EndpointParseError: Error, Equatable, Sendable {
    case empty
    case invalidScheme
    case missingHost
    case invalidHost
    case invalidPort
    case userInfoNotAllowed
    case pathNotAllowed
    case queryNotAllowed
}

/// A validated router address: scheme, lowercase host or IP literal, and an
/// explicit port. Every fact about the router itself is out of scope here —
/// this type only says where to connect, never what the router speaks.
public struct RouterEndpoint: Sendable, Hashable, Codable {
    public let scheme: EndpointScheme
    /// Lowercase hostname or IP literal. IPv6 literals are stored WITHOUT brackets.
    public let host: String
    /// Always explicit; defaulted to 80/443 at parse time when the input omitted it.
    public let port: Int

    private static let defaultPort: [EndpointScheme: Int] = [.http: 80, .https: 443]

    public init(scheme: EndpointScheme, host: String, port: Int) throws {
        guard (1...65535).contains(port) else { throw EndpointParseError.invalidPort }
        guard !host.isEmpty else { throw EndpointParseError.missingHost }
        if Self.isIPv6Literal(host) {
            self.host = host.lowercased()
        } else if Self.isIPv4Literal(host) {
            self.host = host
        } else {
            guard Self.isValidHostname(host) else { throw EndpointParseError.invalidHost }
            self.host = host.lowercased()
        }
        self.scheme = scheme
        self.port = port
    }

    public var isDefaultPort: Bool { Self.defaultPort[scheme] == port }

    private var isIPv6: Bool { host.contains(":") }

    /// "https://host:port/" — IPv6 hosts get brackets, always a trailing slash.
    public var url: URL {
        var components = URLComponents()
        components.scheme = scheme.rawValue
        components.host = isIPv6 ? "[\(host)]" : host
        if !isDefaultPort { components.port = port }
        components.path = "/"
        if let url = components.url { return url }
        assertionFailure("RouterEndpoint could not build a URL for \(scheme.rawValue) host on port \(port)")
        return URL(string: "https://invalid.invalid")!
    }

    /// "https://192.168.8.1" — omits the port when it is the scheme's default.
    public var displayString: String {
        let hostToken = isIPv6 ? "[\(host)]" : host
        let portToken = isDefaultPort ? "" : ":\(port)"
        return "\(scheme.rawValue)://\(hostToken)\(portToken)"
    }

    public static func parse(_ input: String) throws(EndpointParseError) -> RouterEndpoint {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .empty }
        guard !trimmed.contains(where: { $0.isWhitespace }) else { throw .invalidHost }
        guard !trimmed.contains("@") else { throw .userInfoNotAllowed }

        var remainder = Substring(trimmed)
        var scheme = EndpointScheme.https
        let lower = remainder.lowercased()
        if lower.hasPrefix("http://") {
            scheme = .http
            remainder = remainder.dropFirst(7)
        } else if lower.hasPrefix("https://") {
            scheme = .https
            remainder = remainder.dropFirst(8)
        } else if remainder.contains("://") {
            throw .invalidScheme
        }
        guard !remainder.isEmpty else { throw .missingHost }

        let hostPart: Substring
        var afterHost: Substring
        var bracketed = false
        if remainder.first == "[" {
            bracketed = true
            guard let closeIdx = remainder.firstIndex(of: "]") else { throw .invalidHost }
            hostPart = remainder[remainder.index(after: remainder.startIndex)..<closeIdx]
            afterHost = remainder[remainder.index(after: closeIdx)...]
        } else {
            let terminators: Set<Character> = ["/", "?", "#", ":"]
            if let idx = remainder.firstIndex(where: { terminators.contains($0) }) {
                hostPart = remainder[remainder.startIndex..<idx]
                afterHost = remainder[idx...]
            } else {
                hostPart = remainder
                afterHost = remainder[remainder.endIndex...]
            }
        }
        guard !hostPart.isEmpty else { throw .missingHost }

        var port: Int?
        if afterHost.first == ":" {
            afterHost = afterHost.dropFirst()
            let idx = afterHost.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? afterHost.endIndex
            let portString = afterHost[afterHost.startIndex..<idx]
            guard !portString.isEmpty, portString.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw .invalidPort }
            guard let value = Int(portString), (1...65535).contains(value) else { throw .invalidPort }
            port = value
            afterHost = afterHost[idx...]
        }

        if afterHost.isEmpty || afterHost == "/" {
            // no path, or the bare root — both accepted
        } else if afterHost.hasPrefix("/") {
            throw .pathNotAllowed
        } else if afterHost.hasPrefix("?") {
            throw .queryNotAllowed
        } else if afterHost.hasPrefix("#") {
            throw .pathNotAllowed
        } else {
            throw .invalidHost
        }

        let hostString = String(hostPart)
        if bracketed {
            guard isIPv6Literal(hostString) else { throw .invalidHost }
        } else if isIPv4Literal(hostString) {
            // accepted as-is
        } else {
            guard isValidHostname(hostString) else { throw .invalidHost }
        }

        let resolvedPort = port ?? defaultPort[scheme]!
        do {
            return try RouterEndpoint(scheme: scheme, host: hostString, port: resolvedPort)
        } catch let error as EndpointParseError {
            throw error
        } catch {
            throw .invalidHost
        }
    }

    private static func isIPv4Literal(_ host: String) -> Bool {
        var addr = in_addr()
        return host.withCString { inet_pton(AF_INET, $0, &addr) } == 1
    }

    private static func isIPv6Literal(_ host: String) -> Bool {
        var addr = in6_addr()
        return host.withCString { inet_pton(AF_INET6, $0, &addr) } == 1
    }

    /// Shared with `SSHHostValidation`: SSH targets accept exactly the same
    /// literal-or-hostname rules as HTTP endpoints, including rejecting
    /// all-numeric, dot-separated hosts (e.g. "999.999.999.999") that are not
    /// a valid IPv4 literal.
    internal static func isValidHostLiteralOrName(_ host: String) -> Bool {
        isIPv4Literal(host) || isIPv6Literal(host) || isValidHostname(host)
    }

    private static func isValidHostname(_ host: String) -> Bool {
        guard host.count <= 253 else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-")
        guard host.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }
        for label in labels {
            guard !label.isEmpty, label.first != "-", label.last != "-" else { return false }
        }
        // All-numeric, dot-separated hosts that are not a valid IPv4 literal
        // (e.g. "999.999.999.999", "192.168.8.1.1") look like typos of an IP
        // address, not a hostname. Reject rather than silently trying to
        // resolve them as DNS names.
        guard !labels.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else { return false }
        return true
    }
}
