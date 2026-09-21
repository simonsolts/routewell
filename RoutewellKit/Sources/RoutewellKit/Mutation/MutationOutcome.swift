import Foundation

/// Why a mutation was rejected before (or instead of) dispatching a write.
public enum MutationRejection: Sendable, Equatable {
    case gateBusy
    case staleSession
    case capabilityUnavailable
    case preconditionFailed(String)
    case invalidIntent(String)
}

/// The terminal result of a verified mutation. See
/// `../../../../../../routewell-private-docs/architecture/04-mutations.md`
/// for the contract this implements.
public enum MutationOutcome<State: Sendable & Equatable>: Sendable, Equatable {
    case rejected(MutationRejection)
    case verifiedSuccess(State)
    case verifiedMismatch(expected: State, actual: State)
    case verifiedRecovery(restored: State)
    case recoveryFailed(expected: State, actual: State?)
    case conflictingExternalEdit(actual: State)
    case unknownAfterDispatch
}

/// A full record of one mutation attempt, including whether a write was
/// actually sent (as opposed to rejected before dispatch).
public struct MutationReport<State: Sendable & Equatable>: Sendable, Equatable {
    public let outcome: MutationOutcome<State>
    public let dispatched: Bool
    public let startedAt: Date
    public let finishedAt: Date
    public let failure: RefreshFailureCategory?

    public init(
        outcome: MutationOutcome<State>,
        dispatched: Bool,
        startedAt: Date,
        finishedAt: Date,
        failure: RefreshFailureCategory?
    ) {
        self.outcome = outcome
        self.dispatched = dispatched
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.failure = failure
    }
}
