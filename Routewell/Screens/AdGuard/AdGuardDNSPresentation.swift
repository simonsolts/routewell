import Foundation
import RoutewellKit

/// Text for the DNS tab.
enum DNSPresentation {
    static let applyNote = "DNS changes take effect for all devices when applied."
    static let testUpstreams = "Test Upstreams"
    static let clearCache = "Clear Cache"
    static let cacheCleared = "Cache Cleared"
    static let serversNote = "One address per line. Lines starting with # are comments."
    static let addUpstreamTitle = "Add upstream server"
    static let addUpstreamNote = "Plain DNS, https:// (DoH), tls:// (DoT), or quic:// (DoQ)."
    static let addUpstreamPlaceholder = "tls://dns.example.com"

    enum ServerList: String, Identifiable {
        case fallback, bootstrap

        var id: String { rawValue }

        var title: String {
            switch self {
            case .fallback: "Fallback servers"
            case .bootstrap: "Bootstrap servers"
            }
        }

        var subtitle: String? {
            self == .bootstrap ? "Look up encrypted upstreams’ addresses" : nil
        }

        var sheetDescription: String {
            switch self {
            case .fallback: "Used only when every upstream server fails to answer."
            case .bootstrap: "Plain DNS servers used only to find the addresses of your encrypted upstreams. Must be IP addresses."
            }
        }

        var placeholder: String {
            switch self {
            case .fallback: "192.0.2.53\n2001:db8::53"
            case .bootstrap: "192.0.2.10\n198.51.100.10"
            }
        }
    }

    static func modeTitle(_ mode: AdGuardUpstreamMode) -> String {
        switch mode {
        case .loadBalance: "Load balancing"
        case .parallel: "Parallel requests"
        case .fastestAddress: "Fastest IP address"
        }
    }

    static func modeDescription(_ mode: AdGuardUpstreamMode?) -> String {
        switch mode {
        case .loadBalance?: "Prefers the fastest server, spreads the rest"
        case .parallel?: "Asks every server at once and uses the first answer"
        case .fastestAddress?: "Waits for all answers and picks the quickest address"
        case nil: "Unknown"
        }
    }

    static func blockingTitle(_ mode: AdGuardBlockingMode) -> String {
        switch mode {
        case .default: "Default"
        case .nullIP: "Null IP address"
        case .refused: "REFUSED"
        case .nxdomain: "NXDOMAIN"
        case .customIP: "Custom IP address"
        }
    }

    static func blockingDescription(_ mode: AdGuardBlockingMode?) -> String {
        switch mode {
        case .default?: "Hosts-style rules answer with their own address; other rules answer 0.0.0.0 or ::"
        case .nullIP?: "Answers 0.0.0.0 for A and :: for AAAA lookups"
        case .refused?: "Answers with a REFUSED code"
        case .nxdomain?: "Answers as if the domain doesn’t exist"
        case .customIP?: "Answers with the addresses below — useful for a block page on your network"
        case nil: "Unknown"
        }
    }

    static let mebibyte = 1_048_576
    static let cacheSizes = [1, 4, 16, 32].map { $0 * mebibyte }

    /// Adds the current size when it is not one of the standard items.
    static func cacheSizeChoices(current: Int?) -> [Int] {
        guard let current, !cacheSizes.contains(current) else { return cacheSizes }
        return (cacheSizes + [current]).sorted()
    }

    static func cacheSizeTitle(_ bytes: Int) -> String {
        if bytes % mebibyte == 0 { return "\(bytes / mebibyte) MB" }
        if bytes % 1024 == 0 { return "\(bytes / 1024) KB" }
        return "\(bytes) bytes"
    }

    /// The human form beside a seconds field.
    static func duration(_ seconds: Int?) -> String {
        guard let seconds, seconds > 0 else { return "Not overridden" }
        if seconds % 86_400 == 0 { return seconds == 86_400 ? "1 day" : "\(seconds / 86_400) days" }
        if seconds % 3_600 == 0 { return "\(seconds / 3_600) h" }
        if seconds % 60 == 0 { return "\(seconds / 60) min" }
        return "\(seconds) s"
    }

    static func rateLimit(_ value: Int?) -> String {
        guard let value else { return "Unknown" }
        return value == 0 ? "Off" : "\(value) req/s"
    }

    static func seconds(_ value: Int?) -> String {
        value.map { "\($0) s" } ?? "Unknown"
    }

    /// All addresses, comments left out; "None" when empty.
    /// Sheet text as lines: blank lines dropped, `#` comments kept.
    static func lines(_ text: String) -> [String] {
        CustomRulesText.rules(text).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func addresses(_ lines: [String]?) -> String {
        guard let lines else { return "Unknown" }
        let addresses = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        return addresses.isEmpty ? "None" : addresses.joined(separator: ", ")
    }

    static func share(_ usage: UpstreamUsage) -> String {
        usage.sharePercent.map { "\(Int($0.rounded()))%" } ?? "Unknown"
    }

    static func time(_ milliseconds: Double) -> String {
        milliseconds > UpstreamUsage.slowMilliseconds
            ? (milliseconds / 1000).formatted(.number.precision(.fractionLength(1))) + " s"
            : "\(Int(milliseconds.rounded())) ms"
    }

    enum ResponseStyle { case normal, slow, good, failed }

    /// The Avg. response column: the stats time, or the test result.
    static func response(_ usage: UpstreamUsage, test: AdGuardDNSController.TestState, address: String) -> (text: String, style: ResponseStyle, help: String?) {
        switch test {
        case .testing:
            return ("…", .normal, nil)
        case .done(let result):
            switch result.status(of: address) {
            case .ok?:
                guard let ms = usage.averageMilliseconds else { return ("✓ OK", .good, nil) }
                return usage.isSlow ? ("Slow · \(time(ms))", .slow, nil) : ("✓ \(time(ms))", .good, nil)
            case .failed(let error)?:
                return ("✗ Failed", .failed, error)
            case nil:
                break
            }
        case .idle, .failed:
            break
        }
        guard let ms = usage.averageMilliseconds else { return ("Unknown", .normal, nil) }
        return (time(ms), usage.isSlow ? .slow : .normal, nil)
    }

    static func testFailed(_ category: RefreshFailureCategory) -> String {
        "AdGuard Home did not run the test (\(FailureText.text(category)))."
    }

    /// The note under the table, or `nil` when no server is slow.
    static func slowNote(_ slow: [(address: String, milliseconds: Double)], mode: AdGuardUpstreamMode?) -> String? {
        guard let first = slow.first else { return nil }
        if slow.count > 1 {
            return "\(slow.count) servers average over 0.5 s. Removing them may speed up first lookups."
        }
        let tail = mode == .loadBalance
            ? "With load balancing it’s rarely picked, but removing it may speed up first lookups."
            : "Removing it may speed up first lookups."
        return "\(first.address) averages \(time(first.milliseconds)). \(tail)"
    }
}
