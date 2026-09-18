import Foundation
import Observation
import RoutewellKit

@MainActor @Observable
final class AppModel {
    var selection: SidebarDestination = .overview
    var subpages: [SidebarDestination: String] = [:]
    var snapshot: OverviewSnapshot?
    var isRefreshing = false
    var refreshFailed = false
    var showInMenuBar = true
    var showStatusBar = true
    let mode: BackendMode

    init(mode: BackendMode, snapshot: OverviewSnapshot? = nil) {
        self.mode = mode
        self.snapshot = snapshot
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
