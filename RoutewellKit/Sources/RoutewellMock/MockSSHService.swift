import Foundation
import Synchronization
import RoutewellKit

/// Synthetic SSH for the Router screen's Ports, Storage, and Logs segments
/// and the AdGuard process ID. The scenario is readable without `await`, so
/// `MockRouterBackend.ssh` can answer `nil` for "SSH off". Nothing here
/// starts a process.
public final class MockSSHService: SSHService {
    public enum Scenario: String, CaseIterable, Sendable {
        /// SSH is not set up: the backend has no SSH service.
        case off
        /// The probe never finishes while the scenario stays selected.
        case probePending
        /// The router refuses the key.
        case probeFails
        /// The probe times out: capability stays unknown.
        case probeTimesOut
        /// The router presents a different host key: always rejected.
        case hostKeyChanged
        /// The probe succeeds and every segment is populated.
        case populated
    }

    private let selected = Mutex<Scenario>(.populated)

    public init() {}

    public var scenario: Scenario { selected.withLock { $0 } }
    public func setScenario(_ value: Scenario) { selected.withLock { $0 = value } }

    public func check() async throws -> SSHProbeResult {
        let now = Date()
        switch scenario {
        case .off, .populated:
            return SSHProbeResult(capability: Capability(.supported, evidence: .mockScenario("ssh"), observedAt: now), board: Self.board)
        case .probePending:
            try await Task.sleep(for: .seconds(600))
            return SSHProbeResult(capability: Capability(observedAt: Date()), failure: .timedOut)
        case .probeFails:
            return SSHProbeResult(capability: Capability(.unsupported, evidence: .mockScenario("ssh auth failed"), observedAt: now),
                                  failure: .authenticationFailed)
        case .probeTimesOut:
            try await Task.sleep(for: .milliseconds(300))
            return SSHProbeResult(capability: Capability(observedAt: Date()), failure: .timedOut)
        case .hostKeyChanged:
            return SSHProbeResult(capability: Capability(.unsupported, evidence: .mockScenario("ssh host key changed"), observedAt: now),
                                  failure: .hostKeyChanged)
        }
    }

    public func ports() async throws -> AreaRefreshResult<RouterPortsStatus> {
        try Task.checkCancellation()
        guard scenario == .populated else { return .failure(.authentication, attemptedAt: Date()) }
        return .success(Self.ports, observedAt: Date(), source: .mock)
    }

    public func storage() async throws -> AreaRefreshResult<StorageStatus> {
        try Task.checkCancellation()
        guard scenario == .populated else { return .failure(.authentication, attemptedAt: Date()) }
        return .success(Self.storage, observedAt: Date(), source: .mock)
    }

    public func logTail() async throws -> AreaRefreshResult<RouterLogTail> {
        try Task.checkCancellation()
        guard scenario == .populated else { return .failure(.authentication, attemptedAt: Date()) }
        return .success(LogReadParser.parse(Self.logText), observedAt: Date(), source: .mock)
    }

    public func adGuardProcess() async throws -> Observed<Int> {
        try Task.checkCancellation()
        return scenario == .populated ? .value(4321) : .unknown
    }

    public func adGuardResources() async throws -> AdGuardResources {
        try Task.checkCancellation()
        guard scenario == .populated else { return AdGuardResources() }
        return AdGuardResources(memoryBytes: .value(48 * 1024 * 1024), queryLogBytes: .value(12 * 1024 * 1024))
    }

    public static let board = SystemBoard(model: "Example Router", hostname: "flint-demo", boardName: "example,router",
                                          releaseVersion: "21.02-SNAPSHOT", kernel: "5.4.0", target: "example/target")

    /// The Ethernet interfaces a 4.9.1 router enumerates,
    /// with example link states and counters.
    public static let ports = RouterPortsStatus(ports: [
        EthernetPortStatus(name: "eth0", link: .up, speedMbps: 10_000, duplex: "full", rxBytes: 1_000, txBytes: 2_000,
                           rxErrors: 0, txErrors: 0, rxDropped: 0, txDropped: 0),
        EthernetPortStatus(name: "eth1", link: .up, speedMbps: 10_000, duplex: "full", rxBytes: 300_000_000, txBytes: 9_000_000_000,
                           rxErrors: 0, txErrors: 0, rxDropped: 0, txDropped: 0),
        EthernetPortStatus(name: "eth2", link: .up, speedMbps: 1_000, duplex: "full", rxBytes: 50_000_000_000, txBytes: 9_000_000_000,
                           rxErrors: 0, txErrors: 0, rxDropped: 0, txDropped: 0),
        EthernetPortStatus(name: "lan5", link: .down, rxBytes: 0, txBytes: 0, rxErrors: 0, txErrors: 0, rxDropped: 0, txDropped: 0),
        EthernetPortStatus(name: "lan6", link: .down, rxBytes: 0, txBytes: 0, rxErrors: 0, txErrors: 0, rxDropped: 0, txDropped: 0),
        EthernetPortStatus(name: "lan7", link: .up, speedMbps: 1_000, duplex: "full", rxBytes: 4_000_000_000, txBytes: 1_000_000_000,
                           rxErrors: 0, txErrors: 0, rxDropped: 0, txDropped: 0),
        EthernetPortStatus(name: "lan8", link: .down, rxBytes: 0, txBytes: 0, rxErrors: 0, txErrors: 0, rxDropped: 0, txDropped: 0),
    ])

    public static let storage = StorageStatus(
        root: .value(RootFilesystem(filesystem: "overlayfs:/overlay", size: "7.2G", used: "1.1G", available: "6.1G", usePercent: 15, mountPoint: "/")),
        external: .value([MountedVolume(device: "/dev/sda1", mountPoint: "/mnt/sda1", fileSystemType: "ext4",
                                        totalBytes: 500_000_000_000, usedBytes: 120_000_000_000, availableBytes: 380_000_000_000)]),
        samba: .value(.configured([SambaShare(name: "Backups", readOnly: .value(false), guestAccess: .value(false))])))

    /// Log lines in the recorded 4.9.1 format, oldest first as `logread`
    /// prints them, with documentation addresses and example names.
    public static let logText = """
    Thu Jan 15 10:00:01 2026 kern.warn kernel: [100001.000001] [wlan] BN0,mt7990_dump_rx_err_dbg_log() 3662: [rx_err] ICV Error!
    Thu Jan 15 10:00:01 2026 kern.warn kernel: [100001.000002] [wlan] BN0,mt7990_dump_rx_err_dbg_log() 3674: [rx_err] Peer Link Addr: 02:00:00:00:00:01
    Thu Jan 15 10:00:20 2026 daemon.info netifyd[1100]: netlink-ct: Exception while reading CT message: mnl_socket_recvfrom: No buffer space available
    Thu Jan 15 10:00:30 2026 daemon.info dnsmasq-dhcp[1200]: DHCPREQUEST(br-lan) 192.0.2.50 02:00:00:00:00:02
    Thu Jan 15 10:00:30 2026 daemon.info dnsmasq-dhcp[1200]: DHCPACK(br-lan) 192.0.2.50 02:00:00:00:00:02 host-a
    Thu Jan 15 10:00:40 2026 daemon.info eco[1300]: (gl-ngx-session:664) websocket proxy disconnected
    Thu Jan 15 10:00:40 2026 user.err : [screen][ws_callback][error]ws closed
    Thu Jan 15 10:00:45 2026 user.info : [screen][ws_client_wait][info]ws reconnecting...
    Thu Jan 15 10:00:45 2026 user.info : [screen][ws_callback][info]ws connected
    Thu Jan 15 10:00:45 2026 daemon.info eco[1300]: (gl-ngx-session:659) new websocket proxy connection
    Thu Jan 15 10:01:10 2026 daemon.info dnsmasq-dhcp[1200]: DHCPDISCOVER(br-lan) 02:00:00:00:00:04
    Thu Jan 15 10:01:10 2026 daemon.info dnsmasq-dhcp[1200]: DHCPOFFER(br-lan) 192.0.2.52 02:00:00:00:00:04
    Thu Jan 15 10:01:10 2026 daemon.info dnsmasq-dhcp[1200]: DHCPACK(br-lan) 192.0.2.52 02:00:00:00:00:04 host-c
    Thu Jan 15 10:01:20 2026 authpriv.info dropbear[1400]: Child connection from 192.0.2.10:50000
    Thu Jan 15 10:01:20 2026 authpriv.notice dropbear[1400]: Pubkey auth succeeded for 'root' with ssh-rsa key SHA256:example from 192.0.2.10:50000
    Thu Jan 15 10:02:00 2026 daemon.warn hostapd: ra0: STA 02:00:00:00:00:05 IEEE 802.11: disassociated due to inactivity
    Thu Jan 15 10:02:04 2026 daemon.debug AdGuardHome[1600]: debug: dnsproxy: upstream exchange complete
    """
}
