import Observation
import RoutewellKit

/// One certificate the transport could not verify automatically, waiting on
/// a person's decision in `TrustPromptView`.
struct TrustPromptRequest: Equatable {
    let host: String
    let port: Int
    let decision: TrustDecision
}

/// Presents at most one trust prompt at a time. `chunk 09` will call
/// `present(_:)` from the live transport's challenge path; this chunk only
/// wires the controller and view up so that path can be filled in later.
@MainActor @Observable
final class TrustPromptController {
    private(set) var pending: TrustPromptRequest?
    private var continuation: CheckedContinuation<Bool, Never>?

    /// Presents `request`. If another request is already pending, that one
    /// is resolved as cancelled first.
    func present(_ request: TrustPromptRequest) async -> Bool {
        resolve(false)
        pending = request
        return await withCheckedContinuation { continuation = $0 }
    }

    func resolve(_ approved: Bool) {
        pending = nil
        continuation?.resume(returning: approved)
        continuation = nil
    }
}
