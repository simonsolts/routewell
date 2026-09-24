import Foundation

/// Forget Device…: removes the `DeviceRecord`, then this MAC's presence
/// rows. Two files, no shared transaction (architecture 05), recovery class
/// `none`. When the record is gone but the history save fails, the outcome
/// is `unknownAfterDispatch`: the rows age out with the 7-day retention, and
/// the person can retry from Availability if the device returns.
public struct DeviceForgetting: Sendable {
    private let registry: DeviceRegistry
    private let presence: PresenceLog

    public init(registry: DeviceRegistry, presence: PresenceLog) {
        self.registry = registry
        self.presence = presence
    }

    public func run(_ mac: MACAddress, online: Observed<Bool>, at now: Date) async -> MutationReport<MACAddress> {
        let removed = await registry.forget(mac, online: online, at: now)
        guard case .verifiedSuccess = removed.outcome else { return removed }
        let cleared = await presence.clearHistory(mac, at: now)
        guard case .verifiedSuccess = cleared.outcome else {
            return MutationReport(outcome: .unknownAfterDispatch, dispatched: true, startedAt: now, finishedAt: cleared.finishedAt, failure: cleared.failure)
        }
        return MutationReport(outcome: .verifiedSuccess(mac), dispatched: true, startedAt: now, finishedAt: cleared.finishedAt, failure: nil)
    }
}
