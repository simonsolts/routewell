import Foundation
import AppKit
import Observation
import RoutewellKit

/// Router screen actions: the on-demand firmware check, the local
/// pre-upgrade baseline and post-upgrade check (`snapshots.json`), Copy
/// Summary, and Open in Router UI. Nothing here writes to the router, and
/// Routewell never installs firmware.
@MainActor @Observable
final class RouterController {
    struct FirmwareState: Equatable {
        /// A check from another router session is never shown.
        let token: SessionToken
        var check: FirmwareCheck?
        var checking = false
    }

    enum SnapshotIssue: Equatable {
        case notSaved, blocked, nothingObserved
        var message: String {
            switch self {
            case .notSaved: "The baseline could not be saved. Try again."
            case .blocked: "Saved baselines were written by a newer app or cannot be read, so nothing is saved."
            case .nothingObserved: "No router state has been observed yet. Refresh, then try again."
            }
        }
    }

    private(set) var firmwareState: FirmwareState?
    private(set) var snapshots = UpgradeSnapshots()
    private(set) var snapshotIssue: SnapshotIssue?
    private(set) var lastCopied: String?
    private let model: AppModel
    private let baselines: UpgradeBaselineStore
    private let clock: @MainActor () -> Date
    /// The router's web interface for the active profile; `nil` in mock mode.
    var routerURL: @MainActor () -> URL? = { nil }

    init(model: AppModel, baselines: UpgradeBaselineStore, clock: @escaping @MainActor () -> Date = { Date() }) {
        self.model = model
        self.baselines = baselines
        self.clock = clock
    }

    func load() async {
        switch await baselines.load() {
        case .blocked: snapshotIssue = .blocked
        case .empty, .loaded, .recovered: snapshotIssue = nil
        }
        snapshots = await baselines.snapshot()
    }

    // MARK: Firmware

    /// The check for the current session only.
    var firmware: FirmwareState? {
        firmwareState?.token == model.session.expectedToken ? firmwareState : nil
    }

    func checkForUpdates() async {
        guard let lease = model.session.lease, model.session.isReady, firmware?.checking != true else { return }
        firmwareState = FirmwareState(token: lease.token, check: firmware?.check, checking: true)
        let check: FirmwareCheck?
        do {
            check = try await model.session.routerSession.checkFirmware(using: lease)
        } catch {
            // Cancelled, or the session changed: the result belongs to no one.
            if firmwareState?.token == lease.token { firmwareState?.checking = false }
            return
        }
        guard model.session.expectedToken == lease.token, firmwareState?.token == lease.token else { return }
        firmwareState = FirmwareState(token: lease.token, check: check ?? FirmwareCheck(status: .unableToCheck(.notSupported), checkedAt: clock()), checking: false)
    }

    // MARK: Upgrade baseline

    private var routerKey: String? { model.session.expectedToken?.profileID }

    var baseline: UpgradeBaseline? { routerKey.flatMap { snapshots.baselines[$0] } }
    var postUpgradeCheck: PostUpgradeCheck? { routerKey.flatMap { snapshots.checks[$0] } }

    /// Captures the observed state now. Saved to `snapshots.json` only.
    func saveBaseline() async {
        guard let key = routerKey, let token = model.session.expectedToken else { return }
        guard let snapshot = model.snapshot, model.freshness[.router]?.lastSuccess != nil else {
            snapshotIssue = .nothingObserved
            return
        }
        let baseline = UpgradeBaseline(capturedAt: clock(), state: RouterStateSummary.capture(snapshot, wireless: model.wireless))
        let failure = await baselines.saveBaseline(baseline, for: key)
        guard model.session.expectedToken == token else { return }
        snapshotIssue = Self.issue(for: failure)
        snapshots = await baselines.snapshot()
    }

    /// Compares the current observed state with the saved baseline.
    func runPostUpgradeCheck() async {
        guard let key = routerKey, let token = model.session.expectedToken, let baseline, let snapshot = model.snapshot else { return }
        let check = PostUpgradeCheck.compare(baseline, current: RouterStateSummary.capture(snapshot, wireless: model.wireless), at: clock())
        let failure = await baselines.recordCheck(check, for: key)
        guard model.session.expectedToken == token else { return }
        snapshotIssue = Self.issue(for: failure)
        snapshots = await baselines.snapshot()
    }

    private static func issue(for failure: StoreError?) -> SnapshotIssue? {
        switch failure {
        case nil: nil
        case .futureSchema?, .readFailed?: .blocked
        case .corrupt?, .writeFailed?: .notSaved
        }
    }

    // MARK: Copy and open

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        lastCopied = text
    }

    func openRouterUI() {
        guard let url = routerURL() else { return }
        NSWorkspace.shared.open(url)
    }
}
