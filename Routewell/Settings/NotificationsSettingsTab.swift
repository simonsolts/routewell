import SwiftUI

struct NotificationsSettingsTab: View {
    var body: some View {
        Form {
            Section {
                Toggle("New devices", isOn: .constant(false))
                Toggle("Internet outages", isOn: .constant(false))
                Toggle("Operation finished", isOn: .constant(false))
                Toggle("Protection changed", isOn: .constant(false))
                Toggle("Show in Notification Center", isOn: .constant(false))
            }.disabled(true)
            Text("Notifications are not available yet. This build does not request notification permission.")
                .foregroundStyle(.secondary)
        }
    }
}
