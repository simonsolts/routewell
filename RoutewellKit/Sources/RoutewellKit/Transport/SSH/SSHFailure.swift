import Foundation

/// Why one SSH operation did not produce command output. RouterPilot returns
/// sentinel strings for these (`GLiNetSshService.cs:69-105`); Routewell
/// maps each sentinel, and each `/usr/bin/ssh` failure, to one of these
/// cases, so a sentinel is never shown or parsed as output.
public enum SSHFailure: Error, Sendable, Equatable, Hashable {
    /// `SSH_AUTH_FAILED`: the router refused the key or the agent's keys.
    case authenticationFailed
    /// `SSH_CONNECTION_FAILED`: nothing answered on the SSH port.
    case connectionFailed
    /// `SSH_NETWORK_FAILED`: no route, name lookup failed, or the network is down.
    case networkFailed
    /// `SSH_CONFIGURATION_FAILED`: the local setup is incomplete or invalid
    /// (no key file, no agent, invalid user or port).
    case configurationFailed
    /// No host key is trusted for this router yet. Nothing was sent.
    case hostKeyNotTrusted
    /// The router presented a key other than the trusted one. The connection
    /// is always rejected, whatever the person answers.
    case hostKeyChanged
    /// The operation took longer than its deadline.
    case timedOut
    /// The remote command ran and exited with this status.
    case commandFailed(exitStatus: Int32)
    /// `SSH_ERROR:<type>`, or an `ssh` failure with no better match.
    case other(String)
}

public extension SSHFailure {
    /// The refresh category a screen shows for this failure.
    var category: RefreshFailureCategory {
        switch self {
        case .authenticationFailed, .hostKeyNotTrusted, .hostKeyChanged: .authentication
        case .connectionFailed, .networkFailed: .network
        case .timedOut: .timeout
        case .configurationFailed: .unavailable
        case .commandFailed, .other: .malformedResponse
        }
    }

    /// One plain sentence for Settings and the unavailable segments.
    var message: String {
        switch self {
        case .authenticationFailed: "The router refused the SSH key. Check the key file or the SSH agent, and the user name."
        case .connectionFailed: "Nothing answered on the SSH port. Check that SSH is on in the router and the port is correct."
        case .networkFailed: "The router could not be reached over the network."
        case .configurationFailed: "SSH setup is incomplete. Choose a key file or use the SSH agent."
        case .hostKeyNotTrusted: "The router's SSH host key is not trusted yet."
        case .hostKeyChanged: "The router's SSH host key changed. Routewell refused the connection."
        case .timedOut: "The SSH command did not finish in time."
        case .commandFailed(let status): "The router command failed with exit status \(status)."
        case .other: "SSH failed for an unknown reason."
        }
    }
}

/// Maps RouterPilot's sentinel strings to typed failures.
public enum SSHSentinel {
    public static let authFailed = "SSH_AUTH_FAILED"
    public static let connectionFailed = "SSH_CONNECTION_FAILED"
    public static let networkFailed = "SSH_NETWORK_FAILED"
    public static let configurationFailed = "SSH_CONFIGURATION_FAILED"
    public static let errorPrefix = "SSH_ERROR:"

    /// The failure a sentinel line stands for, or `nil` when `text` is not a
    /// sentinel. Only a whole trimmed line counts, so a log message that
    /// mentions a sentinel name in passing is still output.
    public static func failure(in text: String) -> SSHFailure? {
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            switch line {
            case authFailed: return .authenticationFailed
            case connectionFailed: return .connectionFailed
            case networkFailed: return .networkFailed
            case configurationFailed: return .configurationFailed
            default:
                if line.hasPrefix(errorPrefix) {
                    let type = line.dropFirst(errorPrefix.count).trimmingCharacters(in: .whitespaces)
                    return .other(type.isEmpty ? "unknown" : String(type.prefix(64)))
                }
            }
        }
        return nil
    }
}

/// Turns one finished `/usr/bin/ssh` run into command output or a failure.
public enum SSHResultClassifier {
    /// `ssh` exits 255 for its own errors; any other status is the remote
    /// command's. A sentinel line in stdout always fails, never passes
    /// through as output.
    public static func check(_ result: ProcessResult) throws(SSHFailure) -> ProcessResult {
        let stdout = String(decoding: result.stdout, as: UTF8.self)
        if let failure = SSHSentinel.failure(in: stdout) { throw failure }
        let stderr = clientWarningsRemoved(String(decoding: result.stderr, as: UTF8.self))
        if result.exitStatus == 255 { throw classify(stderr: stderr) }
        return ProcessResult(exitStatus: result.exitStatus, stdout: result.stdout, stderr: Data(stderr.utf8),
                             stdoutTruncated: result.stdoutTruncated, stderrTruncated: result.stderrTruncated)
    }

    /// OpenSSH 10 prints a `** WARNING: connection is not using a
    /// post-quantum key exchange algorithm.` block on every connection to
    /// the router's Dropbear. Its `** ` lines are the ssh
    /// client's, not the remote command's, so they never reach a parser.
    public static func clientWarningsRemoved(_ stderr: String) -> String {
        stderr.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("** ") }
            .joined(separator: "\n")
    }

    /// OpenSSH client messages, matched without case.
    public static func classify(stderr: String) -> SSHFailure {
        if let failure = SSHSentinel.failure(in: stderr) { return failure }
        let text = stderr.lowercased()
        if text.contains("host key verification failed") || text.contains("remote host identification has changed") {
            return .hostKeyChanged
        }
        if text.contains("permission denied") || text.contains("too many authentication failures") || text.contains("no more authentication methods") {
            return .authenticationFailed
        }
        if text.contains("connection refused") || text.contains("connection closed") || text.contains("connection reset") {
            return .connectionFailed
        }
        if text.contains("timed out") { return .timedOut }
        if text.contains("could not resolve hostname") || text.contains("no route to host") || text.contains("network is unreachable")
            || text.contains("host is down") {
            return .networkFailed
        }
        if text.contains("no such identity") || text.contains("bad configuration option") || text.contains("could not open")
            || text.contains("bad permissions") || text.contains("load key") {
            return .configurationFailed
        }
        return .other("ssh")
    }
}
