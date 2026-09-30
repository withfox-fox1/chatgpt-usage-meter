import Foundation
import Security

public enum KeychainStoreError: Error {
    case invalidData
    case unhandledError(status: OSStatus)
}

/// Stores the chatgpt.com access token in the Keychain, scoped
/// to this device only (no iCloud Keychain sync), so it survives app
/// relaunches without living in UserDefaults/plist.
public final class KeychainStore {
    private let service: String
    private let account: String
    private let accessGroup: String?

    /// Items go to the file-based login keychain (no `kSecUseDataProtectionKeychain`),
    /// where `accessGroup` has no effect; access is controlled by the item's ACL, which
    /// trusts any build with the same bundle ID signed by the same certificate. So the
    /// token survives rebuilds without a re-login. `accessGroup` defaults to nil
    /// because a shared group needs the `keychain-access-groups` entitlement, which
    /// needs a provisioning profile — and Personal-Team profiles expire after 7 days,
    /// after which the app can no longer launch.
    public init(
        service: String = "dev.local.chatgptusagemeter.token",
        account: String = "accessToken",
        accessGroup: String? = nil
    ) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    public func saveToken(_ token: String) throws {
        guard let data = token.data(using: .utf8) else {
            throw KeychainStoreError.invalidData
        }

        // Remove any existing item first so this behaves as an upsert.
        SecItemDelete(baseQuery() as CFDictionary)

        var addQuery = baseQuery()
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainStoreError.unhandledError(status: status)
        }
    }

    public func loadToken() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func clearToken() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}
