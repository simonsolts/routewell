import SwiftUI
import RoutewellKit

struct FeatureUnavailableView: View {
    let title: String
    let capability: Capability

    static func explanation(for state: CapabilityState) -> String? {
        switch state {
        case .supported: nil
        case .unsupported: "This router does not support this feature."
        case .unknown: "Availability is unknown. Refresh after the router responds."
        }
    }

    var body: some View {
        switch capability.state {
        case .supported:
            EmptyView()
        case .unsupported:
            ContentUnavailableView(title, systemImage: "minus.circle",
                description: Text(Self.explanation(for: .unsupported)!))
        case .unknown:
            ContentUnavailableView(title, systemImage: "questionmark.circle",
                description: Text(Self.explanation(for: .unknown)!))
        }
    }
}

struct SSHRequiredView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    let title: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "terminal")
        } description: {
            Text("This feature needs SSH, which is not set up for this router.")
        } actions: {
            Button("Open Router Settings") {
                model.settingsTab = "Router"
                openSettings()
            }
        }
    }
}
