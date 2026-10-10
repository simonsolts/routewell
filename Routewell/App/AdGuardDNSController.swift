import Foundation
import Observation
import RoutewellKit

/// State and actions for the DNS tab. Edits are staged: they stay until
/// Apply or Revert, across refreshes and tab changes.
@MainActor @Observable
final class AdGuardDNSController {
    enum TestState: Equatable {
        case idle
        case testing
        case done(UpstreamTestResult)
        case failed(RefreshFailureCategory)
    }

    private let adGuard: AdGuardController

    /// The settings with the edits; `nil` when nothing is staged.
    private(set) var staged: AdGuardDNSSettings?
    /// What AdGuard Home had when the first edit was made.
    private(set) var loaded: AdGuardDNSSettings?
    /// The selected upstream line, by index.
    var selection: Int?
    private var testRun: (request: UpstreamTestRequest, state: TestState)?
    private(set) var cacheCleared = false

    init(adGuard: AdGuardController) {
        self.adGuard = adGuard
    }

    /// Another router: its settings are not this one's edits.
    func reset() {
        staged = nil
        loaded = nil
        selection = nil
        testRun = nil
        cacheCleared = false
    }

    var server: AdGuardDNSSettings? { adGuard.dnsSettings }
    /// Read-only shows AdGuard Home's values; staged edits wait for it.
    var settings: AdGuardDNSSettings? { isReadOnly ? server : staged ?? server }
    var stats: AdGuardStats? { adGuard.stats?.value }
    var isReadOnly: Bool { adGuard.availability.isReadOnly }
    var canEdit: Bool { adGuard.availability == .running && server != nil }

    var changes: [String: JSONValue] {
        guard let staged, let loaded else { return [:] }
        return staged.changes(from: loaded)
    }

    var hasChanges: Bool { !changes.isEmpty }

    var isApplying: Bool {
        if case .dns? = adGuard.settingInFlight { true } else { false }
    }

    var canApply: Bool {
        hasChanges && canEdit && !adGuard.isWriting && settings?.problem == nil
    }

    func edit(_ change: (inout AdGuardDNSSettings) -> Void) {
        guard canEdit, var next = staged ?? server else { return }
        if staged == nil { loaded = server }
        change(&next)
        staged = next
        if !hasChanges {
            staged = nil
            loaded = nil
        }
    }

    // MARK: Upstreams

    var upstreamLines: [UpstreamLine] { (settings?.upstreams ?? []).map(UpstreamLine.init) }

    func addUpstream(_ address: String) {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        edit { $0.upstreams = ($0.upstreams ?? []) + [trimmed] }
    }

    func removeSelectedUpstream() {
        guard let selection, upstreamLines.indices.contains(selection) else { return }
        edit { $0.upstreams?.remove(at: selection) }
        self.selection = nil
    }

    /// Only for the lists as they are now.
    var test: TestState {
        guard let testRun, testRun.request == testRequest else { return .idle }
        return testRun.state
    }

    private var testRequest: UpstreamTestRequest? {
        settings.map { UpstreamTestRequest(upstreams: $0.upstreams ?? [], bootstrap: $0.bootstrap ?? [], fallback: $0.fallback ?? []) }
    }

    func runTest() {
        guard let request = testRequest, test != .testing, adGuard.availability == .running else { return }
        testRun = (request, .testing)
        Task {
            let state: TestState = switch await adGuard.testUpstreams(request) {
            case .success(let result)?: .done(result)
            case .failure(let category)?: .failed(category)
            case nil: .idle
            }
            if self.testRun?.request == request { self.testRun = (request, state) }
        }
    }

    // MARK: Apply, Revert, Clear Cache

    func apply() {
        guard canApply, let staged else { return }
        let sent = staged
        guard let task = adGuard.startSetting(.dns(changes: changes)) else { return }
        Task {
            switch await task.value?.outcome {
            case .verifiedSuccess(.dns(let now))?, .verifiedMismatch(_, .dns(let now))?:
                self.keepEdits(madeSince: sent, on: now)
            default:
                break
            }
        }
    }

    /// Edits made while Apply ran, on top of what AdGuard Home has now.
    private func keepEdits(madeSince sent: AdGuardDNSSettings, on now: AdGuardDNSSettings) {
        guard let staged, staged != sent else { return revert() }
        loaded = now
        self.staged = now.applying(staged.changes(from: sent))
        if !hasChanges { revert() }
    }

    func revert() {
        staged = nil
        loaded = nil
        selection = nil
    }

    /// Revert, then read AdGuard Home again.
    func revertAndReload() {
        revert()
        Task { _ = await adGuard.refreshOverviewNow() }
    }

    func clearCache() {
        guard let task = adGuard.startSetting(.clearDNSCache) else { return }
        cacheCleared = false
        Task {
            if case .verifiedSuccess? = await task.value?.outcome { self.cacheCleared = true }
        }
    }
}
