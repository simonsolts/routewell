import Foundation
import Observation
import RoutewellKit

/// The details pane's live DNS feed for one client. The pane runs `follow`
/// in a view task, so a new client, a hidden pane, or Pause cancels it.
/// Pages come from AdGuard Home's query log, one bounded fetch at a time,
/// and are never saved.
@MainActor @Observable
final class ClientDNSController {
    enum Unavailable: Equatable {
        /// The client has no IP address to match query-log entries against.
        case noAddress
        /// No AdGuard Home is set up for this router.
        case notConfigured
    }

    struct Feed: Equatable {
        let mac: MACAddress
        /// Data from another router session is never shown.
        let token: SessionToken?
        var activity: ClientQueryActivity?
        var failure: RefreshFailureCategory?
        var unavailable: Unavailable?
        var loading = true
    }

    private(set) var feed: Feed?
    /// Pause in the header strip: the feed stops and keeps what it shows.
    var paused = false
    private let model: AppModel
    var visibleInterval: Duration = .seconds(5)
    var backgroundInterval: Duration = .seconds(30)
    /// Completed fetches, for tests.
    private(set) var fetchCount = 0

    init(model: AppModel) {
        self.model = model
    }

    func feed(for mac: MACAddress) -> Feed? {
        feed?.mac == mac && feed?.token == model.session.expectedToken ? feed : nil
    }

    /// Fetches until cancelled: every 5 s while DNS activity is the visible
    /// section, else every 30 s so the source-list badge stays current.
    func follow(mac: MACAddress, ip: String?, sectionVisible: Bool) async {
        let token = model.session.expectedToken
        if feed?.mac != mac || feed?.token != token { feed = Feed(mac: mac, token: token) }
        guard let ip else {
            feed?.unavailable = .noAddress
            feed?.loading = false
            return
        }
        feed?.unavailable = nil
        while !Task.isCancelled, !paused {
            await fetch(mac: mac, ip: ip)
            do { try await Task.sleep(for: sectionVisible ? visibleInterval : backgroundInterval) }
            catch { return }
        }
    }

    private func fetch(mac: MACAddress, ip: String) async {
        guard let lease = model.session.lease, model.session.isReady else { return }
        let result: AreaRefreshResult<QueryLogPage>?
        do {
            result = try await model.session.routerSession.recentQueries(using: lease, search: ip, limit: QueryLogLimits.maximum)
        } catch {
            // Cancelled, or the session changed: the result belongs to no one.
            return
        }
        guard !Task.isCancelled, model.session.expectedToken == lease.token, feed?.mac == mac, feed?.token == lease.token else { return }
        fetchCount += 1
        feed?.loading = false
        switch result {
        case nil:
            feed?.unavailable = .notConfigured
        case .success(let page, let observedAt, _)?:
            feed?.activity = ClientQueryActivity.summarize(page, clientIP: ip, fetchedAt: observedAt)
            feed?.failure = nil
        case .failure(let category, _)?:
            feed?.failure = category
        }
    }

    func clear() { feed = nil }
}
