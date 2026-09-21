import Foundation

/// Opaque proof of holding a `MutationGate`. Only the actor that minted a
/// token can compare it against the one it currently holds, so releasing a
/// foreign or already-released token is always a safe no-op.
public struct MutationGateToken: Sendable, Hashable {
    private let id: UUID

    fileprivate init() {
        self.id = UUID()
    }
}

/// One mutation in flight per router. `acquire()` waits its turn and is
/// cancellation-aware: a waiter that is cancelled before its turn never
/// acquires the gate and never blocks the next waiter.
public actor MutationGate {
    private var currentToken: MutationGateToken?
    private var waiterOrder: [UUID] = []
    private var waiters: [UUID: CheckedContinuation<MutationGateToken, Error>] = [:]

    public init() {}

    public var isHeld: Bool { currentToken != nil }

    public func acquire() async throws -> MutationGateToken {
        try Task.checkCancellation()

        if currentToken == nil {
            let token = MutationGateToken()
            currentToken = token
            return token
        }

        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MutationGateToken, Error>) in
                waiterOrder.append(waiterID)
                waiters[waiterID] = continuation
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
    }

    /// Idempotent: releasing a token that is not the one currently held
    /// (foreign, stale, or already released) does nothing.
    public func release(_ token: MutationGateToken) {
        guard currentToken == token else { return }
        currentToken = nil
        advanceQueue()
    }

    private func cancelWaiter(_ id: UUID) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        waiterOrder.removeAll { $0 == id }
        continuation.resume(throwing: CancellationError())
    }

    private func advanceQueue() {
        guard currentToken == nil, !waiterOrder.isEmpty else { return }
        let nextID = waiterOrder.removeFirst()
        guard let continuation = waiters.removeValue(forKey: nextID) else {
            // Already cancelled; try the next waiter in line.
            advanceQueue()
            return
        }
        let token = MutationGateToken()
        currentToken = token
        continuation.resume(returning: token)
    }
}
