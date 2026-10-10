import SwiftUI
import RoutewellKit

/// Read-only when AdGuard Home is not running.
struct AdGuardFiltersView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        @Bindable var filters = environment.filters
        let adGuard = environment.adGuard
        VStack(alignment: .leading, spacing: 14) {
            FiltersHeaderRow()
            if let report = adGuard.lastSettingReport, let intent = adGuard.lastSettingIntent, intent.isFiltersWrite,
               let text = AdGuardPresentation.settingOutcomeText(intent, report.outcome) {
                AdGuardOutcomeNotice(text: text)
            }
            switch filters.segment {
            case .blocklists: FilterListSegment(kind: .blocklist)
            case .allowlists: FilterListSegment(kind: .allowlist)
            case .rules: CustomRulesSegment()
            }
        }
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert(FiltersPresentation.conflictTitle, isPresented: Binding(
            get: { filters.conflict != nil }, set: { if !$0 { filters.keepEditingAfterConflict() } }
        )) {
            Button(FiltersPresentation.conflictDiscard, role: .destructive) { filters.discardForConflict() }
            Button(FiltersPresentation.conflictKeep, role: .cancel) { filters.keepEditingAfterConflict() }
        } message: {
            Text(FiltersPresentation.conflictMessage)
        }
    }
}

extension AdGuardSettingIntent {
    /// The writes the Filters tab starts.
    var isFiltersWrite: Bool {
        switch self {
        case .listEnabled, .addList, .removeList, .updateInterval, .updateLists, .saveRules: true
        case .protection, .filtering, .feature, .domainRule, .dns, .clearDNSCache, .retention, .clearData: false
        }
    }
}

/// The segments at the left; "Check every" and Update Now at the right on
/// the two list segments.
struct FiltersHeaderRow: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        @Bindable var filters = environment.filters
        let readOnly = environment.adGuard.availability.isReadOnly
        HStack(spacing: 8) {
            Picker("Filters", selection: $filters.segment) {
                ForEach(AdGuardFiltersController.Segment.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 290)
            Spacer(minLength: 8)
            if let kind = filters.segment.kind {
                if let last = filters.lastUpdate, last.kind == kind, !filters.isUpdating,
                   let text = FiltersPresentation.updateResult(last.count) {
                    Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Text(FiltersPresentation.checkEvery).font(.system(size: 12)).foregroundStyle(.secondary)
                Picker(FiltersPresentation.checkEvery, selection: Binding(
                    get: { filters.status?.intervalHours },
                    set: { if let hours = $0 { filters.setInterval(hours) } }
                )) {
                    ForEach(FiltersPresentation.intervalChoices(current: filters.status?.intervalHours), id: \.self) { hours in
                        Text(FiltersPresentation.intervalTitle(hours)).tag(Optional(hours))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 96)
                .disabled(readOnly || !filters.canWrite || filters.status?.intervalHours == nil)
                Button(filters.isUpdating ? FiltersPresentation.updating : FiltersPresentation.updateNow) {
                    filters.updateNow(kind: kind)
                }
                .frame(minWidth: 96)
                .disabled(readOnly || !filters.canWrite)
            }
        }
    }
}

/// One row of the list table, keyed by URL.
struct FilterListRow: Identifiable {
    let list: AdGuardFilterList
    var id: String { list.url ?? "id-\(list.id.map(String.init) ?? "unknown")" }
}

struct FilterListSegment: View {
    @Environment(AppEnvironment.self) private var environment
    let kind: FilterListKind
    @State private var adding = false

    var body: some View {
        @Bindable var filters = environment.filters
        let readOnly = environment.adGuard.availability.isReadOnly
        let rows = filters.lists(kind).map(FilterListRow.init)
        let now = Date.now
        VStack(alignment: .leading, spacing: 6) {
            if kind == .allowlist {
                Text(FiltersPresentation.allowlistNote)
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.leading, 2)
            }
            VStack(spacing: 0) {
                Table(rows, selection: $filters.selection) {
                    TableColumn("On") { row in
                        Toggle("On", isOn: Binding(
                            get: { row.list.enabled == true },
                            set: { filters.setEnabled(row.list, kind: kind, enabled: $0) }
                        ))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .disabled(readOnly || !filters.canWrite || row.list.url == nil)
                        .accessibilityLabel("Use \(row.list.name ?? "list")")
                    }
                    .width(36)
                    TableColumn("Name") { row in
                        Text(row.list.name ?? "Unknown").lineLimit(1).truncationMode(.tail).help(row.list.name ?? "")
                    }
                    .width(min: 120, ideal: 260)
                    TableColumn("Source") { row in
                        Text(row.list.host ?? "Unknown").lineLimit(1).truncationMode(.tail).opacity(0.65).help(row.list.url ?? "")
                    }
                    .width(min: 90, ideal: 170)
                    TableColumn("Rules") { row in
                        Text(FiltersPresentation.rules(row.list, downloading: filters.isDownloading(row.list, now: now)))
                            .monospacedDigit().opacity(0.85)
                    }
                    .width(100)
                    .alignment(.trailing)
                    TableColumn("Last updated") { row in
                        Text(FiltersPresentation.lastUpdated(row.list, now: now)).opacity(0.65)
                    }
                    .width(140)
                }
                Divider()
                HStack(spacing: 0) {
                    Button { adding = true } label: {
                        Image(systemName: "plus").frame(width: 26, height: 24).contentShape(Rectangle())
                    }
                    .disabled(readOnly || !filters.canWrite)
                    .help(FiltersPresentation.sheetTitle(kind))
                    Divider().frame(height: 24)
                    Button { filters.removeSelected(kind: kind) } label: {
                        Image(systemName: "minus").frame(width: 26, height: 24).contentShape(Rectangle())
                    }
                    .disabled(readOnly || !filters.canWrite || !rows.contains { $0.id == filters.selection })
                    .help("Remove the selected list")
                    Divider().frame(height: 24)
                    Spacer(minLength: 8)
                    Text(FiltersPresentation.summary(filters.status))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                }
                .buttonStyle(.borderless)
                .frame(height: 24)
                .background(.quinary)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 1))
        }
        .sheet(isPresented: $adding) {
            AddFilterListSheet(kind: kind)
        }
    }
}

/// "Add blocklists": Catalog or Custom URL. "Add allowlists": Custom URL
/// only, because the catalog has blocklists only.
struct AddFilterListSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let kind: FilterListKind
    let catalog = AdGuardListCatalog.bundled

    enum Mode: String, CaseIterable {
        case catalog = "Catalog"
        case custom = "Custom URL"
    }

    @State private var mode: Mode = .catalog
    @State private var selected: Set<Int> = []
    @State private var name = ""
    @State private var url = ""

    private var effectiveMode: Mode { kind == .blocklist ? mode : .custom }

    private var customIsValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && FilterListURL.validated(url) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(FiltersPresentation.sheetTitle(kind)).font(.headline)
            if kind == .blocklist {
                Picker("Source", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }
            switch effectiveMode {
            case .catalog: catalogList
            case .custom: customFields
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(effectiveMode == .catalog ? FiltersPresentation.addTitle(selected: selected.count) : "Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(effectiveMode == .catalog ? selected.isEmpty : !customIsValid)
            }
            .padding(.top, 6)
        }
        .padding(20)
        .frame(width: 420)
    }

    private var catalogList: some View {
        let status = environment.filters.status
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(catalog.sections, id: \.group.id) { section in
                    Text(section.group.name)
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
                        .background(.quinary)
                    ForEach(section.lists) { entry in
                        let added = catalog.isAdded(entry, in: status)
                        HStack(spacing: 8) {
                            Toggle(entry.name, isOn: Binding(
                                get: { added || selected.contains(entry.id) },
                                set: { if $0 { selected.insert(entry.id) } else { selected.remove(entry.id) } }
                            ))
                            .toggleStyle(.checkbox)
                            .disabled(added)
                            Spacer(minLength: 8)
                            if added {
                                Text("Added").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                        .font(.system(size: 13))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .opacity(added ? 0.55 : 1)
                    }
                }
            }
        }
        .frame(maxHeight: 280)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 1))
    }

    private var customFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Name:").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    TextField("Name", text: $name, prompt: Text(FiltersPresentation.namePlaceholder)).labelsHidden()
                }
                GridRow {
                    Text("URL:").foregroundStyle(.secondary)
                    TextField("URL", text: $url, prompt: Text(FiltersPresentation.urlPlaceholder)).labelsHidden()
                }
            }
            Text(FiltersPresentation.customURLNote).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func add() {
        let lists: [(name: String, url: String)]
        switch effectiveMode {
        case .catalog:
            lists = catalog.sections.flatMap(\.lists).filter { selected.contains($0.id) }.map { ($0.name, $0.url) }
        case .custom:
            guard customIsValid else { return }
            lists = [(name, url)]
        }
        environment.filters.add(lists, kind: kind)
        dismiss()
    }
}

/// The custom rules editor and the rule syntax panel.
struct CustomRulesSegment: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let filters = environment.filters
        let canSave = filters.canEditRules && filters.hasRuleChanges && !environment.adGuard.isWriting
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text(FiltersPresentation.rulesNote)
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.leading, 2)
                TextEditor(text: Binding(get: { filters.rulesText }, set: { filters.editRules($0) }))
                    .font(.system(size: 12, design: .monospaced))
                    .autocorrectionDisabled()
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .frame(minHeight: 320, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator, lineWidth: 1))
                    .disabled(!filters.canEditRules)
                    .accessibilityLabel("Custom rules")
                HStack(spacing: 8) {
                    Spacer()
                    Button("Revert") { filters.revertRules() }
                        .disabled(!filters.hasRuleChanges || environment.adGuard.isWriting)
                    Button("Save") { filters.saveRules() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSave)
                }
            }
            .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 9) {
                Text("Rule syntax").fontWeight(.semibold)
                ForEach(FiltersPresentation.syntax, id: \.code) { item in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.code).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.indigo).textSelection(.enabled)
                        Text(item.text).foregroundStyle(.secondary)
                    }
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(width: 250, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 1))
        }
    }
}
