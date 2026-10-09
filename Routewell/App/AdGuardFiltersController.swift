import Foundation
import Observation
import RoutewellKit

/// AdGuard Home › Filters (chunk 19): the segment, the selected list, the
/// lists that are downloading, the last Update Now count, and the custom
/// rules editor. The lists and rules come from `AdGuardController.filtering`
/// (live while running, else the saved copy); every write runs through its
/// setting executor.
@MainActor @Observable
final class AdGuardFiltersController {
    enum Segment: String, CaseIterable {
        case blocklists = "Blocklists"
        case allowlists = "Allowlists"
        case rules = "Custom rules"

        var kind: FilterListKind? {
            switch self {
            case .blocklists: .blocklist
            case .allowlists: .allowlist
            case .rules: nil
            }
        }
    }

    private let adGuard: AdGuardController
    private let refresh: RefreshController
    /// How long a new list may show "Downloading…" without rules.
    static let downloadWindow: TimeInterval = 90
    static let downloadPoll: Duration = .seconds(2)

    var segment: Segment = .blocklists {
        didSet { if segment != oldValue { selection = nil } }
    }
    /// The selected list's URL.
    var selection: String?
    /// Added or turned-on lists and when, until AdGuard Home has their rules.
    private(set) var downloading: [String: Date] = [:]
    /// The last Update Now: its list kind and AdGuard Home's `updated` count.
    private(set) var lastUpdate: (kind: FilterListKind, count: Int?)?
    /// Unsaved editor text; `nil` shows AdGuard Home's rules.
    private(set) var draft: String?
    /// The rules the draft started from; Save stops when AdGuard Home's
    /// rules are no longer these.
    private(set) var loadedRules: [String]?
    /// AdGuard Home's rules when Save found a change from elsewhere.
    var conflict: [String]?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?

    init(adGuard: AdGuardController, refresh: RefreshController) {
        self.adGuard = adGuard
        self.refresh = refresh
    }

    var status: AdGuardFilteringStatus? { adGuard.filtering }
    var canWrite: Bool { adGuard.availability == .running && !adGuard.isWriting }

    func lists(_ kind: FilterListKind) -> [AdGuardFilterList] { status?.lists(kind) ?? [] }

    // MARK: Lists

    func isDownloading(_ list: AdGuardFilterList, now: Date = .now) -> Bool {
        guard let url = list.url, let started = downloading[url], now.timeIntervalSince(started) < Self.downloadWindow else { return false }
        return list.lastUpdated == nil && (list.rulesCount ?? 0) == 0
    }

    var isUpdating: Bool {
        if case .updateLists? = adGuard.settingInFlight { true } else { false }
    }

    func setEnabled(_ list: AdGuardFilterList, kind: FilterListKind, enabled: Bool) {
        guard let url = list.url, let task = adGuard.startSetting(.listEnabled(kind, url: url, enabled: enabled)) else { return }
        // Turning on a list without rules makes AdGuard Home download it.
        let downloads = enabled && list.lastUpdated == nil && (list.rulesCount ?? 0) == 0
        Task {
            if case .verifiedSuccess? = await task.value?.outcome, downloads { self.startDownload(url) }
        }
    }

    /// Adds one list after another; stops at the first one that fails.
    func add(_ lists: [(name: String, url: String)], kind: FilterListKind) {
        guard canWrite, !lists.isEmpty else { return }
        Task {
            for list in lists {
                guard let task = adGuard.startSetting(.addList(kind, name: list.name, url: list.url)),
                      case .verifiedSuccess? = await task.value?.outcome else { return }
                if let url = FilterListURL.validated(list.url) { self.startDownload(url) }
            }
        }
    }

    /// The design removes at once, without a confirm (user, chunk 19).
    func removeSelected(kind: FilterListKind) {
        guard let url = selection, lists(kind).contains(where: { $0.url == url }),
              let task = adGuard.startSetting(.removeList(kind, url: url)) else { return }
        Task {
            if case .verifiedSuccess? = await task.value?.outcome, self.selection == url { self.selection = nil }
        }
    }

    func setInterval(_ hours: Int) {
        guard hours != status?.intervalHours else { return }
        adGuard.startSetting(.updateInterval(hours: hours))
    }

    func updateNow(kind: FilterListKind) {
        guard let task = adGuard.startSetting(.updateLists(kind)) else { return }
        lastUpdate = nil
        Task {
            if case .verifiedSuccess(.listsUpdated(let count, _))? = await task.value?.outcome {
                self.lastUpdate = (kind, count)
            }
        }
    }

    private func startDownload(_ url: String) {
        downloading[url] = .now
        guard downloadTask == nil else { return }
        // Read again every few seconds until each new list has its rules.
        downloadTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: Self.downloadPoll)
                let now = Date.now
                let lists = (self.status?.blocklists ?? []) + (self.status?.allowlists ?? [])
                self.downloading = self.downloading.filter { url, started in
                    now.timeIntervalSince(started) < Self.downloadWindow
                        && !lists.contains { $0.url == url && ($0.lastUpdated != nil || ($0.rulesCount ?? 0) > 0) }
                }
                if self.downloading.isEmpty { break }
                self.refresh.refreshNow()
            }
            self?.downloadTask = nil
        }
    }

    // MARK: Custom rules

    var serverRules: [String]? { status?.userRules }

    var rulesText: String {
        draft ?? CustomRulesText.text(serverRules ?? [])
    }

    var canEditRules: Bool { adGuard.availability == .running && serverRules != nil }

    func editRules(_ text: String) {
        guard canEditRules else { return }
        if draft == nil { loadedRules = serverRules }
        draft = text
    }

    var hasRuleChanges: Bool {
        guard let draft, let loadedRules else { return false }
        return CustomRulesText.rules(draft) != loadedRules
    }

    func revertRules() {
        draft = nil
        loadedRules = nil
    }

    func saveRules() {
        guard hasRuleChanges, let draft, let loadedRules,
              let task = adGuard.startSetting(.saveRules(CustomRulesText.rules(draft), loaded: loadedRules)) else { return }
        Task {
            switch await task.value?.outcome {
            case .verifiedSuccess?:
                // Only when nothing was typed while it saved.
                if self.draft == draft { self.revertRules() }
            case .conflictingExternalEdit(.rules(let actual))?:
                self.conflict = actual
            default:
                break
            }
        }
    }

    /// Conflict: drop the edits and show AdGuard Home's rules.
    func discardForConflict() {
        conflict = nil
        revertRules()
    }

    /// Conflict: keep the edits; the next Save replaces the rules AdGuard
    /// Home has now.
    func keepEditingAfterConflict() {
        if let conflict { loadedRules = conflict }
        conflict = nil
    }
}
