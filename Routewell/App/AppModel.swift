import Foundation
import Observation
import RoutewellKit

@MainActor @Observable
final class AppModel {
    var selection: SidebarDestination = .overview
    var subpages: [SidebarDestination: String] = [:]
    private(set) var snapshot: OverviewSnapshot?
    private(set) var isRefreshing = false
    private(set) var refreshFailed = false
    let session = SessionController()
    var slowMockRefresh = false
    var showInMenuBar = true { didSet { refreshSettingsChanged?() } }
    var refreshIntervalSeconds = 30 { didSet { refreshSettingsChanged?() } }
    var pauseWhenHidden = true { didSet { refreshSettingsChanged?() } }
    @ObservationIgnored var refreshSettingsChanged: (() -> Void)?
    var showStatusBar = true
    let mode: BackendMode

    init(mode: BackendMode, snapshot: OverviewSnapshot? = nil) {
        self.mode = mode
        self.snapshot = snapshot
    }

    func clearSession() {
        snapshot = nil
        isRefreshing = false
        refreshFailed = false
    }

    enum Completion {
        case snapshot(OverviewSnapshot), failure, busy(Bool)
    }

    func accept(_ completion: Completion, token: SessionToken) {
        guard session.isReady, token == session.expectedToken else { return }
        switch completion {
        case .snapshot(let value): snapshot = value
        case .failure: refreshFailed = true
        case .busy(let value):
            isRefreshing = value
            if value { refreshFailed = false }
        }
    }
}

enum BackendMode: Equatable {
    case mock, unconfigured, invalid

    static func resolve(_ value: String?, allowsMock: Bool) -> Self {
        switch value {
        case nil, "": .unconfigured
        case "mock" where allowsMock: .mock
        default: .invalid
        }
    }
}
