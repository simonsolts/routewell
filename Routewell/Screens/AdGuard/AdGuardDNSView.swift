import SwiftUI
import RoutewellKit

/// Staged DNS settings; read-only when AdGuard Home is not running.
struct AdGuardDNSView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var editingList: DNSPresentation.ServerList?
    @State private var addingUpstream = false

    var body: some View {
        let dns = environment.dns
        let adGuard = environment.adGuard
        VStack(spacing: 0) {
            if let settings = dns.settings {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if let report = adGuard.lastSettingReport, let intent = adGuard.lastSettingIntent, intent.isDNSWrite,
                           let text = AdGuardPresentation.settingOutcomeText(intent, report.outcome) {
                            AdGuardOutcomeNotice(text: text)
                        }
                        DNSUpstreamSection(settings: settings, editingList: $editingList, addingUpstream: $addingUpstream)
                        DNSBlockingSection(settings: settings)
                        DNSCacheSection(settings: settings)
                        DNSSecuritySection(settings: settings)
                    }
                    .frame(maxWidth: 760)
                    .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 28)
                    .frame(maxWidth: .infinity)
                }
                if dns.hasChanges, !dns.isReadOnly {
                    DNSApplyBar()
                }
            } else if let failure = adGuard.dnsFailure {
                ContentUnavailableView {
                    Label("DNS settings unavailable", systemImage: "network")
                } description: {
                    Text("AdGuard Home did not send its DNS settings (\(FailureText.text(failure))).")
                } actions: {
                    Button("Refresh") { environment.refresh.refreshNow() }
                }
            } else if adGuard.availability == .running {
                ProgressView("Reading DNS settings…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("No saved DNS settings", systemImage: "network",
                                       description: Text("Routewell saves AdGuard Home's DNS settings while it runs."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $editingList) { DNSServerListSheet(list: $0) }
        .sheet(isPresented: $addingUpstream) { DNSAddUpstreamSheet() }
    }
}

extension AdGuardSettingIntent {
    var isDNSWrite: Bool {
        switch self {
        case .dns, .clearDNSCache: true
        default: false
        }
    }
}

// MARK: - Building blocks

/// A 13 pt semibold title, then a rounded box of rows.
struct DNSSection<Accessory: View, Content: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                accessory
            }
            VStack(spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        if index > 0 { Divider() }
                        row
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 1))
        }
    }
}

extension DNSSection where Accessory == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, accessory: { EmptyView() }, content: content)
    }
}

/// Label and subtitle at the left, the control at the right.
struct DNSRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }
}

/// A switch row. Unknown shows off and disabled.
struct DNSToggleRow: View {
    @Environment(AppEnvironment.self) private var environment
    let title: String
    var subtitle: String?
    let value: Bool?
    let set: (inout AdGuardDNSSettings, Bool) -> Void

    var body: some View {
        let dns = environment.dns
        DNSRow(title: title, subtitle: subtitle) {
            Toggle(title, isOn: Binding(get: { value ?? false }, set: { new in dns.edit { set(&$0, new) } }))
                .toggleStyle(.switch).labelsHidden().controlSize(.small)
                .disabled(!dns.canEdit || value == nil)
        }
    }
}

/// A stepper with its value at the left.
struct DNSStepperRow: View {
    @Environment(AppEnvironment.self) private var environment
    let title: String
    let value: Int?
    let range: ClosedRange<Int>
    let text: String
    let set: (inout AdGuardDNSSettings, Int) -> Void

    var body: some View {
        let dns = environment.dns
        DNSRow(title: title) {
            Text(text).font(.system(size: 13)).monospacedDigit().frame(minWidth: 56, alignment: .trailing)
            Stepper(title, value: Binding(get: { value ?? range.lowerBound }, set: { new in dns.edit { set(&$0, new) } }), in: range)
                .labelsHidden()
                .disabled(!dns.canEdit || value == nil)
        }
    }
}

/// Seconds, with the human value beside the field.
struct DNSSecondsRow: View {
    @Environment(AppEnvironment.self) private var environment
    let title: String
    let value: Int?
    let set: (inout AdGuardDNSSettings, Int) -> Void

    var body: some View {
        let dns = environment.dns
        DNSRow(title: title) {
            Text(DNSPresentation.duration(value)).font(.system(size: 11)).foregroundStyle(.secondary)
            TextField(title, value: Binding<Int?>(get: { value }, set: { new in dns.edit { set(&$0, max(0, new ?? 0)) } }),
                      format: .number.grouping(.never), prompt: Text("0"))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 72)
                .disabled(!dns.canEdit || value == nil)
            Text("s").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Upstream servers

struct DNSUpstreamRow: Identifiable {
    let id: Int
    let line: UpstreamLine
}

struct DNSUpstreamSection: View {
    @Environment(AppEnvironment.self) private var environment
    let settings: AdGuardDNSSettings
    @Binding var editingList: DNSPresentation.ServerList?
    @Binding var addingUpstream: Bool

    var body: some View {
        @Bindable var dns = environment.dns
        let rows = dns.upstreamLines.enumerated().map { DNSUpstreamRow(id: $0.offset, line: $0.element) }
        let stats = dns.stats
        let slow = rows.compactMap { row -> (address: String, milliseconds: Double)? in
            guard let address = row.line.address, let usage = stats?.usage(of: address), usage.isSlow,
                  let ms = usage.averageMilliseconds else { return nil }
            return (address, ms)
        }
        DNSSection(title: "Upstream servers") {
            if dns.test == .testing { ProgressView().controlSize(.small).frame(width: 14, height: 14) }
            Button(DNSPresentation.testUpstreams) { dns.runTest() }
                .controlSize(.small)
                .disabled(!dns.canEdit || dns.test == .testing)
        } content: {
            VStack(spacing: 0) {
                Table(rows, selection: $dns.selection) {
                    TableColumn("Server") { row in
                        Text(row.line.text).font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(row.line.address == nil ? .secondary : .primary)
                            .lineLimit(1).truncationMode(.middle).help(row.line.text)
                    }
                    .width(min: 160, ideal: 320)
                    TableColumn("") { row in
                        if let address = row.line.address {
                            Text(UpstreamProtocol(address: address).rawValue)
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    .width(54)
                    TableColumn("Share") { row in
                        if let address = row.line.address {
                            DNSShareCell(usage: stats?.usage(of: address) ?? UpstreamUsage())
                        }
                    }
                    .width(min: 90, ideal: 120)
                    TableColumn("Avg. response") { row in
                        if let address = row.line.address {
                            DNSResponseCell(response: DNSPresentation.response(stats?.usage(of: address) ?? UpstreamUsage(),
                                                                             test: dns.test, address: address))
                        }
                    }
                    .width(min: 90, ideal: 110)
                    .alignment(.trailing)
                }
                .frame(height: CGFloat(max(rows.count, 2)) * 24 + 30)
                .scrollDisabled(true)
                Divider()
                HStack(spacing: 0) {
                    Button { addingUpstream = true } label: {
                        Image(systemName: "plus").frame(width: 26, height: 24).contentShape(Rectangle())
                    }
                    .disabled(!dns.canEdit)
                    .help(DNSPresentation.addUpstreamTitle)
                    Divider().frame(height: 24)
                    Button { dns.removeSelectedUpstream() } label: {
                        Image(systemName: "minus").frame(width: 26, height: 24).contentShape(Rectangle())
                    }
                    .disabled(!dns.canEdit || dns.selection == nil)
                    .help("Remove the selected line")
                    Divider().frame(height: 24)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .frame(height: 24)
                .background(.quinary)
            }
            if case .failed(let category) = dns.test {
                DNSNote(text: DNSPresentation.testFailed(category))
            } else if dns.test != .testing, let note = DNSPresentation.slowNote(slow, mode: settings.upstreamMode) {
                DNSNote(text: note)
            }
            DNSRow(title: "Query routing", subtitle: DNSPresentation.modeDescription(settings.upstreamMode)) {
                Picker("Query routing", selection: Binding(get: { settings.upstreamMode },
                                                          set: { mode in dns.edit { $0.upstreamMode = mode } })) {
                    if settings.upstreamMode == nil { Text("Unknown").tag(AdGuardUpstreamMode?.none) }
                    ForEach(AdGuardUpstreamMode.allCases, id: \.self) { Text(DNSPresentation.modeTitle($0)).tag(Optional($0)) }
                }
                .labelsHidden().frame(width: 170)
                .disabled(!dns.canEdit)
            }
            DNSServerListRow(list: .fallback, lines: settings.fallback, editingList: $editingList)
            DNSServerListRow(list: .bootstrap, lines: settings.bootstrap, editingList: $editingList)
        }
    }
}

struct DNSShareCell: View {
    let usage: UpstreamUsage

    var body: some View {
        HStack(spacing: 6) {
            if let share = usage.sharePercent {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(Color.accentColor).frame(width: proxy.size.width * share / 100)
                    }
                }
                .frame(height: 3)
            }
            Text(DNSPresentation.share(usage)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

struct DNSResponseCell: View {
    let response: (text: String, style: DNSPresentation.ResponseStyle, help: String?)

    var body: some View {
        let text = Text(response.text).monospacedDigit()
        switch response.style {
        case .normal: text.foregroundStyle(.secondary)
        case .slow: text.fontWeight(.semibold).foregroundStyle(.orange)
        case .good: text.fontWeight(.semibold).foregroundStyle(.green)
        case .failed: text.fontWeight(.semibold).foregroundStyle(.red).help(response.help ?? "")
        }
    }
}

struct DNSNote: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(.orange).accessibilityHidden(true)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

struct DNSServerListRow: View {
    @Environment(AppEnvironment.self) private var environment
    let list: DNSPresentation.ServerList
    let lines: [String]?
    @Binding var editingList: DNSPresentation.ServerList?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(list.title).font(.system(size: 13))
                if let subtitle = list.subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text(DNSPresentation.addresses(lines))
                    .font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 12)
            Button("Edit…") { editingList = list }
                .controlSize(.small)
                .disabled(!environment.dns.canEdit || lines == nil)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }
}

struct DNSServerListSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let list: DNSPresentation.ServerList
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(list.title).font(.headline)
            Text(list.sheetDescription).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 6).padding(.vertical, 4)
                .frame(minHeight: 130)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator, lineWidth: 1))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(list.placeholder).font(.system(size: 12, design: .monospaced)).foregroundStyle(.tertiary)
                            .padding(.horizontal, 11).padding(.vertical, 4).allowsHitTesting(false)
                    }
                }
                .accessibilityLabel(list.title)
            Text(DNSPresentation.serversNote).font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            let settings = environment.dns.settings
            text = CustomRulesText.text((list == .fallback ? settings?.fallback : settings?.bootstrap) ?? [])
        }
    }

    private func save() {
        let lines = DNSPresentation.lines(text)
        environment.dns.edit { settings in
            if list == .fallback { settings.fallback = lines } else { settings.bootstrap = lines }
        }
        dismiss()
    }
}

struct DNSAddUpstreamSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(DNSPresentation.addUpstreamTitle).font(.headline)
            TextField("Address", text: $address, prompt: Text(DNSPresentation.addUpstreamPlaceholder))
                .font(.system(size: 12, design: .monospaced))
                .labelsHidden()
            Text(DNSPresentation.addUpstreamNote).font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    environment.dns.addUpstream(address)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 380)
    }
}

// MARK: - Blocking, Cache, Security and privacy

struct DNSBlockingSection: View {
    @Environment(AppEnvironment.self) private var environment
    let settings: AdGuardDNSSettings

    var body: some View {
        let dns = environment.dns
        DNSSection(title: "Blocking") {
            VStack(spacing: 0) {
                DNSRow(title: "Blocked response", subtitle: DNSPresentation.blockingDescription(settings.blockingMode)) {
                    Picker("Blocked response", selection: Binding(get: { settings.blockingMode },
                                                                 set: { mode in dns.edit { $0.blockingMode = mode } })) {
                        if settings.blockingMode == nil { Text("Unknown").tag(AdGuardBlockingMode?.none) }
                        ForEach(AdGuardBlockingMode.allCases, id: \.self) { Text(DNSPresentation.blockingTitle($0)).tag(Optional($0)) }
                    }
                    .labelsHidden().frame(width: 150)
                    .disabled(!dns.canEdit)
                }
                if settings.blockingMode == .customIP {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                        GridRow {
                            Text("IPv4:").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                            TextField("IPv4", text: Binding(get: { settings.blockingIPv4 ?? "" },
                                                            set: { value in dns.edit { $0.blockingIPv4 = value } }),
                                      prompt: Text("192.168.8.1"))
                                .font(.system(size: 12, design: .monospaced))
                        }
                        GridRow {
                            Text("IPv6:").foregroundStyle(.secondary)
                            TextField("IPv6", text: Binding(get: { settings.blockingIPv6 ?? "" },
                                                            set: { value in dns.edit { $0.blockingIPv6 = value } }),
                                      prompt: Text("::"))
                                .font(.system(size: 12, design: .monospaced))
                        }
                    }
                    .font(.system(size: 12))
                    .labelsHidden()
                    .disabled(!dns.canEdit)
                    .padding(10)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 12).padding(.bottom, 10)
                }
            }
            DNSStepperRow(title: "Blocked answer TTL", value: settings.blockedResponseTTL, range: 0...3600,
                          text: DNSPresentation.seconds(settings.blockedResponseTTL)) { $0.blockedResponseTTL = $1 }
        }
    }
}

struct DNSCacheSection: View {
    @Environment(AppEnvironment.self) private var environment
    let settings: AdGuardDNSSettings

    var body: some View {
        let dns = environment.dns
        DNSSection(title: "Cache") {
            Button(dns.cacheCleared ? DNSPresentation.cacheCleared : DNSPresentation.clearCache) { dns.clearCache() }
                .controlSize(.small)
                .disabled(!dns.canEdit || environment.adGuard.isWriting)
        } content: {
            DNSToggleRow(title: "DNS cache", value: settings.cacheEnabled) { $0.cacheEnabled = $1 }
            DNSToggleRow(title: "Optimistic caching", subtitle: "Serve expired answers while refreshing",
                         value: settings.cacheOptimistic) { $0.cacheOptimistic = $1 }
            DNSRow(title: "Cache size") {
                Picker("Cache size", selection: Binding(get: { settings.cacheSize },
                                                       set: { size in if let size { dns.edit { $0.cacheSize = size } } })) {
                    if settings.cacheSize == nil { Text("Unknown").tag(Int?.none) }
                    ForEach(DNSPresentation.cacheSizeChoices(current: settings.cacheSize), id: \.self) {
                        Text(DNSPresentation.cacheSizeTitle($0)).tag(Optional($0))
                    }
                }
                .labelsHidden().frame(width: 100)
                .disabled(!dns.canEdit)
            }
            DNSSecondsRow(title: "Cache answers for at least", value: settings.cacheTTLMin) { $0.cacheTTLMin = $1 }
            DNSSecondsRow(title: "Cache answers for at most", value: settings.cacheTTLMax) { $0.cacheTTLMax = $1 }
        }
    }
}

struct DNSSecuritySection: View {
    let settings: AdGuardDNSSettings

    var body: some View {
        DNSSection(title: "Security and privacy") {
            DNSToggleRow(title: "Validate with DNSSEC", value: settings.dnssecEnabled) { $0.dnssecEnabled = $1 }
            DNSToggleRow(title: "EDNS Client Subnet", subtitle: "Shares part of your IP for closer CDN servers",
                         value: settings.ednsClientSubnet) { $0.ednsClientSubnet = $1 }
            DNSToggleRow(title: "Resolve IPv6 addresses", value: settings.resolvesIPv6) { $0.resolvesIPv6 = $1 }
            DNSStepperRow(title: "Rate limit per device", value: settings.rateLimit, range: 0...200,
                          text: DNSPresentation.rateLimit(settings.rateLimit)) { $0.rateLimit = $1 }
        }
    }
}

// MARK: - Apply bar

struct DNSApplyBar: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let dns = environment.dns
        HStack(spacing: 8) {
            if let problem = dns.settings?.problem {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
                Text(problem).font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Text(DNSPresentation.applyNote).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if dns.isApplying { ProgressView().controlSize(.small) }
            Button("Revert") { dns.revertAndReload() }
                .disabled(environment.adGuard.isWriting)
            Button("Apply") { dns.apply() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!dns.canApply)
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
