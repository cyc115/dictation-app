import Foundation

/// Where the cloud API key is saved.
protocol SecretStore: AnyObject {
    func get(_ account: String) -> String?
    func set(_ value: String?, for account: String)
}

/// Secrets in a JSON file only your user account can read: the file is 0600 and its folder 0700,
/// and looser permissions are tightened before every read. Not the Keychain: this app has no Apple
/// team ID, so the Keychain saw each build as a new app and asked for your password again.
final class FileSecretStore: SecretStore {
    static let defaultFile = AppPaths.file("secrets.json")
    let file: URL

    /// Which file the cached values came from: inode, size and modification time. The command-line
    /// tool rewrites the file from another process, which changes all three.
    private struct Stamp: Equatable {
        let inode: ino_t, size: off_t, modified: timespec
        init(_ status: stat) {
            inode = status.st_ino
            size = status.st_size
            modified = status.st_mtimespec
        }
        static func == (a: Stamp, b: Stamp) -> Bool {
            a.inode == b.inode && a.size == b.size
                && a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec
        }
    }
    private var cached: (stamp: Stamp, values: [String: String])?
    private let lock = NSLock()

    init(file: URL = FileSecretStore.defaultFile) { self.file = file }

    func get(_ account: String) -> String? {
        let value = values()[account]
        return value?.isEmpty == false ? value : nil
    }

    func set(_ value: String?, for account: String) {
        var values = values()
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
        lock.withLock { cached = nil }
    }

    /// The file's values. Its permissions are checked (and tightened) on every call, with one `stat`;
    /// its contents are read again only when it has changed since last time.
    private func values() -> [String: String] {
        lock.withLock {
            var status = stat()
            guard stat(file.path, &status) == 0 else {
                cached = nil
                return [:]
            }
            if status.st_mode & 0o777 != 0o600 { chmod(file.path, 0o600) }
            let stamp = Stamp(status)
            if let cached, cached.stamp == stamp { return cached.values }
            let dir = file.deletingLastPathComponent().path
            if stat(dir, &status) == 0, status.st_mode & 0o777 != 0o700 { chmod(dir, 0o700) }
            let values = FileManager.default.contents(atPath: file.path)
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } ?? [:]
            cached = (stamp, values)
            return values
        }
    }
}
