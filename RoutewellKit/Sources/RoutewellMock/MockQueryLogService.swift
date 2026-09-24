import Foundation
import RoutewellKit

/// Synthetic query-log pages for the mock clients, anchored to the current
/// time so the details pane's "live" feed moves. Domains follow the DNS
/// activity mockup.
public actor MockQueryLogService: QueryLogService {
    private var behavior: MockRouterBackend.FeatureBehavior = .supported

    public init() {}

    public func setBehavior(_ value: MockRouterBackend.FeatureBehavior) { behavior = value }

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
        try Task.checkCancellation()
        let selected = behavior
        if selected == .slow { try await Task.sleep(for: .seconds(5)) }
        let now = Date.now
        switch selected {
        case .unsupported: return .failure(.unavailable, attemptedAt: now)
        case .failing, .unknown: return .failure(.network, attemptedAt: now)
        case .supported, .slow: break
        }
        let entries = Self.clients
            .filter { search == nil || $0.ip == search }
            .flatMap { Self.entries(for: $0, now: now) }
            .sorted { ($0.time ?? .distantPast) > ($1.time ?? .distantPast) }
        let page = Array(entries.prefix(limit))
        return .success(QueryLogPage(entries: page, oldest: page.last?.time, limit: limit), observedAt: now, source: .mock)
    }

    private struct Source {
        let ip: String
        let count: Int
        let blockedEvery: Int
    }

    private static let clients: [Source] = [
        Source(ip: "192.168.8.192", count: 89, blockedEvery: 3),
        Source(ip: "192.168.8.150", count: 61, blockedEvery: 5),
        Source(ip: "192.168.8.233", count: 44, blockedEvery: 8),
        Source(ip: "192.168.8.199", count: 38, blockedEvery: 11),
        Source(ip: "192.168.8.228", count: 30, blockedEvery: 15),
        Source(ip: "192.168.8.120", count: 22, blockedEvery: 0),
        Source(ip: "192.168.8.105", count: 18, blockedEvery: 9),
        Source(ip: "192.168.8.116", count: 9, blockedEvery: 0),
        Source(ip: "192.168.8.20", count: 6, blockedEvery: 0),
    ]

    private static let allowed = [
        "_dns-push-tls._tcp.service.arpa", "_matter._tcp.default.service.arpa", "gateway.icloud.com",
        "_dns-push-tls._tcp.service.arpa", "_matter._tcp.default.service.arpa", "time.apple.com",
        "gateway.icloud.com", "www.apple.com", "api.apple-cloudkit.com",
    ]

    private static let blocked = [
        "app-analytics-services.com", "mask.icloud.com", "app-analytics-services.com", "googleads.g.doubleclick.net",
        "mask.icloud.com", "b79c66077e27a1c.us-east-1.prod.service.minerva.devices.a2z.com",
        "region1.app-analytics-services.com", "app-analytics-services.com", "googleads.g.doubleclick.net",
    ]

    private static func entries(for source: Source, now: Date) -> [QueryLogEntry] {
        // One query every 7 s, newest first, starting at the current 7 s step.
        let step: TimeInterval = 7
        let anchor = (now.timeIntervalSince1970 / step).rounded(.down) * step
        return (0..<source.count).map { index in
            let time = Date(timeIntervalSince1970: anchor - Double(index) * step)
            let isBlocked = source.blockedEvery > 0 && index % source.blockedEvery == 2
            let domain = isBlocked ? blocked[index % blocked.count] : allowed[index % allowed.count]
            return QueryLogEntry(time: time, client: source.ip, domain: domain,
                                 reason: isBlocked ? "FilteredBlackList" : "NotFilteredNotFound")
        }
    }
}
