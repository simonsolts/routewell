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

@Test func succeedsBehaviorAppliesAndOverviewReflectsIt() async throws {
    let backend = MockRouterBackend()
    await backend.setProtectionBehavior(.succeeds)
    guard let service = backend.protection else {
        Issue.record("expected a protection service"); return
    }
    let report = await service.setProtection(.disable, allowRecovery: false)
    #expect(report.outcome == .verifiedSuccess(.disabled))
    #expect(report.dispatched == true)

    let overview = try await backend.overview()
    guard case .success(let adGuard, _, _) = overview.adGuard else {
        Issue.record("expected adGuard success"); return
    }
    #expect(adGuard.protection == .disabled)
}

@Test func mismatchThenRecoversBehaviorRestoresPreviousStateWhenAllowed() async throws {
    let backend = MockRouterBackend()
    await backend.setProtectionBehavior(.mismatchThenRecovers)
    let report = await backend.protection!.setProtection(.disable, allowRecovery: true)
    guard case .verifiedRecovery(let restored) = report.outcome else {
        Issue.record("expected verifiedRecovery, got \(report.outcome)"); return
    }
    #expect(restored == .enabled)

    let overview = try await backend.overview()
    guard case .success(let adGuard, _, _) = overview.adGuard else {
        Issue.record("expected adGuard success"); return
    }
    #expect(adGuard.protection == .enabled)
}

@Test func mismatchThenRecoversBehaviorLeavesMismatchWhenRecoveryNotAllowed() async throws {
    let backend = MockRouterBackend()
    await backend.setProtectionBehavior(.mismatchThenRecovers)
    let report = await backend.protection!.setProtection(.disable, allowRecovery: false)
    #expect(report.outcome == .verifiedMismatch(expected: .disabled, actual: .enabled))
}

@Test func lostResponseThenAppliedBehaviorStillApplies() async throws {
    let backend = MockRouterBackend()
    await backend.setProtectionBehavior(.lostResponseThenApplied)
    let report = await backend.protection!.setProtection(.enable, allowRecovery: false)
    #expect(report.outcome == .verifiedSuccess(.enabled))
    #expect(report.dispatched == true)

    let overview = try await backend.overview()
    guard case .success(let adGuard, _, _) = overview.adGuard else {
        Issue.record("expected adGuard success"); return
    }
    #expect(adGuard.protection == .enabled)
}

@Test func externalEditBehaviorReportsConflictAndOverviewReflectsIt() async throws {
    let backend = MockRouterBackend()
    await backend.setProtectionBehavior(.externalEdit)
    let report = await backend.protection!.setProtection(.enable, allowRecovery: false)
    guard case .conflictingExternalEdit(let actual) = report.outcome else {
        Issue.record("expected conflictingExternalEdit, got \(report.outcome)"); return
    }
    guard case .paused = actual else {
        Issue.record("expected a paused actual state"); return
    }

    let overview = try await backend.overview()
    guard case .success(let adGuard, _, _) = overview.adGuard else {
        Issue.record("expected adGuard success"); return
    }
    #expect(adGuard.protection == actual)
}

@Test func unauthorizedBehaviorRejectsButStillCountsAsDispatched() async throws {
    let backend = MockRouterBackend()
    await backend.setProtectionBehavior(.unauthorized)
    let report = await backend.protection!.setProtection(.enable, allowRecovery: false)
    // Matches the live path: a 401/403 reaches the server and is a
    // definitive rejection, not an ambiguous one, but a request was sent.
    #expect(report.dispatched == true)
    #expect(report.outcome == .rejected(.preconditionFailed("AdGuard Home refused the login")))
}

@Test func invalidIntentIsRejectedRegardlessOfBehavior() async throws {
    let backend = MockRouterBackend()
    await backend.setProtectionBehavior(.succeeds)
    let report = await backend.protection!.setProtection(.pause(.seconds(10)), allowRecovery: false)
    #expect(report.dispatched == false)
    guard case .rejected(.invalidIntent) = report.outcome else {
        Issue.record("expected rejected(.invalidIntent), got \(report.outcome)"); return
    }
}

@Test func concurrentMockMutationsSerializeThroughAGateAndOverviewReflectsConsistentState() async throws {
    let backend = MockRouterBackend()
    await backend.setProtectionBehavior(.succeeds)

    let clock = ContinuousClock()
    let start = clock.now
    async let reportA = backend.protection!.setProtection(.enable, allowRecovery: false)
    async let reportB = backend.protection!.setProtection(.disable, allowRecovery: false)
    let (a, b) = await (reportA, reportB)
    let elapsed = clock.now - start

    // Each mock mutation sleeps ~50ms while it reads and writes shared
    // state. If the two calls are serialized through a shared gate, the
    // wall-clock time for both is close to 2x that sleep; if they
    // interleaved instead (the bug this guards against), it would be
    // close to 1x. 90ms only ever fails in the interleaved case: any
    // amount of extra CI slowness only makes the serialized case slower,
    // never faster.
    #expect(elapsed >= .milliseconds(90))

    #expect(a.outcome == .verifiedSuccess(.enabled))
    #expect(a.dispatched == true)
    #expect(b.outcome == .verifiedSuccess(.disabled))
    #expect(b.dispatched == true)

    let overview = try await backend.overview()
    guard case .success(let adGuard, _, _) = overview.adGuard else {
        Issue.record("expected adGuard success"); return
    }
    // Whichever call actually ran last through the gate determines the
    // final state; either is a valid, self-consistent outcome, but it
    // must match one of the two intended states exactly, never a mix.
    #expect(adGuard.protection == .enabled || adGuard.protection == .disabled)
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
