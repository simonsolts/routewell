import Foundation
import Testing
import RoutewellKit
@testable import Routewell

@MainActor @Test func trustPromptCancelResolvesFalseAndClearsPending() async {
    let controller = TrustPromptController()
    let request = TrustPromptRequest(host: "192.168.8.1", port: 443, decision: .untrustedNew(try! CertificateFingerprint(sha256: Data(repeating: 1, count: 32))))
    let task = Task { await controller.present(request) }
    while controller.pending == nil { await Task.yield() }
    controller.resolve(false)
    #expect(await task.value == false)
    #expect(controller.pending == nil)
}

@MainActor @Test func trustPromptApproveResolvesTrue() async {
    let controller = TrustPromptController()
    let request = TrustPromptRequest(host: "192.168.8.1", port: 443, decision: .untrustedNew(try! CertificateFingerprint(sha256: Data(repeating: 1, count: 32))))
    let task = Task { await controller.present(request) }
    while controller.pending == nil { await Task.yield() }
    controller.resolve(true)
    #expect(await task.value == true)
}

@MainActor @Test func secondPresentCancelsThePendingFirstOne() async {
    let controller = TrustPromptController()
    let first = TrustPromptRequest(host: "192.168.8.1", port: 443, decision: .untrustedNew(try! CertificateFingerprint(sha256: Data(repeating: 1, count: 32))))
    let second = TrustPromptRequest(host: "192.168.8.2", port: 443, decision: .untrustedNew(try! CertificateFingerprint(sha256: Data(repeating: 2, count: 32))))
    let firstTask = Task { await controller.present(first) }
    while controller.pending == nil { await Task.yield() }
    let secondTask = Task { await controller.present(second) }
    #expect(await firstTask.value == false)
    while controller.pending != second { await Task.yield() }
    controller.resolve(true)
    #expect(await secondTask.value == true)
}
