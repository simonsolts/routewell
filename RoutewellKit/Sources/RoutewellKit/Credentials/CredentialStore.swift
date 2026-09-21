import Foundation

public struct CredentialReference: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case mockPassword, routerPassword, adGuardPassword }
    public let profileID: UUID
    public let endpoint: String
    public let kind: Kind

    public init(profileID: UUID, endpoint: String, kind: Kind = .mockPassword) {
        self.profileID = profileID
        self.endpoint = endpoint
        self.kind = kind
    }
}

public enum CredentialError: Error, Equatable, Sendable, CaseIterable {
    case missing, locked, unavailable, accessDenied, unexpected

    public var message: String {
        switch self {
        case .missing: "No mock credential is stored."
        case .locked: "Keychain is locked or requires interaction. Unlock it and retry."
        case .unavailable: "Keychain is unavailable. Try again later."
        case .accessDenied: "Keychain access was denied. Check access permissions and retry."
        case .unexpected: "The Keychain operation failed. Try again."
        }
    }
}

public protocol CredentialStore: Sendable {
    func read(_ reference: CredentialReference) async throws -> Data
    func save(_ secret: Data, for reference: CredentialReference) async throws
    func delete(_ reference: CredentialReference) async throws
}

public actor InMemoryCredentialStore: CredentialStore {
    private var values: [CredentialReference: Data] = [:]
    public var failure: CredentialError?
    public init() {}
    public func setFailure(_ failure: CredentialError?) { self.failure = failure }
    public func read(_ reference: CredentialReference) throws -> Data {
        if let failure { throw failure }
        guard let value = values[reference] else { throw CredentialError.missing }
        return value
    }
    public func save(_ secret: Data, for reference: CredentialReference) throws {
        if let failure { throw failure }
        values[reference] = secret
    }
    public func delete(_ reference: CredentialReference) throws {
        if let failure { throw failure }
        values[reference] = nil
    }

}
