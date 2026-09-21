import SwiftUI
import AppKit
import RoutewellKit

struct LogsScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(AppEnvironment.self) private var environment
    @State private var exportMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Session diagnostics").font(.title2.weight(.semibold))
                Spacer()
                Button("Copy redacted JSON", systemImage: "doc.on.doc") { copyExport() }
                    .disabled(model.logEvents.isEmpty)
                Button("Clear", role: .destructive) { environment.logging.clear() }
                    .disabled(model.logEvents.isEmpty)
            }
            Text("Only sanitized, session-only events appear here. Router responses, credentials, addresses, and request details are never retained.")
                .foregroundStyle(.secondary)
            if let exportMessage { Text(exportMessage).font(.caption).foregroundStyle(.secondary) }
            if model.logEvents.isEmpty {
                ContentUnavailableView("No session events", systemImage: "doc.text",
                                       description: Text("Events from this app session will appear here."))
            } else {
                List(model.logEvents.reversed()) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(event.message)
                            Spacer()
                            Text(event.level.rawValue.capitalized).foregroundStyle(tint(event.level))
                        }
                        Text(event.occurredAt.formatted(date: .omitted, time: .standard))
                            .font(.caption).foregroundStyle(.secondary)
                        if !event.fields.isEmpty {
                            Text(event.fields.map { "\($0.key): \($0.value)" }.sorted().joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 3)
                }.listStyle(.inset)
            }
        }.padding(20)
    }

    private func copyExport() {
        Task {
            do {
                let data = try await environment.logging.export()
                let text = String(decoding: data, as: UTF8.self)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                exportMessage = "Redacted JSON copied to the clipboard."
            } catch { exportMessage = FailureCategory.privacyDenied.message }
        }
    }

    private func tint(_ level: LogEvent.Level) -> Color {
        switch level { case .info: .secondary; case .warning: .orange; case .error: .red }
    }
}
