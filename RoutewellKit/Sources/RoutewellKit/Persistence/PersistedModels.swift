import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    public var showInMenuBar = true
    public var refreshIntervalSeconds = 30
    public var pauseWhenHidden = true
    public var showStatusBar = true
    public init() {}
}

public struct RouterProfile: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public let endpoint: String
    public let credential: CredentialReference

    private enum CodingKeys: String, CodingKey { case id, name, endpoint, credential }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        endpoint = try values.decode(String.self, forKey: .endpoint)
        credential = try values.decode(CredentialReference.self, forKey: .credential)
        guard credential.profileID == id, credential.endpoint == endpoint else {
            throw DecodingError.dataCorruptedError(forKey: .credential, in: values, debugDescription: "Credential reference does not match profile")
        }
    }

    public init(id: UUID = UUID(), name: String, endpoint: String) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        credential = CredentialReference(profileID: id, endpoint: endpoint)
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
