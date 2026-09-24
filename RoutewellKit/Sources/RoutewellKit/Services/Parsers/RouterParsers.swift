import Foundation

/// `wifi get_config` joined with `wifi get_status`, `[verified live]` on
/// firmware 4.9.1: `get_config` `band` is `2G`/`5G`/`6G`, `get_status`
/// `band` is `2g`/`5g`/`6g`, so the join ignores case.
public enum WirelessParser {
    /// `nil` when `get_config` has no `res` array (a malformed reply).
    public static func parse(config: JSONValue, status: JSONValue?) -> WirelessStatus? {
        guard let radios = config["res"]?.array else { return nil }
        var channels: [WirelessBand: Int] = [:]
        for radio in status?["res"]?.array ?? [] {
            if let band = WirelessBand.parse(radio["band"]?.string), let channel = radio["channel"]?.int, channel > 0 {
                channels[band] = channels[band] ?? channel
            }
        }
        return WirelessStatus(radios: radios.map { radio in
            let band = WirelessBand.parse(radio["band"]?.string)
            return WirelessRadio(
                device: text(radio["device"]),
                band: band,
                configuredChannel: radio["channel"]?.int,
                currentChannel: band.flatMap { channels[$0] },
                htmode: text(radio["htmode"]),
                txPower: text(radio["txpower"]) ?? radio["txpower"]?.double.map { $0.formatted() },
                networks: (radio["ifaces"]?.array ?? []).map { iface in
                    WirelessNetwork(interface: text(iface["name"]), ssid: text(iface["ssid"]),
                                    enabled: iface["enabled"]?.bool.map(Observed.value) ?? .unknown,
                                    guest: iface["guest"]?.bool, iot: iface["iot"]?.bool)
                }
            )
        })
    }

    private static func text(_ value: JSONValue?) -> String? {
        guard let raw = value?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return raw
    }
}

public enum SQMParser {
    /// `nil` when the reply is not an object. Missing fields stay unknown.
    public static func parse(_ result: JSONValue) -> SQMConfiguration? {
        guard result.object != nil else { return nil }
        let enabled: Observed<Bool> = switch result["enable"] {
        case .bool(let value)?: .value(value)
        case .number(let value)? where value == 0 || value == 1: .value(value == 1)
        default: .unknown
        }
        return SQMConfiguration(enabled: enabled, queueDiscipline: value(result["qdisc"]),
                                upload: value(result["upload"]), download: value(result["download"]))
    }

    /// Numbers and strings both appear; empty means unset.
    private static func value(_ json: JSONValue?) -> String? {
        switch json {
        case .string(let text)?:
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        case .number(let number)?:
            return number == number.rounded() ? String(Int(number)) : String(number)
        default:
            return nil
        }
    }
}

public enum FirmwareCheckParser {
    /// On 4.9.1 with no update the reply holds only `current_version`,
    /// `current_compile_time`, and `current_type` `[verified live]`, which
    /// does not say that no update exists, so it reads as ambiguous.
    /// Ambiguous data is never read as "up to date": only an explicit
    /// `update_available` flag, or two equal version strings, decide it.
    public static func parse(_ result: JSONValue, at date: Date) -> FirmwareCheck {
        let current = version(result["current_version"])
        let latest = version(result["new_firmware_version"])
        let flag: Bool? = switch result["update_available"] {
        case .bool(let value)?: value
        case .number(let value)? where value == 0 || value == 1: value == 1
        default: nil
        }
        let status: FirmwareUpdateStatus
        switch (flag, current, latest) {
        case (true?, _, _): status = .updateAvailable
        case (false?, _, _): status = .upToDate
        case (nil, let current?, let latest?): status = current == latest ? .upToDate : .updateAvailable
        default: status = .unableToCheck(.ambiguousReply)
        }
        let notes = notes(result["release_note"]) ?? notes(result["release_notes"])
        return FirmwareCheck(current: current.map(Observed.value) ?? .unknown,
                             latest: latest.map(Observed.value) ?? (status == .upToDate ? current.map(Observed.value) ?? .unknown : .unknown),
                             status: status, releaseNotes: notes, checkedAt: date)
    }

    private static func version(_ value: JSONValue?) -> String? {
        guard let text = value?.string?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        return text
    }

    /// One string, or an array of strings joined by lines.
    private static func notes(_ value: JSONValue?) -> String? {
        switch value {
        case .string(let text)?:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .array(let items)?:
            let lines = items.compactMap(\.string).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        default:
            return nil
        }
    }
}
