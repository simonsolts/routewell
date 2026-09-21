import Foundation
import RoutewellKit

@MainActor
final class LoggingController {
    /// Exposed so live backends can log through the same session-lifetime
    /// event log the Logs screen reads from.
    let eventLog: SessionEventLog
    private weak var model: AppModel?

    init(model: AppModel, eventLog: SessionEventLog = SessionEventLog()) {
        self.model = model
        self.eventLog = eventLog
    }

    func record(level: LogEvent.Level = .info, kind: LogEvent.Kind, message: String,
                fields: [String: String] = [:]) {
        let event = LogEvent(level: level, kind: kind, message: message, fields: fields)
        Task { [weak self] in
            guard let self else { return }
            await eventLog.record(event)
            model?.replaceLogEvents(await eventLog.events())
        }
    }

    func clear() {
        Task { [weak self] in
            guard let self else { return }
            await eventLog.clear()
            model?.replaceLogEvents([])
        }
    }

    func export() async throws -> Data { try LogRedactor.export(await eventLog.events()) }
}
