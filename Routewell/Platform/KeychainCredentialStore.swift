import Foundation
import Security
import RoutewellKit

actor KeychainCredentialStore: CredentialStore {
    private let namespace: String
    init(namespace: String = "com.simonsolts.Routewell") { self.namespace = namespace }

    func read(_ reference: CredentialReference) throws -> Data {
        var query = query(reference)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        try check(SecItemCopyMatching(query as CFDictionary, &result))
        guard let data = result as? Data else { throw CredentialError.unexpected }
        return data
    }

    func save(_ secret: Data, for reference: CredentialReference) throws {
        let query = query(reference)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: secret] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData] = secret
            item[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            try check(SecItemAdd(item as CFDictionary, nil))
        } else { try check(status) }
    }

    func delete(_ reference: CredentialReference) throws {
        try check(SecItemDelete(query(reference) as CFDictionary), allowMissing: true)
    }



    private func base(_ profileID: UUID) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword,
         kSecAttrService: "\(namespace).credentials.\(profileID.uuidString)",
         kSecUseDataProtectionKeychain: true]
    }

    private func query(_ reference: CredentialReference) -> [CFString: Any] {
        var result = base(reference.profileID)
        // Base64 keeps endpoint delimiters unambiguous; no secret is in the key.
        result[kSecAttrAccount] = "\(reference.kind.rawValue):\(Data(reference.endpoint.utf8).base64EncodedString())"
        return result
    }

    private func check(_ status: OSStatus, allowMissing: Bool = false) throws {
        if status == errSecSuccess || (allowMissing && status == errSecItemNotFound) { return }
        switch status {
        case errSecItemNotFound: throw CredentialError.missing
        case errSecInteractionNotAllowed: throw CredentialError.locked
        case errSecNotAvailable: throw CredentialError.unavailable
        case errSecAuthFailed, errSecUserCanceled, errSecMissingEntitlement: throw CredentialError.accessDenied
        default: throw CredentialError.unexpected
        }
    }
}
