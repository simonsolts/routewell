import Foundation
import Testing
import RoutewellKit
import RoutewellMock

@Test func partialResultFailsOnlyClients() {
    let result = MockRouterBackend.result(scenario: .partial, at: .distantPast)
    guard case .success = result.router, case .success = result.internet,
          case .success = result.adGuard, case .failure(.timeout, _) = result.clients else {
        Issue.record("Expected only Clients to fail")
        return
    }
}

@Test func fixturesAreDeterministicAndIndependent() async throws {
    let date = Date(timeIntervalSince1970: 1_000)
    var first = MockRouterBackend.snapshot(at: date)
    let second = MockRouterBackend.snapshot(at: date)
    #expect(first == second)
    first.router.hostname = "changed"
    #expect(second.router.hostname == "flint-demo")
    #expect(second.adGuard.protection == .paused(until: date.addingTimeInterval(1800)))
    let stale = MockRouterBackend.result(scenario: .stale, at: date)
    guard case .success(_, let observedAt, _) = stale.clients else {
        Issue.record("Expected stale Clients data")
        return
    }
    #expect(observedAt == date.addingTimeInterval(-65 * 60))
}

/// Chunk 17: protection runs through the real executor against the mock
/// AdGuard Home, and the overview shows the result.
@Test func mockPauseAndResumeRunThroughTheExecutor() async throws {
    let backend = MockRouterBackend()
    await backend.mockAdGuard.setScenario(.running)
    let settings = try #require(backend.adGuardSettings)
    let paused = await settings.run(.protection(.pause(.seconds(60))), availability: .running)
    guard case .verifiedSuccess(.protection(.paused)) = paused.outcome else {
        Issue.record("expected a verified pause, got \(paused.outcome)"); return
    }
    guard case .success(let adGuard, _, _) = try await backend.overview().adGuard, case .paused = adGuard.protection else {
        Issue.record("expected the overview to show the pause"); return
    }
    let resumed = await settings.run(.protection(.enable), availability: .running)
    #expect(resumed.outcome == .verifiedSuccess(.protection(.enabled)))
    guard case .success(let after, _, _) = try await backend.overview().adGuard else {
        Issue.record("expected adGuard success"); return
    }
    #expect(after.protection == .enabled)
}

@Test func mockPausedScenarioStartsPaused() async throws {
    let backend = MockRouterBackend()
    await backend.mockAdGuard.setScenario(.paused)
    guard case .success(let adGuard, _, _) = try await backend.overview().adGuard, case .paused(let until) = adGuard.protection else {
        Issue.record("expected a paused protection"); return
    }
    #expect(until > Date())
}

@Test func mockSwitchFailsScenarioReportsAMismatchForParentalOnly() async throws {
    let backend = MockRouterBackend()
    await backend.mockAdGuard.setScenario(.switchFails)
    let settings = try #require(backend.adGuardSettings)
    let parental = await settings.run(.feature(.parental, enabled: true), availability: .running)
    #expect(parental.outcome == .verifiedMismatch(expected: .feature(true), actual: .feature(false)))
    let safeSearch = await settings.run(.feature(.safeSearch, enabled: true), availability: .running)
    #expect(safeSearch.outcome == .verifiedSuccess(.feature(true)))
    let writes = await backend.mockAdGuard.writes
    #expect(writes.count == 2)
    // Safe Search sends the engine flags back with the switch.
    guard case .safeSearchSettings(let body)? = writes.last else { Issue.record("expected a Safe Search write"); return }
    #expect(body["google"] == .bool(true))
}

@Test func mockFilterRequestsTurnsOffAndTheOverviewShowsIt() async throws {
    let backend = MockRouterBackend()
    await backend.mockAdGuard.setScenario(.running)
    let report = await backend.adGuardSettings!.run(.filtering(enabled: false), availability: .running)
    #expect(report.outcome == .verifiedSuccess(.feature(false)))
    let reading = try await backend.adGuardOverview!.overview(range: .day)
    #expect(try reading.filtering.get().enabled == false)
    guard case .filteringConfig(false, 24)? = await backend.mockAdGuard.writes.last else {
        Issue.record("expected the filtering config with the interval as read"); return
    }
}

@Test func mockOverviewLimitsRangesToTheRetention() async throws {
    let backend = MockRouterBackend()
    await backend.mockAdGuard.setScenario(.running)
    let overview = try #require(backend.adGuardOverview)
    let day = try await overview.overview(range: .day)
    #expect(try day.stats.get().matches(.day))
    let retention = try day.statsConfig.get().intervalMilliseconds
    #expect(AdGuardStatsRange.week.isAvailable(retentionMilliseconds: retention))
    #expect(!AdGuardStatsRange.month.isAvailable(retentionMilliseconds: retention))
    let week = try await overview.overview(range: .week)
    #expect(try week.stats.get().matches(.week))
    #expect(try day.protection.get() == ProtectionOptions(safeBrowsing: true, parental: false, safeSearch: false))
}

@Test func mockOverviewFailsWhenAdGuardDoesNotAnswer() async throws {
    let backend = MockRouterBackend()
    await backend.mockAdGuard.setScenario(.unreachable)
    let reading = try await #require(backend.adGuardOverview).overview(range: .day)
    #expect(reading.stats == .failure(.timeout))
    let settings = await (try #require(backend.adGuardSettings)).run(.protection(.enable), availability: .running)
    #expect(settings.outcome == .rejected(.preconditionFailed("status unavailable")))
}

@Test func mockCachedSeedHoldsTheOverviewSections() {
    let archive = MockAdGuardScenario.cached.seedArchive(now: Date())
    #expect(archive?.stats(for: .day) != nil)
    #expect(archive?.protection?.value.safeBrowsing == true)
    #expect(archive?.filtering?.value.enabledBlocklists.count == 3)
    #expect(MockAdGuardScenario.running.seedArchive(now: Date()) == nil)
}

/// Service and setting writes share the router's one gate.
@Test func mockSettingAndServiceWritesShareOneGate() async throws {
    let backend = MockRouterBackend()
    await backend.mockAdGuard.setScenario(.running)
    let clock = ContinuousClock()
    let start = clock.now
    async let first = backend.adGuardSettings!.run(.feature(.safeBrowsing, enabled: false), availability: .running)
    async let second = backend.adGuardSettings!.run(.feature(.parental, enabled: true), availability: .running)
    let (a, b) = await (first, second)
    // Each mock write waits 150 ms; serialized, the two take at least 300 ms.
    #expect(clock.now - start >= .milliseconds(290))
    #expect(a.outcome == .verifiedSuccess(.feature(false)))
    #expect(b.outcome == .verifiedSuccess(.feature(true)))
}

@Test func cancelledReadDoesNotReturnData() async {
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await MockRouterBackend().overview()
    }
    do {
        _ = try await task.value
        Issue.record("Expected cancellation")
    } catch is CancellationError {
        // Expected.
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}
