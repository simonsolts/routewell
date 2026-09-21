import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    public var showInMenuBar = true
    public var refreshIntervalSeconds = 30
    public var pauseWhenHidden = true
    public var showStatusBar = true
    public init() {}
}

/// Settings for an optional AdGuard Home instance reachable through the same
/// router profile. Every field defaults so version-1 and version-2 profile
/// files (saved before this struct existed) still decode.
public struct AdGuardSettings: Codable, Equatable, Sendable {
    public var port: Int = 3000
    public var useRouterCredentials: Bool = true
    public var useHTTPS: Bool = false
    public var username: String = ""

    public init(port: Int = 3000, useRouterCredentials: Bool = true, useHTTPS: Bool = false, username: String = "") {
        self.port = port
        self.useRouterCredentials = useRouterCredentials
        self.useHTTPS = useHTTPS
        self.username = username
    }
}

/// SSH access for a live router profile. Key-only: there is no password field.
public struct SSHSettings: Codable, Equatable, Sendable {
    public var enabled: Bool = false
    public var port: Int = 22
    public var user: String = "root"
    public var keyFilePath: String?

    public init(enabled: Bool = false, port: Int = 22, user: String = "root", keyFilePath: String? = nil) {
        self.enabled = enabled
        self.port = port
        self.user = user
        self.keyFilePath = keyFilePath
    }
}

public struct RouterProfile: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public let endpoint: String
    public let credential: CredentialReference
    /// nil for mock profiles. Set for live profiles created from `SetupScreen`.
    public var liveEndpoint: RouterEndpoint?
    public var username: String = "root"
    public var plainHTTPAcknowledged: Bool = false
    public var adGuard: AdGuardSettings?
    public var ssh: SSHSettings?

    private enum CodingKeys: String, CodingKey {
        case id, name, endpoint, credential, liveEndpoint, username, plainHTTPAcknowledged, adGuard, ssh
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        endpoint = try values.decode(String.self, forKey: .endpoint)
        credential = try values.decode(CredentialReference.self, forKey: .credential)
        liveEndpoint = try values.decodeIfPresent(RouterEndpoint.self, forKey: .liveEndpoint)
        username = try values.decodeIfPresent(String.self, forKey: .username) ?? "root"
        plainHTTPAcknowledged = try values.decodeIfPresent(Bool.self, forKey: .plainHTTPAcknowledged) ?? false
        adGuard = try values.decodeIfPresent(AdGuardSettings.self, forKey: .adGuard)
        ssh = try values.decodeIfPresent(SSHSettings.self, forKey: .ssh)
        guard credential.profileID == id, credential.endpoint == endpoint else {
            throw DecodingError.dataCorruptedError(forKey: .credential, in: values, debugDescription: "Credential reference does not match profile")
        }
    }

    /// Mock profiles: `endpoint` is a `mock://` marker, there is no live address.
    public init(id: UUID = UUID(), name: String, endpoint: String) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        credential = CredentialReference(profileID: id, endpoint: endpoint)
    }

    /// Live profiles: `endpoint` is derived from `liveEndpoint.displayString`
    /// and the credential is a `routerPassword` reference.
    public init(
        id: UUID = UUID(),
        name: String,
        liveEndpoint: RouterEndpoint,
        username: String = "root",
        plainHTTPAcknowledged: Bool = false,
        adGuard: AdGuardSettings? = nil,
        ssh: SSHSettings? = nil
    ) {
        self.id = id
        self.name = name
        endpoint = liveEndpoint.displayString
        self.liveEndpoint = liveEndpoint
        self.username = username
        self.plainHTTPAcknowledged = plainHTTPAcknowledged
        self.adGuard = adGuard
        self.ssh = ssh
        credential = CredentialReference(profileID: id, endpoint: endpoint, kind: .routerPassword)
    }
}

public struct ProfileSettings: Codable, Equatable, Sendable {
    public var profiles: [RouterProfile]
    public var selectedID: UUID?
    private enum CodingKeys: String, CodingKey { case profiles, selectedID }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        profiles = try values.decode([RouterProfile].self, forKey: .profiles)
        selectedID = try values.decodeIfPresent(UUID.self, forKey: .selectedID)
        guard Set(profiles.map(\.id)).count == profiles.count else {
            throw DecodingError.dataCorruptedError(forKey: .profiles, in: values, debugDescription: "Duplicate profile IDs")
        }
    }

    public init(profiles: [RouterProfile], selectedID: UUID? = nil) {
        self.profiles = profiles
        self.selectedID = selectedID ?? profiles.first?.id
    }
}
