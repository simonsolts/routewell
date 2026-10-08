import SwiftUI
import RoutewellKit

/// AdGuard Home › Instance, parts 1 and 2: the header card with Restart and
/// Stop…, and "On this router". Software update, Backups, and Data follow in
/// chunk 19B. While the tabs show the saved copy, only the AdGuard Home
/// switch stays enabled, and only to turn it on.
struct AdGuardInstanceView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppEnvironment.self) private var environment
    @State private var confirmingStop = false

    private var adGuard: AdGuardController { environment.adGuard }
    private var availability: AdGuardAvailability { adGuard.availability }
    private var busy: Bool { adGuard.inFlight != nil || !model.session.isReady }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if let report = adGuard.lastReport, let intent = adGuard.lastIntent,
                   let text = AdGuardPresentation.outcomeText(intent, report.outcome) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
                        Text(text).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Refresh") { environment.refresh.refreshNow() }.controlSize(.small)
                    }
                    .padding(12)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.5))
                }
                onThisRouter
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 28)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .alert("Turn off AdGuard Home?", isPresented: $confirmingStop) {
            Button("Turn Off", role: .destructive) { adGuard.run(.turnOff) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Devices go back to the router’s normal DNS and ads won’t be blocked. Your settings, stats and log are kept.")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ShieldTile(size: 52, colors: availability == .running
                       ? [Color(red: 0.43, green: 0.84, blue: 0.51), Color(red: 0.16, green: 0.69, blue: 0.29)]
                       : [Color(red: 0.75, green: 0.75, blue: 0.76), Color(red: 0.59, green: 0.59, blue: 0.61)])
            VStack(alignment: .leading, spacing: 2) {
                Text("AdGuard Home").font(.title3.weight(.semibold))
                HStack(spacing: 6) {
                    StatusDot(tone: AdGuardPresentation.sidebarTone(availability, protection: nil) ?? .unknown)
                    Text(AdGuardPresentation.instanceLine(availability, status: adGuard.status,
                                                          sshConfigured: model.sshConfigured, now: model.evaluatedAt))
                        .lineLimit(1).truncationMode(.tail)
                }
                .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if case .restart? = adGuard.inFlight { ProgressView().controlSize(.small) }
            Button("Restart") { adGuard.run(.restart) }
                .disabled(availability.isReadOnly || busy)
            Button("Stop…") { confirmingStop = true }
                .disabled(availability.isReadOnly || busy)
        }
        .padding(16)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    private var onThisRouter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("On this router").font(.headline).padding(.horizontal, 2)
            VStack(spacing: 0) {
                switchRow(title: "AdGuard Home",
                          detail: "When off, the service stops. Stats and the query log stay viewable here, read-only.",
                          isOn: Binding(get: { enabledSwitch }, set: setEnabled),
                          disabled: busy || !(availability == .running || availability == .cached))
                Divider()
                switchRow(title: "Handle DNS requests from devices",
                          detail: "Turn off to protect only devices you set up by hand.",
                          isOn: Binding(get: { handlesDNSSwitch }, set: { adGuard.run(.setHandlesDNS($0)) }),
                          disabled: availability.isReadOnly || busy || adGuard.handlesDNS == nil)
            }
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 1))
        }
    }

    /// While a write runs, the switch shows where it is going.
    private var enabledSwitch: Bool {
        switch adGuard.inFlight {
        case .turnOn?, .restart?: true
        case .turnOff?: false
        default: availability == .running
        }
    }

    private var handlesDNSSwitch: Bool {
        if case .setHandlesDNS(let value)? = adGuard.inFlight { return value }
        return adGuard.handlesDNS ?? false
    }

    /// Off asks first; on is Turn On with the saved Handle DNS setting.
    private func setEnabled(_ value: Bool) {
        if value {
            adGuard.run(.turnOn(handlesDNS: adGuard.handlesDNS ?? true))
        } else {
            confirmingStop = true
        }
    }

    private func switchRow(title: String, detail: String, isOn: Binding<Bool>, disabled: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle(title, isOn: isOn).toggleStyle(.switch).labelsHidden().disabled(disabled)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }
}
