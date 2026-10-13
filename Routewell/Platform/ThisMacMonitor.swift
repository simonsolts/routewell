import Foundation
import Network
import Observation
import RoutewellKit

/// Whether this Mac's main path uses Wi-Fi, and its current Wi-Fi address
/// (the private address macOS uses on this network). No SSID is read, so no
/// Location Services permission is needed.
@MainActor @Observable
final class ThisMacMonitor {
    private(set) var onWiFi: Bool?
    private(set) var wifiMAC: MACAddress?

    @ObservationIgnored private let main = NWPathMonitor()
    @ObservationIgnored private let wifi = NWPathMonitor(requiredInterfaceType: .wifi)

    func start() {
        main.pathUpdateHandler = { [weak self] path in
            let type = path.status == .satisfied ? path.availableInterfaces.first?.type : nil
            Task { @MainActor in self?.onWiFi = type.map { $0 == .wifi } }
        }
        wifi.pathUpdateHandler = { [weak self] path in
            let name = path.availableInterfaces.first?.name
            let address = name.flatMap(Self.linkAddress)
            Task { @MainActor in self?.wifiMAC = address }
        }
        main.start(queue: .global(qos: .utility))
        wifi.start(queue: .global(qos: .utility))
    }

    /// The `AF_LINK` address of a BSD interface (`en0`).
    nonisolated static func linkAddress(_ interface: String) -> MACAddress? {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return nil }
        defer { freeifaddrs(first) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  String(cString: entry.ifa_name) == interface else { continue }
            return address.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { link -> MACAddress? in
                let dl = link.pointee
                guard dl.sdl_alen == 6 else { return nil }
                // The address follows the name; both can run past `sdl_data`.
                guard let offset = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data) else { return nil }
                let start = UnsafeRawPointer(link).advanced(by: offset + Int(dl.sdl_nlen))
                let bytes = (0 ..< 6).map { start.load(fromByteOffset: $0, as: UInt8.self) }
                return MACAddress(bytes.map { String(format: "%02x", $0) }.joined(separator: ":"))
            }
        }
        return nil
    }
}
