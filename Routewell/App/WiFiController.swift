import Foundation
import Observation
import RoutewellKit

/// The Wi-Fi screen's own state: the derived Overview, the dismissed
/// suggestions (this session only), the devices a suggestion highlights,
/// the selected Radios lane and its staged edits, the staged change and the
/// apply run. The reads live on `AppModel`.
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
    /// The `wireless` options read over SSH when the sheet opened.
    private(set) var baseSections: [WirelessSectionOptions]?
    /// The Radios tab's staged edits; none once their session has ended.
    var radioEdits: WiFiRadioEdits? {
        get { stagedRadios?.token == model.session.expectedToken ? stagedRadios : nil }
        set { stagedRadios = newValue }
    }
    private var stagedRadios: WiFiRadioEdits?
    private var reviewingRadios = false
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

    /// The SSH options, when SSH answers.
    var sections: [WirelessSectionOptions]? { airState == .available ? model.wifiAir?.sections : nil }

    var thisMacLink: ThisMacLink {
        let mac = thisMac()
        return ThisMacLink.resolve(onWiFi: mac.onWiFi, wifiMAC: mac.mac, clients: clients, devices: overview?.devices ?? [])
    }

    func openNetwork(_ group: WiFiNetworkGroup) {
        guard canEdit, let wireless = model.wireless else { return }
        begin(wireless)
        draft = WiFiNetworkDraft(group: group, wireless: wireless, isolate: subnets?.first { $0.name == "main" }?.isolate, sections: sections)
        sheet = .network
    }

    func openUseOneName() {
        guard canEdit, let wireless = model.wireless else { return }
        begin(wireless)
        keepName = overview?.groups.first { $0.kind == .main }?.name
        sheet = .useOneName
    }

    private func begin(_ wireless: WirelessStatus, sections: [WirelessSectionOptions]? = nil) {
        editToken = model.session.expectedToken
        base = wireless
        baseSections = sections ?? self.sections
        reviewingRadios = false
        draft = nil
        pending = nil
        run = nil
    }

    /// The plan for a change against the values the sheet opened with.
    func plan(for change: WiFiChangeSet) -> WiFiApplyPlan? {
        guard editToken == model.session.expectedToken, let wireless = base else { return nil }
        return WiFiApplyPlan(change: change, wireless: wireless, subnets: subnets, options: baseSections, devices: overview?.devices ?? [],
                             thisMac: thisMacLink)
    }

    /// Use One Name: every main band under the kept name, with its password,
    /// and WPA3 when 6 GHz is among the bands.
    func useOneNameChange(keeping name: String) -> WiFiChangeSet? {
        guard let wireless = base, let groups = overview?.groups.filter({ $0.kind == .main }),
              let kept = groups.first(where: { $0.name == name }) else { return nil }
        let draft = WiFiNetworkDraft(group: kept, wireless: wireless, isolate: nil, sections: nil)
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

    // MARK: Radios

    /// Stages a change to one band's radio fields. The first edit keeps the
    /// reads it started from.
    func editRadio(_ band: WirelessBand, _ change: (inout WiFiRadioSettings) -> Void) {
        guard canEdit, var edits = radioEdits ?? newRadioEdits(), var settings = edits.current(band) else { return }
        change(&settings)
        edits.settings[band] = settings
        radioEdits = edits
    }

    /// Stages Auto's use of the DFS channels on 5 GHz (SSH).
    func setAutoDFS(_ on: Bool) {
        guard canEdit, var edits = radioEdits ?? newRadioEdits(), edits.canWriteAutoDFS else { return }
        edits.autoDFS = on
        radioEdits = edits
    }

    /// Auto or Manual. Manual starts on the channel in use. A width the new
    /// choice cannot hold drops to the widest one it can.
    func setAutoChannel(_ band: WirelessBand, _ auto: Bool) {
        guard let radio = model.wireless?.radio(band) else { return }
        let channel = auto ? 0 : (WiFiFormat.channel(radio) ?? radio.channels.first?.number ?? 0)
        setChannel(band, channel, radio: radio)
    }

    /// A manual channel, from the menu or a click on the lane.
    func pickChannel(_ band: WirelessBand, _ channel: Int) {
        guard let radio = model.wireless?.radio(band) else { return }
        setChannel(band, channel, radio: radio)
    }

    private func setChannel(_ band: WirelessBand, _ channel: Int, radio: WirelessRadio) {
        let autoDFS = (radioEdits ?? newRadioEdits())?.currentAutoDFS
        editRadio(band) { settings in
            settings.channel = channel
            guard let width = settings.width else { return }
            let numbers = radio.channels.map(\.number)
            let holds: (Int) -> Bool = { width in
                channel == 0 ? !(band == .ghz5 && width >= 160 && autoDFS != true) : WiFiLane.fits(band: band, channel: channel, width: width, channels: numbers)
            }
            if !holds(width) { settings.width = radio.widthOptions.filter(holds).max() ?? 20 }
        }
    }

    func revertRadios() { radioEdits = nil }

    private func newRadioEdits() -> WiFiRadioEdits? {
        guard let wireless = model.wireless else { return nil }
        return WiFiRadioEdits(token: model.session.expectedToken, base: wireless, sections: sections)
    }

    /// Review and apply for the staged radio edits.
    func reviewRadios() {
        guard canEdit, let edits = radioEdits else { return }
        begin(edits.base, sections: edits.sections)
        reviewingRadios = true
        review(edits.change)
    }

    func closeSheet() {
        guard !isApplying else { return }
        // A finished apply ends the staged radio edits, whatever its outcome.
        if run?.outcome != nil, reviewingRadios { radioEdits = nil }
        reviewingRadios = false
        sheet = nil
        draft = nil
        pending = nil
        run = nil
        base = nil
        baseSections = nil
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
    /// The `wireless` sections of the network's slots; empty without SSH or
    /// when one cannot be written.
    let roamingSections: [(section: String, band: WirelessBand)]
    let originalRoamingHelp: Bool?
    let originalFastRoaming: Bool?
    var roamingHelp: Bool?
    var fastRoaming: Bool?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.groupID == rhs.groupID && lhs.original == rhs.original && lhs.originalIsolate == rhs.originalIsolate && lhs.name == rhs.name
            && lhs.password == rhs.password && lhs.security == rhs.security && lhs.visible == rhs.visible && lhs.randomBSSID == rhs.randomBSSID
            && lhs.bands == rhs.bands && lhs.isolate == rhs.isolate && lhs.roamingSections.map(\.section) == rhs.roamingSections.map(\.section)
            && lhs.roamingHelp == rhs.roamingHelp && lhs.fastRoaming == rhs.fastRoaming
    }

    init(group: WiFiNetworkGroup, wireless: WirelessStatus, isolate: Bool?, sections: [WirelessSectionOptions]?) {
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

        let bandOf = Dictionary(wireless.radios.flatMap { radio in radio.networks.compactMap { network in
            network.interface.flatMap { interface in radio.band.map { (interface, $0) } }
        } }, uniquingKeysWith: { first, _ in first })
        let own = (sections ?? []).filter { section in section.ifname.map(group.interfaces.contains) ?? false }
        let writable = !own.isEmpty && own.allSatisfy { UCISectionName($0.section) != nil && $0.ifname.flatMap { bandOf[$0] } != nil }
        roamingSections = writable ? own.compactMap { section in section.ifname.flatMap { bandOf[$0] }.map { (section.section, $0) } } : []
        let first = own.first
        originalRoamingHelp = first.flatMap { section in section.ieee80211k.flatMap { k in section.bssTransition.map { k && $0 } } }
        originalFastRoaming = first?.ieee80211r
        roamingHelp = originalRoamingHelp
        fastRoaming = originalFastRoaming
    }

    /// The roaming switches can change: SSH answers and every section has a
    /// name Routewell can write.
    var canWriteRoaming: Bool { !roamingSections.isEmpty }

    /// 6 GHz allows only WPA3.
    var effectiveSecurity: WiFiSecurity { bands.contains(.ghz6) ? .wpa3 : security }

    var edit: WiFiNetworkEdit {
        let samePassword = password == (original.password?.revealed ?? "")
        return WiFiNetworkEdit(interfaces: original.interfaces, name: name, password: samePassword ? original.password : WiFiPassword(password),
                               security: effectiveSecurity, hidden: !visible, randomBSSID: randomBSSID, bands: bands.sorted())
    }

    var change: WiFiChangeSet {
        let edit = edit
        var options: [WiFiOptionEdit] = []
        for (section, band) in roamingSections {
            if let roamingHelp, roamingHelp != originalRoamingHelp { options.append(WiFiOptionEdit(section: section, band: band, setting: .roamingHelp(roamingHelp))) }
            if let fastRoaming, fastRoaming != originalFastRoaming { options.append(WiFiOptionEdit(section: section, band: band, setting: .fastRoaming(fastRoaming))) }
        }
        return WiFiChangeSet(networks: edit == original ? [] : [edit], isolate: isolate != originalIsolate ? isolate : nil, options: options)
    }

    var hasChanges: Bool { change != WiFiChangeSet() }
}

/// The Radios tab's staged edits, against the reads of the first edit.
struct WiFiRadioEdits: Equatable {
    let token: SessionToken?
    let base: WirelessStatus
    let sections: [WirelessSectionOptions]?
    var settings: [WirelessBand: WiFiRadioSettings] = [:]
    /// Auto may use the 5 GHz DFS channels; `nil` keeps the router's value.
    var autoDFS: Bool?

    func original(_ band: WirelessBand) -> WiFiRadioSettings? { base.radio(band).flatMap(WiFiRadioSettings.init) }
    func current(_ band: WirelessBand) -> WiFiRadioSettings? { settings[band] ?? original(band) }

    /// The 5 GHz radio section and its skip list, when SSH read them.
    private var fiveGHz: (radio: WirelessRadio, section: WirelessSectionOptions)? {
        guard let radio = base.radio(.ghz5), let device = radio.device,
              let section = sections?.first(where: { $0.section == device }) else { return nil }
        return (radio, section)
    }

    /// On when Auto may use some DFS channel. `nil` without the skip list.
    var originalAutoDFS: Bool? {
        guard let five = fiveGHz else { return nil }
        let dfs = five.radio.channels.filter(\.dfs).map(\.number)
        return !dfs.allSatisfy((five.section.autoSkips ?? []).contains)
    }

    var currentAutoDFS: Bool? { autoDFS ?? originalAutoDFS }

    var canWriteAutoDFS: Bool { fiveGHz.map { UCISectionName($0.section.section) != nil } ?? false }

    /// The skip list without the DFS channels (on) or with all of them (off).
    private func skips(autoDFS on: Bool) -> [Int]? {
        guard let five = fiveGHz else { return nil }
        let dfs = Set(five.radio.channels.filter(\.dfs).map(\.number))
        let skips = Set(five.section.autoSkips ?? [])
        return Array(on ? skips.subtracting(dfs) : skips.union(dfs)).sorted()
    }

    var change: WiFiChangeSet {
        let radios = WirelessBand.allCases.compactMap { band -> WiFiRadioSettings? in
            guard let settings = settings[band], settings != original(band) else { return nil }
            return settings
        }
        var options: [WiFiOptionEdit] = []
        if let autoDFS, autoDFS != originalAutoDFS, let section = fiveGHz?.section.section, let list = skips(autoDFS: autoDFS) {
            options.append(WiFiOptionEdit(section: section, band: .ghz5, setting: .autoSkips(list)))
        }
        return WiFiChangeSet(radios: radios, options: options)
    }

    /// One per changed field.
    var changeCount: Int {
        var count = 0
        for band in WirelessBand.allCases {
            guard let now = settings[band], let was = original(band) else { continue }
            count += [now.channel != was.channel, now.width != was.width, now.hwmode != was.hwmode, now.txPower != was.txPower,
                      now.pscOnly != was.pscOnly].filter { $0 }.count
        }
        if let autoDFS, autoDFS != originalAutoDFS { count += 1 }
        return count
    }

    var changedBands: [WirelessBand] {
        var bands = Set(change.radios.map(\.band))
        if !change.options.isEmpty { bands.insert(.ghz5) }
        return bands.sorted()
    }
}
