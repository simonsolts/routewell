import SwiftUI
import RoutewellKit

/// AdGuard Home (chunk 16): the empty state when it is off with no saved
/// copy, else the five tabs, read-only under a strip when AdGuard Home is
/// off or does not answer. The toolbar's tab bar lives in `MainWindow`.
struct AdGuardScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let adGuard = environment.adGuard
        let availability = adGuard.availability
        Group {
            switch availability {
            case .unknown:
                ProgressView("Checking AdGuard Home…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .off:
                AdGuardEmptyStateView()
            case .unreachable(let problem) where adGuard.archive == nil:
                AdGuardUnreachableView(problem: problem)
            case .running, .cached, .unreachable:
                VStack(spacing: 0) {
                    if let strip = AdGuardPresentation.strip(availability, archive: adGuard.archive) {
                        AdGuardReadOnlyStrip(strip: strip)
                    }
                    tabBody.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var tabBody: some View {
        switch AdGuardTab(rawValue: model.subpages[.adGuard] ?? "") ?? .overview {
        case .overview: AdGuardOverviewView()
        case .instance: AdGuardInstanceView()
        case .queryLog:
            // Read live only; there is no saved copy of the log.
            if environment.adGuard.availability == .running {
                AdGuardQueryLogView()
            } else {
                QueryLogUnavailableView(availability: environment.adGuard.availability)
            }
        case let tab: AdGuardPlaceholderTab(tab: tab)
        }
    }
}

/// Lock, title, saved date, and one action, under the toolbar.
struct AdGuardReadOnlyStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openSettings) private var openSettings
    let strip: AdGuardPresentation.Strip

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock").foregroundStyle(.secondary).accessibilityHidden(true)
            Text(strip.title).fontWeight(.semibold)
            Text(strip.message).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            switch strip.action {
            case .turnOn:
                Button("Turn On") {
                    environment.adGuard.run(.turnOn(handlesDNS: environment.adGuard.handlesDNS ?? true))
                }
                .controlSize(.small)
                .disabled(environment.adGuard.inFlight != nil)
            case .openRouterSettings:
                Button("Open Router Settings") { SSHRequiredView.openRouterSettings(model, open: { openSettings() }) }
                    .controlSize(.small)
            }
            if environment.adGuard.inFlight != nil { ProgressView().controlSize(.small) }
        }
        .font(.callout)
        .lineLimit(1)
        .padding(.horizontal, 16).padding(.vertical, 7)
        .background(.quaternary.opacity(0.5))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }
}

/// On (or not readable) and no saved copy: nothing to show read-only.
struct AdGuardUnreachableView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openSettings) private var openSettings
    let problem: AdGuardProblem

    var body: some View {
        ContentUnavailableView {
            Label(AdGuardPresentation.problemTitle(problem), systemImage: "exclamationmark.shield")
        } description: {
            Text("Routewell has no saved copy of AdGuard Home's data for this router yet.")
        } actions: {
            Button("Open Router Settings") { SSHRequiredView.openRouterSettings(model, open: { openSettings() }) }
            Button("Refresh") { environment.refresh.refreshNow() }
        }
    }
}

/// A tab whose chunk has not landed yet (19, 19A).
struct AdGuardPlaceholderTab: View {
    let tab: AdGuardTab

    var body: some View {
        ContentUnavailableView {
            Label(tab.rawValue, systemImage: "shield")
        } description: {
            Text("This tab is not available yet.")
        }
    }
}
