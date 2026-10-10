import Foundation

/// Joins AdGuard Home data onto the router's client list: by
/// MAC when AdGuard knows one, else by IP. An IP join happens only when one
/// router client clearly owns that IP, because stale offline entries can
/// share an address with a current device `[verified live]`.
public enum ClientMerge {
    public static func merge(
        router: [RouterClientEntry],
        adGuardDirectory: AdGuardClientsParser.Directory?,
        topClientQueries: [String: Int]?
    ) -> [Client] {
        let owners = ipOwners(router)
        var persistentByMAC: [MACAddress: String] = [:]
        var persistentByIP: [String: String] = [:]
        for persistent in adGuardDirectory?.persistent ?? [] {
            for mac in persistent.macs where persistentByMAC[mac] == nil { persistentByMAC[mac] = persistent.name }
            for ip in persistent.ips where persistentByIP[ip] == nil { persistentByIP[ip] = persistent.name }
        }

        return router.map { entry in
            var client = Client(
                mac: entry.mac, ip: entry.ip, routerName: entry.routerName, hostname: entry.hostname,
                online: entry.online, connection: GLiNetClientListParser.connection(interface: entry.interface),
                reportedVendor: entry.reportedVendor
            )
            let ownedIP = entry.ip.flatMap { owners[$0] == entry.mac ? $0 : nil }
            if let adGuardDirectory {
                client.adGuardName = persistentByMAC[entry.mac]
                    ?? ownedIP.flatMap { persistentByIP[$0] }
                    ?? ownedIP.flatMap { adGuardDirectory.automaticNames[$0] }
            }
            if let topClientQueries, let ownedIP, let queries = topClientQueries[ownedIP] {
                client.dnsQueries = .value(queries)
            }
            return client
        }
    }

    /// The single router client each IP belongs to: the only online holder,
    /// else the only holder. Ambiguous IPs have no owner.
    static func ipOwners(_ router: [RouterClientEntry]) -> [String: MACAddress] {
        var holders: [String: [RouterClientEntry]] = [:]
        for entry in router {
            guard let ip = entry.ip else { continue }
            holders[ip, default: []].append(entry)
        }
        var owners: [String: MACAddress] = [:]
        for (ip, entries) in holders {
            let online = entries.filter { $0.online == .value(true) }
            if online.count == 1 { owners[ip] = online[0].mac }
            else if online.isEmpty, entries.count == 1 { owners[ip] = entries[0].mac }
        }
        return owners
    }
}
