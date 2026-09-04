import Foundation
import Security

/// The API key store.
///
/// The key goes here and never into `UserDefaults`, which is a plist any process running
/// as the user can read. Accounts are keyed by provider, so switching providers in
/// Settings keeps each key rather than destroying the previous one.
enum Keychain {
    private static let service = "ai.pivotstudio.orbitflow.apikey"

    /// Idempotent: deletes any existing item for the account before adding.
    /// `SecItemAdd` fails with `errSecDuplicateItem` otherwise, and delete-then-add is
    /// less code than the `SecItemUpdate` branch.
    @discardableResult
    static func save(_ value: String, account: String) -> Bool {
        // Encode BEFORE deleting. The other order destroys the stored key and then
        // returns false, which a caller reads as "nothing changed" — the one outcome
        // a secret store must never produce.
        guard let data = value.data(using: .utf8) else { return false }
        delete(account: account)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // Never sync to iCloud Keychain. The key stays on this machine.
            kSecAttrSynchronizable as String: false,
            kSecValueData as String: data,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Presence check for the UI, which shows "a key is saved" rather than the key.
    static func hasKey(account: String) -> Bool {
        read(account: account)?.isEmpty == false
    }
}
