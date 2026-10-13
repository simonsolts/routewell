import Foundation
import Observation
import RoutewellKit

/// The Wi-Fi screen's own state: the derived Overview, the dismissed
/// suggestions (this session only), the devices a suggestion highlights,
/// the selected Radios lane, the staged change and the apply run. The reads
/// live on `AppModel`.
@MainActor @Observable
final class WiFiController {
    private let model: AppModel
    private let refresh: RefreshController
    private var dismissed: (token: SessionToken?, kinds: Set<WiFiSuggestion.Kind>) = (nil, [])
    var highlighted: Set<MACAddress> = []
    var selectedBand: WirelessBand = .ghz5
    /// The open sheet; none once the session it opened in has ended.
    var sheet: WiFiSheet? {
        get { editToken == model.session.expectedToken ? openSheet : nil }
        set { openSheet = newValue }
    }
    private var openSheet: WiFiSheet?
    /// The session the sheet opened in.
    private var editToken: SessionToken?
    /// The `get_config` read the sheet opened with. Plans compare against
    /// it, so an outside edit after that is a conflict, not a new baseline.
    private(set) var base: WirelessStatus?
    /// The network sheet's fields.
    var draft: WiFiNetworkDraft?
    /// Use One Name's "Keep the name".
    var keepName: String?
    /// What Review and apply shows and sends.
    private(set) var pending: WiFiChangeSet?
    private(set) var run: WiFiApplyRun?
    /// Whether this Mac's path uses Wi-Fi, and its Wi-Fi address.
    @ObservationIgnored var thisMac: @MainActor () -> (onWiFi: Bool?, mac: MACAddress?) = { (nil, nil) }

    init(model: AppModel, refresh: RefreshController) {
        self.model = model
        self.refresh = refresh
    }

    /// Why parts that need SSH show "—", or `nil` when SSH data can come.
    var airState: WiFiAirState {
        guard model.sshConfigured else { return .notSetUp }
        guard let probe = model.sshProbe else { return .checking }
        return probe.capability.state == .supported ? .available : .notWorking
    }

    private var clients: [WiFiClientInfo]? {
        model.clientInventory?.clients.map { client in
            WiFiClientInfo(client: client, name: ClientNaming.automatic(client: client, record: model.deviceRegistry.records[client.mac]).text)
        }
    }

    /// `nil` before the first successful `get_config` in this session.
    var overview: WiFiOverview? {
        guard let wireless = model.wireless else { return nil }
        let air = airState == .available ? model.wifiAir : nil
        return WiFiOverview(wireless: wireless, mlo: try? model.wifi?.mlo.get(), air: air, clients: clients)
    }

    var suggestions: [WiFiSuggestion] {
        let kinds = dismissed.token == model.session.expectedToken ? dismissed.kinds : []
        return (overview?.suggestions ?? []).filter { !kinds.contains($0.kind) }
    }

    func dismiss(_ suggestion: WiFiSuggestion) {
        let token = model.session.expectedToken
        if dismissed.token != token { dismissed = (token, []) }
        dismissed.kinds.insert(suggestion.kind)
        highlighted = []
    }

    func openRadios(_ band: WirelessBand) {
        selectedBand = band
        model.subpages[.wifi] = WiFiTab.radios.rawValue
    }

    func openMultiLink() {
        model.subpages[.wifi] = WiFiTab.multiLink.rawValue
    }

    // MARK: Editing

    /// Writes need a current `get_config`, a write control, and no other apply.
    var canEdit: Bool {
        model.session.isReady && model.wireless != nil && model.wifiFreshness.failure == nil
            && model.session.lease?.backend.wifiControl != nil && !isApplying
    }

    var isApplying: Bool { model.wifiApplying }

    var subnets: [SubnetPolicy]? { try? model.wifi?.subnets.get() }

    var thisMacLink: ThisMacLink {
        let mac = thisMac()
        return ThisMacLink.resolve(onWiFi: mac.onWiFi, wifiMAC: mac.mac, clients: clients, devices: overview?.devices ?? [])
    }

    func openNetwork(_ group: WiFiNetworkGroup) {
        guard canEdit, let wireless = model.wireless else { return }
        begin(wireless)
        draft = WiFiNetworkDraft(group: group, wireless: wireless, isolate: subnets?.first { $0.name == "main" }?.isolate)
        sheet = .network
    }

    func openUseOneName() {
        guard canEdit, let wireless = model.wireless else { return }
        begin(wireless)
        keepName = overview?.groups.first { $0.kind == .main }?.name
        sheet = .useOneName
    }

    private func begin(_ wireless: WirelessStatus) {
        editToken = model.session.expectedToken
        base = wireless
        draft = nil
        pending = nil
        run = nil
    }

    /// The plan for a change against the values the sheet opened with.
    func plan(for change: WiFiChangeSet) -> WiFiApplyPlan? {
        guard editToken == model.session.expectedToken, let wireless = base else { return nil }
        return WiFiApplyPlan(change: change, wireless: wireless, subnets: subnets, devices: overview?.devices ?? [], thisMac: thisMacLink)
    }

    /// Use One Name: every main band under the kept name, with its password,
    /// and WPA3 when 6 GHz is among the bands.
    func useOneNameChange(keeping name: String) -> WiFiChangeSet? {
        guard let wireless = base, let groups = overview?.groups.filter({ $0.kind == .main }),
              let kept = groups.first(where: { $0.name == name }) else { return nil }
        let draft = WiFiNetworkDraft(group: kept, wireless: wireless, isolate: nil)
        var edit = draft.original
        edit.bands = Array(Set(groups.flatMap(\.bands))).sorted()
        edit.sameOnEveryBand = true
        if edit.bands.contains(.ghz6) { edit.security = .wpa3 }
        return WiFiChangeSet(networks: [edit])
    }

    func review(_ change: WiFiChangeSet) {
        guard canEdit, let plan = plan(for: change), !plan.isEmpty else { return }
        pending = change
        run = nil
        sheet = .review
    }

    func closeSheet() {
        guard !isApplying else { return }
        sheet = nil
        draft = nil
        pending = nil
        run = nil
        base = nil
    }

    func apply() {
        guard canEdit, let change = pending, let plan = plan(for: change), !plan.isEmpty, let lease = model.session.lease else { return }
        run = WiFiApplyRun(plan: plan, macWasOnWiFi: { if case .wifi = thisMacLink { true } else { false } }())
        model.setWiFiApplying(true)
        Task {
            let report: MutationReport<WiFiApplyState>?
            do {
                report = try await model.session.routerSession.command(lease) { backend in
                    await backend.wifiControl?.apply(plan) { step in
                        await MainActor.run {
                            if lease.token == self.model.session.expectedToken { self.run?.step = step }
                        }
                    } ?? .capabilityUnavailable
                }
            } catch {
                report = nil
            }
            // After a session switch the new session owns the Wi-Fi state and
            // reads Wi-Fi afresh.
            guard lease.token == model.session.expectedToken else { return }
            model.setWiFiApplying(false)
            if let report {
                run?.outcome = report.outcome
            } else {
                closeSheet()
            }
            refresh.refreshNow()
        }
    }
}

enum WiFiAirState: Equatable {
    case notSetUp, checking, notWorking, available
}

enum WiFiSheet: String, Identifiable {
    case network, useOneName, review
    var id: String { rawValue }
}

/// One apply as the progress sheet shows it.
struct WiFiApplyRun: Equatable {
    let plan: WiFiApplyPlan
    let macWasOnWiFi: Bool
    var step: WiFiApplyStep = .sending
    var outcome: MutationOutcome<WiFiApplyState>?
}

/// The network sheet's fields, and the change they make.
struct WiFiNetworkDraft: Equatable {
    let groupID: String
    let original: WiFiNetworkEdit
    let originalIsolate: Bool?
    var name: String
    var password: String
    var security: WiFiSecurity
    var visible: Bool
    var randomBSSID: Bool
    var bands: Set<WirelessBand>
    var isolate: Bool?

    init(group: WiFiNetworkGroup, wireless: WirelessStatus, isolate: Bool?) {
        let network = wireless.networks.first { $0.interface == group.interfaces.first }
        let original = WiFiNetworkEdit(interfaces: group.interfaces, name: group.name, password: network?.password,
                                       security: network?.encryption ?? group.security ?? .wpa3, hidden: network?.hidden ?? false,
                                       randomBSSID: network?.randomBSSID ?? true, bands: group.bands)
        groupID = group.id
        self.original = original
        originalIsolate = isolate
        name = original.name
        password = original.password?.revealed ?? ""
        security = original.security
        visible = !original.hidden
        randomBSSID = original.randomBSSID
        bands = Set(original.bands)
        self.isolate = isolate
    }

    /// 6 GHz allows only WPA3.
    var effectiveSecurity: WiFiSecurity { bands.contains(.ghz6) ? .wpa3 : security }

    var edit: WiFiNetworkEdit {
        let samePassword = password == (original.password?.revealed ?? "")
        return WiFiNetworkEdit(interfaces: original.interfaces, name: name, password: samePassword ? original.password : WiFiPassword(password),
                               security: effectiveSecurity, hidden: !visible, randomBSSID: randomBSSID, bands: bands.sorted())
    }

    var change: WiFiChangeSet {
        let edit = edit
        return WiFiChangeSet(networks: edit == original ? [] : [edit], isolate: isolate != originalIsolate ? isolate : nil)
    }

    var hasChanges: Bool { change != WiFiChangeSet() }
}
