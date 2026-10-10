import Foundation

/// Turns raw GL.iNet RPC `result` payloads into the Overview model types.
///
/// Every router API fact here is `[assumed]`. A missing or
/// differently-typed field always yields `nil`/`.unknown`, never a thrown
/// error — only a caller who cannot even reach the router (nil inputs) should
/// see `.unknown` reachability.
public enum GLiNetStatusParser {
    public static func routerStatus(getStatus: JSONValue?, getInfo: JSONValue?) -> RouterStatus {
        var status = RouterStatus()
        status.reachability = (getStatus != nil || getInfo != nil) ? .connected : .unknown

        let boardInfo = getInfo?["board_info"]
        status.hostname = boardInfo?["hostname"]?.string
        status.model = boardInfo?["model"]?.string ?? getInfo?["model"]?.string
        status.firmware = getInfo?["firmware_version"]?.string
        status.openWrtVersion = boardInfo?["openwrt_version"]?.string
        status.kernelVersion = boardInfo?["kernel_version"]?.string
        status.architecture = boardInfo?["architecture"]?.string

        let system = getStatus?["system"]
        status.lanAddress = system?["lan_ip"]?.string
        // 4.9.1 reports fractional seconds (`413388.56`) `[verified live]`.
        status.uptimeSeconds = numericDouble(system?["uptime"]).flatMap { $0 >= 0 && $0.isFinite ? Int($0) : nil }
        status.loadAverages = system?["load_average"]?.array?.compactMap(numericDouble) ?? []

        let memoryTotal = system?["memory_total"]?.int
        let memoryFree = system?["memory_free"]?.int
        let buffersAndCache = system?["memory_buff_cache"]?.int
        if let memoryTotal, let memoryFree {
            status.memoryTotalBytes = Int64(memoryTotal)
            status.memoryFreeBytes = Int64(memoryFree)
            status.memoryBuffersAndCacheBytes = buffersAndCache.map(Int64.init)
            // Buffers and cache are reclaimable, so they do not count as used
            // when the router reports them (4.9.1 does `[verified live]`).
            let used = memoryTotal - memoryFree - (buffersAndCache ?? 0)
            status.memoryUsedBytes = Int64(used >= 0 ? used : memoryTotal - memoryFree)
        }
        if let total = system?["flash_total"]?.int, let free = system?["flash_free"]?.int, total > 0 {
            status.storageTotalBytes = Int64(total)
            status.storageFreeBytes = Int64(free)
        }
        if let timestamp = numericDouble(system?["timestamp"]), timestamp > 0 {
            status.routerTime = Date(timeIntervalSince1970: timestamp)
        }
        if let sqm = system?["sqm_enabled"]?.bool { status.sqmEnabled = .value(sqm) }

        if let temperature = numericDouble(system?["cpu"]?["temperature"]) {
            status.temperatureCelsius = .value(temperature)
        } else {
            status.temperatureCelsius = .unknown
        }

        return status
    }

    public static func internetStatus(getStatus: JSONValue?, cableStatus: JSONValue?) -> InternetStatus {
        var status = InternetStatus()

        if let wan = getStatus?["network"]?.array?.first(where: { $0["interface"]?.string == "wan" }) {
            switch wan["online"]?.bool {
            case true: status.reachability = .connected
            case false: status.reachability = .unreachable
            case nil: status.reachability = .unknown
            }
        } else {
            status.reachability = .unknown
        }

        status.uplinks = getStatus?["network"]?.array?.compactMap { entry in
            guard let name = entry["interface"]?.string, !name.isEmpty else { return nil }
            return UplinkInterface(name: name,
                                   up: entry["up"]?.bool.map(Observed.value) ?? .unknown,
                                   online: entry["online"]?.bool.map(Observed.value) ?? .unknown)
        } ?? []
        status.wanProtocol = cableStatus?["protocol"]?.string.flatMap { $0.isEmpty ? nil : $0 }

        let ipv4 = cableStatus?["ipv4"]
        if let ip = ipv4?["ip"]?.string {
            status.publicAddress = String(ip.split(separator: "/", maxSplits: 1).first ?? Substring(ip))
        }
        status.gateway = ipv4?["gateway"]?.string
        status.dnsServers = ipv4?["dns"]?.array?.compactMap(\.string) ?? []

        return status
    }

    public static func clientStatus(getStatus: JSONValue?, clientList: JSONValue?) -> ClientStatus {
        var status = ClientStatus()

        if let clients = clientList?["clients"]?.array {
            let activeCount = clients.filter { $0["online"]?.bool == true }.count
            status.activeCount = .value(activeCount)
            if let parsed = clientList.flatMap(GLiNetClientListParser.parse) {
                status.listed = Dictionary(parsed.entries.map { ($0.mac, $0.online) }, uniquingKeysWith: { first, _ in first })
                var byBand: [WirelessBand: Int] = [:]
                for entry in parsed.entries where entry.online == .value(true) {
                    if let band = WirelessBand.parse(entry.interface) { byBand[band, default: 0] += 1 }
                }
                status.onlineByBand = byBand
            }
        } else if let entry = getStatus?["client"]?.array?.first,
                  let wireless = entry["wireless_total"]?.int,
                  let cable = entry["cable_total"]?.int {
            status.activeCount = .value(wireless + cable)
        } else {
            status.activeCount = .unknown
        }

        return status
    }

    /// Numbers or numeric strings; GL.iNet's own examples mix the two.
    private static func numericDouble(_ value: JSONValue?) -> Double? {
        guard let value else { return nil }
        if let value = value.double { return value }
        if let string = value.string { return Double(string) }
        return nil
    }
}
