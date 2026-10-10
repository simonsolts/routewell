import Foundation
import Observation
import RoutewellKit

/// AdGuard Home › Query Log: a live view of AdGuard Home's own
/// log. The tab runs `follow` in a view task while it is visible and
/// AdGuard Home runs; a new search, status, session, or Refresh restarts it
/// from page one. Nothing is saved.
@MainActor @Observable
final class QueryLogController {
    enum Phase: Equatable {
        case idle, loading, loaded
        case failed(RefreshFailureCategory)
        /// No AdGuard Home connection for this router.
        case notConfigured
    }

    /// The applied search and status. The view task restarts when it changes.
    struct Filter: Hashable {
        var search: String?
        var status: QueryLogStatusFilter = .all
    }

    private let model: AppModel
    private(set) var filter = Filter()
    /// The search field's text; applied with `applySearch`.
    var searchText = ""
    private(set) var browser = QueryLogBrowser()
    private(set) var phase: Phase = .idle
    private(set) var loadingMore = false
    private(set) var moreFailure: RefreshFailureCategory?
    /// Pages from another router session are never shown.
    private var token: SessionToken?
    var selection: QueryLogEntry.ID?
    /// The table shows its first rows; Live adds rows only then.
    var isAtTop = true
    var liveInterval: Duration = .seconds(3)
    /// Live reads made, for tests.
    private(set) var liveReads = 0
    /// Goes up when page one starts loading or the tab closes. A read from
    /// an older generation changes nothing.
    private var generation = 0

    init(model: AppModel) {
        self.model = model
    }

    /// The loaded entries, for this session only.
    var entries: [QueryLogEntry] {
        token == model.session.expectedToken ? browser.entries : []
    }

    var selectedEntry: QueryLogEntry? {
        guard let selection else { return nil }
        return entries.first { $0.id == selection }
    }

    var isFiltered: Bool { filter.search != nil || filter.status != .all }

    /// Live runs: page one is shown, no filter is set, and the list is at the top.
    var isLive: Bool { phase == .loaded && !isFiltered && isAtTop }

    /// Live pauses while Load More reads, so the older page always fits.
    private var readsLive: Bool { isLive && !loadingMore }

    // MARK: Filters

    /// The search field's text becomes the server-side search.
    func applySearch() {
        let query = QueryLogQuery(search: searchText, limit: 1)
        filter.search = query.search
    }

    func setStatus(_ status: QueryLogStatusFilter) {
        filter.status = status
    }

    func clear() {
        searchText = ""
        filter = Filter()
    }

    /// Show Only This Client, Top devices, Clients' Show DNS Log: the
    /// client's IP goes in the search field. The status stays.
    func search(for text: String) {
        searchText = text
        applySearch()
    }

    /// A hand-off from the Overview or Clients opens the tab searching for
    /// it, with all statuses.
    func open(_ handoff: AdGuardQueryLogFilter) {
        searchText = handoff.search
        filter = Filter(search: QueryLogQuery(search: handoff.search, limit: 1).search)
    }

    // MARK: Reading

    /// Page one, then a Live read every 3 s while `isLive`, until cancelled.
    func follow() async {
        await loadFirstPage()
        while !Task.isCancelled {
            do { try await Task.sleep(for: liveInterval) } catch { return }
            guard readsLive else { continue }
            await readLive()
        }
    }

    /// Leaving the tab drops the loaded pages.
    func stop() {
        generation += 1
        browser = QueryLogBrowser(search: filter.search, status: filter.status)
        phase = .idle
        loadingMore = false
        moreFailure = nil
        selection = nil
        token = nil
    }

    func loadFirstPage() async {
        let fresh = QueryLogBrowser(search: filter.search, status: filter.status)
        // The rows stay until page one arrives, unless the filter changed.
        if browser.search != fresh.search || browser.status != fresh.status || token != model.session.expectedToken {
            browser = fresh
            selection = nil
        }
        generation += 1
        phase = .loading
        loadingMore = false
        moreFailure = nil
        guard let (page, lease) = await read(fresh.firstPageQuery, generation: generation) else { return }
        var loaded = fresh
        loaded.replace(with: page)
        browser = loaded
        token = lease
        phase = .loaded
        if let selection, !loaded.entries.contains(where: { $0.id == selection }) { self.selection = nil }
    }

    func loadMore() async {
        guard !loadingMore, phase == .loaded, let query = browser.nextPageQuery else { return }
        loadingMore = true
        moreFailure = nil
        let started = generation
        defer { if generation == started { loadingMore = false } }
        guard let (page, lease) = await read(query, generation: started,
                                             failure: { [weak self] in self?.moreFailure = $0 }) else { return }
        // A reload, a new filter, or Close during the read wins.
        guard lease == token else { return }
        browser.append(page)
    }

    private func readLive() async {
        let expected = browser
        guard let (page, lease) = await read(QueryLogBrowser.liveQuery, generation: generation, failure: { _ in }) else { return }
        liveReads += 1
        guard browser == expected, lease == token, readsLive else { return }
        if browser.mergeLive(page) == .reloadNeeded { await loadFirstPage() }
    }

    /// One fenced read. `nil` when cancelled, the session or generation
    /// changed, or the read failed (`failure` gets the category; by default
    /// it fails page one).
    private func read(_ query: QueryLogQuery, generation: Int,
                      failure: ((RefreshFailureCategory) -> Void)? = nil) async -> (QueryLogPage, SessionToken)? {
        guard let lease = model.session.lease, model.session.isReady else { return nil }
        let result: AreaRefreshResult<QueryLogPage>?
        do {
            result = try await model.session.routerSession.queryLogPage(using: lease, query: query)
        } catch {
            // Cancelled, or the session changed: the result belongs to no one.
            return nil
        }
        guard !Task.isCancelled, model.session.expectedToken == lease.token, generation == self.generation else { return nil }
        switch result {
        case nil:
            if failure == nil { phase = .notConfigured }
            return nil
        case .failure(let category, _)?:
            if let failure { failure(category) } else { phase = .failed(category) }
            return nil
        case .success(let page, _, _)?:
            return (page, lease.token)
        }
    }
}
