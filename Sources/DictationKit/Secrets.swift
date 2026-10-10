import Foundation
import Security

/// Where the cloud API key is saved.
protocol SecretStore: AnyObject {
    func get(_ account: String) -> String?
    func set(_ value: String?, for account: String)
}

/// Secrets in a JSON file only your user account can read: the file is 0600 and its folder 0700,
/// and looser permissions are tightened before every read. Not the Keychain: this app has no Apple
/// team ID, so the Keychain saw each build as a new app and asked for your password again.
final class FileSecretStore: SecretStore {
    static let defaultFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("DictationApp/secrets.json")
    let file: URL

    init(file: URL = FileSecretStore.defaultFile) { self.file = file }

    func get(_ account: String) -> String? {
        tighten()
        let value = read()[account]
        return value?.isEmpty == false ? value : nil
    }

    func set(_ value: String?, for account: String) {
        var values = read()
        values[account] = value?.isEmpty == false ? value : nil
        let fm = FileManager.default
        let dir = file.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]) else { return }
        // Created 0600 in place of the old file, so the key is never readable by anyone else, even briefly.
        let temp = dir.appendingPathComponent(".secrets-\(UUID().uuidString).json")
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        let moved = fm.fileExists(atPath: file.path)
            ? (try? fm.replaceItemAt(file, withItemAt: temp)) != nil
            : (try? fm.moveItem(at: temp, to: file)) != nil
        if !moved { try? fm.removeItem(at: temp) }
        tighten()
    }

    private func read() -> [String: String] {
        guard let data = FileManager.default.contents(atPath: file.path) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: String]) ?? [:]
    }

    private func tighten() {
        let fm = FileManager.default
        for (path, mode) in [(file.deletingLastPathComponent().path, 0o700), (file.path, 0o600)] {
            guard let current = (try? fm.attributesOfItem(atPath: path))?[.posixPermissions] as? Int, current != mode else { continue }
            try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
        }
    }

    /// Moves a key saved in the Keychain by older builds into this file, then deletes it there.
    /// Reading it asks for your password one last time; only done when the file doesn't have it.
    func moveFromKeychain(_ account: String, service: String = "com.mikechen.DictationApp") {
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        guard get(account) == nil, SecItemCopyMatching(item as CFDictionary, nil) == errSecSuccess else { return }
        var query = item
        query[kSecReturnData as String] = true
        var data: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &data) == errSecSuccess,
              let value = (data as? Data).flatMap({ String(data: $0, encoding: .utf8) }), !value.isEmpty else { return }
        set(value, for: account)
        if get(account) == value { SecItemDelete(item as CFDictionary) }
    }
}

final class InMemorySecretStore: SecretStore {
    private var values: [String: String] = [:]
    func get(_ account: String) -> String? { values[account] }
    func set(_ value: String?, for account: String) { values[account] = (value?.isEmpty ?? true) ? nil : value }
}
