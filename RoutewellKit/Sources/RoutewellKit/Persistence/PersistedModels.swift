import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    public var showInMenuBar = true
    public var refreshIntervalSeconds = 30
    public var pauseWhenHidden = true
    public var showStatusBar = true
    /// Clients details pane: shown or hidden, its height in
    /// points, and the selected section in its source list.
    public var clientsDetailsVisible = true
    public var clientsDetailsHeight = 300.0
    public var clientsDetailsSection = "overview"
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case showInMenuBar, refreshIntervalSeconds, pauseWhenHidden, showStatusBar
        case clientsDetailsVisible, clientsDetailsHeight, clientsDetailsSection
    }

    /// Every key is optional, so a file written before a setting existed
    /// still loads with that setting's default instead of being treated as
    /// damaged.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        showInMenuBar = try values.decodeIfPresent(Bool.self, forKey: .showInMenuBar) ?? true
        refreshIntervalSeconds = try values.decodeIfPresent(Int.self, forKey: .refreshIntervalSeconds) ?? 30
        pauseWhenHidden = try values.decodeIfPresent(Bool.self, forKey: .pauseWhenHidden) ?? true
        showStatusBar = try values.decodeIfPresent(Bool.self, forKey: .showStatusBar) ?? true
        clientsDetailsVisible = try values.decodeIfPresent(Bool.self, forKey: .clientsDetailsVisible) ?? true
        clientsDetailsHeight = try values.decodeIfPresent(Double.self, forKey: .clientsDetailsHeight) ?? 300
        clientsDetailsSection = try values.decodeIfPresent(String.self, forKey: .clientsDetailsSection) ?? "overview"
    }
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

/// SSH access for a live router profile. Key-only: there is no password
/// field. `enabled` is true only after the host key was trusted.
public struct SSHSettings: Codable, Equatable, Sendable {
    public var enabled: Bool = false
    public var port: Int = 22
    public var user: String = "root"
    public var keyFilePath: String?
    /// A security-scoped bookmark to `keyFilePath`, so a sandboxed app can
    /// read the key again after a relaunch. `nil` for keys chosen before it existed.
    public var keyFileBookmark: Data?
    /// Use the SSH agent from `SSH_AUTH_SOCK` instead of a key file.
    public var useAgent: Bool = false

    public init(enabled: Bool = false, port: Int = 22, user: String = "root", keyFilePath: String? = nil,
                keyFileBookmark: Data? = nil, useAgent: Bool = false) {
        self.enabled = enabled
        self.port = port
        self.user = user
        self.keyFilePath = keyFilePath
        self.keyFileBookmark = keyFileBookmark
        self.useAgent = useAgent
    }

    private enum CodingKeys: String, CodingKey { case enabled, port, user, keyFilePath, keyFileBookmark, useAgent }

    /// Every key is optional, so a profile saved before a field existed
    /// still loads with that field's default.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        port = try values.decodeIfPresent(Int.self, forKey: .port) ?? 22
        user = try values.decodeIfPresent(String.self, forKey: .user) ?? "root"
        keyFilePath = try values.decodeIfPresent(String.self, forKey: .keyFilePath)
        keyFileBookmark = try values.decodeIfPresent(Data.self, forKey: .keyFileBookmark)
        useAgent = try values.decodeIfPresent(Bool.self, forKey: .useAgent) ?? false
    }

    /// The identity these settings name, or `nil` when neither a key file
    /// nor the agent is chosen.
    public var identity: SSHIdentity? {
        if useAgent { return .agent }
        guard let keyFilePath, keyFilePath.hasPrefix("/") else { return nil }
        return .keyFile(URL(fileURLWithPath: keyFilePath))
    }
}

public struct RouterProfile: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public let endpoint: String
    public let credential: CredentialReference
    /// nil for mock profiles. Set for live profiles created by onboarding.
    public var liveEndpoint: RouterEndpoint?
    public var username: String = "root"
    public var plainHTTPAcknowledged: Bool = false
    public var adGuard: AdGuardSettings?
    public var ssh: SSHSettings?
    /// False from sign-in until onboarding's Finish. A profile left false
    /// (onboarding closed or the app quit) is removed at the next launch,
    /// so onboarding always starts empty. Older profiles without the field
    /// read as complete.
    public var setupComplete: Bool = true

    private enum CodingKeys: String, CodingKey {
        case id, name, endpoint, credential, liveEndpoint, username, plainHTTPAcknowledged, adGuard, ssh, setupComplete
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
        setupComplete = try values.decodeIfPresent(Bool.self, forKey: .setupComplete) ?? true
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
        ssh: SSHSettings? = nil,
        setupComplete: Bool = true
    ) {
        self.id = id
        self.name = name
        self.setupComplete = setupComplete
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
