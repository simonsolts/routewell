import Foundation
@testable import RoutewellKit

/// Refuses every certificate.
struct DenyAllTrustPromptHandler: TrustPromptHandler {
    func requestTrust(host: String, port: Int, decision: TrustDecision) async -> Bool { false }
}
