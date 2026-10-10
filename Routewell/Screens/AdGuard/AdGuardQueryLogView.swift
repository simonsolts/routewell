import SwiftUI
import RoutewellKit

/// AdGuard Home › Query Log: filter row, table, footer, and a
/// 280 pt inspector, read live from AdGuard Home while it runs.
struct AdGuardQueryLogView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppEnvironment.self) private var environment

    /// The view task restarts on a new session, filter, or Refresh.
    private struct TaskKey: Hashable {
        let token: SessionToken?
        let filter: QueryLogController.Filter
        let refreshes: Int
    }

    var body: some View {
        let controller = environment.queryLog
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                QueryLogFilterRow()
                Divider()
                QueryLogTable()
                Divider()
                QueryLogFooter()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            QueryLogInspector()
                .frame(width: 280)
                .frame(maxHeight: .infinity)
                .background(.quinary.opacity(0.5))
        }
        .task(id: TaskKey(token: model.session.expectedToken, filter: controller.filter, refreshes: model.personRefreshes)) {
            await controller.follow()
        }
        .onChange(of: model.adGuardQueryLogFilter, initial: true) { _, handoff in
            guard let handoff else { return }
            controller.open(handoff)
            model.adGuardQueryLogFilter = nil
        }
        .onDisappear { controller.stop() }
    }
}

struct QueryLogFilterRow: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        @Bindable var controller = environment.queryLog
        HStack(spacing: 8) {
            TextField("Search", text: $controller.searchText, prompt: Text(QueryLogPresentation.searchPrompt))
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .onSubmit { controller.applySearch() }
                .accessibilityLabel("Search domain or client")
            Picker("Status", selection: Binding(get: { controller.filter.status }, set: { controller.setStatus($0) })) {
                ForEach(QueryLogStatusFilter.allCases, id: \.self) { status in
                    Text(QueryLogPresentation.statusTitle(status)).tag(status)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 120)
            if controller.isFiltered || !controller.searchText.isEmpty {
                Button("Clear") { controller.clear() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
            Spacer(minLength: 8)
            if controller.isLive {
                HStack(spacing: 5) {
                    Circle().fill(.green).frame(width: 6, height: 6)
                    Text("Live").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .help("New queries appear every 3 seconds.")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        // A pause in typing applies the search, like pressing Return.
        .task(id: controller.searchText) {
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            controller.applySearch()
        }
    }
}

struct QueryLogTable: View {
    @Environment(AppModel.self) private var model
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        @Bindable var controller = environment.queryLog
        let filtering = environment.adGuard.filtering
        let clients = model.clientInventory?.clients ?? []
        let records = model.deviceRegistry.records
        let now = Date.now
        Table(controller.entries, selection: $controller.selection) {
            TableColumn("Time") { entry in
                Text(entry.time.map { QueryLogTimeFormat.row($0, now: now) } ?? "Unknown")
                    .monospacedDigit().opacity(0.75)
            }
            .width(min: 64, ideal: 78)
            TableColumn("Domain") { entry in
                Text(entry.domain ?? "Unknown").lineLimit(1).truncationMode(.tail).help(entry.domain ?? "")
            }
            .width(min: 120, ideal: 205)
            TableColumn("Type") { entry in
                Text(entry.type ?? "—").opacity(0.7)
            }
            .width(min: 44, ideal: 58)
            TableColumn("Device") { entry in
                Text(QueryLogPresentation.deviceCell(entry, name: entry.client.flatMap { ClientNaming.automatic(ip: $0, clients: clients, records: records) }))
                    .lineLimit(1).truncationMode(.tail)
            }
            .width(min: 80, ideal: 120)
            TableColumn("Status") { entry in
                HStack(spacing: 6) {
                    Circle().fill(QueryLogPresentation.statusColor(entry.result)).frame(width: 7, height: 7)
                        .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 1))
                    Text(QueryLogPresentation.statusText(entry.result))
                }
            }
            .width(min: 84, ideal: 98)
            TableColumn("Reason") { entry in
                Text(QueryLogPresentation.reasonCell(entry, filtering: filtering)).lineLimit(1).truncationMode(.tail).opacity(0.75)
            }
            .width(min: 90, ideal: 135)
            TableColumn("Response") { entry in
                Text(QueryLogPresentation.response(entry.elapsedMilliseconds))
                    .monospacedDigit().opacity(0.75)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 64, ideal: 76)
        }
        .alternatingRowBackgrounds()
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y <= -geometry.contentInsets.top + 4
        } action: { _, atTop in
            controller.isAtTop = atTop
        }
        .overlay { overlay(controller) }
    }

    @ViewBuilder private func overlay(_ controller: QueryLogController) -> some View {
        if controller.entries.isEmpty {
            switch controller.phase {
            case .idle, .loading:
                ProgressView("Reading the query log…")
            case .failed(let category):
                ContentUnavailableView {
                    Label("Query Log Not Read", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(QueryLogPresentation.failure(category))
                } actions: {
                    Button("Try Again") { Task { await controller.loadFirstPage() } }
                }
            case .notConfigured:
                ContentUnavailableView("AdGuard Home is not set up in Routewell.", systemImage: "shield")
            case .loaded:
                Text(QueryLogPresentation.emptyTable(filtered: controller.isFiltered))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
    }
}

struct QueryLogFooter: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let controller = environment.queryLog
        let browser = controller.browser
        HStack(spacing: 8) {
            if !controller.entries.isEmpty {
                Text(QueryLogPresentation.footer(count: controller.entries.count, oldest: browser.oldestLoaded,
                                                 filtered: controller.isFiltered, now: .now))
            }
            if case .failed(let category) = controller.phase, !controller.entries.isEmpty {
                Text(QueryLogPresentation.failure(category)).foregroundStyle(.orange)
            }
            if browser.isAtCap {
                Text(QueryLogPresentation.capNote)
            }
            Spacer(minLength: 8)
            if let failure = controller.moreFailure {
                Text(QueryLogPresentation.failure(failure)).foregroundStyle(.orange)
            }
            if controller.loadingMore {
                ProgressView().controlSize(.mini)
            } else if browser.canLoadMore {
                Button("Load More") { Task { await controller.loadMore() } }
                    .controlSize(.small)
                    .help("Read the next 500 older queries")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(height: 26)
    }
}

struct QueryLogInspector: View {
    @Environment(AppModel.self) private var model
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        if let entry = environment.queryLog.selectedEntry {
            ScrollView {
                QueryLogInspectorContent(entry: entry)
                    .padding(16)
            }
        } else {
            Text(QueryLogPresentation.emptyInspector)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct QueryLogInspectorContent: View {
    @Environment(AppModel.self) private var model
    @Environment(AppEnvironment.self) private var environment
    let entry: QueryLogEntry

    var body: some View {
        let adGuard = environment.adGuard
        let filtering = adGuard.filtering
        let name = entry.client.flatMap {
            ClientNaming.automatic(ip: $0, clients: model.clientInventory?.clients ?? [], records: model.deviceRegistry.records)
        }
        let reason = QueryLogPresentation.reasonRow(entry, filtering: filtering)
        let action: DomainRuleAction = entry.result == .blocked ? .unblock : .block
        let color = QueryLogPresentation.statusColor(entry.result)
        VStack(alignment: .leading, spacing: 0) {
            Text(QueryLogPresentation.pillText(entry.result))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(color.opacity(0.13), in: .rect(cornerRadius: 5))
            Text(entry.domain ?? "Unknown")
                .font(.system(size: 15, weight: .semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            Text(entry.time.map { QueryLogTimeFormat.full($0, now: .now) } ?? "Unknown time")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.top, 2)
            VStack(spacing: 0) {
                row("Device", QueryLogPresentation.deviceRow(entry, name: name))
                Divider()
                row("Type", QueryLogPresentation.typeRow(entry))
                Divider()
                row(reason.label, reason.value)
                if entry.result == .blocked, let rule = entry.rule {
                    Divider()
                    row("Rule", rule, monospaced: true)
                }
                Divider()
                row("Upstream", QueryLogPresentation.upstreamRow(entry))
                Divider()
                row("Response", QueryLogPresentation.response(entry.elapsedMilliseconds))
                Divider()
                row("Answer", QueryLogPresentation.answerRow(entry))
            }
            .background(.background, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
            .padding(.top, 14)
            VStack(spacing: 6) {
                Button(action == .block ? "Block Domain" : "Unblock Domain") {
                    if let domain = entry.domain { adGuard.runSetting(.domainRule(action, domain: domain)) }
                }
                .frame(maxWidth: .infinity)
                .disabled(adGuard.isWriting || adGuard.availability != .running || action.rule(for: entry.domain ?? "") == nil)
                Button("Show Only This Client") {
                    if let client = entry.client { environment.queryLog.search(for: client) }
                }
                .frame(maxWidth: .infinity)
                .disabled(entry.client == nil)
                if case .domainRule = adGuard.settingInFlight {
                    ProgressView().controlSize(.small)
                } else if let intent = adGuard.lastSettingIntent, case .domainRule(_, let domain) = intent, domain == entry.domain,
                          let report = adGuard.lastSettingReport {
                    Text(Self.resultText(intent, report.outcome))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .controlSize(.regular)
            .padding(.top, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// After Block or Unblock: the rule that is now in the custom rules, or
    /// what went wrong.
    static func resultText(_ intent: AdGuardSettingIntent, _ outcome: MutationOutcome<AdGuardSettingState>) -> String {
        if let problem = AdGuardPresentation.settingOutcomeText(intent, outcome) { return problem }
        guard case .domainRule(let action, let domain) = intent, let rule = action.rule(for: domain) else { return "" }
        return "Added \(rule) to the custom rules."
    }

    private func row(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 82, alignment: .leading)
            Text(value)
                .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 12))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10).padding(.vertical, 6)
    }
}

/// AdGuard Home is off, read-only, or not answering: the log is not shown,
/// because it is read only from a running AdGuard Home.
struct QueryLogUnavailableView: View {
    @Environment(AppEnvironment.self) private var environment
    let availability: AdGuardAvailability

    var body: some View {
        let adGuard = environment.adGuard
        ContentUnavailableView {
            Label(QueryLogPresentation.unavailableTitle, systemImage: "list.bullet.rectangle")
        } description: {
            Text(QueryLogPresentation.unavailableMessage(availability))
        } actions: {
            switch availability {
            case .cached:
                Button("Turn On") { adGuard.run(.turnOn(handlesDNS: adGuard.handlesDNS ?? true)) }
                    .disabled(adGuard.inFlight != nil)
            case .unreachable:
                Button("Refresh") { environment.refresh.refreshFromPerson() }
            default:
                EmptyView()
            }
        }
    }
}
