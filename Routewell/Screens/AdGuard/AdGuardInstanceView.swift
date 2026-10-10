import AppKit
import SwiftUI
import RoutewellKit

/// AdGuard Home › Instance: the header card with Restart and Stop…, "On
/// this router", Software update, Backups, and Data. While the tabs show
/// the saved copy, the AdGuard Home switch stays enabled only to turn it
/// on, and the backups list and Export… still work.
struct AdGuardInstanceView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppEnvironment.self) private var environment
    @State private var confirmingStop = false
    @State private var confirmingRestore: AdGuardBackup?
    @State private var confirmingClear: AdGuardDataKind?

    private var adGuard: AdGuardController { environment.adGuard }
    private var instance: AdGuardInstanceController { environment.instance }
    private var availability: AdGuardAvailability { adGuard.availability }
    private var busy: Bool { adGuard.inFlight != nil || !model.session.isReady || instance.activity != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                ForEach(problems, id: \.self) { text in
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
                softwareUpdate
                backupsSection
                dataSection
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 28)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .task(id: adGuard.profileID()) { await instance.load() }
        .task(id: availability == .running) { await adGuard.loadVersionCheck() }
        .alert("Turn off AdGuard Home?", isPresented: $confirmingStop) {
            Button("Turn Off", role: .destructive) { adGuard.run(.turnOff) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Devices go back to the router’s normal DNS and ads won’t be blocked. Your settings, stats and log are kept.")
        }
        .alert(AdGuardInstancePresentation.restoreTitle, isPresented: Binding(
            get: { confirmingRestore != nil }, set: { if !$0 { confirmingRestore = nil } }
        ), presenting: confirmingRestore) { backup in
            Button("Restore", role: .destructive) { instance.restore(backup) }
            Button("Cancel", role: .cancel) {}
        } message: { backup in
            Text(AdGuardInstancePresentation.restoreMessage(backup, now: model.evaluatedAt))
        }
        .alert(confirmingClear.map(AdGuardInstancePresentation.clearTitle) ?? "", isPresented: Binding(
            get: { confirmingClear != nil }, set: { if !$0 { confirmingClear = nil } }
        ), presenting: confirmingClear) { kind in
            Button(AdGuardInstancePresentation.clearAction(kind), role: .destructive) { instance.clear(kind) }
            Button("Cancel", role: .cancel) {}
        } message: { kind in
            Text(AdGuardInstancePresentation.clearMessage(kind))
        }
    }

    /// The last write's problem, if any: the service, a Data write, or a
    /// backup or restore.
    private var problems: [String] {
        var texts: [String] = []
        if let report = adGuard.lastReport, let intent = adGuard.lastIntent,
           let text = AdGuardPresentation.outcomeText(intent, report.outcome) { texts.append(text) }
        if let report = adGuard.lastSettingReport, let intent = adGuard.lastSettingIntent, intent.isInstanceWrite,
           let text = AdGuardPresentation.settingOutcomeText(intent, report.outcome) { texts.append(text) }
        if let message = instance.message { texts.append(message) }
        return texts
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
                    Text(AdGuardPresentation.instanceLine(availability, status: adGuard.status, sshConfigured: model.sshConfigured,
                                                          memory: model.adGuardResources?.memoryBytes ?? .unknown, now: model.evaluatedAt))
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
        section("On this router") {
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
    }

    // MARK: Software update

    private var softwareUpdate: some View {
        let update = AdGuardInstancePresentation.update(adGuard.versionCheck, current: adGuard.status?.version)
        return VStack(alignment: .leading, spacing: 6) {
            section("Software update") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(update.title).fontWeight(.semibold)
                            Text(update.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        Button {
                            NSWorkspace.shared.open(AdGuardInstancePresentation.updaterGuide)
                        } label: {
                            Label("Open Updater Guide", systemImage: "arrow.up.right").labelStyle(TrailingIconLabelStyle())
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    howItWorks
                }
                .padding(12)
            }
            Text(AdGuardInstancePresentation.updaterCredit).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 2)
        }
    }

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How it works").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            step(1, "Back up your settings.")
            step(2, "Run the updater on the router.", body: "The guide has a one-line SSH command.")
            step(3, "Come back here.")
            HStack(spacing: 8) {
                Button("Back Up Now") { instance.backUp() }
                    .controlSize(.small)
                    .disabled(!instance.canChange)
                Text(AdGuardInstancePresentation.lastBackup(instance.backups, now: model.evaluatedAt))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func step(_ number: Int, _ title: String, body: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.caption2.weight(.semibold))
                .frame(width: 18, height: 18)
                .background(Color.secondary.opacity(0.2), in: Circle())
            Text(title).fontWeight(.medium)
            if let body { Text(body).foregroundStyle(.secondary) }
        }
    }

    // MARK: Backups

    private var backupsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Backups").font(.headline)
                Spacer()
                if instance.activity == .backingUp { ProgressView().controlSize(.small) }
                if model.sshConfigured {
                    Button("Back Up Now") { instance.backUp() }
                        .controlSize(.small)
                        .disabled(!instance.canChange)
                }
            }
            .padding(.horizontal, 2)
            Group {
                if !model.sshConfigured {
                    SSHRequiredView(title: "Backups").padding(.vertical, 8).frame(maxWidth: .infinity)
                } else if instance.backups.isEmpty {
                    Text("No backups yet. Back Up Now saves AdGuard Home’s settings on this Mac.")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                } else {
                    VStack(spacing: 0) {
                        ForEach(instance.backups) { backup in
                            backupRow(backup)
                            if backup.id != instance.backups.last?.id { Divider() }
                        }
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 1))
            Text(AdGuardInstancePresentation.backupsFootnote).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 2)
        }
    }

    private func backupRow(_ backup: AdGuardBackup) -> some View {
        let selected = instance.selection == backup.id
        return HStack(spacing: 10) {
            Image(systemName: "archivebox").foregroundStyle(.secondary).frame(width: 16).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(AdGuardInstancePresentation.date(backup.createdAt, now: model.evaluatedAt))
                Text(AdGuardInstancePresentation.detail(backup)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if selected {
                if instance.activity == .restoring { ProgressView().controlSize(.small) }
                Button("Export…") { export(backup) }.controlSize(.small)
                Button("Restore…") { confirmingRestore = backup }
                    .controlSize(.small)
                    .disabled(!instance.canChange)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(selected ? Color.accentColor.opacity(0.12) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { instance.selection = backup.id }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    private func export(_ backup: AdGuardBackup) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "AdGuardHome-\(backup.createdAt.formatted(.iso8601.year().month().day())).yaml"
        panel.message = "This file holds AdGuard Home’s password hashes. Keep it private."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { _ = await instance.export(backup, to: url) }
    }

    // MARK: Data

    private var dataSection: some View {
        section("Data") {
            dataRow(.queryLog, title: "Keep query log for",
                    detail: AdGuardInstancePresentation.queryLogSize(model.adGuardResources, sshConfigured: model.sshConfigured),
                    current: adGuard.queryLogConfig?.intervalMilliseconds)
            Divider()
            dataRow(.stats, title: "Keep statistics for", detail: nil, current: adGuard.statsConfig?.intervalMilliseconds)
        }
    }

    private func dataRow(_ kind: AdGuardDataKind, title: String, detail: String?, current: Int?) -> some View {
        let pending: Int? = if case .retention(kind, let value)? = adGuard.settingInFlight { value } else { nil }
        let shown = pending ?? current
        let disabled = availability.isReadOnly || busy || adGuard.isWriting
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 12)
            Picker(title, selection: Binding(get: { shown ?? 0 }, set: { instance.setRetention(kind, milliseconds: $0) })) {
                if shown == nil { Text("Unknown").tag(0) }
                ForEach(AdGuardInstancePresentation.retentionOptions(current: shown), id: \.self) { value in
                    Text(AdGuardInstancePresentation.retention(value)).tag(value)
                }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(disabled || shown == nil)
            Button("Clear…", role: .destructive) { confirmingClear = kind }
                .controlSize(.small)
                .foregroundStyle(disabled ? Color.secondary : Color.red)
                .disabled(disabled)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    // MARK: Parts

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).padding(.horizontal, 2)
            VStack(spacing: 0, content: content)
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

/// The title, then the icon.
private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon
        }
    }
}

extension AdGuardSettingIntent {
    /// The writes the Instance tab starts.
    var isInstanceWrite: Bool {
        switch self {
        case .retention, .clearData: true
        default: false
        }
    }
}
