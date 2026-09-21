import Foundation

/// Turns raw GL.iNet RPC `result` payloads into the Overview model types.
///
/// Every router API fact here is "assumed" (see chunk 09 plan). A missing or
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

        let system = getStatus?["system"]
        status.lanAddress = system?["lan_ip"]?.string
        status.uptimeSeconds = system?["uptime"]?.int
        status.loadAverages = system?["load_average"]?.array?.compactMap(numericDouble) ?? []

        let memoryTotal = system?["memory_total"]?.int
        let memoryFree = system?["memory_free"]?.int
        if let memoryTotal, let memoryFree {
            status.memoryTotalBytes = Int64(memoryTotal)
            status.memoryUsedBytes = Int64(memoryTotal - memoryFree)
        }

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
