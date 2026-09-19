import Testing
@testable import RoutewellKit

private struct Backend: RouterBackend {
    func overview() async throws -> OverviewSnapshot { OverviewSnapshot(observedAt: .distantPast) }
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

private actor HeldBackend: RouterBackend {
    private var result: CheckedContinuation<OverviewSnapshot, any Error>?
    private var started: CheckedContinuation<Void, Never>?
    func overview() async throws -> OverviewSnapshot {
        try await withCheckedThrowingContinuation {
            result = $0
            started?.resume()
            started = nil
        }
    }
    func waitForStart() async {
        if result != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish(fails: Bool) {
        if fails { result?.resume(throwing: SessionError.switching) }
        else { result?.resume(returning: OverviewSnapshot(observedAt: .distantPast)) }
        result = nil
    }
}
