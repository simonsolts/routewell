import Foundation
import Testing
import RoutewellKit
import RoutewellMock

@Test func unknownSnapshotDoesNotInventObservations() {
    let snapshot = MockRouterBackend.snapshot(scenario: .unknown, at: .distantPast)
    #expect(snapshot.router.reachability == .unknown)
    #expect(snapshot.router.temperatureCelsius == .unknown)
    #expect(snapshot.internet.publicAddress == nil)
    #expect(snapshot.adGuard.protection == .unknown)
}

@Test func fixturesAreDeterministicAndIndependent() async throws {
    let date = Date(timeIntervalSince1970: 1_000)
    var first = MockRouterBackend.snapshot(at: date)
    let second = MockRouterBackend.snapshot(at: date)
    #expect(first == second)
    first.router.hostname = "changed"
    #expect(second.router.hostname == "flint-demo")
    #expect(second.adGuard.protection == .paused(until: date.addingTimeInterval(1800)))
    let unknown = try await MockRouterBackend(scenario: .unknown).overview()
    #expect(unknown.router.reachability == .unknown)
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
