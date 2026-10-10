import AppKit
import SwiftUI
import Testing
import RoutewellKit
import RoutewellMock
@testable import Routewell

@MainActor
private func eventually(timeout: Duration = .seconds(15), _ predicate: () async -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await predicate() { return }
        try? await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("Condition did not settle")
}

/// A mock environment in `scenario`, on the Instance tab with its reads done.
@MainActor
private func environment(_ scenario: MockAdGuardScenario = .running, ssh: MockSSHService.Scenario = .populated)
    async -> (AppEnvironment, MockRouterBackend) {
    let backend = MockRouterBackend()
    let environment = AppEnvironment(model: AppModel(mode: .mock), backend: backend)
    await environment.waitUntilReady()
    await environment.refresh.waitForRefresh()
    environment.setMockAdGuardScenario(scenario)
    if ssh != .populated { environment.setMockSSHScenario(ssh) }
    await eventually { await backend.mockAdGuard.scenario == scenario }
    let wanted: AdGuardAvailability = scenario == .cached ? .cached : .running
    await eventually {
        await environment.refresh.waitForRefresh()
        return environment.adGuard.availability == wanted
    }
    environment.model.selection = .adGuard
    environment.model.subpages[.adGuard] = AdGuardTab.instance.rawValue
    if let lease = environment.model.session.lease { try? await environment.adGuard.refreshOverview(using: lease) }
    await environment.adGuard.loadVersionCheck()
    if ssh == .populated {
        await eventually { environment.model.sshProbe?.capability.state == .supported }
    }
    await environment.instance.load()
    return (environment, backend)
}

@MainActor
private func render(_ environment: AppEnvironment) {
    let hosting = NSHostingView(rootView: AdGuardInstanceView().environment(environment.model).environment(environment))
    hosting.frame = CGRect(x: 0, y: 0, width: 900, height: 1400)
    let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    hosting.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
}

struct InstanceTabTests {
    // MARK: - Texts

    @Test func updateTexts() {
        let current = "v0.107.65"
        #expect(AdGuardInstancePresentation.update(AdGuardVersionCheck(disabled: false, newVersion: "v0.107.70"), current: current)
            == .init(title: "Version v0.107.70 is available", subtitle: "You have v0.107.65."))
        #expect(AdGuardInstancePresentation.update(AdGuardVersionCheck(disabled: false), current: current).title == "AdGuard Home is up to date")
        #expect(AdGuardInstancePresentation.update(AdGuardVersionCheck(disabled: true), current: current).title == "Update check not available")
        #expect(AdGuardInstancePresentation.update(nil, current: nil) == .init(title: "Update check not available", subtitle: "Version unknown."))
    }

    @Test func dataTexts() {
        let day = 24 * AdGuardRetention.hour
        #expect(AdGuardRetention.options.map(AdGuardInstancePresentation.retention) == ["24 hours", "7 days", "30 days", "90 days"])
        #expect(AdGuardInstancePresentation.retention(6 * AdGuardRetention.hour) == "6 hours")
        #expect(AdGuardInstancePresentation.retentionOptions(current: 7 * day) == AdGuardRetention.options)
        #expect(AdGuardInstancePresentation.retentionOptions(current: 6 * AdGuardRetention.hour).first == 6 * AdGuardRetention.hour)
        #expect(AdGuardInstancePresentation.queryLogSize(nil, sshConfigured: false) == "Size on the router needs SSH")
        #expect(AdGuardInstancePresentation.queryLogSize(AdGuardResources(), sshConfigured: true) == nil)
        #expect(AdGuardInstancePresentation.queryLogSize(AdGuardResources(queryLogBytes: .value(12_000_000)), sshConfigured: true)
            == "Currently 12 MB on the router")
        #expect(AdGuardInstancePresentation.clearTitle(.stats) == "Clear statistics?")
    }

    @Test func backupTexts() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let today = AdGuardBackup(createdAt: now.addingTimeInterval(-60), kind: .manual, size: 14_000)
        #expect(AdGuardInstancePresentation.date(today.createdAt, now: now).hasPrefix("Today at "))
        #expect(AdGuardInstancePresentation.detail(today) == "Manual backup · 14 KB")
        #expect(AdGuardInstancePresentation.lastBackup([today], now: now).hasPrefix("Last backup: today at "))
        #expect(AdGuardInstancePresentation.lastBackup([], now: now) == "No backups yet")
        #expect(AdGuardInstancePresentation.note(.beforeRestore) == "Before restore")
        let state = AdGuardRestoreState(written: true, answering: true, dnsMatches: true)
        #expect(AdGuardInstancePresentation.restoreText(.verifiedSuccess(state)) == nil)
        #expect(AdGuardInstancePresentation.restoreText(.verifiedRecovery(restored: state))?.contains("put the earlier settings back") == true)
        #expect(AdGuardInstancePresentation.restoreText(.recoveryFailed(expected: state, actual: nil))?.contains("did not work") == true)
    }

    @Test func headerShowsMemory() {
        var status = AdGuardStatusResponse(version: "v0.107.65")
        status.startTime = Date(timeIntervalSince1970: 0)
        let now = Date(timeIntervalSince1970: 3 * 86_400)
        #expect(AdGuardPresentation.instanceLine(.running, status: status, sshConfigured: false, now: now)
            == "Running for 3 days · Version v0.107.65 · Memory needs SSH")
        let line = AdGuardPresentation.instanceLine(.running, status: status, sshConfigured: true, memory: .value(48 * 1024 * 1024), now: now)
        #expect(line.hasPrefix("Running for 3 days · Version v0.107.65 · ") && line.hasSuffix("MB"))
        #expect(AdGuardPresentation.instanceLine(.running, status: status, sshConfigured: true, now: now) == "Running for 3 days · Version v0.107.65")
    }

    // MARK: - With SSH

    @MainActor @Test func readsUpdateRetentionAndResources() async {
        let (environment, backend) = await environment(.updateAvailable)
        #expect(environment.adGuard.versionCheck?.update(current: environment.adGuard.status?.version) == .available("v0.107.70"))
        #expect(environment.adGuard.queryLogConfig?.intervalMilliseconds == 90 * 86_400_000)
        // Once per session: a refresh and another load do not read it again.
        await environment.adGuard.loadVersionCheck()
        if let lease = environment.model.session.lease { try? await environment.adGuard.refreshOverview(using: lease) }
        #expect(await backend.mockAdGuard.versionChecks == 1)
        environment.refresh.setWindowVisible(true)
        environment.refresh.refreshNow()
        await eventually { environment.model.adGuardResources?.memoryBytes == .value(48 * 1024 * 1024) }
        render(environment)
    }

    @MainActor @Test func backUpNowThenRestore() async throws {
        let (environment, backend) = await environment()
        let instance = environment.instance
        #expect(instance.canChange)
        instance.backUp()
        await eventually { instance.backups.count == 1 && instance.activity == nil }
        let backup = try #require(instance.backups.first)
        #expect(backup.kind == .manual)
        #expect(instance.selection == backup.id)
        render(environment)

        instance.restore(backup)
        await eventually { instance.activity == nil && instance.backups.count == 2 }
        #expect(instance.message == nil)
        #expect(instance.backups.first?.kind == .beforeRestore)
        #expect(try await backend.mockAdGuard.readConfigFile().isEmpty == false)
    }

    @MainActor @Test func failedRestoreRollsBack() async throws {
        let (environment, backend) = await environment(.restoreFails)
        let instance = environment.instance
        instance.backUp()
        await eventually { instance.backups.count == 1 && instance.activity == nil }
        let original = try await backend.mockAdGuard.readConfigFile()
        instance.restore(try #require(instance.backups.first))
        await eventually(timeout: .seconds(30)) { instance.activity == nil && instance.message != nil }
        #expect(instance.message == AdGuardInstancePresentation.restoreText(.verifiedRecovery(restored:
            AdGuardRestoreState(written: true, answering: true, dnsMatches: true))))
        #expect(try await backend.mockAdGuard.readConfigFile() == original)
    }

    @MainActor @Test func exportWritesTheBackup() async throws {
        let (environment, backend) = await environment()
        environment.instance.backUp()
        await eventually { environment.instance.backups.count == 1 && environment.instance.activity == nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString).yaml")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(await environment.instance.export(try #require(environment.instance.backups.first), to: url))
        #expect(try Data(contentsOf: url) == (try await backend.mockAdGuard.readConfigFile()))
    }

    @MainActor @Test func retentionAndClearReachAdGuardHome() async {
        let (environment, _) = await environment()
        environment.instance.setRetention(.stats, milliseconds: 24 * AdGuardRetention.hour)
        await eventually { environment.adGuard.settingInFlight == nil && environment.adGuard.statsConfig?.intervalMilliseconds == 86_400_000 }
        environment.instance.clear(.queryLog)
        await eventually { environment.adGuard.settingInFlight == nil && environment.adGuard.lastSettingIntent == .clearData(.queryLog) }
        let writes = await environment.mockAdGuardWrites()
        #expect(writes.contains(.clearQueryLog))
        #expect(writes.contains { if case .statsConfig(let config) = $0 { config["interval"]?.int == 86_400_000 } else { false } })
    }

    // MARK: - Without SSH, and cached

    @MainActor @Test func withoutSSHNothingAttemptsBackups() async {
        let (environment, _) = await environment(ssh: .off)
        #expect(!environment.model.sshConfigured)
        #expect(!environment.instance.canChange)
        environment.instance.backUp()
        #expect(environment.instance.activity == nil)
        #expect(environment.model.adGuardResources == nil)
        #expect(AdGuardInstancePresentation.queryLogSize(environment.model.adGuardResources, sshConfigured: false) == "Size on the router needs SSH")
        render(environment)
    }

    @MainActor @Test func cachedShowsTheSavedCopyReadOnly() async {
        let (environment, _) = await environment(.cached)
        #expect(environment.adGuard.availability == .cached)
        #expect(environment.adGuard.queryLogConfig?.intervalMilliseconds == 90 * 86_400_000)
        #expect(environment.adGuard.versionCheck == AdGuardVersionCheck(disabled: false))
        #expect(!environment.instance.canChange)
        render(environment)
    }

    // MARK: - Snapshots

    /// PNGs of the Instance tab's states, light and dark, when
    /// `ROUTEWELL_SNAPSHOTS=1`. For reviewing the layout only.
    @MainActor @Test func writeInstanceSnapshotsWhenAsked() async throws {
        guard ProcessInfo.processInfo.environment["ROUTEWELL_SNAPSHOTS"] == "1" else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("adguard-snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func write(_ name: String, _ environment: AppEnvironment) {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let host = NSHostingView(rootView: AdGuardInstanceView().environment(environment.model).environment(environment)
                    .background(Color(nsColor: .windowBackgroundColor)))
                host.appearance = NSAppearance(named: appearance)
                host.frame = CGRect(x: 0, y: 0, width: 900, height: 1300)
                let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearance)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?
                    .write(to: directory.appendingPathComponent("instance19b-\(name)-\(appearance == .aqua ? "light" : "dark").png"))
            }
        }
        let (available, _) = await environment(.updateAvailable)
        available.refresh.setWindowVisible(true)
        available.refresh.refreshNow()
        await eventually { available.model.adGuardResources != nil }
        available.instance.backUp()
        await eventually { available.instance.backups.count == 1 && available.instance.activity == nil }
        write("update-available", available)
        let (upToDate, _) = await environment()
        write("up-to-date", upToDate)
        let (checkOff, _) = await environment(.updateCheckOff)
        write("update-unknown", checkOff)
        let (noSSH, _) = await environment(ssh: .off)
        write("no-ssh", noSSH)
        let (cached, _) = await environment(.cached)
        write("cached", cached)
    }
}
