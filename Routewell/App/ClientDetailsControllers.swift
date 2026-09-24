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

/// Ping and Wake for one client. The mechanism comes from the backend:
/// `nil` hides the buttons, `.sshRequired` explains that SSH is needed and
/// sends nothing.
@MainActor @Observable
final class ClientActionsController {
    enum Action: String { case ping, wake }

    struct Status: Equatable {
        let mac: MACAddress
        let action: Action
        var text: String
        var tone: StatusTone
        var running: Bool
    }

    private(set) var status: Status?
    /// Set when a button needs SSH that is not set up; the screen shows
    /// `SSHRequiredView` for it.
    var sshRequiredAction: Action?
    /// Bumped when the mock mechanism changes, so views re-read it.
    private var revision = 0
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    var mechanism: ClientActionMechanism? {
        _ = revision
        return model.session.lease?.backend.clientActions?.mechanism
    }

    func mechanismChanged() { revision += 1 }

    func isRunning(_ mac: MACAddress) -> Bool { status?.mac == mac && status?.running == true }

    func status(for mac: MACAddress) -> Status? { status?.mac == mac ? status : nil }

    func ping(_ entry: ClientListEntry) {
        guard begin(.ping, entry) else { return }
        guard let ip = entry.client?.ip, let address = IPv4Literal(ip) else {
            finish(entry.mac, .ping, "This client has no IPv4 address to ping.", .unknown)
            return
        }
        guard let lease = model.session.lease else { return }
        let session = model.session.routerSession
        Task {
            let text: String
            let tone: StatusTone
            do {
                switch try await session.ping(using: lease, address: address) {
                case .success(let result)? where result.replied:
                    let average = result.averageMilliseconds.map { " · \($0.formatted(.number.precision(.fractionLength(1)))) ms average" } ?? ""
                    (text, tone) = ("Ping: replied to \(result.received) of \(result.transmitted)\(average).", .healthy)
                case .success(let result)?:
                    (text, tone) = ("Ping: no reply to \(result.transmitted) packets.", .degraded)
                case .failure(let category)?:
                    (text, tone) = ("Ping did not run. \(category.failureCategory.message)", .error)
                case nil:
                    (text, tone) = ("Ping is not available for this router.", .unknown)
                }
            } catch {
                (text, tone) = ("The router changed before the ping finished.", .unknown)
            }
            guard model.session.expectedToken == lease.token else { return }
            finish(entry.mac, .ping, text, tone)
        }
    }

    func wake(_ entry: ClientListEntry) {
        guard begin(.wake, entry) else { return }
        guard let lease = model.session.lease else { return }
        let session = model.session.routerSession
        Task {
            let text: String
            let tone: StatusTone
            do {
                switch try await session.wake(using: lease, mac: entry.mac)?.outcome {
                case .verifiedSuccess?:
                    (text, tone) = ("Wake-on-LAN packet sent. The device can take a minute to wake.", .healthy)
                case .rejected(.preconditionFailed(SSHClientActions.wakeToolMissing))?:
                    (text, tone) = ("The router has no Wake-on-LAN tool (etherwake or wol), so nothing was sent.", .degraded)
                case .rejected?:
                    (text, tone) = ("Wake did not run. Nothing was sent.", .unknown)
                case nil:
                    (text, tone) = ("Wake is not available for this router.", .unknown)
                default:
                    (text, tone) = ("The router may not have sent the packet. Check the device, then try again.", .degraded)
                }
            } catch {
                (text, tone) = ("The router changed during Wake. The packet may have been sent.", .unknown)
            }
            guard model.session.expectedToken == lease.token else { return }
            finish(entry.mac, .wake, text, tone)
        }
    }

    /// False when the action cannot start: another one is running for this
    /// client, or SSH is needed and not set up.
    private func begin(_ action: Action, _ entry: ClientListEntry) -> Bool {
        guard !isRunning(entry.mac), model.session.lease != nil, let mechanism else { return false }
        if mechanism == .sshRequired {
            sshRequiredAction = action
            return false
        }
        status = Status(mac: entry.mac, action: action, text: action == .ping ? "Pinging…" : "Sending Wake-on-LAN…",
                        tone: .inProgress, running: true)
        return true
    }

    private func finish(_ mac: MACAddress, _ action: Action, _ text: String, _ tone: StatusTone) {
        status = Status(mac: mac, action: action, text: text, tone: tone, running: false)
    }
}
