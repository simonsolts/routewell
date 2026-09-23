import Foundation
import RoutewellKit

/// Owns the app's one `DeviceRegistry` and mirrors its state into `AppModel`.
/// The registry outlives router sessions: device history is local data.
@MainActor
final class ClientsController {
    let registry: DeviceRegistry
    private let model: AppModel
    private let logging: LoggingController?

    init(model: AppModel, registry: DeviceRegistry, logging: LoggingController? = nil) {
        self.model = model
        self.registry = registry
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
    }

    /// Clears the review flag for a device opened from the review sheet.
    func markReviewed(_ mac: MACAddress) async {
        let saved = await registry.markReviewed(mac)
        let state = await registry.snapshot()
        model.replaceDeviceRegistry(state, issue: saved ? nil : .notSaved)
    }
}
