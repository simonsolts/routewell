import Foundation

/// Why one Test Connection check failed. Never holds the router's own text.
public enum ConnectionCheckFailure: Sendable, Equatable {
    case noResponse
    case signInRefused
    case signInPaused
    case certificateNotTrusted
    case unexpectedReply

    public init(_ error: GLiNetRPCError) {
        switch error {
        case .transport(.untrustedServer): self = .certificateNotTrusted
        case .transport(.responseTooLarge), .transport(.invalidResponse): self = .unexpectedReply
        case .transport: self = .noResponse
        case .accessDenied, .credentialUnavailable: self = .signInRefused
        case .loginPaused: self = .signInPaused
        case .httpStatus, .malformedResponse, .methodNotFound, .invalidParameters, .rpcError,
             .unsupportedAlgorithm, .unsupportedHashMethod: self = .unexpectedReply
        }
    }

    public init(_ error: AdGuardClientError) {
        switch error {
        case .transport(.untrustedServer): self = .certificateNotTrusted
        case .transport(.responseTooLarge), .transport(.invalidResponse): self = .unexpectedReply
        case .transport: self = .noResponse
        case .unauthorized, .credentialUnavailable: self = .signInRefused
        case .httpStatus, .malformedResponse: self = .unexpectedReply
        }
    }
}

/// Router (HTTPS): one signed-in round trip.
public enum RouterCheck: Sendable, Equatable {
    case responded(milliseconds: Int)
    case failed(ConnectionCheckFailure)

    /// Whole milliseconds, at least 1.
    public static func responded(after duration: Duration) -> RouterCheck {
        let (seconds, attoseconds) = duration.components
        let milliseconds = Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
        return .responded(milliseconds: max(1, milliseconds))
    }
}

/// SSH: the session's probe, only when SSH is on.
public enum SSHCheck: Sendable, Equatable {
    case working
    case off
    /// The router check failed, so this one did not run.
    case notTested
    case failed(SSHFailure?)
}

/// AdGuard Home: `adguardhome get_config`, then `control/status`.
public enum AdGuardCheck: Sendable, Equatable {
    case working
    case offOnRouter
    /// The profile has no AdGuard Home connection.
    case notSetUp
    /// The router check failed, so this one did not run.
    case notTested
    case failed(ConnectionCheckFailure)
}

/// The three result rows under the header card. `nil` means still testing.
public struct ConnectionTestReport: Sendable, Equatable {
    public var router: RouterCheck?
    public var ssh: SSHCheck?
    public var adGuard: AdGuardCheck?

    public init(router: RouterCheck? = nil, ssh: SSHCheck? = nil, adGuard: AdGuardCheck? = nil) {
        self.router = router
        self.ssh = ssh
        self.adGuard = adGuard
    }

    public var isComplete: Bool { router != nil && ssh != nil && adGuard != nil }
}

/// Settings › Router › Test Connection. The router check runs
/// first. When it fails, SSH and AdGuard Home are not tested, so nothing
/// else is sent. Otherwise both run at the same time.
public struct ConnectionTest: Sendable {
    public var router: @Sendable () async -> RouterCheck
    /// The profile has SSH switched on.
    public var sshEnabled: Bool
    public var ssh: @Sendable () async -> SSHProbeResult
    /// The profile has an AdGuard Home connection.
    public var adGuardConfigured: Bool
    /// `adguardhome get_config` `enabled`.
    public var adGuardEnabled: @Sendable () async -> Observed<Bool>
    /// `control/status`: `nil` when it answered.
    public var adGuardStatus: @Sendable () async -> ConnectionCheckFailure?

    public init(router: @escaping @Sendable () async -> RouterCheck,
                sshEnabled: Bool, ssh: @escaping @Sendable () async -> SSHProbeResult,
                adGuardConfigured: Bool, adGuardEnabled: @escaping @Sendable () async -> Observed<Bool>,
                adGuardStatus: @escaping @Sendable () async -> ConnectionCheckFailure?) {
        self.router = router
        self.sshEnabled = sshEnabled
        self.ssh = ssh
        self.adGuardConfigured = adGuardConfigured
        self.adGuardEnabled = adGuardEnabled
        self.adGuardStatus = adGuardStatus
    }

    /// Runs the checks. `progress` gets the report each time a row is known.
    public func run(progress: @escaping @Sendable (ConnectionTestReport) async -> Void = { _ in }) async -> ConnectionTestReport {
        var report = ConnectionTestReport()
        await progress(report)
        report.router = await router()
        guard case .responded = report.router else {
            report.ssh = sshEnabled ? .notTested : .off
            report.adGuard = adGuardConfigured ? .notTested : .notSetUp
            await progress(report)
            return report
        }
        if !sshEnabled { report.ssh = .off }
        if !adGuardConfigured { report.adGuard = .notSetUp }
        await progress(report)
        async let sshResult = sshEnabled ? checkSSH() : .off
        async let adGuardResult = adGuardConfigured ? checkAdGuard() : .notSetUp
        let finishedSSH = await sshResult
        report.ssh = finishedSSH
        await progress(report)
        report.adGuard = await adGuardResult
        await progress(report)
        return report
    }

    private func checkSSH() async -> SSHCheck {
        let probe = await ssh()
        return probe.capability.state == .supported ? .working : .failed(probe.failure)
    }

    private func checkAdGuard() async -> AdGuardCheck {
        if await adGuardEnabled() == .value(false) { return .offOnRouter }
        if let failure = await adGuardStatus() { return .failed(failure) }
        return .working
    }
}
