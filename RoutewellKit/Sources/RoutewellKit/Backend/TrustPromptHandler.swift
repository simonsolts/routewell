import Foundation

/// Asks a person whether an unrecognized (or changed) certificate should be
/// trusted for one router or AdGuard endpoint. Implementations must not
/// block forever without a way for the person to cancel; a cancelled prompt
/// should return `false`.
public protocol TrustPromptHandler: Sendable {
    /// Return `true` to trust `decision`'s certificate and retry. `LiveRouterBackend`
    /// stores the approval (keyed by `host`/`port`) itself when this returns `true`.
    func requestTrust(host: String, port: Int, decision: TrustDecision) async -> Bool
}

/// Always refuses. Useful for headless contexts (tests, background refreshes
/// with no one to ask) where an unrecognized certificate must never be trusted
/// silently.
public struct DenyAllTrustPromptHandler: TrustPromptHandler {
    public init() {}

    public func requestTrust(host: String, port: Int, decision: TrustDecision) async -> Bool {
        false
    }
}
