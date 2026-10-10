import Charts
import SwiftUI
import RoutewellKit

/// AdGuard Home › Overview: the status banner with Pause and
/// Resume, Activity with ranges, the Protection switches and Blocklists
/// row, and the three top lists. Read-only (the saved copy) when AdGuard
/// Home is off or does not answer: every write is disabled, the rows still
/// open the Query Log.
struct AdGuardOverviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppEnvironment.self) private var environment

    private var adGuard: AdGuardController { environment.adGuard }
    private var readOnly: Bool { adGuard.availability.isReadOnly }
    private var busy: Bool { adGuard.isWriting || !model.session.isReady }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                AdGuardBanner()
                if let report = adGuard.lastSettingReport, let intent = adGuard.lastSettingIntent,
                   let text = AdGuardPresentation.settingOutcomeText(intent, report.outcome) {
                    AdGuardOutcomeNotice(text: text)
                }
                HStack(alignment: .top, spacing: 18) {
                    AdGuardActivity().frame(maxWidth: .infinity)
                    AdGuardProtectionCard().frame(width: 300)
                }
                AdGuardTopLists()
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 28)
        }
    }
}

/// An orange line with Refresh, after a write that did not do what was asked.
struct AdGuardOutcomeNotice: View {
    @Environment(AppEnvironment.self) private var environment
    let text: String

    var body: some View {
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
}

// MARK: - Banner

struct AdGuardBanner: View {
    @Environment(AppModel.self) private var model
    @Environment(AppEnvironment.self) private var environment

    private var adGuard: AdGuardController { environment.adGuard }
    private var busy: Bool { adGuard.isWriting || !model.session.isReady }

    var body: some View {
        let banner = AdGuardPresentation.banner(
            adGuard.availability, protection: adGuard.protection, handlesDNS: adGuard.handlesDNS,
            stats: adGuard.stats?.value, filtering: adGuard.filtering, savedAt: adGuard.archive?.savedAt, now: model.evaluatedAt
        )
        HStack(spacing: 14) {
            ShieldTile(size: 40, colors: Self.tile(banner.tone))
            VStack(alignment: .leading, spacing: 1) {
                Text(banner.title).font(.system(size: 17, weight: .semibold))
                Text(banner.message).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if adGuard.settingInFlight.map(Self.isProtection) == true || adGuard.inFlight == .setHandlesDNS(true) {
                ProgressView().controlSize(.small)
            }
            ForEach(banner.actions, id: \.self) { action in
                button(action)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(Self.background(banner.tone), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func button(_ action: AdGuardPresentation.BannerAction) -> some View {
        switch action {
        case .pause:
            Menu("Pause") {
                ProtectionMenuItems(adGuard: adGuard)
            }
            .menuIndicator(.visible)
            .fixedSize()
            .disabled(busy)
        case .resume:
            Button("Resume") { adGuard.runSetting(.protection(.enable)) }
                .buttonStyle(.borderedProminent)
                .disabled(busy)
        case .turnOnProtection:
            Button("Turn On") { adGuard.runSetting(.protection(.enable)) }
                .buttonStyle(.borderedProminent)
                .disabled(busy)
        case .handleDNS:
            Button("Handle DNS Requests") { adGuard.run(.setHandlesDNS(true)) }
                .disabled(busy)
        }
    }

    private static func isProtection(_ intent: AdGuardSettingIntent) -> Bool {
        if case .protection = intent { return true }
        return false
    }

    private static func tile(_ tone: AdGuardPresentation.BannerTone) -> [Color] {
        switch tone {
        case .on, .notFiltering: [Color(red: 0.43, green: 0.84, blue: 0.51), Color(red: 0.16, green: 0.69, blue: 0.29)]
        case .paused: [Color(red: 1, green: 0.67, blue: 0.31), Color(red: 0.96, green: 0.50, blue: 0.12)]
        case .readOnly: [Color(red: 0.75, green: 0.75, blue: 0.76), Color(red: 0.59, green: 0.59, blue: 0.61)]
        }
    }

    private static func background(_ tone: AdGuardPresentation.BannerTone) -> Color {
        switch tone {
        case .on: Color.green.opacity(0.06)
        case .paused: Color.orange.opacity(0.07)
        case .notFiltering: Color.yellow.opacity(0.08)
        case .readOnly: Color.secondary.opacity(0.08)
        }
    }
}

/// The Pause menu: the design's four durations, then until tomorrow, then
/// Turn Off Protection. The Router menu uses it too.
struct ProtectionMenuItems: View {
    let adGuard: AdGuardController

    var body: some View {
        ForEach(ProtectionPauseChoice.allCases.filter { $0 != .untilTomorrow }, id: \.self) { choice in
            Button(choice.title) { adGuard.runSetting(.protection(choice.intent(from: .now))) }
        }
        Divider()
        Button(ProtectionPauseChoice.untilTomorrow.title) {
            adGuard.runSetting(.protection(ProtectionPauseChoice.untilTomorrow.intent(from: .now)))
        }
        Divider()
        Button("Turn Off Protection") { adGuard.runSetting(.protection(.disable)) }
    }
}

// MARK: - Activity

struct AdGuardActivity: View {
    @Environment(AppModel.self) private var model
    @Environment(AppEnvironment.self) private var environment
    @State private var hovered: Date?

    private var adGuard: AdGuardController { environment.adGuard }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Activity").font(.headline)
                Spacer()
                if adGuard.rangesUnsupported {
                    // One range only: name the period the stats cover.
                    Text(adGuard.stats.flatMap { AdGuardPresentation.span($0.value) } ?? AdGuardStatsRange.day.title)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Range", selection: Binding(get: { adGuard.range }, set: { adGuard.setRange($0) })) {
                        ForEach(AdGuardStatsRange.allCases, id: \.self) { range in
                            Text(range.title).tag(range).selectionDisabled(!adGuard.availableRanges.contains(range))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }
            .padding(.horizontal, 2)
            VStack(spacing: 0) {
                metrics
                Divider()
                chart.padding(14)
            }
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 1))
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 2)
            }
        }
    }

    private var note: String? {
        if adGuard.statsConfig?.enabled == false { return "Statistics are off in AdGuard Home." }
        if adGuard.rangesUnsupported { return "This version of AdGuard Home shows one range only." }
        return nil
    }

    private var metrics: some View {
        let colors: [Color] = [Color.blue.opacity(0.45), .red, .orange, Color(nsColor: .tertiaryLabelColor)]
        return HStack(spacing: 0) {
            ForEach(Array(AdGuardPresentation.metrics(adGuard.stats?.value).enumerated()), id: \.offset) { index, metric in
                if index > 0 { Divider() }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(colors[index]).frame(width: 7, height: 7)
                        Text(metric.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if let value = metric.value {
                            Text(value).font(.system(size: 22, weight: .semibold)).monospacedDigit()
                        } else {
                            Text("Unknown").font(.title3).foregroundStyle(.secondary)
                        }
                        if let detail = metric.detail { Text(detail).font(.callout).foregroundStyle(.secondary) }
                    }
                    .lineLimit(1).minimumScaleFactor(0.7)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var chart: some View {
        if let stats = adGuard.stats?.value, let units = stats.timeUnits {
            let bars = AdGuardPresentation.bars(stats, now: adGuard.stats?.savedAt ?? model.evaluatedAt)
            let unit: Calendar.Component = units == .hours ? .hour : .day
            let selected = hovered.flatMap { date in bars.first { Calendar.current.isDate($0.start, equalTo: date, toGranularity: unit) } }
            Chart {
                ForEach(bars) { bar in
                    BarMark(x: .value("Time", bar.start, unit: unit), y: .value("Count", bar.blocked))
                        .foregroundStyle(by: .value("Kind", "Blocked"))
                    BarMark(x: .value("Time", bar.start, unit: unit), y: .value("Count", bar.allowed))
                        .foregroundStyle(by: .value("Kind", "Allowed"))
                }
                if let selected {
                    RuleMark(x: .value("Time", selected.start, unit: unit))
                        .foregroundStyle(Color.secondary.opacity(0.25))
                        .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            Text(AdGuardPresentation.barTip(selected, units: units))
                                .font(.caption)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        }
                }
            }
            .chartForegroundStyleScale(["Blocked": Color.red, "Allowed": Color.blue.opacity(0.28)])
            .chartLegend(.hidden)
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: .stride(by: unit, count: units == .hours ? 6 : (bars.count > 10 ? 7 : 1))) {
                    AxisValueLabel(format: units == .hours ? .dateTime.hour().minute() : .dateTime.month(.abbreviated).day())
                }
            }
            .chartXSelection(value: $hovered)
            .frame(height: 132)
            .opacity(adGuard.availability.isReadOnly ? 0.55 : 1)
            .accessibilityLabel("Queries and blocked queries per \(units == .hours ? "hour" : "day")")
        } else {
            Group {
                if adGuard.availability.isReadOnly {
                    Text("No saved stats for this range.")
                } else if let failure = adGuard.statsFailure {
                    Text("AdGuard Home did not send its stats (\(FailureText.text(failure))).")
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 132)
        }
    }
}

/// Short words for a failed read.
enum FailureText {
    static func text(_ category: RefreshFailureCategory) -> String {
        switch category {
        case .network: "network problem"
        case .authentication: "sign-in refused"
        case .timeout: "no answer in time"
        case .malformedResponse: "unexpected reply"
        case .unavailable: "not available"
        }
    }
}

// MARK: - Protection

struct AdGuardProtectionCard: View {
    @Environment(AppModel.self) private var model
    @Environment(AppEnvironment.self) private var environment

    private var adGuard: AdGuardController { environment.adGuard }
    private var busy: Bool { adGuard.isWriting || !model.session.isReady }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Protection").font(.headline).frame(height: 22).padding(.horizontal, 2)
            VStack(spacing: 0) {
                filteringRow
                Divider()
                ForEach(AdGuardFeature.allCases, id: \.self) { feature in
                    row(feature)
                    Divider()
                }
                Button {
                    model.subpages[.adGuard] = AdGuardTab.filters.rawValue
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Blocklists")
                            Text(AdGuardPresentation.blocklistSummary(adGuard.filtering)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open Filters")
            }
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 1))
        }
    }

    /// AdGuard Home's "Filter requests": blocklists,
    /// allowlists, and custom rules all at once.
    private var filteringRow: some View {
        let value = adGuard.filtering?.enabled
        let title = AdGuardPresentation.filteringTitle
        var shown = value ?? false
        if case .filtering(let enabled)? = adGuard.settingInFlight { shown = enabled }
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if value == nil { Text("Unknown").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            if case .filtering? = adGuard.settingInFlight { ProgressView().controlSize(.small) }
            Toggle(title, isOn: Binding(get: { shown }, set: { adGuard.runSetting(.filtering(enabled: $0)) }))
                .toggleStyle(.switch).labelsHidden()
                .disabled(adGuard.availability.isReadOnly || busy || value == nil)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    private func row(_ feature: AdGuardFeature) -> some View {
        let value = adGuard.protectionOptions?[feature]
        let title = AdGuardPresentation.title(feature)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if value == nil { Text("Unknown").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            if case .feature(feature, _)? = adGuard.settingInFlight { ProgressView().controlSize(.small) }
            Toggle(title, isOn: Binding(get: { switchValue(feature) ?? false },
                                        set: { adGuard.runSetting(.feature(feature, enabled: $0)) }))
                .toggleStyle(.switch).labelsHidden()
                .disabled(adGuard.availability.isReadOnly || busy || value == nil)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    /// While a write runs, the switch shows where it is going.
    private func switchValue(_ feature: AdGuardFeature) -> Bool? {
        if case .feature(feature, let enabled)? = adGuard.settingInFlight { return enabled }
        return adGuard.protectionOptions?[feature]
    }
}

// MARK: - Top lists

struct AdGuardTopLists: View {
    @Environment(AppModel.self) private var model
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let stats = environment.adGuard.stats?.value
        let clients = model.clientInventory?.clients ?? []
        let records = model.deviceRegistry.records
        HStack(alignment: .top, spacing: 18) {
            column(AdGuardPresentation.domainList(title: "Top blocked", entries: stats?.topBlocked ?? [], total: stats?.blockedFiltering),
                   color: .red) { model.showQueryLog(AdGuardQueryLogFilter(search: $0)) }
            column(AdGuardPresentation.domainList(title: "Top queried", entries: stats?.topQueried ?? [], total: stats?.queries),
                   color: Color.blue.opacity(0.6)) { model.showQueryLog(AdGuardQueryLogFilter(search: $0)) }
            column(stats.map { AdGuardPresentation.deviceList($0) { ClientNaming.automatic(ip: $0, clients: clients, records: records) } }
                   ?? AdGuardPresentation.TopList(title: "Top devices", hint: "", rows: []),
                   color: .indigo) { model.showQueryLog(AdGuardQueryLogFilter(search: $0)) }
        }
    }

    private func column(_ list: AdGuardPresentation.TopList, color: Color, open: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(list.title).font(.headline)
                Spacer()
                Text(list.hint).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)
            VStack(spacing: 0) {
                if list.rows.isEmpty {
                    Text("Nothing to show").font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                }
                ForEach(Array(list.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider() }
                    Button { open(row.key) } label: {
                        VStack(spacing: 4) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(row.name).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 4)
                                Text(row.count).monospacedDigit()
                            }
                            HStack(spacing: 8) {
                                GeometryReader { proxy in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(.quaternary)
                                        Capsule().fill(color).frame(width: proxy.size.width * row.fraction)
                                    }
                                }
                                .frame(height: 3)
                                Text(row.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    .frame(width: 96, alignment: .trailing)
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show in Query Log")
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 1))
        }
        .frame(maxWidth: .infinity)
    }
}
