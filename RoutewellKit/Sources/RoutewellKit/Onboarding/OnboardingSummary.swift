import Foundation

/// The three rows on onboarding's Finish step, built only from what the
/// router and the SSH probe reported. Nothing is invented: a value the
/// router did not give shows as such.
public struct OnboardingSummary: Sendable, Equatable {
    public enum Tone: Sendable, Equatable { case connected, off, unknown }

    public struct Row: Sendable, Equatable {
        public var title: String
        public var detail: String
        public var state: String
        public var tone: Tone
    }

    public enum SSH: Sendable, Equatable {
        /// The probe signed in with this key file name.
        case connected(keyName: String)
        case off
    }

    public var router: Row
    public var ssh: Row
    public var adGuard: Row

    /// - Parameters:
    ///   - name: the name the person chose; empty means the default `router`.
    ///   - probe: from sign-in (`system.get_info`).
    ///   - adGuardEnabled: `adguardhome.get_config` `enabled`.
    public init(name: String, address: String, probe: RouterProbe?, ssh: SSH, adGuardEnabled: Observed<Bool>) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = probe?.model.flatMap { $0.isEmpty ? nil : $0 } ?? "Model unknown"
        router = Row(title: trimmed.isEmpty ? "router" : trimmed, detail: "\(model) · \(address)", state: "Connected", tone: .connected)
        switch ssh {
        case .connected(let keyName):
            self.ssh = Row(title: "SSH", detail: "Signed in with \(keyName)", state: "Connected", tone: .connected)
        case .off:
            self.ssh = Row(title: "SSH", detail: "Not set up. Turn it on any time in Settings › Router.", state: "Off", tone: .off)
        }
        switch adGuardEnabled {
        case .value(true):
            adGuard = Row(title: "AdGuard Home", detail: "Running on your router", state: "Active", tone: .connected)
        case .value(false):
            adGuard = Row(title: "AdGuard Home", detail: "Off on your router. Protection stats appear when it’s on.", state: "Off", tone: .off)
        case .unknown, .unavailable:
            adGuard = Row(title: "AdGuard Home", detail: "Routewell couldn’t read this from the router.", state: "Unknown", tone: .unknown)
        }
    }

    public var rows: [Row] { [router, ssh, adGuard] }
}
