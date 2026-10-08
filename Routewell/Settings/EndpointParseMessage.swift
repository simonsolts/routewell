import RoutewellKit

extension EndpointParseError {
    /// Plain-language text shown under the address field. Never echoes the
    /// typed text back — only the user's own settings fields do that.
    var message: String {
        switch self {
        case .empty, .missingHost: "Enter a router address."
        case .invalidScheme: "Use http:// or https://, or leave the scheme off."
        case .invalidHost: "This does not look like a valid hostname or IP address."
        case .invalidPort: "Port must be a number between 1 and 65535."
        case .userInfoNotAllowed: "Remove the username and password from the address."
        case .pathNotAllowed: "Remove the path from the address."
        case .queryNotAllowed: "Remove the query from the address."
        }
    }
}
