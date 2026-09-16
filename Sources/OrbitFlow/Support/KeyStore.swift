import Foundation

/// The API key store: a 0600 JSON file under Application Support, keyed by provider.
///
/// This used to be the Keychain, and on paper that is the better home. In practice the
/// legacy keychain guards an item's data with an ACL naming the app allowed to read it,
/// identified by its code signature — and a locally built app is ad-hoc signed, so its
/// cdhash changes on every `make`. The ACL then stops matching and *every read* pops
/// "Orbit Flow wants to access key … in your keychain", with "Always Allow" holding only
/// until the next rebuild. The data-protection keychain has no ACL prompts, but on macOS
/// it wants a team identifier this app doesn't have.
///
/// So: a file the user owns. It is plainer than the Keychain — any process running as the
/// user can read it — but this app is already unsandboxed and holds a system-wide event
/// tap, so that process could read the key out of our memory anyway.
///
/// ponytail: plaintext at 0600 in a 0700 directory. If this ever ships with a Developer ID
/// (stable signature, real team identifier), move back to the Keychain with
/// kSecUseDataProtectionKeychain and delete this file.
enum KeyStore {
    private static let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OrbitFlow", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true,
            // The directory is the second guard: 0700 keeps other users out regardless of
            // what an atomic replace does to the file's own mode.
            attributes: [.posixPermissions: 0o700]
        )
        // …and again unconditionally, because `attributes:` only applies to a directory
        // this call actually creates. DictionaryStore and RunLog got here first on every
        // existing install, leaving it 0755.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: base.path
        )
        return base.appendingPathComponent("keys.json")
    }()

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let keys = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return keys
    }

    @discardableResult
    private static func store(_ keys: [String: String]) -> Bool {
        guard let data = try? JSONEncoder().encode(keys) else { return false }
        do {
            // .atomic writes a temp file and renames, so the mode below has to be set
            // after the fact — the replacement doesn't inherit the old file's.
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: fileURL.path
            )
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    static func save(_ value: String, account: String) -> Bool {
        var keys = load()
        keys[account] = value
        return store(keys)
    }

    static func read(account: String) -> String? {
        load()[account]
    }

    static func delete(account: String) {
        var keys = load()
        keys.removeValue(forKey: account)
        store(keys)
    }

    /// Presence check for the UI, which shows "a key is saved" rather than the key.
    static func hasKey(account: String) -> Bool {
        read(account: account)?.isEmpty == false
    }
}
