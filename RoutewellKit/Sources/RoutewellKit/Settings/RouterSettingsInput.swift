import Foundation

/// Checks for what the person types in Settings › Router (chunk 15B).
public enum RouterSettingsInput {
    public enum AddressProblem: Error, Sendable, Equatable {
        case invalid(EndpointParseError)
        /// Routewell signs in over HTTPS only, as onboarding does.
        case plainHTTP
    }

    /// Longest router name, in characters.
    public static let nameLimit = 64

    /// The trimmed name, or `nil` when nothing is left (the old name stays).
    public static func name(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(nameLimit))
    }

    public static func address(_ text: String) -> Result<RouterEndpoint, AddressProblem> {
        let endpoint: RouterEndpoint
        do {
            endpoint = try RouterEndpoint.parse(text)
        } catch {
            return .failure(.invalid(error))
        }
        guard endpoint.scheme == .https else { return .failure(.plainHTTP) }
        return .success(endpoint)
    }

    /// A TCP port from 1 to 65535, or `nil`.
    public static func port(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.allSatisfy(\.isASCII), let value = Int(trimmed), (1...65535).contains(value) else { return nil }
        return value
    }
}
