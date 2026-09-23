import Foundation
import RoutewellKit

/// Owns the app's one `DeviceRegistry` and `PresenceLog` and mirrors their
/// state into `AppModel`. Both outlive router sessions: device history is
/// local data. Every write here is local and never reaches the router.
@MainActor
final class ClientsController {
    let registry: DeviceRegistry
    let presence: PresenceLog
    private let model: AppModel
    private let logging: LoggingController?

    init(model: AppModel, registry: DeviceRegistry, presence: PresenceLog, logging: LoggingController? = nil) {
        self.model = model
        self.registry = registry
        self.presence = presence
        self.logging = logging
    }

    func load() async {
        let result = await registry.load()
        let state = await registry.snapshot()
        switch result {
        case .blocked:
            model.replaceDeviceRegistry(state, issue: .blocked)
            logging?.record(level: .warning, kind: .persistence, message: "Device history cannot be saved")
        case .recovered:
            model.replaceDeviceRegistry(state)
            logging?.record(level: .warning, kind: .persistence, message: "Damaged device history was preserved in a recovery file")
        case .empty, .loaded:
            model.replaceDeviceRegistry(state)
        }
        let presenceResult = await presence.load()
        let presenceState = await presence.snapshot()
        switch presenceResult {
        case .blocked(let error):
            model.replacePresence(presenceState, failure: error)
            logging?.record(level: .warning, kind: .persistence, message: "Presence history cannot be saved")
        case .recovered:
            model.replacePresence(presenceState)
            logging?.record(level: .warning, kind: .persistence, message: "Damaged presence history was preserved in a recovery file")
        case .empty, .loaded:
            model.replacePresence(presenceState)
        }
    }

    /// Clears the review flag for a device opened from the review sheet.
    func markReviewed(_ mac: MACAddress) async {
        let saved = await registry.markReviewed(mac)
        let state = await registry.snapshot()
        model.replaceDeviceRegistry(state, issue: saved ? nil : .notSaved)
    }

    /// Save Profile, Clear Profile, and the Favourite and Monitor switches.
    @discardableResult
    func edit(_ mac: MACAddress, _ edit: DeviceProfileEdit) async -> MutationReport<DeviceProfile> {
        let report = await registry.edit(mac, edit, at: Date())
        model.replaceDeviceRegistry(await registry.snapshot(), issue: model.deviceRegistryIssue == .blocked ? .blocked : nil)
        switch report.outcome {
        case .verifiedSuccess:
            if model.clientNotice?.mac == mac { model.clientNotice = nil }
        case .rejected(.invalidIntent(let reason)):
            model.clientNotice = .init(mac: mac, text: "\(reason).", tone: .degraded)
        case .rejected:
            model.clientNotice = .init(mac: mac, text: "This device is not stored on this Mac yet. Refresh, then try again.", tone: .degraded)
        case .unknownAfterDispatch, .verifiedMismatch, .verifiedRecovery, .recoveryFailed, .conflictingExternalEdit:
            model.clientNotice = .init(mac: mac, text: "The profile could not be saved on this Mac. Try again.", tone: .error)
            logging?.record(level: .warning, kind: .persistence, message: "Device profile not saved")
        }
        return report
    }

    /// Forget Device…: removes the record, then this device's presence rows.
    @discardableResult
    func forget(_ mac: MACAddress, online: Observed<Bool>) async -> MutationReport<MACAddress> {
        let report = await DeviceForgetting(registry: registry, presence: presence).run(mac, online: online, at: Date())
        let registryState = await registry.snapshot()
        model.replaceDeviceRegistry(registryState, issue: model.deviceRegistryIssue == .blocked ? .blocked : nil)
        model.replacePresence(await presence.snapshot())
        let listed = model.clientInventory?.clients.contains { $0.mac == mac } == true
        switch report.outcome {
        case .verifiedSuccess:
            logging?.record(kind: .persistence, message: "Device forgotten")
            if listed {
                model.clientNotice = .init(mac: mac, text: "Routewell forgot this device. The router still lists it, so it appears again with no saved history.")
            } else {
                model.clientsSelection.remove(mac)
            }
        case .rejected:
            model.clientNotice = .init(mac: mac, text: "This device is on the network or its state is unknown, so it cannot be forgotten now.", tone: .degraded)
        default:
            let stillStored = registryState.records[mac] != nil
            model.clientNotice = .init(mac: mac, text: stillStored
                ? "Routewell could not save the change. The device is still stored on this Mac."
                : "The device was forgotten, but its presence history could not be removed. It expires within 7 days.", tone: .error)
            logging?.record(level: .warning, kind: .persistence, message: "Forget device not fully saved")
        }
        return report
    }

    /// Clear History… for one device.
    @discardableResult
    func clearHistory(_ mac: MACAddress) async -> MutationReport<MACAddress> {
        let report = await presence.clearHistory(mac, at: Date())
        model.replacePresence(await presence.snapshot())
        if case .verifiedSuccess = report.outcome {
            if model.clientNotice?.mac == mac { model.clientNotice = nil }
        } else {
            model.clientNotice = .init(mac: mac, text: "Presence history could not be cleared. Try again.", tone: .error)
        }
        return report
    }

    /// Saves pending presence samples, for example before the app quits.
    func flushPresence() async {
        await presence.flush(at: Date())
    }
}
