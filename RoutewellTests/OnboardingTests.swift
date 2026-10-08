import Foundation
import Testing
import RoutewellKit
@testable import Routewell

/// Chunk 15A: the onboarding flow, driven through the mock services, plus the
/// live sign-in mapping, first-run launch, and "closed before Finish".

@MainActor
private func makeRun(_ scenario: MockOnboardingScenario) -> (OnboardingModel, MockOnboardingServices) {
    let services = MockOnboardingServices(scenario: scenario, delay: .milliseconds(5))
    let model = OnboardingModel(services: services)
    model.pauseDuration = .milliseconds(50)
    return (model, services)
}

/// Waits for `state`, failing after two seconds.
@MainActor
private func reach(_ model: OnboardingModel, _ state: OnboardingState, sourceLocation: SourceLocation = #_sourceLocation) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while model.state != state, clock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    #expect(model.state == state, sourceLocation: sourceLocation)
    if model.state == state { await waitIdle(model) }
}

/// Waits until no button work is running.
@MainActor
private func waitIdle(_ model: OnboardingModel) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while model.busy, clock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
}

/// Waits for `state` without failing; false when the run went elsewhere.
@MainActor
private func arrive(_ model: OnboardingModel, _ state: OnboardingState) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    let transient: Set<OnboardingState> = [.welcome, .searching, .fallback, .signing, .sshCheck]
    while model.state != state, clock.now < deadline {
        if !transient.contains(model.state), !model.busy, model.state != state { break }
        try? await Task.sleep(for: .milliseconds(5))
    }
    await waitIdle(model)
    return model.state == state
}

/// Primary-button path to a given state, from Welcome. Stops quietly where
/// a scenario leaves the path (its failure state), so the caller can check it.
@MainActor
private func walk(_ model: OnboardingModel, to target: OnboardingState) async {
    let path: [OnboardingState] = [.found, .name, .cert, .password, .sshOffer, .sshKey, .sshChosen, .hostkey, .done]
    model.primary()
    for state in path {
        guard await arrive(model, state) else { return }
        if state == target { return }
        switch state {
        case .password: model.password = "example-password"; model.primary()
        case .sshKey: model.chooseKey()
        default: model.primary()
        }
    }
}

// MARK: - The primary path

@MainActor @Test func everyPrimaryButtonGivesAWorkingSetupWithSSH() async {
    let (model, services) = makeRun(.found)
    var finished = false
    model.onFinish = { finished = true }
    await walk(model, to: .done)
    #expect(model.history.contains(.searching))
    #expect(model.name == "router")
    #expect(model.summary?.router.title == "router")
    #expect(model.summary?.router.detail == "GL-EXAMPLE · 192.0.2.1")
    #expect(model.summary?.ssh.detail == "Signed in with id_example")
    #expect(model.summary?.adGuard.state == "Active")
    model.primary()
    await model.settle()
    #expect(finished)
    #expect(model.finished)
    // Nothing secret before the certificate is trusted.
    let calls = services.calls
    #expect(calls.firstIndex(of: "trust")! < calls.firstIndex(of: "signIn")!)
    #expect(calls.prefix(2) == ["discover", "trust"])
}

@MainActor @Test func everyDesignStateIsReachable() async {
    var seen = Set<OnboardingState>()
    for scenario in MockOnboardingScenario.allCases {
        let (model, _) = makeRun(scenario)
        await walk(model, to: .done)
        // Drive each scenario's failure state on to its recovery.
        switch model.state {
        case .manual:
            if scenario == .denied { break }
            model.address = "192.0.2.30"
            model.primary()
            await reach(model, .name)
        case .denied:
            model.secondary()
            await reach(model, .manual)
        case .wrong, .unreach:
            model.primary()
            await reach(model, .sshOffer)
        case .locked:
            await reach(model, .password)
        case .sshPass:
            model.chooseKey()
            await reach(model, .sshChosen)
        case .sshRejected, .sshUnreach:
            model.primary()
            await reach(model, .done)
        default: break
        }
        seen.formUnion(model.history)
    }
    let (skipped, _) = makeRun(.found)
    await walk(skipped, to: .sshOffer)
    skipped.secondary()
    await reach(skipped, .doneNoSsh)
    seen.formUnion(skipped.history)
    #expect(Set(OnboardingState.allCases).subtracting(seen).isEmpty, "not reached: \(Set(OnboardingState.allCases).subtracting(seen))")
}

// MARK: - Back and Skip SSH

@MainActor @Test func backGoesWhereTheDesignSays() async {
    let (model, _) = makeRun(.found)
    await walk(model, to: .name)
    model.secondary()
    #expect(model.state == .found)
    model.primary()
    model.primary()
    #expect(model.state == .cert)
    model.secondary()
    #expect(model.state == .name)
    model.primary()
    model.primary()
    await reach(model, .password)
    model.secondary()
    #expect(model.state == .cert)

    let (later, _) = makeRun(.found)
    await walk(later, to: .hostkey)
    later.secondary()
    #expect(later.state == .sshChosen)
    later.secondary()
    #expect(later.state == .sshOffer)
}

@MainActor @Test func nameBackReturnsToTheManualAddress() async {
    let (model, _) = makeRun(.manual)
    model.primary()
    await reach(model, .manual)
    model.address = "192.0.2.30"
    model.primary()
    await reach(model, .name)
    model.secondary()
    #expect(model.state == .manual)
}

@MainActor @Test func skipSSHFromEverySSHStateFinishesWithoutSSH() async {
    for target in [OnboardingState.sshKey, .sshChosen, .hostkey] {
        let (model, services) = makeRun(.found)
        await walk(model, to: target)
        #expect(model.spec.skipSSH)
        model.tertiary()
        await reach(model, .doneNoSsh)
        #expect(services.calls.contains("disableSSH"))
        #expect(model.summary?.ssh.state == "Off")
    }
    for scenario in [MockOnboardingScenario.passphraseKey, .keyRejected, .sshNotReachable] {
        let (model, _) = makeRun(scenario)
        await walk(model, to: .done)
        #expect([.sshPass, .sshRejected, .sshUnreach].contains(model.state))
        model.tertiary()
        await reach(model, .doneNoSsh)
    }
    let (offer, _) = makeRun(.found)
    await walk(offer, to: .sshOffer)
    #expect(!offer.spec.skipSSH)
}

// MARK: - Scenarios

@MainActor @Test func fallbackFindsTheUsualAddress() async {
    let (model, _) = makeRun(.fallback)
    await walk(model, to: .found)
    #expect(model.history.contains(.fallback))
    #expect(model.router?.endpoint.host == RouterDiscovery.fallbackHost)
    #expect(model.router?.source == .fallback)
}

@MainActor @Test func manualAddressIsCheckedBeforeConnecting() async {
    let (model, _) = makeRun(.manual)
    model.primary()
    await reach(model, .manual)
    #expect(model.primaryDisabled)
    model.address = "http://192.0.2.30"
    model.primary()
    #expect(model.manualMessage?.contains("HTTPS") == true)
    model.address = "router_lan"
    model.primary()
    #expect(model.manualMessage != nil)
    #expect(model.state == .manual)
    model.secondary()
    #expect(model.state == .searching)
}

@MainActor @Test func deniedOffersSystemSettingsAndTryAgain() async {
    let (model, services) = makeRun(.denied)
    model.primary()
    await reach(model, .denied)
    model.primary()
    #expect(model.state == .denied)
    #expect(services.calls.contains("openSettings"))
    model.secondary()
    #expect(model.state == .searching)
}

@MainActor @Test func signInFailuresHaveTheirOwnStates() async {
    let (wrong, _) = makeRun(.wrongPassword)
    await walk(wrong, to: .sshOffer)
    #expect(wrong.state == .wrong)
    #expect(wrong.spec.badge == .error)

    let (paused, _) = makeRun(.paused)
    await walk(paused, to: .sshOffer)
    #expect(paused.state == .locked)
    #expect(paused.primaryDisabled)
    await reach(paused, .password)

    let (unreachable, _) = makeRun(.unreachable)
    await walk(unreachable, to: .sshOffer)
    #expect(unreachable.state == .unreach)
    unreachable.secondary()
    #expect(unreachable.state == .manual)
    #expect(unreachable.address == "192.0.2.1")
}

@MainActor @Test func aPassphraseKeyCannotContinue() async {
    let (model, _) = makeRun(.passphraseKey)
    await walk(model, to: .sshChosen)
    #expect(model.state == .sshPass)
    #expect(model.primaryDisabled)
    #expect(model.key?.inspection.problem?.contains("passphrase") == true)
    model.chooseKey()
    #expect(model.state == .sshChosen)
    #expect(!model.primaryDisabled)
}

@MainActor @Test func aRejectedKeyCanBeChangedOrRetried() async {
    let (model, _) = makeRun(.keyRejected)
    await walk(model, to: .done)
    #expect(model.state == .sshRejected)
    #expect(model.state.rows == [.ok, .fail])
    model.secondary()
    #expect(model.state == .sshKey)
    #expect(model.key == nil)

    let (unreachable, _) = makeRun(.sshNotReachable)
    await walk(unreachable, to: .done)
    #expect(unreachable.state == .sshUnreach)
    unreachable.primary()
    await reach(unreachable, .done)
}

@MainActor @Test func adGuardOffShowsItsFinish() async {
    let (model, _) = makeRun(.adGuardOff)
    await walk(model, to: .done)
    await reach(model, .doneNoAdg)
    #expect(model.summary?.adGuard.state == "Off")
}

@Test func probeVerdictsMatchTheCheckStates() {
    let now = Date()
    #expect(SSHProbeResult(capability: Capability(.supported, evidence: .successfulResponse, observedAt: now)).verdict == .connected)
    #expect(SSHProbeResult(capability: Capability(observedAt: now), failure: .authenticationFailed).verdict == .rejected)
    #expect(SSHProbeResult(capability: Capability(observedAt: now), failure: .hostKeyChanged).verdict == .rejected)
    #expect(SSHProbeResult(capability: Capability(observedAt: now), failure: .connectionFailed).verdict == .unreachable)
    #expect(SSHProbeResult(capability: Capability(observedAt: now), failure: .timedOut).verdict == .unreachable)
}

@Test func theDesignCopyIsKept() {
    #expect(OnboardingState.welcome.spec.primary == "Find My Router")
    #expect(OnboardingState.locked.spec.title == "Sign-in paused")
    #expect(OnboardingState.sshUnreach.spec.body.contains("port 22"))
    #expect(OnboardingState.allCases.filter { $0.spec.skipSSH }.count == 7)
    #expect(OnboardingStep.allCases.map(\.label) == ["Find router", "Name", "Sign in", "SSH", "Finish"])
}

// MARK: - Live sign-in and the saved profile

/// Answers `challenge`, then `login` with the given error code (or a sid),
/// then `system.get_info`. Records every method.
private actor ScriptedRouter: HTTPTransport {
    let loginError: Int?
    private(set) var methods: [String] = []
    init(loginError: Int?) { self.loginError = loginError }

    func send(_ request: URLRequest, limits: HTTPRequestLimits) async throws -> (Data, HTTPURLResponse) {
        let body = (try? JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data())) ?? .null
        let method = body["method"]?.string ?? ""
        methods.append(method)
        let result: JSONValue
        switch method {
        case "challenge": result = .object(["alg": .number(1), "salt": .string("saltsalt12"), "nonce": .string("nonceabcdef")])
        case "login":
            if let loginError {
                return Self.reply(.object(["jsonrpc": .string("2.0"), "id": .number(1),
                                           "error": .object(["code": .number(Double(loginError)), "message": .string("x")])]), request)
            }
            result = .object(["sid": .string("SID-EXAMPLE")])
        default: result = .object(["model": .string("GL-EXAMPLE"), "firmware_version": .string("4.0.0")])
        }
        return Self.reply(.object(["jsonrpc": .string("2.0"), "id": .number(1), "result": result]), request)
    }

    static func reply(_ value: JSONValue, _ request: URLRequest) -> (Data, HTTPURLResponse) {
        (try! JSONEncoder().encode(value), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor
private func liveEnvironment(_ router: ScriptedRouter, store: AtomicJSONStore? = nil,
                             credentials: any CredentialStore = InMemoryCredentialStore()) -> AppEnvironment {
    AppEnvironment(model: AppModel(mode: .live), backend: nil, store: store, credentials: credentials,
                   processRunner: NoProcesses(), transportFactory: { _ in router })
}

private struct NoProcesses: ProcessRunning {
    func run(executable: URL, arguments: [String], environment: [String: String], limits: ProcessLimits) async throws -> ProcessResult {
        Issue.record("onboarding tests must not start a process")
        throw ProcessRunnerError.cancelled
    }
}

private let discovered = DiscoveredRouter(endpoint: try! RouterEndpoint.parse("192.0.2.1"), source: .gateway,
                                          fingerprint: try! CertificateFingerprint(sha256: Data(repeating: 0xA5, count: 32)))

@MainActor @Test func liveSignInMapsTheRouterAnswers() async {
    for (code, expected) in [(-32000, OnboardingSignIn.wrongPassword), (-32003, .paused)] {
        let router = ScriptedRouter(loginError: code)
        let environment = liveEnvironment(router)
        await environment.waitUntilReady()
        let services = LiveOnboardingServices(environment: environment)
        #expect(await services.signIn(to: discovered, name: "router", password: "example-password") == expected)
        #expect(environment.persistence.profiles.profiles.allSatisfy { $0.liveEndpoint == nil })
    }
}

@MainActor @Test func liveSignInSavesAnUnfinishedProfileAndFinishCompletesIt() async {
    let router = ScriptedRouter(loginError: nil)
    let environment = liveEnvironment(router)
    await environment.waitUntilReady()
    let services = LiveOnboardingServices(environment: environment)
    #expect(await services.trust(discovered))
    let result = await services.signIn(to: discovered, name: "Home", password: "example-password")
    #expect(result == .signedIn(RouterProbe(model: "GL-EXAMPLE", firmware: "4.0.0")))
    let profile = environment.persistence.selectedProfile
    #expect(profile?.name == "Home")
    #expect(profile?.username == "root")
    #expect(profile?.setupComplete == false)
    #expect(environment.model.needsSetup)
    #expect(await router.methods.prefix(2) == ["challenge", "login"])

    #expect(await services.finish(name: "Home"))
    #expect(environment.persistence.selectedProfile?.setupComplete == true)
    #expect(!environment.model.needsSetup)
}

@MainActor @Test func closingBeforeFinishRemovesWhatTheRunSaved() async {
    let router = ScriptedRouter(loginError: nil)
    let credentials = InMemoryCredentialStore()
    let environment = liveEnvironment(router, credentials: credentials)
    await environment.waitUntilReady()
    let services = LiveOnboardingServices(environment: environment)
    _ = await services.trust(discovered)
    _ = await services.signIn(to: discovered, name: "router", password: "example-password")
    let credential = try! #require(environment.persistence.selectedProfile?.credential)
    await services.abandon()
    #expect(environment.persistence.profiles.profiles.allSatisfy { $0.liveEndpoint == nil })
    #expect(await environment.trust.store.trusted(host: "192.0.2.1", port: 443) == nil)
    await #expect(throws: (any Error).self) { _ = try await credentials.read(credential) }
    #expect(environment.model.needsSetup)
}

@MainActor @Test func anUnfinishedProfileIsRemovedAtTheNextLaunch() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("onboarding-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentials = InMemoryCredentialStore()
    let router = ScriptedRouter(loginError: nil)

    let first = liveEnvironment(router, store: AtomicJSONStore(directory: directory), credentials: credentials)
    await first.waitUntilReady()
    let services = LiveOnboardingServices(environment: first)
    _ = await services.trust(discovered)
    _ = await services.signIn(to: discovered, name: "router", password: "example-password")
    await first.persistence.flush()
    let credential = try #require(first.persistence.selectedProfile?.credential)
    // Quit before Finish: the launch guess opens onboarding.
    #expect(AppEnvironment.peekNeedsSetup(in: directory))

    let second = liveEnvironment(router, store: AtomicJSONStore(directory: directory), credentials: credentials)
    await second.waitUntilReady()
    #expect(second.model.needsSetup)
    #expect(second.persistence.profiles.profiles.allSatisfy { $0.liveEndpoint == nil })
    await #expect(throws: (any Error).self) { _ = try await credentials.read(credential) }
    #expect(await second.trust.store.trusted(host: "192.0.2.1", port: 443) == nil)
}

@MainActor @Test func aFinishedRouterOpensTheMainWindowAtLaunch() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("onboarding-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let router = ScriptedRouter(loginError: nil)
    let environment = liveEnvironment(router, store: AtomicJSONStore(directory: directory))
    await environment.waitUntilReady()
    let services = LiveOnboardingServices(environment: environment)
    _ = await services.trust(discovered)
    _ = await services.signIn(to: discovered, name: "router", password: "example-password")
    #expect(await services.finish(name: "router"))
    #expect(!AppEnvironment.peekNeedsSetup(in: directory))
}

// MARK: - Launch: no flash of the main window

@MainActor @Test func launchOpensOnboardingOnlyWhenSetupIsNeeded() {
    let live = AppEnvironment.configured(variables: [:], persist: false) { _ in ScriptedRouter(loginError: nil) }
    #expect(live.launchShowsOnboarding)
    let mock = AppEnvironment.configured(variables: ["ROUTEWELL_BACKEND": "mock"], persist: false)
    #expect(!mock.launchShowsOnboarding)
    #expect(!mock.model.needsSetup)
    let firstRunMock = AppEnvironment.configured(variables: ["ROUTEWELL_BACKEND": "mock", "ROUTEWELL_ONBOARDING": "fallback"], persist: false)
    #expect(firstRunMock.launchShowsOnboarding)
    #expect(firstRunMock.onboarding.launchMockScenario == .fallback)
    let empty = FileManager.default.temporaryDirectory.appendingPathComponent("none-\(UUID().uuidString)")
    #expect(AppEnvironment.peekNeedsSetup(in: empty))
}

@MainActor @Test func theWindowStartsTheFirstRunOnlyAfterBootstrap() async {
    let environment = AppEnvironment.configured(variables: [:], persist: false) { _ in ScriptedRouter(loginError: nil) }
    await environment.waitUntilReady()
    #expect(environment.model.needsSetup)
    let run = environment.onboarding.runForLaunch()
    #expect(run?.state == .welcome)
    #expect(environment.onboarding.runForLaunch() === run)
    environment.onboarding.windowClosed()
    #expect(environment.onboarding.run == nil)

    let mock = AppEnvironment.configured(variables: ["ROUTEWELL_BACKEND": "mock"], persist: false)
    await mock.waitUntilReady()
    #expect(mock.onboarding.runForLaunch() == nil)
}

// MARK: - SSH steps alone (for 15B)

@MainActor @Test func theSSHStepsRunAloneAndReportTheResult() async {
    var result: Bool?
    let services = MockOnboardingServices(scenario: .found, delay: .milliseconds(5))
    let model = OnboardingModel(sshStepsWith: services, host: "192.0.2.1") { result = $0 }
    #expect(model.state == .sshKey)
    model.chooseKey()
    #expect(model.state == .sshChosen)
    model.primary()
    await reach(model, .hostkey)
    model.primary()
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while result == nil, clock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    #expect(result == true)
    #expect(model.state == .sshCheck)
    #expect(!services.calls.contains("signIn"))

    var skipped: Bool?
    let other = OnboardingModel(sshStepsWith: MockOnboardingServices(scenario: .found, delay: .zero), host: "192.0.2.1") { skipped = $0 }
    other.tertiary()
    await other.settle()
    #expect(skipped == false)
}
