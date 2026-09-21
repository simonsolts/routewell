import Darwin
import Foundation

/// Hostname/IP-literal validation shared with `RouterEndpoint` (chunk 08, task 1).
/// Kept here as a small private-to-the-package validator so the two can be merged
/// once both land: hostname labels are `[A-Za-z0-9-]`, no leading or trailing hyphen,
/// and a bracket-free literal must parse as IPv4 or IPv6 via `inet_pton`.
enum SSHHostValidation {
    static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253 else { return false }
        return isValidIPv4Literal(host) || isValidIPv6Literal(host) || isValidHostname(host)
    }

    static func isValidUser(_ user: String) -> Bool {
        guard user.unicodeScalars.count <= 32, let first = user.unicodeScalars.first else { return false }
        guard isASCIILowerLetter(first) || first == "_" else { return false }
        for scalar in user.unicodeScalars.dropFirst() {
            guard isASCIILowerLetter(scalar) || isASCIIDigit(scalar) || scalar == "_" || scalar == "-" else { return false }
        }
        return true
    }

    private static func isValidHostname(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }
        for label in labels {
            guard !label.isEmpty, label.count <= 63 else { return false }
            guard label.first != "-", label.last != "-" else { return false }
            for scalar in label.unicodeScalars {
                guard isASCIILowerLetter(scalar) || isASCIIUpperLetter(scalar) || isASCIIDigit(scalar) || scalar == "-" else { return false }
            }
        }
        return true
    }

    private static func isValidIPv4Literal(_ host: String) -> Bool {
        var address = in_addr()
        return host.withCString { inet_pton(AF_INET, $0, &address) } == 1
    }

    private static func isValidIPv6Literal(_ host: String) -> Bool {
        var address = in6_addr()
        return host.withCString { inet_pton(AF_INET6, $0, &address) } == 1
    }

    private static func isASCIILowerLetter(_ scalar: Unicode.Scalar) -> Bool { scalar.value >= 97 && scalar.value <= 122 }
    private static func isASCIIUpperLetter(_ scalar: Unicode.Scalar) -> Bool { scalar.value >= 65 && scalar.value <= 90 }
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
