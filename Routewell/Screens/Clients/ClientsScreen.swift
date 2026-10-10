import SwiftUI
import RoutewellKit

/// Clients: All Clients (table, filter row, status line, details pane). The
/// segmented control and Refresh live in `MainWindow`'s toolbar; this view
/// adds the search field and the details-pane toggle.
struct ClientsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""

    var body: some View {
        @Bindable var model = model
        AllClientsView(search: search)
            .searchable(text: $search, placement: .toolbar, prompt: "Search clients")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.clientsDetailsVisible.toggle()
                    } label: {
                        Label(model.clientsDetailsVisible ? "Hide Details" : "Show Details",
                              systemImage: "rectangle.bottomthird.inset.filled")
                    }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(model.clientsDetailsVisible ? Color.accentColor : Color.secondary)
                    .help(model.clientsDetailsVisible ? "Hide the details pane" : "Show the details pane")
                    .accessibilityValue(model.clientsDetailsVisible ? "Shown" : "Hidden")
                }
            }
    }
}

/// The shared "no data yet" states.
struct ClientsUnavailableView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        if model.capabilities[.clients]?.state == .unsupported {
            FeatureUnavailableView(title: "Clients", capability: model.capabilities[.clients] ?? Capability())
        } else if model.session.lease == nil && !model.session.switching {
            ContentUnavailableView("No router connected", systemImage: "wifi.router",
                                   description: Text("Connect a router to see its clients."))
        } else if let failure = model.clientsFreshness.failure {
            ContentUnavailableView {
                Label("Client list unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(failure.failureCategory.message)
            } actions: {
                Button("Refresh") { environment.refresh.refreshNow() }
                    .disabled(!environment.refresh.isAvailable || model.isRefreshing)
            }
        } else {
            ProgressView("Loading clients…")
        }
    }
}
