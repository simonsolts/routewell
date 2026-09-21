import Darwin
import Foundation

/// Hostname/IP-literal validation shared with `RouterEndpoint` (chunk 08, task 1).
/// Delegates to `RouterEndpoint.isValidHostLiteralOrName` so SSH targets accept
/// exactly the same hosts as HTTP endpoints, including rejecting all-numeric
/// non-IP hosts like "999.999.999.999".
enum SSHHostValidation {
    static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253 else { return false }
        return RouterEndpoint.isValidHostLiteralOrName(host)
    }

    static func isValidUser(_ user: String) -> Bool {
        guard user.unicodeScalars.count <= 32, let first = user.unicodeScalars.first else { return false }
        guard isASCIILowerLetter(first) || first == "_" else { return false }
        for scalar in user.unicodeScalars.dropFirst() {
            guard isASCIILowerLetter(scalar) || isASCIIDigit(scalar) || scalar == "_" || scalar == "-" else { return false }
        }
        return true
    }

    private static func isASCIILowerLetter(_ scalar: Unicode.Scalar) -> Bool { scalar.value >= 97 && scalar.value <= 122 }
    private static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool { scalar.value >= 48 && scalar.value <= 57 }
}

public enum SSHTargetError: Error, Equatable, Sendable {
    case invalidHost, invalidPort, invalidUser
}

public struct SSHTarget: Sendable, Hashable, Codable {
    public let host: String
    public let port: Int
    public let user: String

    public init(host: String, port: Int, user: String) throws {
        guard SSHHostValidation.isValidHost(host) else { throw SSHTargetError.invalidHost }
        guard (1...65535).contains(port) else { throw SSHTargetError.invalidPort }
        guard SSHHostValidation.isValidUser(user) else { throw SSHTargetError.invalidUser }
        self.host = host
        self.port = port
        self.user = user
    }
}

/// Key-only. Routewell never asks for or stores an SSH password.
public enum SSHIdentity: Sendable, Hashable, Codable {
    case keyFile(URL)
    case agent
}

public struct SSHLaunchPlan: Sendable, Equatable {
    public let executable: URL
    public let arguments: [String]
}

public enum SSHLaunchError: Error, Equatable, Sendable {
    case agentSocketRequired
}

public enum SSHLauncher {
    /// Builds the argv for `/usr/bin/ssh`. `knownHostsFile` is a Routewell-owned file;
    /// host key checking is always strict (`StrictHostKeyChecking=yes` is never
    /// weakened to "no"). `agentSocket` is required, and only used, with `.agent`.
    public static func plan(
        target: SSHTarget,
        identity: SSHIdentity,
        knownHostsFile: URL,
        command: SSHCommand,
        connectTimeout: Duration = .seconds(10),
        agentSocket: URL? = nil
    ) throws(SSHLaunchError) -> SSHLaunchPlan {
        var arguments: [String] = [
            "-F", "/dev/null",
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "UserKnownHostsFile=\(knownHostsFile.path)",
            "-o", "ConnectTimeout=\(connectTimeout.components.seconds)",
            "-o", "ClearAllForwardings=yes",
        ]
        switch identity {
        case .keyFile(let keyFile):
            arguments += ["-o", "IdentitiesOnly=yes"]
            arguments += ["-i", keyFile.path]
            arguments += ["-o", "IdentityAgent=none"]
        case .agent:
            guard let agentSocket else { throw SSHLaunchError.agentSocketRequired }
            arguments += ["-o", "IdentityAgent=\(agentSocket.path)"]
        }
        arguments += ["-T", "-a", "-x", "-p", "\(target.port)", "--", "\(target.user)@\(target.host)", command.rendered]
        return SSHLaunchPlan(executable: URL(fileURLWithPath: "/usr/bin/ssh"), arguments: arguments)
    }
}
