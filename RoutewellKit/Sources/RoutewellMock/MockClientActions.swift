import Foundation
import Synchronization
import RoutewellKit

/// Ping and Wake for the mock, with a selectable mechanism so every button
/// state can be reviewed: RPC, SSH, SSH required, or hidden (`nil`).
public final class MockClientActions: ClientActionsService {
    private let selected = Mutex<ClientActionMechanism?>(.ssh)
    /// Mock addresses that answer a ping.
    private static let reachable: Set<String> = [
        "192.168.8.192", "192.168.8.150", "192.168.8.233", "192.168.8.199", "192.168.8.228",
        "192.168.8.120", "192.168.8.105", "192.168.8.116", "192.168.8.20",
    ]

    public init() {}

    /// `nil` hides the buttons.
    public func setMechanism(_ value: ClientActionMechanism?) { selected.withLock { $0 = value } }
    public var currentMechanism: ClientActionMechanism? { selected.withLock { $0 } }
    public var mechanism: ClientActionMechanism { currentMechanism ?? .sshRequired }

    public func ping(_ address: IPv4Literal) async throws -> Result<PingResult, RefreshFailureCategory> {
        guard mechanism != .sshRequired else { return .failure(.unavailable) }
        try await Task.sleep(for: .milliseconds(300))
        if Self.reachable.contains(address.description) {
            return .success(PingResult(transmitted: 3, received: 3, averageMilliseconds: 3.2))
        }
        return .success(PingResult(transmitted: 3, received: 0))
    }

    public func wake(_ mac: MACAddress) async -> MutationReport<WakeResult> {
        let startedAt = Date()
        guard mechanism != .sshRequired else {
            return MutationReport(outcome: .rejected(.capabilityUnavailable), dispatched: false, startedAt: startedAt, finishedAt: startedAt, failure: nil)
        }
        try? await Task.sleep(for: .milliseconds(100))
        return MutationReport(outcome: .verifiedSuccess(.sent), dispatched: true, startedAt: startedAt, finishedAt: Date(), failure: nil)
    }
}
