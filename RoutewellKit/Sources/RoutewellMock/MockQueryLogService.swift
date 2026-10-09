import Foundation
import RoutewellKit

/// Synthetic query log for the mock clients and the Query Log tab, anchored
/// to the current time so Live and the details pane's feed move. Every
/// domain, list, and upstream is a neutral sample.
public actor MockQueryLogService: QueryLogService {
    private var behavior: MockRouterBackend.FeatureBehavior = .supported
    /// The "Empty" Query Log scenario: AdGuard Home answers with no entries.
    private var empty = false

    public init() {}

    public func setBehavior(_ value: MockRouterBackend.FeatureBehavior) { behavior = value }
    public func setEmpty(_ value: Bool) { empty = value }

    public func probe() async -> Capability {
        let selected = behavior
        if selected == .slow {
            do { try await Task.sleep(for: .seconds(5)) }
            catch { return Capability() }
        }
        guard !Task.isCancelled else { return Capability() }
        switch selected {
        case .supported, .slow: return Capability(.supported, evidence: .mockScenario("supported"), observedAt: .now)
        case .unsupported: return Capability(.unsupported, evidence: .mockScenario("unsupported"), observedAt: .now)
        case .unknown, .failing: return Capability()
        }
    }

    public func recentQueries(search: String?, limit: Int) async throws -> AreaRefreshResult<QueryLogPage> {
        // The details pane searches by client IP and keeps exact matches.
        try await page(QueryLogQuery(search: search, limit: limit))
    }

    public func page(_ query: QueryLogQuery) async throws -> AreaRefreshResult<QueryLogPage> {
        try Task.checkCancellation()
        let selected = behavior
        if selected == .slow { try await Task.sleep(for: .seconds(5)) }
        let now = Date.now
        switch selected {
        case .unsupported: return .failure(.unavailable, attemptedAt: now)
        case .failing, .unknown: return .failure(.network, attemptedAt: now)
        case .supported, .slow: break
        }
        guard !empty else { return .success(QueryLogPage(entries: [], limit: query.limit), observedAt: now, source: .mock) }
        let olderThan = query.olderThan.flatMap(QueryLogParser.timestamp)
        var page: [QueryLogEntry] = []
        var oldest: Date?
        for index in 0..<Self.count {
            let entry = Self.entry(index, now: now)
            guard let time = entry.time else { continue }
            if let olderThan, time >= olderThan { continue }
            oldest = time
            guard Self.matches(entry, query) else { continue }
            page.append(entry)
            if page.count == query.limit { break }
        }
        let oldestText = oldest.map { $0.formatted(.iso8601) }
        return .success(QueryLogPage(entries: page, oldest: oldest, oldestText: oldestText, limit: query.limit), observedAt: now, source: .mock)
    }

    /// Like AdGuard Home: `search` matches the domain or the client, and
    /// `response_status` the result.
    static func matches(_ entry: QueryLogEntry, _ query: QueryLogQuery) -> Bool {
        if let search = query.search?.lowercased(),
           !(entry.domain?.lowercased().contains(search) == true || entry.client?.contains(search) == true) {
            return false
        }
        switch query.status {
        case .all: return true
        case .blocked: return entry.result == .blocked
        case .processed: return entry.result == .processed
        case .allowed: return entry.result == .allowed
        case .rewritten: return entry.result == .rewritten
        }
    }

    /// About two and a half days: every 5 s for the newest 2,000, then every
    /// 65 s, so Load More reaches yesterday and the 5,000 cap. 65 s is 13
    /// slots, so every client and kind of entry keeps its share.
    static let count = 5_600
    static let step: TimeInterval = 5

    static let clients = ["192.168.8.192", "192.168.8.150", "192.168.8.233", "192.168.8.199", "192.168.8.228",
                          "192.168.8.120", "192.168.8.105", "192.168.8.116", "192.168.8.20"]
    static let processed = ["time.example.com", "www.example.com", "api.example.net", "cdn.example.org",
                            "_dns-sd._udp.example.arpa", "mail.example.com", "updates.example.net"]
    static let blocked = ["ads.example.net", "tracker.example.com", "metrics.example.org", "banner.example.net"]
    static let upstreams = ["192.0.2.53:53", "https://dns.example.net/dns-query"]
    static let types = ["A", "AAAA", "HTTPS", "A", "A", "PTR"]

    /// Entry `index`, counted back from now. The same index keeps the same
    /// content, so Live adds rows at the top as time passes.
    static func entry(_ index: Int, now: Date) -> QueryLogEntry {
        let anchor = (now.timeIntervalSince1970 / step).rounded(.down) * step
        let offset = index < 2_000 ? Double(index) * step : 2_000 * step + Double(index - 2_000) * 65
        let time = Date(timeIntervalSince1970: anchor - offset)
        // Content follows the absolute slot, not the position from the top.
        let slot = Int((time.timeIntervalSince1970 / step).rounded(.down))
        let client = clients[slot % clients.count]
        let type = types[slot % types.count]
        var entry: QueryLogEntry
        switch slot % 11 {
        case 0, 4:
            let domain = blocked[slot % blocked.count]
            entry = QueryLogEntry(domain: domain, type: type, reason: "FilteredBlackList", elapsedMilliseconds: 0.21,
                                  cached: false, clientProtocol: "", rule: "||\(domain)^", filterID: slot % 2 + 1,
                                  responseCode: "NOERROR", answers: type == "A" ? ["0.0.0.0"] : [])
        case 7:
            entry = QueryLogEntry(domain: "media.example.org", type: type, reason: "FilteredBlockedService", elapsedMilliseconds: 0.18,
                                  cached: false, clientProtocol: "", rule: "||media.example.org^", filterID: -2,
                                  serviceName: "Example video", responseCode: "NOERROR")
        case 9:
            entry = QueryLogEntry(domain: "nas.example.lan", type: "A", reason: "Rewrite", elapsedMilliseconds: 0.12,
                                  cached: false, clientProtocol: "", responseCode: "NOERROR", answers: ["192.0.2.40"])
        case 10:
            entry = QueryLogEntry(domain: "login.example.com", type: type, reason: "NotFilteredWhiteList", upstream: upstreams[0],
                                  elapsedMilliseconds: 18, cached: false, clientProtocol: "", rule: "@@||login.example.com^",
                                  filterID: 0, responseCode: "NOERROR", answers: ["192.0.2.80"])
        default:
            let cached = slot % 3 == 0
            entry = QueryLogEntry(domain: processed[slot % processed.count], type: type, reason: "NotFilteredNotFound",
                                  upstream: cached ? nil : upstreams[slot % upstreams.count],
                                  elapsedMilliseconds: cached ? 0.3 : Double(8 + slot % 40), cached: cached,
                                  clientProtocol: slot % 5 == 0 ? "doh" : "", responseCode: "NOERROR",
                                  answers: type == "HTTPS" ? [] : ["192.0.2.\(10 + slot % 80)"])
        }
        entry.time = time
        entry.timeText = time.formatted(.iso8601)
        entry.client = client
        return entry
    }
}
