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
    /// The air map dot under the pointer, which shows its card.
    var hovered: MACAddress?
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
    /// The `get_mlo_config` read the sheet opened with.
    private(set) var baseMLO: MLOConfiguration?
    /// The Radios tab's staged edits; none once their session has ended.
    var radioEdits: WiFiRadioEdits? {
        get { stagedRadios?.token == model.session.expectedToken ? stagedRadios : nil }
        set { stagedRadios = newValue }
    }
    private var stagedRadios: WiFiRadioEdits?
    private var reviewingRadios = false
    /// The network sheet's fields.
    var draft: WiFiNetworkDraft?
    /// The guest or IoT sheet's fields.
    var guestDraft: WiFiGuestDraft?
    /// Use One Name's "Keep the name".
    var keepName: String?
    /// The multi-link setup sheet's fields.
    var mloDraft: WiFiMLODraft?
    /// The Multi-link tab's staged edits; none once their session has ended.
    var mloEdits: WiFiMLODraft? {
        get { stagedMLO?.token == model.session.expectedToken ? stagedMLO?.draft : nil }
        set { stagedMLO = newValue.map { (model.session.expectedToken, $0) } }
    }
    private var stagedMLO: (token: SessionToken?, draft: WiFiMLODraft)?
    private var reviewingMLO = false
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

    var mlo: MLOConfiguration? { try? model.wifi?.mlo.get() }

    /// The Wi-Fi 7 devices, which can use multi-link.
    var wifi7Devices: [WiFiDevice] { (overview?.devices ?? []).filter { $0.generation == .wifi7 } }

    /// The setup sheet: bands, name, review, then Turn On.
    func openMultiLinkSetup() {
        guard canEdit, let wireless = model.wireless, let network = mlo?.main else { return }
        begin(wireless)
        mloDraft = WiFiMLODraft(network: network, wireless: wireless, mlo: mlo, setup: true)
        sheet = .multiLink
    }

    /// Stages a change on the Multi-link tab. The first edit keeps the reads
    /// it started from.
    func editMLO(_ change: (inout WiFiMLODraft) -> Void) {
        guard canEdit, let wireless = model.wireless, let network = mlo?.main else { return }
        var draft = mloEdits ?? WiFiMLODraft(network: network, wireless: wireless, mlo: mlo, setup: false)
        change(&draft)
        mloEdits = draft
    }

    func revertMLO() { mloEdits = nil }

    /// The staged edits, else the network as the router has it.
    var mloShown: WiFiMLODraft? {
        if let mloEdits { return mloEdits }
        guard let wireless = model.wireless, let network = mlo?.main else { return nil }
        return WiFiMLODraft(network: network, wireless: wireless, mlo: mlo, setup: false)
    }

    /// Review and apply for the Multi-link tab's staged edits.
    func reviewMLO() {
        guard canEdit, let draft = mloEdits else { return }
        begin(draft.wireless, mlo: draft.mlo)
        reviewingMLO = true
        review(draft.change)
    }

    /// Turn On from the setup sheet: the sheet is its own review.
    func turnOnMultiLink() {
        guard canEdit, let draft = mloDraft else { return }
        pending = draft.change
        apply()
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

    /// The guest or IoT sheet: set up when the network is off, change or
    /// turn off when it is on. The IoT sheet picks the devices the
    /// "own network" suggestion names. A card's group keeps the sheet to
    /// that card's slots when the bands have different names.
    func openGuest(_ kind: WiFiNetworkKind, group: WiFiNetworkGroup? = nil) {
        guard canEdit, let wireless = model.wireless else { return }
        begin(wireless)
        let suggested = overview?.suggestions.first { $0.kind == .ownNetwork }?.devices ?? []
        guestDraft = WiFiGuestDraft(kind: kind, wireless: wireless, subnet: subnet(kind), group: group,
                                    mainNames: overview?.groups.filter { $0.kind == .main }.map(\.name) ?? [],
                                    moving: kind == .iot ? Set(suggested) : [])
        sheet = .guestIoT
    }

    func subnet(_ kind: WiFiNetworkKind) -> SubnetPolicy? {
        subnets?.first { $0.name == WiFiSubnetRules.subnetName(kind) }
    }

    /// The devices the IoT sheet can offer to move: on a main network on 2.4 GHz.
    var moveCandidates: [WiFiDevice] {
        (overview?.devices ?? []).filter { $0.kind == .main && $0.band == .ghz2_4 && !$0.viaLink }
    }

    func isPrinter(_ mac: MACAddress) -> Bool { model.deviceRegistry.records[mac]?.category == .printer }

    /// The moved devices that are on the IoT network now.
    func joinedIoT(_ macs: Set<MACAddress>) -> Set<MACAddress> {
        WiFiClientInfo.joined(Array(macs), clients: clients, subnet: subnet(.iot))
    }

    /// Turn On applies at once: the sheet is its own review.
    func turnOn() {
        guard canEdit, let draft = guestDraft else { return }
        let change = draft.change
        guestDraft?.movingDevices = moveCandidates.filter { draft.moving.contains($0.mac) }
        pending = change
        apply()
    }

    private func begin(_ wireless: WirelessStatus, sections: [WirelessSectionOptions]? = nil, mlo: MLOConfiguration? = nil) {
        editToken = model.session.expectedToken
        base = wireless
        baseSections = sections ?? self.sections
        baseMLO = mlo ?? self.mlo
        reviewingRadios = false
        reviewingMLO = false
        draft = nil
        guestDraft = nil
        mloDraft = nil
        pending = nil
        run = nil
    }

    /// The plan for a change against the values the sheet opened with.
    func plan(for change: WiFiChangeSet) -> WiFiApplyPlan? {
        guard editToken == model.session.expectedToken, let wireless = base else { return nil }
        return WiFiApplyPlan(change: change, wireless: wireless, subnets: subnets, options: baseSections, mlo: baseMLO,
                             devices: overview?.devices ?? [], thisMac: thisMacLink)
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

    /// Stages Auto's use of the DFS channels on 5 GHz (SSH). Off drops a
    /// width Auto can no longer use.
    func setAutoDFS(_ on: Bool) {
        guard canEdit, var edits = radioEdits ?? newRadioEdits(), edits.canWriteAutoDFS else { return }
        edits.autoDFS = on
        radioEdits = edits
        if !on, let radio = model.wireless?.radio(.ghz5), let channel = edits.current(.ghz5)?.channel { setChannel(.ghz5, channel, radio: radio) }
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
        if run?.outcome != nil, reviewingMLO { mloEdits = nil }
        reviewingRadios = false
        reviewingMLO = false
        sheet = nil
        draft = nil
        guestDraft = nil
        mloDraft = nil
        pending = nil
        run = nil
        base = nil
        baseSections = nil
        baseMLO = nil
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
    case network, useOneName, guestIoT, multiLink, review
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
    /// The `wireless` sections of the network's slots, and of the slot each
    /// other band would use; empty without SSH or when one of the network's
    /// own cannot be written.
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
        var roaming = writable ? own.compactMap { section in section.ifname.flatMap { bandOf[$0] }.map { (section: section.section, band: $0) } } : []
        for radio in wireless.radios where writable {
            guard let band = radio.band, !roaming.contains(where: { $0.band == band }), let interface = radio.mainNetwork?.interface,
                  let section = sections?.first(where: { $0.ifname == interface }), UCISectionName(section.section) != nil else { continue }
            roaming.append((section.section, band))
        }
        roamingSections = roaming
        let first = own.first
        if writable {
            // A missing flag is off.
            originalRoamingHelp = (first?.ieee80211k ?? false) && (first?.bssTransition ?? false)
            originalFastRoaming = first?.ieee80211r ?? false
        } else {
            originalRoamingHelp = first.flatMap { section in section.ieee80211k.flatMap { k in section.bssTransition.map { k && $0 } } }
            originalFastRoaming = first?.ieee80211r
        }
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
        // An added band gets the network's values; the plan drops writes it
        // already has.
        for (section, band) in roamingSections where bands.contains(band) {
            let added = !original.bands.contains(band)
            if let roamingHelp, added || roamingHelp != originalRoamingHelp { options.append(WiFiOptionEdit(section: section, band: band, setting: .roamingHelp(roamingHelp))) }
            if let fastRoaming, added || fastRoaming != originalFastRoaming { options.append(WiFiOptionEdit(section: section, band: band, setting: .fastRoaming(fastRoaming))) }
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

/// The guest or IoT sheet's fields, and the change they make. The network
/// is on when the router has one of its slots on.
struct WiFiGuestDraft: Equatable {
    let kind: WiFiNetworkKind
    /// The network as read; no bands when it is off.
    let original: WiFiNetworkEdit
    let originalRules: WiFiSubnetRules?
    /// "192.168.9.1/24".
    let range: String?
    /// The main network names, for the help texts.
    let mainNames: [String]
    var name: String
    var password: String
    /// IoT only; the guest network's security follows the bands.
    var security: WiFiSecurity
    var visible: Bool
    var bands: Set<WirelessBand>
    /// `nil` when the subnet read failed.
    var eachOther: Bool?
    var reachesModem: Bool?
    var moving: Set<MACAddress>
    /// The chosen devices as they were at Turn On, for the join list.
    var movingDevices: [WiFiDevice] = []

    init(kind: WiFiNetworkKind, wireless: WirelessStatus, subnet: SubnetPolicy?, group: WiFiNetworkGroup? = nil, mainNames: [String],
         moving: Set<MACAddress>) {
        let slots = wireless.radios.compactMap { radio in radio.network(kind).map { (band: radio.band, network: $0) } }
        let on = slots.filter { slot in slot.network.isOn && (group.map { slot.network.interface.map($0.interfaces.contains) ?? false } ?? true) }
        let first = on.first?.network ?? slots.first?.network
        original = WiFiNetworkEdit(kind: kind, interfaces: on.compactMap(\.network.interface), name: first?.ssid ?? "",
                                   password: first?.password, security: first?.encryption ?? .wpa2WPA3, hidden: first?.hidden ?? false,
                                   randomBSSID: first?.randomBSSID ?? true, bands: on.compactMap(\.band).sorted())
        self.kind = kind
        self.mainNames = mainNames
        range = subnet?.range
        let rules = subnet.map { WiFiSubnetRules(kind: kind, subnet: $0) }
        originalRules = rules
        let isOn = !original.bands.isEmpty
        let fallback = "\(mainNames.first ?? "Flint") \(kind == .guest ? "Guest" : "IoT")"
        name = first?.ssid ?? fallback
        let key = first?.password?.revealed ?? ""
        password = isOn || key.count >= 8 ? key : Self.newPassword()
        security = kind == .iot && [.wpa2, .wpa2WPA3].contains(original.security) ? original.security : .wpa2
        visible = !original.hidden
        bands = isOn ? Set(original.bands) : kind == .iot ? [.ghz2_4] : [.ghz2_4, .ghz5]
        // Off: the design's defaults. On: as the router has them.
        eachOther = rules.flatMap { isOn ? $0.eachOther : kind == .iot }
        reachesModem = rules.flatMap { isOn ? $0.reachesModem : false }
        self.moving = moving
    }

    var isOn: Bool { !original.bands.isEmpty }

    /// The guest network uses WPA3 with 6 GHz, else WPA2/WPA3.
    var effectiveSecurity: WiFiSecurity {
        kind == .guest ? (bands.contains(.ghz6) ? .wpa3 : .wpa2WPA3) : security
    }

    var edit: WiFiNetworkEdit {
        let samePassword = password == (original.password?.revealed ?? "")
        return WiFiNetworkEdit(kind: kind, interfaces: original.interfaces, name: name, password: samePassword ? original.password : WiFiPassword(password),
                               security: effectiveSecurity, hidden: !visible, randomBSSID: original.randomBSSID, bands: bands.sorted())
    }

    var change: WiFiChangeSet {
        let edit = edit
        // Only the rules the person changed; the others stay as the router has them now.
        let rules = WiFiSubnetRules(kind: kind, eachOther: eachOther == originalRules?.eachOther ? nil : eachOther,
                                    reachesModem: reachesModem == originalRules?.reachesModem ? nil : reachesModem)
        let changed = rules.eachOther != nil || rules.reachesModem != nil
        return WiFiChangeSet(networks: edit == original ? [] : [edit], rules: changed ? [rules] : [])
    }

    var turnOffChange: WiFiChangeSet {
        var edit = original
        edit.bands = []
        return WiFiChangeSet(networks: [edit])
    }

    /// Three groups of four letters and digits that are easy to read out.
    static func newPassword() -> String {
        let characters = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return (0..<3).map { _ in String((0..<4).map { _ in characters.randomElement()! }) }.joined(separator: "-")
    }
}

/// The multi-link network's fields, from the setup sheet or the Multi-link
/// tab, and the change they make. Security is WPA3: 6 GHz allows only WPA3,
/// and GL's own page offers nothing else.
struct WiFiMLODraft: Equatable {
    /// The reads the draft started from.
    let wireless: WirelessStatus
    let mlo: MLOConfiguration?
    let original: MLONetwork
    /// The main network on 6 GHz, else on 5 GHz: the "Same as" name and the
    /// "Same password as" key.
    let fastName: String?
    let fastPassword: WiFiPassword?
    var enabled: Bool
    var bands: Set<WirelessBand>
    var sameName: Bool
    var name: String
    var samePassword: Bool
    var password: String

    /// `setup`: the design's defaults (on, 5 + 6 GHz, a new name, the same
    /// password); else as the router has it.
    init(network: MLONetwork, wireless: WirelessStatus, mlo: MLOConfiguration? = nil, setup: Bool) {
        self.wireless = wireless
        self.mlo = mlo
        original = network
        let fast = [WirelessBand.ghz6, .ghz5].lazy.compactMap { wireless.radio($0)?.mainNetwork }.first { $0.isOn }
        fastName = fast?.ssid
        fastPassword = fast?.password
        let home = wireless.radio(.ghz2_4)?.mainNetwork?.ssid ?? fast?.ssid ?? "Flint"
        if setup {
            enabled = true
            bands = [.ghz5, .ghz6]
            sameName = false
            name = "\(home) 7"
            samePassword = fastPassword != nil
            password = fastPassword == nil ? WiFiGuestDraft.newPassword() : ""
        } else {
            enabled = network.isOn
            bands = Set(network.bands)
            sameName = false
            name = network.ssid ?? ""
            samePassword = fastPassword != nil && network.password == fastPassword
            password = network.password?.revealed ?? ""
        }
    }

    var network: MLONetwork {
        var network = original
        network.enabled = .value(enabled)
        network.bands = bands.sorted()
        network.ssid = sameName ? fastName : name
        network.encryption = .wpa3
        network.password = if samePassword { fastPassword } else if password == original.password?.revealed { original.password } else { WiFiPassword(password) }
        return network
    }

    var change: WiFiChangeSet { network.sent == original.sent ? WiFiChangeSet() : WiFiChangeSet(mlo: network) }

    var hasChanges: Bool { change != WiFiChangeSet() }
}
