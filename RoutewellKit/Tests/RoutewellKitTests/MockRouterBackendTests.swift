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
