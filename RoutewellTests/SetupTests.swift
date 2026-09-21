import Foundation
import Testing
import RoutewellKit
@testable import Routewell

@Test func emptyAddressCannotSave() {
    let validation = SetupFormState().validate()
    #expect(!validation.canSave)
    guard case .failure(let error) = validation.endpoint else {
        Issue.record("expected a parse failure for an empty address")
        return
    }
    #expect(error == .empty)
}

@Test func validHTTPSAddressWithCredentialsCanSave() {
    var form = SetupFormState()
    form.addressText = "192.168.8.1"
    form.username = "root"
    form.password = "secret"
    let validation = form.validate()
    #expect(validation.usernameProblem == nil)
    #expect(validation.passwordProblem == nil)
    #expect(!validation.plainHTTPNeedsAck)
    #expect(validation.canSave)
    guard case .success(let endpoint) = validation.endpoint else {
        Issue.record("expected a valid endpoint")
        return
    }
    #expect(endpoint.scheme == .https)
}

@Test func plainHTTPRequiresAcknowledgementBeforeSaving() {
    var form = SetupFormState()
    form.addressText = "http://192.168.8.1"
    form.username = "root"
    form.password = "secret"
    let unacknowledged = form.validate()
    #expect(unacknowledged.plainHTTPNeedsAck)
    #expect(!unacknowledged.canSave)

    form.plainHTTPAcknowledged = true
    let acknowledged = form.validate()
    #expect(!acknowledged.plainHTTPNeedsAck)
    #expect(acknowledged.canSave)
}

@Test func blankUsernameOrPasswordCannotSave() {
    var form = SetupFormState()
    form.addressText = "192.168.8.1"
    form.username = "   "
    form.password = ""
    let validation = form.validate()
    #expect(validation.usernameProblem != nil)
    #expect(validation.passwordProblem != nil)
    #expect(!validation.canSave)
}

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
