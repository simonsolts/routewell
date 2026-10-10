#if DEBUG
import Foundation
import AppKit
import RoutewellKit
import RoutewellMock

extension AppEnvironment {
    func setMockFeatureBehavior(_ behavior: MockRouterBackend.FeatureBehavior, for area: DataArea) {
        guard model.mode == .mock, let mockBackend else { return }
        Task {
            await mockBackend.setFeatureBehavior(behavior, for: area)
            refresh.refreshNow()
        }
    }

    /// `nil` hides Ping and Wake.
    func setMockClientActions(_ mechanism: ClientActionMechanism?) {
        guard model.mode == .mock, let mockBackend else { return }
        mockClientActionsMechanism = mechanism
        mockBackend.mockClientActions.setMechanism(mechanism)
        clientActions.mechanismChanged()
    }

    func setMockSQMBehavior(_ behavior: MockRouterService.SQMBehavior) {
        guard model.mode == .mock, let mockBackend else { return }
        mockSQMBehavior = behavior
        Task {
            await mockBackend.mockRouter.setSQMBehavior(behavior)
            refresh.refreshNow()
        }
    }

    func setMockFirmwareBehavior(_ behavior: MockRouterService.FirmwareBehavior) {
        guard model.mode == .mock, let mockBackend else { return }
        mockFirmwareBehavior = behavior
        Task { await mockBackend.mockRouter.setFirmwareBehavior(behavior) }
    }

    /// SSH off, probe pending, fails, times out, host key
    /// changed, or populated. The probe runs again for the new scenario.
    func setMockSSHScenario(_ scenario: MockSSHService.Scenario) {
        guard model.mode == .mock, let mockBackend else { return }
        mockSSHScenario = scenario
        mockBackend.mockSSH.setScenario(scenario)
        refresh.reprobeSSH()
        refresh.refreshNow()
    }

    /// The writes the mock AdGuard Home received, for tests.
    func mockAdGuardWrites() async -> [AdGuardWrite] {
        await mockBackend?.mockAdGuard.writes ?? []
    }

    /// The router's AdGuard Home setting and the saved copy.
    func setMockAdGuardScenario(_ scenario: MockAdGuardScenario) {
        guard model.mode == .mock, let mockBackend else { return }
        mockAdGuardScenario = scenario
        Task {
            await mockBackend.mockAdGuard.setScenario(scenario)
            await adGuard.replaceArchive(scenario.seedArchive(now: .now))
            refresh.refreshNow()
        }
    }

    func setMockClientsScenario(_ scenario: MockClientsService.Scenario) {
        guard model.mode == .mock, let mockBackend else { return }
        mockClientsScenario = scenario
        Task {
            await mockBackend.setClientsScenario(scenario)
            refresh.refreshNow()
        }
    }

    func setMockQueryLogEmpty(_ empty: Bool) {
        guard model.mode == .mock, let mockBackend else { return }
        mockQueryLogEmpty = empty
        Task { await mockBackend.mockQueryLog.setEmpty(empty) }
        model.personRefreshes += 1
    }

    func recordFixtures() {
        guard model.mode == .live, let lease = model.session.lease,
              lease.backend is LiveRouterBackend else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose a folder for live router responses with private values replaced by examples"
        panel.prompt = "Record Fixtures"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        let session = model.session.routerSession
        Task {
            do {
                let count = try await FixtureRecorder().record(session: session, lease: lease, to: directory)
                let sshNote = lease.backend.ssh == nil
                    ? " SSH is not set up, so the SSH commands were skipped. Set up SSH in Settings › Router, then record again."
                    : " SSH output is text: addresses, quoted names, and key fingerprints are replaced, but log lines can hold other private text."
                let alert = NSAlert()
                alert.messageText = "Fixtures recorded"
                alert.informativeText = "Recorded \(count) read-only calls from the connected live router. Example addresses and names are privacy aliases, not mock responses.\(sshNote) Check _recording-manifest.json and review the files before committing."
                alert.runModal()
            } catch {
                let reason = Self.recordingFailure(error)
                self.logging.record(level: .warning, kind: .session, message: "Fixture recording stopped", fields: ["reason": reason])
                let alert = NSAlert()
                alert.messageText = "Fixture recording stopped"
                alert.informativeText = reason
                alert.runModal()
            }
        }
    }

    /// The real reason a recording stopped, in plain words.
    nonisolated static func recordingFailure(_ error: any Error) -> String {
        switch error {
        case SessionError.stale:
            return "The router session changed during the recording, for example after a reconnect or a settings change. Record again."
        case SessionError.switching:
            return "The router session was still connecting. Wait for the sidebar to show the router, then record again."
        case RecorderError.unsafePlan:
            return "The recording plan holds a call that is not a read, so nothing was sent."
        case RecorderError.unavailable:
            return "This router session cannot record fixtures."
        case is CancellationError:
            return "The recording was cancelled."
        case let error as CocoaError:
            let path = error.filePath ?? (error.userInfo[NSURLErrorKey] as? URL)?.path ?? "unknown path"
            return "A file could not be written: \(error.localizedDescription) (\(path), code \(error.code.rawValue))."
        default:
            let error = error as NSError
            return "Unexpected error: \(error.domain) \(error.code): \(error.localizedDescription)"
        }
    }

    /// The first mock profile keeps its hostname when it is renamed.
    func installMock(profile: RouterProfile, scenarioID: String) {
        let hostname = profile.endpoint == "mock://home" ? "flint-demo" : "travel-demo"
        let scenario = MockRouterBackend.Scenario(rawValue: scenarioID) ?? .healthy
        let backend = MockRouterBackend(scenario: scenario, hostname: hostname)
        backend.mockClientActions.setMechanism(mockClientActionsMechanism)
        backend.mockSSH.setScenario(mockSSHScenario)
        mockBackend = backend
        let clientsScenario = mockClientsScenario
        let sqm = mockSQMBehavior
        let firmware = mockFirmwareBehavior
        let adGuardScenario = mockAdGuardScenario
        let queryLogEmpty = mockQueryLogEmpty
        setup = model.session.switchProfile(profile.name, model: model, refresh: refresh) {
            await backend.mockAdGuard.setScenario(adGuardScenario)
            await backend.mockQueryLog.setEmpty(queryLogEmpty)
            await backend.setClientsScenario(clientsScenario)
            await backend.mockRouter.setSQMBehavior(sqm)
            await backend.mockRouter.setFirmwareBehavior(firmware)
            return SessionLease(token: $0, backend: backend)
        }
    }
}
#endif
