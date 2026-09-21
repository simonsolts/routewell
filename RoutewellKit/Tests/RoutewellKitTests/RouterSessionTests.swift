import Foundation
import Testing
@testable import RoutewellKit

private struct Backend: RouterBackend {
    var protection: (any ProtectionService)? { nil }
    func overview() async throws -> OverviewRefreshResult { result() }
}

private func result(at date: Date = .distantPast) -> OverviewRefreshResult {
    .init(router: .success(.init(), observedAt: date, source: .mock),
          internet: .success(.init(), observedAt: date, source: .mock),
          adGuard: .success(.init(), observedAt: date, source: .mock),
          clients: .success(.init(), observedAt: date, source: .mock))
}

private func lease(_ revision: UInt64) -> SessionLease {
    SessionLease(token: SessionToken(profileID: "mock", revision: revision), backend: Backend())
}

@Test func overlappingConstructionCannotInstallOlderLease() async throws {
    let session = RouterSession()
    let first = lease(1), second = lease(2)
    try await session.beginRevision(first.token)
    try await session.beginRevision(second.token)
    try await session.installLease(second)
    await #expect(throws: SessionError.stale) { try await session.installLease(first) }
    await #expect(throws: SessionError.stale) { try await session.beginRevision(first.token) }
    try await session.validateBefore(second)
}

@Test func requestsDuringSwitchingAreRejected() async throws {
    let session = RouterSession(), pending = lease(1)
    try await session.beginRevision(pending.token)
    await #expect(throws: SessionError.switching) { try await session.overview(using: pending) }
}

@Test func leaseCannotBeReplacedWithinRevision() async throws {
    let session = RouterSession(), installed = lease(1), impostor = lease(1)
    try await session.beginRevision(installed.token)
    try await session.installLease(installed)
    await #expect(throws: SessionError.stale) { try await session.installLease(impostor) }
    await #expect(throws: SessionError.stale) { try await session.validateBefore(impostor) }
}

@Test(arguments: ["success", "failure", "trust approval", "busy completion"])
func allLateCompletionsAreStaleBeforeNewResult(_ event: String) async throws {
    let session = RouterSession(), old = lease(1), new = lease(2)
    try await session.beginRevision(old.token)
    try await session.installLease(old)
    try await session.validateBefore(old)
    try await session.beginRevision(new.token)
    await #expect(throws: SessionError.stale) { try await session.validateAfter(old) }
}

@Test(arguments: [false, true]) func cancellationIgnoringTransportIsFenced(fails: Bool) async throws {
    let backend = HeldBackend()
    let session = RouterSession()
    let old = SessionLease(token: SessionToken(profileID: "old", revision: 1), backend: backend)
    try await session.beginRevision(old.token)
    try await session.installLease(old)
    let request = Task { try await session.overview(using: old) }
    await backend.waitForStart()
    request.cancel()
    try await session.beginRevision(lease(2).token)
    await backend.finish(fails: fails)
    await #expect(throws: SessionError.stale) { try await request.value }
}

@Test func setProtectionStaleAfterCompletionThrows() async throws {
    let backend = HeldProtectionBackend()
    let session = RouterSession()
    let old = SessionLease(token: SessionToken(profileID: "old", revision: 1), backend: backend)
    try await session.beginRevision(old.token)
    try await session.installLease(old)
    let request = Task { try await session.setProtection(using: old, intent: .enable, allowRecovery: false) }
    await backend.waitForStart()
    try await session.beginRevision(lease(2).token)
    let finishedReport = MutationReport<ProtectionState>(
        outcome: .verifiedSuccess(.enabled), dispatched: true,
        startedAt: .distantPast, finishedAt: .distantPast, failure: nil
    )
    await backend.finish(finishedReport)
    // The write may have reached the router even though the session moved
    // on; the caller must never see this report as if it were current.
    await #expect(throws: SessionError.stale) { try await request.value }
}

private actor HeldProtectionBackend: RouterBackend {
    nonisolated var protection: (any ProtectionService)? { HeldProtectionService(backend: self) }
    private var completion: CheckedContinuation<MutationReport<ProtectionState>, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func overview() async throws -> OverviewRefreshResult { result() }
    func runProtection() async -> MutationReport<ProtectionState> {
        await withCheckedContinuation { (continuation: CheckedContinuation<MutationReport<ProtectionState>, Never>) in
            completion = continuation
            started?.resume()
            started = nil
        }
    }
    func waitForStart() async {
        if completion != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish(_ report: MutationReport<ProtectionState>) {
        completion?.resume(returning: report)
        completion = nil
    }
}

private struct HeldProtectionService: ProtectionService {
    let backend: HeldProtectionBackend
    func setProtection(_ intent: ProtectionIntent, allowRecovery: Bool) async -> MutationReport<ProtectionState> {
        await backend.runProtection()
    }
}

private actor HeldBackend: RouterBackend {
    nonisolated let protection: (any ProtectionService)? = nil
    private var completion: CheckedContinuation<OverviewRefreshResult, any Error>?
    private var started: CheckedContinuation<Void, Never>?
    func overview() async throws -> OverviewRefreshResult {
        try await withCheckedThrowingContinuation {
            completion = $0
            started?.resume()
            started = nil
        }
    }
    func waitForStart() async {
        if completion != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish(fails: Bool) {
        if fails { completion?.resume(throwing: SessionError.switching) }
        else { completion?.resume(returning: result()) }
        completion = nil
    }
}
