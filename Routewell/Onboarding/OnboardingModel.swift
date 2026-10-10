import Foundation
import Observation
import RoutewellKit

/// One run of the setup assistant: the current design state, what the
/// person typed or chose, and the async work behind each button. The
/// primary button on every step leads to a safe, working setup.
@MainActor @Observable
final class OnboardingModel {
    private(set) var state: OnboardingState = .welcome { didSet { history.append(state) } }
    /// Every state this run showed, in order. Tests read it.
    @ObservationIgnored private(set) var history: [OnboardingState] = [.welcome]
    /// The Manual step's field. Also shows the found address elsewhere.
    var address = ""
    var name = "router"
    var password = ""
    private(set) var router: DiscoveredRouter?
    /// Red text under the address field.
    private(set) var manualMessage: String?
    /// Shown on the Certificate step when the router's certificate changed
    /// between trusting it and signing in.
    private(set) var certificateNotice: String?
    /// Red text under the password field for a failure with no state of its own.
    private(set) var passwordMessage: String?
    /// Red text on Finish when the router could not be saved.
    private(set) var finishMessage: String?
    private(set) var probe: RouterProbe?
    private(set) var key: ChosenSSHKey?
    private(set) var hostKey: SSHHostKeyCandidate?
    private(set) var summary: OnboardingSummary?
    /// Work is running that the current state does not show by itself
    /// (Connect, reading the host key, reading AdGuard Home before Finish).
    private(set) var busy = false
    private(set) var finished = false
    /// True once sign-in saved a profile, so closing the window must remove it.
    private(set) var savedProfile = false

    let services: any OnboardingServices
    /// Opens the main window and closes this one.
    @ObservationIgnored var onFinish: (() -> Void)?
    /// Set for the SSH steps alone (15B's sheet when Use SSH is switched on):
    /// the run starts at Choose Key and reports here instead of showing
    /// Finish. True means SSH connected; false means it was skipped.
    @ObservationIgnored var onSSHDone: ((Bool) -> Void)?
    @ObservationIgnored private var work: Task<Void, Never>?
    /// From the found card or the Manual step: where Name's Back goes.
    @ObservationIgnored private var foundManually = false
    /// The host key scan failed, so SSH Try Again scans again instead of probing.
    @ObservationIgnored private var hostKeyFailed = false
    /// How long "Sign-in paused" keeps Sign In disabled. `[assumed]`: the
    /// router does not say.
    @ObservationIgnored var pauseDuration: Duration = .seconds(60)

    init(services: any OnboardingServices) {
        self.services = services
    }

    /// The SSH steps alone, for a router that is already set up. A usable
    /// `key` (Settings after a port change) starts at Key Chosen.
    convenience init(sshStepsWith services: any OnboardingServices, host: String, key: ChosenSSHKey? = nil,
                     onDone: @escaping (Bool) -> Void) {
        self.init(services: services)
        address = host
        onSSHDone = onDone
        if let key, key.inspection.isUsable {
            self.key = key
            state = .sshChosen
        } else {
            state = .sshKey
        }
        history = [state]
    }

    var spec: OnboardingSpec { state.spec }

    var primaryDisabled: Bool {
        if busy { return true }
        switch state {
        case .manual: return address.trimmingCharacters(in: .whitespaces).isEmpty
        case .password, .wrong: return password.isEmpty
        case .hostkey: return hostKey == nil
        default: return spec.primaryDisabled
        }
    }

    /// "<address>" for rows, notes, and the fingerprint box.
    var displayAddress: String { router.map { Self.shortAddress($0.endpoint) } ?? address }

    /// "192.168.8.1", or "host:port" when the port is not 443. Onboarding
    /// always uses HTTPS, so the scheme is left out.
    static func shortAddress(_ endpoint: RouterEndpoint) -> String {
        let host = endpoint.host.contains(":") ? "[\(endpoint.host)]" : endpoint.host
        return endpoint.port == 443 ? host : "\(host):\(endpoint.port)"
    }
    var host: String { router?.endpoint.host ?? address }

    // MARK: Buttons

    func primary() {
        guard !primaryDisabled else { return }
        switch state {
        case .welcome: search()
        case .found: go(.name)
        case .manual: connect()
        case .denied: services.openLocalNetworkSettings()
        case .name: go(.cert)
        case .cert: trust()
        case .password, .wrong, .unreach: signIn()
        case .sshOffer: go(.sshKey)
        case .sshChosen: readHostKey()
        case .hostkey: enableSSH()
        case .sshRejected: recheck()
        case .sshUnreach: hostKeyFailed ? readHostKey() : recheck()
        case .done, .doneNoSsh, .doneNoAdg: finish()
        case .searching, .fallback, .signing, .locked, .sshKey, .sshPass, .sshCheck: break
        }
    }

    func secondary() {
        switch state {
        case .manual, .denied: search()
        case .name: go(foundManually ? .manual : .found)
        case .unreach:
            address = displayAddress
            go(.manual)
        case .sshOffer: skipSSH()
        case .sshRejected:
            key = nil
            go(.sshKey)
        default:
            if let back = state.back { go(back) }
        }
    }

    /// "Skip SSH".
    func tertiary() {
        guard spec.skipSSH else { return }
        skipSSH()
    }

    /// "Enter Address Manually…" and "Use a Different Address…".
    func enterAddress() {
        if router != nil { address = displayAddress }
        go(.manual)
    }

    func chooseKey() {
        guard state.kind == .key, let chosen = services.chooseKeyFile() else { return }
        key = chosen
        hostKey = nil
        go(chosen.inspection.isUsable ? .sshChosen : .sshPass)
    }

    /// The window closed before Finish.
    func abandon() {
        let pending = work
        pending?.cancel()
        guard !finished else { return }
        Task { [services] in
            // A cancelled step must end before its changes are undone.
            await pending?.value
            await services.abandon()
        }
    }

    /// Waits for the work the last button started. For tests.
    func settle() async { await work?.value }

    #if DEBUG
    /// Puts the run in `state` with mock values, for previews and snapshots.
    func preview(_ state: OnboardingState) {
        let endpoint = try! RouterEndpoint.parse(MockOnboardingServices.gateway)
        router = DiscoveredRouter(endpoint: endpoint, source: .gateway, fingerprint: MockOnboardingServices.fingerprint)
        address = Self.shortAddress(endpoint)
        probe = MockOnboardingServices.probe
        if state.kind == .key || state.kind == .hostkey || state.kind == .check || state.isFinish {
            key = state == .sshKey ? nil : ChosenSSHKey(url: MockOnboardingServices.keyURL, bookmark: nil,
                                                        inspection: state == .sshPass ? .passphraseProtected : .usable(kind: "ED25519"))
        }
        if state == .hostkey {
            hostKey = SSHHostKeyCandidate(keyLine: "192.0.2.1 ssh-ed25519 \(Data(repeating: 0x11, count: 32).base64EncodedString())")
        }
        if state.isFinish {
            summary = OnboardingSummary(name: name, address: address, probe: probe,
                                        ssh: state == .doneNoSsh ? .off : .connected(keyName: key?.name ?? ""),
                                        adGuardEnabled: .value(state != .doneNoAdg))
        }
        if state == .password || state == .wrong { password = "example" }
        self.state = state
    }
    #endif

    // MARK: Steps

    private func go(_ next: OnboardingState) {
        work?.cancel()
        busy = false
        state = next
    }

    private func run(_ body: @escaping @MainActor (OnboardingModel) async -> Void) {
        work?.cancel()
        work = Task { [weak self] in
            guard let self else { return }
            await body(self)
        }
    }

    private func search() {
        router = nil
        go(.searching)
        run { model in
            let result = await model.services.discover { [weak model] in
                if model?.state == .searching { model?.state = .fallback }
            }
            guard !Task.isCancelled else { return }
            switch result {
            case .found(let found):
                model.router = found
                model.foundManually = false
                model.address = Self.shortAddress(found.endpoint)
                model.state = .found
            case .notFound:
                model.manualMessage = nil
                model.state = .manual
            case .localNetworkDenied:
                model.state = .denied
            }
        }
    }

    private func connect() {
        let text = address.trimmingCharacters(in: .whitespaces)
        let endpoint: RouterEndpoint
        do {
            endpoint = try RouterEndpoint.parse(text)
        } catch {
            manualMessage = error.message
            return
        }
        guard endpoint.scheme == .https else {
            manualMessage = "Routewell connects over HTTPS. Remove http:// from the address."
            return
        }
        manualMessage = nil
        busy = true
        run { model in
            let result = await model.services.probe(manual: endpoint)
            guard !Task.isCancelled else { return }
            model.busy = false
            switch result {
            case .found(let found):
                model.router = found
                model.foundManually = true
                model.state = .name
            case .notGLiNet:
                model.manualMessage = "Something answered at \(Self.shortAddress(endpoint)), but it isn’t a GL.iNet router."
            case .noAnswer:
                model.manualMessage = "No response from \(Self.shortAddress(endpoint))."
            case .localNetworkDenied:
                model.state = .denied
            }
        }
    }

    private func trust() {
        guard let router else { return }
        busy = true
        run { model in
            let trusted = await model.services.trust(router)
            guard !Task.isCancelled else { return }
            model.busy = false
            if trusted {
                model.certificateNotice = nil
                model.passwordMessage = nil
                model.state = .password
            } else {
                model.certificateNotice = "The certificate could not be saved. Try again."
            }
        }
    }

    private func signIn() {
        guard let router else { return }
        let secret = password
        let chosenName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        passwordMessage = nil
        go(.signing)
        run { model in
            let result = await model.services.signIn(to: router, name: chosenName.isEmpty ? "router" : chosenName, password: secret)
            guard !Task.isCancelled else { return }
            switch result {
            case .signedIn(let probe):
                model.probe = probe
                model.password = ""
                model.savedProfile = true
                model.state = .sshOffer
            case .wrongPassword:
                model.state = .wrong
            case .paused:
                model.state = .locked
                try? await Task.sleep(for: model.pauseDuration)
                if !Task.isCancelled, model.state == .locked { model.state = .password }
            case .unreachable:
                model.state = .unreach
            case .certificateChanged(let fingerprint):
                model.router?.fingerprint = fingerprint
                model.certificateNotice = "The router now shows a different certificate. Check it again before you trust it."
                model.state = .cert
            case .failed(let message):
                model.passwordMessage = message
                model.state = .password
            }
        }
    }

    private func readHostKey() {
        guard key?.inspection.isUsable == true else { return }
        hostKey = nil
        hostKeyFailed = false
        go(.hostkey)
        busy = true
        let host = host
        run { model in
            let result = await model.services.scanHostKey(host: host)
            guard !Task.isCancelled else { return }
            model.busy = false
            switch result {
            case .success(let candidate):
                model.hostKey = candidate
            case .failure:
                model.hostKeyFailed = true
                model.state = .sshUnreach
            }
        }
    }

    private func enableSSH() {
        guard let key, let hostKey else { return }
        let host = host
        go(.sshCheck)
        run { model in
            let probe = await model.services.enableSSH(key: key, hostKey: hostKey, host: host)
            guard !Task.isCancelled else { return }
            await model.apply(probe)
        }
    }

    private func recheck() {
        go(.sshCheck)
        run { model in
            let probe = await model.services.recheckSSH()
            guard !Task.isCancelled else { return }
            await model.apply(probe)
        }
    }

    private func apply(_ probe: SSHProbeResult) async {
        switch probe.verdict {
        case .connected: await showFinish(ssh: true)
        case .rejected: state = .sshRejected
        case .unreachable: state = .sshUnreach
        }
    }

    private func skipSSH() {
        let pending = work
        busy = true
        run { model in
            // A cancelled Trust and Continue must end before SSH is put back.
            await pending?.value
            await model.services.disableSSH()
            guard !Task.isCancelled else { return }
            model.key = nil
            model.hostKey = nil
            await model.showFinish(ssh: false)
        }
    }

    private func showFinish(ssh: Bool) async {
        if let onSSHDone {
            busy = false
            finished = true
            onSSHDone(ssh)
            return
        }
        busy = true
        let adGuard = await services.adGuardHomeEnabled()
        guard !Task.isCancelled else { return }
        busy = false
        summary = OnboardingSummary(name: name, address: displayAddress, probe: probe,
                                    ssh: ssh ? .connected(keyName: key?.name ?? "your key") : .off,
                                    adGuardEnabled: adGuard)
        if !ssh {
            state = .doneNoSsh
        } else {
            state = adGuard == .value(false) ? .doneNoAdg : .done
        }
    }

    private func finish() {
        let chosenName = name
        finishMessage = nil
        busy = true
        run { model in
            let saved = await model.services.finish(name: chosenName)
            model.busy = false
            guard saved else {
                model.finishMessage = "Routewell couldn’t save the router. Try again."
                return
            }
            model.finished = true
            model.onFinish?()
        }
    }
}

extension SSHKeyInspection {
    var isUsable: Bool { if case .usable = self { true } else { false } }

    /// Red text for a key Routewell cannot use.
    var problem: String? {
        switch self {
        case .usable: nil
        case .passphraseProtected: "This key is protected by a passphrase, which Routewell can’t use. Choose a key without a passphrase."
        case .publicKey: "This is a public key. Choose the private key, the file without .pub."
        case .notAKey: "This file isn’t a private key Routewell recognises. Choose another file."
        case .unreadable: "Routewell can’t read this file. Choose it again."
        }
    }
}
