import Foundation

/// Maps transport errors to the category a screen shows, and keeps
/// cancellation apart from failure. Services and executors use it.
enum FailureMapping {
    /// Any error a transport can throw. Errors of other types are
    /// `.unavailable`.
    static func category(for error: any Error) -> RefreshFailureCategory {
        switch error {
        case let error as GLiNetRPCError: category(for: error)
        case let error as AdGuardClientError: category(for: error)
        case let error as TransportError: category(for: error)
        case let failure as SSHFailure: failure.category
        case ProcessRunnerError.timedOut: .timeout
        default: .unavailable
        }
    }

    static func category(for error: GLiNetRPCError) -> RefreshFailureCategory {
        switch error {
        case .transport(let transportError):
            return category(for: transportError)
        case .httpStatus, .malformedResponse, .invalidParameters, .rpcError, .unsupportedAlgorithm, .unsupportedHashMethod:
            return .malformedResponse
        case .accessDenied, .loginPaused, .credentialUnavailable:
            return .authentication
        case .methodNotFound:
            return .unavailable
        }
    }

    static func category(for error: AdGuardClientError) -> RefreshFailureCategory {
        switch error {
        case .transport(let transportError):
            return category(for: transportError)
        case .unauthorized:
            return .authentication
        case .httpStatus, .malformedResponse:
            return .malformedResponse
        case .credentialUnavailable:
            return .authentication
        }
    }

    static func category(for error: TransportError) -> RefreshFailureCategory {
        switch error {
        case .timedOut:
            return .timeout
        case .unreachable, .redirectRefused, .tlsFailure, .localNetworkDenied:
            return .network
        case .cancelled:
            // Defensive only: every call site checks `rethrowIfCancelled` first
            // and throws `CancellationError` instead of reaching this mapping.
            return .network
        case .untrustedServer:
            // Only reached after a refused trust prompt; an approved one is
            // resolved by retrying the whole overview instead of mapping here.
            return .network
        case .responseTooLarge, .invalidResponse:
            return .malformedResponse
        }
    }

    /// Real task cancellation through `URLSessionTransport` surfaces as
    /// `TransportError.cancelled`, not Swift's `CancellationError` — without
    /// this, a cancelled refresh would be reported as a `.network` failure
    /// instead of the cancellation propagating out of `overview()`/`probe()`.
    /// `Task.isCancelled` is checked too, in case cancellation ever surfaces
    /// as some other error instead.
    static func rethrowIfCancelled(_ error: GLiNetRPCError) throws {
        if isCancelled(error) || Task.isCancelled { throw CancellationError() }
    }

    static func rethrowIfCancelled(_ error: AdGuardClientError) throws {
        if isCancelled(error) || Task.isCancelled { throw CancellationError() }
    }

    /// One AdGuard Home read as a result. Cancellation propagates.
    static func adGuardResult<Value: Sendable>(_ read: @Sendable () async throws -> Value) async throws -> Result<Value, RefreshFailureCategory> {
        do {
            return .success(try await read())
        } catch let error as AdGuardClientError {
            try rethrowIfCancelled(error)
            return .failure(category(for: error))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failure(.unavailable)
        }
    }

    private static func isCancelled(_ error: GLiNetRPCError) -> Bool {
        if case .transport(.cancelled) = error { return true }
        return false
    }

    private static func isCancelled(_ error: AdGuardClientError) -> Bool {
        if case .transport(.cancelled) = error { return true }
        return false
    }
}

extension GLiNetRPCClient {
    /// One call as a result. Cancellation propagates.
    func checkedCall(_ call: GLiNetRPCCall) async throws -> Result<JSONValue, GLiNetRPCError> {
        do {
            return .success(try await self.call(call))
        } catch let error as GLiNetRPCError {
            try FailureMapping.rethrowIfCancelled(error)
            return .failure(error)
        }
    }
}
