import Foundation
import RoutewellKit

/// Texts for the network sheet, Use One Name, and Review and apply.
enum WiFiEditFormat {
    /// "2.4 GHz", "5 and 6 GHz", "2.4, 5 and 6 GHz".
    static func bandList(_ bands: [WirelessBand]) -> String {
        let shorts = bands.sorted().map(WiFiFormat.short)
        switch shorts.count {
        case 0: return WiFiFormat.dash
        case 1: return "\(shorts[0]) GHz"
        default: return "\(shorts.dropLast().joined(separator: ", ")) and \(shorts.last!) GHz"
        }
    }

    /// The standard join string a phone camera reads:
    /// `WIFI:T:WPA;S:<name>;P:<password>;H:true;;`.
    static func joinCode(name: String, password: String, security: WiFiSecurity?, hidden: Bool) -> String {
        func escape(_ text: String) -> String {
            var escaped = ""
            for character in text {
                if "\\;,:\"".contains(character) { escaped.append("\\") }
                escaped.append(character)
            }
            return escaped
        }
        var code = "WIFI:"
        code += security?.isSecured == false ? "T:nopass;" : "T:WPA;"
        code += "S:\(escape(name));"
        if security?.isSecured != false { code += "P:\(escape(password));" }
        if hidden { code += "H:true;" }
        return code + ";"
    }

    /// GL's choices for a main network; anything else the router has stays
    /// in the list so it is not changed by accident.
    static func securityChoices(current: WiFiSecurity) -> [WiFiSecurity] {
        let standard: [WiFiSecurity] = [.wpa3, .wpa2WPA3, .wpa2]
        return standard.contains(current) ? standard : standard + [current]
    }

    static func problem(_ problem: WiFiEditProblem) -> String {
        switch problem {
        case .emptyName: "Enter a name."
        case .nameTooLong: "The name can have at most 32 bytes."
        case .passwordLength: "The password needs 8 to 63 characters."
        case .noBand: "Choose at least one band."
        case .wpa3With6GHz: "6 GHz allows only WPA3."
        }
    }

    static let radarCheckTime = "The radar check takes about 1 minute, or up to 10 minutes on some channels."

    static func channel(_ channel: Int) -> String { channel == 0 ? "Auto" : "\(channel)" }
    static func width(_ width: Int?) -> String { width.map { "\($0) MHz" } ?? "Auto" }

    static func onOff(_ value: Bool?) -> String {
        switch value { case true?: "On"; case false?: "Off"; case nil: WiFiFormat.dash }
    }

    /// The sheet's footer: who must join again, by the network they use now.
    static func mustJoinLine(_ plan: WiFiApplyPlan, devices: [WiFiDevice]) -> String? {
        guard !plan.mustJoin.isEmpty else { return nil }
        let members = devices.filter { plan.mustJoin.contains($0.mac) }
        var order: [String] = []
        var counts: [String: Int] = [:]
        for device in members {
            let name = device.network ?? WiFiFormat.dash
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += 1
        }
        guard !order.isEmpty else { return nil }
        return "Must join again: " + order.map { "\(WiFiFormat.devices(counts[$0] ?? 0)) on \($0)" }.joined(separator: ", ")
    }

    /// A band tile's second line in the network sheet.
    static func bandTile(_ band: WirelessBand, draft: WiFiNetworkDraft, wireless: WirelessStatus, devices: [WiFiDevice]) -> String {
        let main = wireless.radio(band)?.mainNetwork
        if draft.original.bands.contains(band) {
            guard let interface = main?.interface else { return WiFiFormat.dash }
            let count = devices.filter { $0.interface == interface || ($0.interface == nil && $0.band == band) }.count
            return count == 0 ? "Not used" : WiFiFormat.devices(count)
        }
        if let main, main.isOn, let name = main.ssid { return "Used by \(name)" }
        return "Not used"
    }

    /// The band another name holds that this draft takes.
    static func movedBands(_ draft: WiFiNetworkDraft, wireless: WirelessStatus) -> [WirelessBand] {
        draft.bands.filter { band in
            !draft.original.bands.contains(band) && wireless.radio(band)?.mainNetwork?.isOn == true
        }.sorted()
    }
}

enum WiFiRadioFormat {
    /// The radios' country code as the router reports it (SSH).
    static func country(_ air: WiFiAir?) -> String { "Country: \(air?.country ?? WiFiFormat.dash)" }

    /// "1 change · 5 GHz restarts", "3 changes · 2.4 and 5 GHz restart".
    static func applyBar(_ edits: WiFiRadioEdits) -> String {
        let count = edits.changeCount
        let bands = edits.changedBands
        let changes = "\(count) \(count == 1 ? "change" : "changes")"
        guard !bands.isEmpty else { return changes }
        return "\(changes) · \(WiFiEditFormat.bandList(bands)) \(bands.count == 1 ? "restarts" : "restart")"
    }
}

/// The networks before and after, as small cards.
struct WiFiMiniNetwork: Equatable, Identifiable {
    let name: String
    let bands: [WirelessBand]
    var id: String { name }
}

/// Review and apply: title, before and after, the change list, and the
/// impact rows.
struct WiFiReviewPresentation: Equatable {
    struct Impact: Equatable, Identifiable {
        enum Kind: Equatable { case restart, devices, thisMac }
        let kind: Kind
        let bold: String
        let rest: String
        var id: String { "\(kind)-\(bold)" }
    }

    let title: String
    let before: [WiFiMiniNetwork]
    let after: [WiFiMiniNetwork]
    let changes: [String]
    let impacts: [Impact]
    /// Said when this Mac must join by hand.
    let ethernetHint: String?
    let macDrops: Bool

    /// Estimated, not measured: a guide that the change is not instant.
    static let networkRestart = "about 5 s"
    static let radioRestart = "about 20 s"

    init(change: WiFiChangeSet, plan: WiFiApplyPlan, wireless: WirelessStatus, sections: [WirelessSectionOptions]? = nil) {
        let applied = Self.applied(plan, to: wireless)
        before = Self.mains(wireless)
        after = Self.mains(applied)

        var changes: [String] = []
        let slots = Dictionary(wireless.radios.flatMap { radio in radio.networks.compactMap { network in network.interface.map { ($0, (radio.band, network)) } } },
                               uniquingKeysWith: { first, _ in first })
        for edit in change.networks {
            guard let original = edit.interfaces.first.flatMap({ slots[$0]?.1 }) else { continue }
            let name = original.ssid ?? WiFiFormat.dash
            if original.ssid != edit.name { changes.append("Name: \(name) → \(edit.name)") }
            if let password = edit.password, original.password != password { changes.append("\(edit.name): new password") }
            if original.encryption != edit.security {
                changes.append("\(edit.name) security: \(WiFiFormat.security(original.encryption)) → \(WiFiFormat.security(edit.security))")
            }
            if (original.hidden ?? false) != edit.hidden { changes.append("\(edit.name) visible: \(WiFiEditFormat.onOff(!edit.hidden))") }
            if (original.randomBSSID ?? true) != edit.randomBSSID {
                changes.append("\(edit.name) random hardware address: \(WiFiEditFormat.onOff(edit.randomBSSID))")
            }
            for (band, network) in edit.interfaces.dropFirst().compactMap({ slots[$0] }) where edit.sameOnEveryBand {
                let band = WiFiFormat.band(band)
                if let password = edit.password, network.password != password { changes.append("\(edit.name) \(band): same password as the other bands") }
                if network.encryption != edit.security {
                    changes.append("\(edit.name) \(band) security: \(WiFiFormat.security(network.encryption)) → \(WiFiFormat.security(edit.security))")
                }
            }
            let had = Set(edit.interfaces.compactMap { slots[$0]?.0 })
            for band in edit.bands where !had.contains(band) {
                if let other = wireless.radio(band)?.mainNetwork, other.isOn, let otherName = other.ssid {
                    changes.append("\(WiFiFormat.band(band)) moves from \(otherName) to \(edit.name)")
                } else {
                    changes.append("\(edit.name) adds \(WiFiFormat.band(band))")
                }
            }
            for band in had.subtracting(edit.bands).sorted() { changes.append("\(edit.name) stops using \(WiFiFormat.band(band))") }
        }
        if let isolate = change.isolate { changes.append("Isolate devices: \(WiFiEditFormat.onOff(isolate)), on every main network") }
        changes += Self.radioLines(change.radios, wireless: wireless)
        changes += Self.optionLines(change.options, wireless: wireless, sections: sections)
        self.changes = changes
        let count = max(1, changes.count)
        title = count == 1 ? "Apply 1 change?" : "Apply \(count) changes?"

        var impacts: [Impact] = []
        let radios = plan.restarts.compactMap { if case .radio(let band) = $0 { band } else { nil } }
        let networks = plan.restarts.compactMap { if case .network(let band) = $0 { band } else { nil } }
        if !radios.isEmpty {
            impacts.append(Impact(kind: .restart, bold: WiFiEditFormat.bandList(radios),
                                  rest: "\(radios.count == 1 ? "restarts" : "restart"), \(Self.radioRestart)"))
        }
        if !networks.isEmpty {
            impacts.append(Impact(kind: .restart, bold: "The network on \(WiFiEditFormat.bandList(networks))",
                                  rest: "restarts, \(Self.networkRestart); other networks there stay up"))
        }
        if plan.restarts.contains(.subnet) {
            impacts.append(Impact(kind: .restart, bold: "Main network settings", rest: "reload, \(Self.networkRestart)"))
        }
        if let check = plan.radarCheck {
            impacts.append(Impact(kind: .restart, bold: WiFiFormat.band(check.band),
                                  rest: "checks channel \(check.channel) for radar first. \(WiFiEditFormat.radarCheckTime)"))
        }
        if !plan.mustJoin.isEmpty {
            impacts.append(Impact(kind: .devices, bold: WiFiFormat.devices(plan.mustJoin.count), rest: "must join again"))
        }
        if !plan.reconnect.isEmpty {
            impacts.append(Impact(kind: .devices, bold: WiFiFormat.devices(plan.reconnect.count), rest: "drop, then join again by themselves"))
        }
        impacts.append(Impact(kind: .thisMac, bold: "This Mac", rest: Self.macLine(plan.thisMac)))
        self.impacts = impacts
        macDrops = plan.thisMac.drops
        ethernetHint = switch plan.thisMac {
        case .mustJoin, .mustEnterPassword: "Use Ethernet for this change if you can."
        default: nil
        }
    }

    /// One line per changed radio field.
    static func radioLines(_ radios: [WiFiRadioSettings], wireless: WirelessStatus) -> [String] {
        var lines: [String] = []
        for now in radios {
            guard let was = wireless.radio(now.band).flatMap(WiFiRadioSettings.init) else { continue }
            let band = WiFiFormat.band(now.band)
            if now.channel != was.channel { lines.append("\(band) channel: \(WiFiEditFormat.channel(was.channel)) → \(WiFiEditFormat.channel(now.channel))") }
            if now.width != was.width { lines.append("\(band) width: \(WiFiEditFormat.width(was.width)) → \(WiFiEditFormat.width(now.width))") }
            if now.hwmode != was.hwmode {
                lines.append("\(band) Wi-Fi versions: \(WiFiFormat.versions(was.hwmode, band: now.band)) → \(WiFiFormat.versions(now.hwmode, band: now.band))")
            }
            if now.txPower != was.txPower { lines.append("\(band) power: \(WiFiFormat.power(was.txPower)) → \(WiFiFormat.power(now.txPower))") }
            if now.pscOnly != was.pscOnly {
                lines.append("\(band) preferred channels only: \(WiFiEditFormat.onOff(was.pscOnly)) → \(WiFiEditFormat.onOff(now.pscOnly))")
            }
        }
        return lines
    }

    /// One line per option and network name.
    static func optionLines(_ options: [WiFiOptionEdit], wireless: WirelessStatus, sections: [WirelessSectionOptions]?) -> [String] {
        var lines: [String] = []
        for option in options {
            let line: String
            switch option.setting {
            case .autoSkips(let skips):
                let dfs = wireless.radio(option.band)?.channels.filter(\.dfs).map(\.number) ?? []
                line = "\(WiFiFormat.band(option.band)) DFS channels for Auto: \(WiFiEditFormat.onOff(!dfs.allSatisfy(skips.contains)))"
            case .roamingHelp(let on), .fastRoaming(let on):
                let ifname = sections?.first { $0.section == option.section }?.ifname
                let name = wireless.networks.first { $0.interface == ifname && ifname != nil }?.ssid ?? WiFiFormat.dash
                let what = if case .roamingHelp = option.setting { "roaming help" } else { "fast roaming" }
                line = "\(name) \(what): \(WiFiEditFormat.onOff(on))"
            }
            if !lines.contains(line) { lines.append(line) }
        }
        return lines
    }

    static func macLine(_ impact: ThisMacImpact) -> String {
        switch impact {
        case .staysOnEthernet: "stays on Ethernet"
        case .staysConnected: "stays connected"
        case .dropsThenJoins(let name): "drops, then joins \(name)"
        case .mustJoin(let name): "must join \(name) by hand"
        case .mustEnterPassword(let name): "must enter the new password for \(name)"
        case .unknown: "may lose the router for a moment"
        }
    }

    /// The main networks by name, in band order.
    static func mains(_ wireless: WirelessStatus) -> [WiFiMiniNetwork] {
        var order: [String] = []
        var bands: [String: [WirelessBand]] = [:]
        for radio in wireless.radios.sorted(by: { ($0.band ?? .ghz6) < ($1.band ?? .ghz6) }) {
            guard let network = radio.mainNetwork, network.isOn, let name = network.ssid, let band = radio.band else { continue }
            if bands[name] == nil { order.append(name) }
            bands[name, default: []].append(band)
        }
        return order.map { WiFiMiniNetwork(name: $0, bands: bands[$0] ?? []) }
    }

    /// The router's networks with the plan's calls applied.
    static func applied(_ plan: WiFiApplyPlan, to wireless: WirelessStatus) -> WirelessStatus {
        var result = wireless
        for call in plan.calls {
            guard case .network(let slot, _, _) = call else { continue }
            for radio in result.radios.indices {
                for index in result.radios[radio].networks.indices where result.radios[radio].networks[index].interface == slot.interface {
                    result.radios[radio].networks[index].ssid = slot.ssid
                    if let enabled = slot.enabled { result.radios[radio].networks[index].enabled = .value(enabled) }
                }
            }
        }
        return result
    }

    /// The progress trail: Send changes, Restart, then Reconnect this Mac
    /// or Check the router.
    static func trail(macDrops: Bool) -> [String] {
        ["Send changes", "Restart", macDrops ? "Reconnect this Mac" : "Check the router"]
    }

    static func trailIndex(_ step: WiFiApplyStep) -> Int {
        switch step {
        case .sending: 0
        case .restarting, .radarCheck: 1
        case .reconnecting, .checking: 2
        }
    }

    /// The progress title: the current trail step, or the radar check.
    static func progressTitle(_ step: WiFiApplyStep, plan: WiFiApplyPlan) -> String {
        if step == .radarCheck {
            return "Checking \(plan.radarCheck.map { WiFiFormat.band($0.band) } ?? "Wi-Fi") for radar…"
        }
        return "\(trail(macDrops: plan.thisMac.drops)[trailIndex(step)])…"
    }
}

/// The last screen of an apply.
struct WiFiOutcomePresentation: Equatable {
    enum Tone: Equatable { case success, warning, neutral }
    let title: String
    let text: String
    let tone: Tone
    let showsWiFiSettings: Bool

    init(_ outcome: MutationOutcome<WiFiApplyState>, run: WiFiApplyRun) {
        let join: String? = switch run.plan.thisMac {
        case .dropsThenJoins(let name), .mustJoin(let name), .mustEnterPassword(let name): name
        default: nil
        }
        switch outcome {
        case .verifiedSuccess:
            title = "Applied"
            text = switch run.plan.thisMac {
            case .mustJoin(let name): "Join \(name) on this Mac if it does not join by itself."
            case .mustEnterPassword(let name): "Enter the new password for \(name) on this Mac if it asks."
            default: run.plan.mustJoin.isEmpty ? "The router has the new settings." : "Devices on the changed networks must join again with the new settings."
            }
            tone = .success
            showsWiFiSettings = false
        case .unknownAfterDispatch where run.macWasOnWiFi:
            title = "This Mac is not back on Wi-Fi"
            text = "Join \(join ?? "the router's network") on this Mac. Routewell then connects again by itself."
            tone = .warning
            showsWiFiSettings = true
        case .unknownAfterDispatch:
            title = "The router did not answer"
            text = "Routewell could not check the change. It may have applied. Routewell reads the router again when it answers."
            tone = .warning
            showsWiFiSettings = false
        case .verifiedMismatch(_, let actual) where !actual.radar.isEmpty:
            let band = actual.radar.first
            title = "Radar on \(WiFiFormat.band(band))"
            let channel = run.plan.radarCheck.map { "channel \($0.channel)" } ?? "this channel"
            text = "\(WiFiFormat.band(band)) found radar during its check, so it cannot use \(channel) now. Choose another channel or Auto."
            tone = .warning
            showsWiFiSettings = false
        case .verifiedMismatch:
            title = "Not every change applied"
            text = "The router has other values than Routewell sent. The Wi-Fi screen shows what the router has now."
            tone = .warning
            showsWiFiSettings = false
        case .conflictingExternalEdit:
            title = "Changed on the router"
            text = "The Wi-Fi settings changed after this sheet opened. Nothing was sent. Open the network again to see the new values."
            tone = .neutral
            showsWiFiSettings = false
        case .rejected(let rejection):
            title = "Not applied"
            text = switch rejection {
            case .preconditionFailed(let message), .invalidIntent(let message): message
            case .capabilityUnavailable: "This router does not accept Wi-Fi changes from Routewell."
            case .gateBusy: "Another change is running. Try again when it ends."
            case .staleSession: "The router connection changed. Nothing was sent."
            }
            tone = .neutral
            showsWiFiSettings = false
        case .verifiedRecovery, .recoveryFailed:
            title = "Settings put back"
            text = "The router has the earlier settings."
            tone = .neutral
            showsWiFiSettings = false
        }
    }
}
