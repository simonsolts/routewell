import Foundation
import Observation
import RoutewellKit

/// What the header card shows under the router's name.
struct RouterFacts: Equatable {
    var model: String?
    var firmware: String?
    var reachability: Reachability = .unknown
    var uptimeSeconds: Int?
}

/// The three confirmations on the Router tab.
enum RouterSettingsAlert: Identifiable, Equatable {
    case startSetupAgain, forgetCertificate, forgetHostKey

    var id: Self { self }

    var title: String {
        switch self {
        case .startSetupAgain: "Start setup again?"
        case .forgetCertificate: "Forget the trusted certificate?"
        case .forgetHostKey: "Forget the SSH host key?"
        }
    }

    func message(name: String) -> String {
        switch self {
        case .startSetupAgain:
            "This removes “\(name)” and all of its settings from this Mac: password, trusted certificate, SSH key and host key, and AdGuard config. Nothing on the router changes."
        case .forgetCertificate:
            "Routewell will stop connecting until you confirm the router’s certificate again. You’ll be asked the next time it connects."
        case .forgetHostKey:
            "SSH features stop until you confirm the router’s SSH fingerprint again. You’ll be asked the next time Routewell connects over SSH."
        }
    }

    var action: String {
        switch self {
        case .startSetupAgain: "Remove and Start Setup"
        case .forgetCertificate: "Forget Certificate"
        case .forgetHostKey: "Forget Host Key"
        }
    }
}

/// Everything the Router tab reads and changes outside its own state. Live
/// and DEBUG mock implementations, as for onboarding.
@MainActor
protocol RouterSettingsServices: AnyObject {
    var name: String { get }
    /// "192.168.8.1", or "host:port" when the port is not 443.
    var address: String { get }
    /// The bare host, for the SSH steps.
    var host: String { get }
    var username: String { get }
    var facts: RouterFacts { get }
    var ssh: SSHSettings { get }
    var adGuard: AdGuardSettings? { get }
    /// The pinned certificate for this address, or `nil`. Local only.
    func certificate() async -> CertificateFingerprint?
    /// The trusted SSH host key's SHA256 fingerprint, or `nil`. Local only.
    func hostKey() async -> String?
    /// `adguardhome get_config` `enabled`: one router read.
    func adGuardHomeEnabled() async -> Observed<Bool>
    func rename(_ name: String)
    func setAddress(_ endpoint: RouterEndpoint) async -> Bool
    func changePassword(_ password: Data) async -> Bool
    func forgetCertificate() async
    func forgetHostKey() async
    /// Onboarding's SSH steps, for the sheet.
    func sshSteps() -> any OnboardingServices
    func sshStepsEnded(connected: Bool)
    func turnSSHOff()
    func chooseKeyFile() -> ChosenSSHKey?
    /// The saved key, inspected again, for the sheet after a port change.
    func savedKey() -> ChosenSSHKey?
    func useKey(_ key: ChosenSSHKey)
    /// Saves the port with SSH off: the host key belongs to one port.
    func setSSHPortOff(_ port: Int)
    func updateAdGuard(_ settings: AdGuardSettings)
    func saveAdGuardPassword(_ password: Data) async -> Bool
    func connectionTest(trustPrompt: TrustPromptController, onProbe: @escaping @MainActor (RouterProbe) -> Void) -> ConnectionTest?
    func startSetupAgain() async
}

/// Settings › Router: the drafts, alerts, Test Connection, and
/// the SSH sheet, without the views. The views bind to it; tests drive it.
@MainActor @Observable
final class RouterSettingsModel {
    let services: any RouterSettingsServices
    let app: AppModel
    /// The Settings window's own certificate prompt, so Test Connection asks there.
    let trustPrompt = TrustPromptController()

    var nameDraft = ""
    var addressDraft = ""
    private(set) var addressMessage: String?
    private(set) var editingPassword = false
    var newPassword = ""
    private(set) var passwordMessage: String?
    var portDraft = ""
    private(set) var sshMessage: String?
    var adGuardExpanded = false
    var adGuardUsernameDraft = ""
    var adGuardPasswordDraft = ""
    var adGuardPortDraft = ""
    private(set) var adGuardMessage: String?

    /// False until the first `reloadLocal()`, so the header does not flash
    /// "Waiting for you to confirm the certificate".
    private(set) var loaded = false
    private(set) var certificate: CertificateFingerprint?
    private(set) var hostKey: String?
    private(set) var adGuardOnRouter: Observed<Bool> = .unknown
    /// From the last Test Connection: what the router reported.
    private(set) var probe: RouterProbe?
    private(set) var test: ConnectionTestReport?
    private(set) var testing = false
    var alert: RouterSettingsAlert?
    /// The SSH steps in a sheet, while Use SSH is being switched on.
    private(set) var sshSheet: OnboardingModel?
    @ObservationIgnored private var testTask: Task<Void, Never>?

    init(services: any RouterSettingsServices, app: AppModel) {
        self.services = services
        self.app = app
        resetDrafts()
    }

    func resetDrafts() {
        nameDraft = services.name
        addressDraft = services.address
        portDraft = String(services.ssh.port)
        let adGuard = services.adGuard ?? AdGuardSettings()
        adGuardUsernameDraft = adGuard.username
        adGuardPortDraft = String(adGuard.port)
    }

    /// On appear: the local trust state, then AdGuard Home's state on the router.
    func load() async {
        await reloadLocal()
        adGuardOnRouter = await services.adGuardHomeEnabled()
    }

    /// The pinned certificate and host key. Nothing goes to the router.
    func reloadLocal() async {
        certificate = await services.certificate()
        hostKey = await services.hostKey()
        loaded = true
    }

    // MARK: Header

    enum Status: Equatable {
        case connected(uptime: String?)
        case notReachable
        case waitingForCertificate
        case checking

        var text: String {
            switch self {
            case .connected(let uptime?): "Connected · \(uptime) up"
            case .connected(nil): "Connected"
            case .notReachable: "Not reachable"
            case .waitingForCertificate: "Waiting for you to confirm the certificate"
            case .checking: "Checking…"
            }
        }
    }

    var status: Status {
        guard loaded else { return .checking }
        if certificate == nil { return .waitingForCertificate }
        if case .failed? = test?.router { return .notReachable }
        let facts = services.facts
        switch facts.reachability {
        case .connected: return .connected(uptime: facts.uptimeSeconds.map(Self.uptime))
        case .unreachable: return .notReachable
        case .unknown: return .checking
        }
    }

    /// "model · Firmware x.y.z · address". A part the router has not
    /// reported says so.
    var subtitle: String {
        let facts = services.facts
        let model = probe?.model ?? facts.model ?? "Unknown model"
        let firmware = probe?.firmware ?? facts.firmware
        return [model, firmware.map { "Firmware \($0)" } ?? "Firmware unknown", services.address].joined(separator: " · ")
    }

    /// "0d 22h".
    static func uptime(_ seconds: Int) -> String {
        let hours = max(0, seconds) / 3600
        return "\(hours / 24)d \(hours % 24)h"
    }

    // MARK: Test Connection

    func runTest() {
        guard !testing, let connectionTest = services.connectionTest(trustPrompt: trustPrompt, onProbe: { [weak self] in self?.probe = $0 }) else { return }
        testing = true
        test = ConnectionTestReport()
        testTask = Task { [weak self] in
            let report = await connectionTest.run { report in
                await MainActor.run { self?.test = report }
            }
            guard let self else { return }
            test = report
            testing = false
            switch report.adGuard {
            case .working?: adGuardOnRouter = .value(true)
            case .offOnRouter?: adGuardOnRouter = .value(false)
            default: break
            }
            await reloadLocal()
        }
    }

    /// One result row under the header card. `value` is `nil` while testing.
    struct TestRow: Equatable {
        let label: String
        let value: String?
        let tone: StatusTone
        let failed: Bool
    }

    var testRows: [TestRow] {
        guard let test else { return [] }
        return [Self.row(test.router), Self.row(test.ssh), Self.row(test.adGuard)]
    }

    private static func row(_ check: RouterCheck?) -> TestRow {
        switch check {
        case nil: TestRow(label: "Router (HTTPS)", value: nil, tone: .inProgress, failed: false)
        case .responded(let milliseconds)?: TestRow(label: "Router (HTTPS)", value: "\(milliseconds) ms", tone: .healthy, failed: false)
        case .failed(let failure)?: TestRow(label: "Router (HTTPS)", value: failure.text, tone: .error, failed: true)
        }
    }

    private static func row(_ check: SSHCheck?) -> TestRow {
        switch check {
        case nil: TestRow(label: "SSH", value: nil, tone: .inProgress, failed: false)
        case .working?: TestRow(label: "SSH", value: "Working", tone: .healthy, failed: false)
        case .off?: TestRow(label: "SSH", value: "Off", tone: .unknown, failed: false)
        case .notTested?: TestRow(label: "SSH", value: "Not tested", tone: .unknown, failed: false)
        case .failed(let failure)?: TestRow(label: "SSH", value: failure?.message ?? "Not working", tone: .error, failed: true)
        }
    }

    private static func row(_ check: AdGuardCheck?) -> TestRow {
        switch check {
        case nil: TestRow(label: "AdGuard Home", value: nil, tone: .inProgress, failed: false)
        case .working?: TestRow(label: "AdGuard Home", value: "Working", tone: .healthy, failed: false)
        case .offOnRouter?: TestRow(label: "AdGuard Home", value: "Off on router", tone: .unknown, failed: false)
        case .notSetUp?: TestRow(label: "AdGuard Home", value: "Not set up", tone: .unknown, failed: false)
        case .notTested?: TestRow(label: "AdGuard Home", value: "Not tested", tone: .unknown, failed: false)
        case .failed(let failure)?: TestRow(label: "AdGuard Home", value: failure.text, tone: .error, failed: true)
        }
    }

    /// Waits for the running test. For tests.
    func settleTest() async { await testTask?.value }

    func cancelTest() {
        testTask?.cancel()
        trustPrompt.resolve(false)
    }

    // MARK: Router group

    /// Return or focus loss. An empty name puts the old one back.
    func commitName() {
        guard let name = RouterSettingsInput.name(nameDraft) else {
            nameDraft = services.name
            return
        }
        nameDraft = name
        if name != services.name { services.rename(name) }
    }

    func commitAddress() async {
        switch RouterSettingsInput.address(addressDraft) {
        case .failure(.plainHTTP):
            addressMessage = "Routewell connects over HTTPS. Remove http:// from the address."
        case .failure(.invalid(let error)):
            addressMessage = error.message
        case .success(let endpoint):
            addressMessage = nil
            guard OnboardingModel.shortAddress(endpoint) != services.address else {
                addressDraft = services.address
                return
            }
            if await services.setAddress(endpoint) {
                addressDraft = services.address
                test = nil
                probe = nil
                await reloadLocal()
            } else {
                addressMessage = "Routewell couldn’t save the new address. Try again."
            }
        }
    }

    func beginPasswordChange() {
        newPassword = ""
        passwordMessage = nil
        editingPassword = true
    }

    func cancelPasswordChange() {
        newPassword = ""
        passwordMessage = nil
        editingPassword = false
    }

    func savePassword() async {
        guard !newPassword.isEmpty else { return }
        let secret = Data(newPassword.utf8)
        newPassword = ""
        if await services.changePassword(secret) {
            passwordMessage = nil
            editingPassword = false
        } else {
            passwordMessage = "Routewell couldn’t save the password. Try again."
        }
    }

    // MARK: Alerts

    func confirm(_ alert: RouterSettingsAlert) async {
        self.alert = nil
        switch alert {
        case .forgetCertificate:
            await services.forgetCertificate()
            await reloadLocal()
        case .forgetHostKey:
            await services.forgetHostKey()
            await reloadLocal()
        case .startSetupAgain:
            cancelTest()
            await services.startSetupAgain()
        }
    }

    // MARK: SSH group

    var sshOn: Bool { services.ssh.enabled }

    /// On opens onboarding's SSH steps in a sheet; SSH turns on only when
    /// they finish. Off saves straight away.
    func setSSH(_ on: Bool) {
        sshMessage = nil
        if on {
            openSSHSheet(key: nil)
        } else {
            services.turnSSHOff()
        }
    }

    private func openSSHSheet(key: ChosenSSHKey?) {
        sshSheet?.abandon()
        sshSheet = OnboardingModel(sshStepsWith: services.sshSteps(), host: services.host, key: key) { [weak self] connected in
            guard let self else { return }
            sshSheet = nil
            services.sshStepsEnded(connected: connected)
            portDraft = String(services.ssh.port)
            Task { await self.reloadLocal() }
        }
    }

    /// The sheet closed before the steps ended: undo what they changed.
    func sshSheetClosed() {
        guard let sheet = sshSheet else { return }
        sshSheet = nil
        sheet.abandon()
        services.sshStepsEnded(connected: false)
        Task { [weak self] in
            await sheet.settle()
            await self?.reloadLocal()
        }
    }

    /// Choose…: Routewell checks the key before it saves it.
    func chooseKeyFile() {
        guard let key = services.chooseKeyFile() else { return }
        if let problem = key.inspection.problem {
            sshMessage = problem
            return
        }
        sshMessage = nil
        services.useKey(key)
    }

    /// The host key belongs to one port, so a new port asks for the router's
    /// host key on it again, with the same key file.
    func commitPort() {
        guard let port = RouterSettingsInput.port(portDraft) else {
            sshMessage = "Port must be a number between 1 and 65535."
            return
        }
        sshMessage = nil
        portDraft = String(port)
        guard port != services.ssh.port else { return }
        let key = services.savedKey()
        services.setSSHPortOff(port)
        openSSHSheet(key: key)
    }

    enum SSHStatus: Equatable {
        case working, checking, notConnected
        case failed(String)

        var text: String {
            switch self {
            case .working: "Working"
            case .checking: "Checking…"
            case .notConnected: "Not connected"
            case .failed(let message): message
            }
        }
    }

    var sshStatus: SSHStatus {
        guard app.sshConfigured else { return .notConnected }
        guard let probe = app.sshProbe else { return .checking }
        if probe.capability.state == .supported { return .working }
        return .failed(probe.failure?.message ?? "Not working")
    }

    // MARK: AdGuard config

    var adGuard: AdGuardSettings { services.adGuard ?? AdGuardSettings() }

    func setAdGuardSeparateAccount(_ separate: Bool) {
        var settings = adGuard
        guard settings.useRouterCredentials == separate else { return }
        settings.useRouterCredentials = !separate
        services.updateAdGuard(settings)
    }

    func commitAdGuardUsername() {
        var settings = adGuard
        let username = adGuardUsernameDraft.trimmingCharacters(in: .whitespaces)
        guard username != settings.username else { return }
        settings.username = username
        services.updateAdGuard(settings)
    }

    func saveAdGuardPassword() async {
        guard !adGuardPasswordDraft.isEmpty else { return }
        let secret = Data(adGuardPasswordDraft.utf8)
        adGuardPasswordDraft = ""
        adGuardMessage = await services.saveAdGuardPassword(secret)
            ? "Saved in your Keychain."
            : "Routewell couldn’t save the password. Try again."
    }

    func commitAdGuardPort() {
        guard let port = RouterSettingsInput.port(adGuardPortDraft) else {
            adGuardMessage = "Port must be a number between 1 and 65535."
            return
        }
        adGuardMessage = nil
        adGuardPortDraft = String(port)
        var settings = adGuard
        guard port != settings.port else { return }
        settings.port = port
        services.updateAdGuard(settings)
    }

    func setAdGuardHTTPS(_ on: Bool) {
        var settings = adGuard
        guard settings.useHTTPS != on else { return }
        settings.useHTTPS = on
        services.updateAdGuard(settings)
    }

    var adGuardOff: Bool { adGuardOnRouter == .value(false) }

    enum AdGuardState: Equatable {
        case active, offOnRouter, unknown

        var text: String {
            switch self {
            case .active: "AdGuard Home active"
            case .offOnRouter: "AdGuard Home off on router"
            case .unknown: "AdGuard Home state unknown"
            }
        }
    }

    var adGuardStatus: AdGuardState {
        switch adGuardOnRouter {
        case .value(true): .active
        case .value(false): .offOnRouter
        case .unavailable, .unknown: .unknown
        }
    }
}

extension OnboardingModel: Identifiable {}

extension ConnectionCheckFailure {
    var text: String {
        switch self {
        case .noResponse: "No response"
        case .signInRefused: "Sign-in refused"
        case .signInPaused: "Sign-in paused"
        case .certificateNotTrusted: "Certificate not trusted"
        case .unexpectedReply: "Unexpected reply"
        }
    }
}
