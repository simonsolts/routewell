import SwiftUI

/// The five steps shown by the dots, each with the system tint the design uses.
enum OnboardingStep: Int, CaseIterable {
    case findRouter, name, signIn, ssh, finish

    var label: String {
        switch self {
        case .findRouter: "Find router"
        case .name: "Name"
        case .signIn: "Sign in"
        case .ssh: "SSH"
        case .finish: "Finish"
        }
    }

    var tint: Color {
        switch self {
        case .findRouter: .teal
        case .name: .indigo
        case .signIn: .orange
        case .ssh: .purple
        case .finish: .green
        }
    }
}

/// Every state of the Quiet design (`S` keys in `Routewell Onboarding.dc.html`).
/// The design's `prompt` state is a picture of macOS's own Local Network
/// dialog, which the system draws over `searching`, so it has no case here.
enum OnboardingState: String, CaseIterable {
    case welcome, searching, fallback, found, manual, denied
    case name
    case cert, password, signing, wrong, locked, unreach
    case sshOffer, sshKey, sshChosen, sshPass, hostkey, sshCheck, sshRejected, sshUnreach
    case done, doneNoSsh, doneNoAdg

    /// Which controls the content area shows (`kind` in the design).
    enum Kind { case intro, search, found, manual, denied, name, cert, password, offer, key, hostkey, check, done }

    var spec: OnboardingSpec { OnboardingSpec.table[self]! }
    var step: OnboardingStep { spec.step }
    var kind: Kind { spec.kind }
}

/// Copy, artwork, and buttons for one state, verbatim from the design.
struct OnboardingSpec {
    let step: OnboardingStep
    let motif: ArtMotif
    var badge: ArtBadge?
    let title: String
    let body: String
    let kind: OnboardingState.Kind
    let primary: String
    var primaryDisabled = false
    var secondary: String?
    /// Only "Skip SSH" uses the tertiary slot.
    var skipSSH = false

    static let table: [OnboardingState: OnboardingSpec] = {
        let looking = "Looking for your router…"
        let searching = "Searching the network your Mac is on."
        let signIn = "Sign in to your router"
        let samePassword = "Use the same password as the router’s admin panel."
        let chooseKey = "Choose your SSH key"
        let selectKey = "Select the private key file your router already accepts."
        let allSet = "You’re all set"
        let ready = "Routewell is connected and ready to show your router."
        return [
            .welcome: .init(step: .findRouter, motif: .network, title: "Welcome to Routewell",
                            body: "Let’s connect Routewell to your GL.iNet router. It takes about a minute.",
                            kind: .intro, primary: "Find My Router"),
            .searching: .init(step: .findRouter, motif: .search, title: looking, body: searching, kind: .search,
                              primary: "Continue", primaryDisabled: true),
            .fallback: .init(step: .findRouter, motif: .search, title: looking,
                             body: "Not found automatically. Trying the usual GL.iNet address.", kind: .search,
                             primary: "Continue", primaryDisabled: true),
            .found: .init(step: .findRouter, motif: .router, badge: .check, title: "Found your router",
                          body: "Routewell will connect to this router.", kind: .found, primary: "Continue"),
            .manual: .init(step: .findRouter, motif: .warn, title: "Couldn’t find your router",
                           body: "Enter its address. You’ll find it on the router’s label or in its admin panel.",
                           kind: .manual, primary: "Connect", secondary: "Search Again"),
            .denied: .init(step: .findRouter, motif: .network, badge: .warn, title: "Routewell needs Local Network access",
                           body: "Without it, macOS blocks every connection to your router. You can turn it on in System Settings.",
                           kind: .denied, primary: "Open System Settings", secondary: "Try Again"),
            .name: .init(step: .name, motif: .tag, title: "Name your router",
                         body: "The name appears in the sidebar and in notifications.", kind: .name,
                         primary: "Continue", secondary: "Back"),
            .cert: .init(step: .signIn, motif: .cert, title: "Is this your router?",
                         body: "Your router uses its own security certificate. Trust it once, and Routewell will warn you if it ever changes.",
                         kind: .cert, primary: "Trust Certificate", secondary: "Back"),
            .password: .init(step: .signIn, motif: .lock, title: signIn, body: samePassword, kind: .password,
                             primary: "Sign In", secondary: "Back"),
            .signing: .init(step: .signIn, motif: .lock, title: signIn, body: samePassword, kind: .password,
                            primary: "Sign In", primaryDisabled: true, secondary: "Back"),
            .wrong: .init(step: .signIn, motif: .lock, badge: .error, title: signIn, body: samePassword, kind: .password,
                          primary: "Sign In", secondary: "Back"),
            .locked: .init(step: .signIn, motif: .lock, badge: .warn, title: "Sign-in paused",
                           body: "The router has paused sign-in after too many incorrect passwords.", kind: .password,
                           primary: "Sign In", primaryDisabled: true, secondary: "Back"),
            .unreach: .init(step: .signIn, motif: .warn, title: "Can’t reach your router",
                            body: "Check that this Mac is on the router’s network, then try again.", kind: .password,
                            primary: "Try Again", secondary: "Change Address…"),
            .sshOffer: .init(step: .ssh, motif: .terminal, title: "Do more with SSH",
                             body: "SSH lets Routewell work directly with your router for things its web interface doesn’t offer.",
                             kind: .offer, primary: "Set Up SSH", secondary: "Not Now"),
            .sshKey: .init(step: .ssh, motif: .key, title: chooseKey, body: selectKey, kind: .key,
                           primary: "Continue", primaryDisabled: true, secondary: "Back", skipSSH: true),
            .sshChosen: .init(step: .ssh, motif: .key, badge: .check, title: chooseKey, body: selectKey, kind: .key,
                              primary: "Continue", secondary: "Back", skipSSH: true),
            .sshPass: .init(step: .ssh, motif: .key, badge: .error, title: chooseKey, body: selectKey, kind: .key,
                            primary: "Continue", primaryDisabled: true, secondary: "Back", skipSSH: true),
            .hostkey: .init(step: .ssh, motif: .fingerprint, title: "Check the router’s SSH fingerprint",
                            body: "This identifies your router over SSH. It’s separate from the certificate you trusted earlier.",
                            kind: .hostkey, primary: "Trust and Continue", secondary: "Back", skipSSH: true),
            .sshCheck: .init(step: .ssh, motif: .terminal, title: "Checking SSH…",
                             body: "Making sure Routewell can sign in with your key.", kind: .check,
                             primary: "Continue", primaryDisabled: true, skipSSH: true),
            .sshRejected: .init(step: .ssh, motif: .terminal, badge: .error, title: "The router didn’t accept this key",
                                body: "Make sure its public key is added to the router, then try again.", kind: .check,
                                primary: "Try Again", secondary: "Choose Another Key…", skipSSH: true),
            .sshUnreach: .init(step: .ssh, motif: .terminal, badge: .warn, title: "SSH isn’t responding",
                               body: "Check that SSH is turned on in the router’s admin panel. It usually uses port 22.",
                               kind: .check, primary: "Try Again", skipSSH: true),
            .done: .init(step: .finish, motif: .done, title: allSet, body: ready, kind: .done, primary: "Open Routewell"),
            .doneNoSsh: .init(step: .finish, motif: .done, title: allSet, body: ready, kind: .done, primary: "Open Routewell"),
            .doneNoAdg: .init(step: .finish, motif: .done, title: allSet, body: ready, kind: .done, primary: "Open Routewell"),
        ]
    }()
}

/// The state of one row in the search and SSH check lists.
enum OnboardingRowState: Equatable { case spin, ok, fail, wait }

extension OnboardingState {
    /// Row states in the order the design lists them.
    var rows: [OnboardingRowState] {
        switch self {
        case .searching: [.spin, .wait]
        case .fallback: [.fail, .spin]
        case .sshCheck: [.ok, .spin]
        case .sshRejected: [.ok, .fail]
        case .sshUnreach: [.fail, .wait]
        default: []
        }
    }

    /// Where the secondary "Back" goes when it does not depend on the run.
    var back: OnboardingState? {
        switch self {
        case .cert: .name
        case .password, .signing, .wrong, .locked: .cert
        case .sshKey, .sshChosen, .sshPass: .sshOffer
        case .hostkey: .sshChosen
        default: nil
        }
    }

    var isFinish: Bool { kind == .done }
}
