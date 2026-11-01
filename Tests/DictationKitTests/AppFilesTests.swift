import XCTest
@testable import DictationKit

final class AppFilesTests: XCTestCase {
    private struct Saved: Codable, Equatable { var date: Date; var text: String }

    func testWritesIntoNewFoldersAndReadsBack() throws {
        let url = makeTempURL(self, "a/b/saved.json")
        let value = Saved(date: Date(timeIntervalSince1970: 1_800_000_000), text: "你好")
        XCTAssertNil(JSONFile.read(Saved.self, from: url), "no file yet")
        JSONFile.save(value, to: url)
        XCTAssertEqual(JSONFile.read(Saved.self, from: url), value)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("2027-01-15T08:00:00Z"), "dates as ISO 8601")
        try "not json".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(JSONFile.read(Saved.self, from: url))
    }

    func testEverythingLivesInTheAppFolder() {
        for url in [HistoryStore.defaultFileURL, LearnedPromptStore.defaultFileURL, DictationSetup.customFile,
                    FileSecretStore.defaultFile, RecordingArchive.defaultDirectory, CommandMode.defaultFolder] {
            XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, AppPaths.folder.standardizedFileURL, url.path)
        }
    }
}

/// secrets.json, which the command-line tool (`dictationapp set openRouterKey -`) writes from
/// another process while the app runs.
final class SecretStoreTests: XCTestCase {
    func testAKeyWrittenByAnotherProcessIsSeen() throws {
        let file = makeTempURL(self, "secrets.json")
        let store = FileSecretStore(file: file)
        store.set("first", for: "openRouter")
        XCTAssertEqual(store.get("openRouter"), "first")
        let other = FileSecretStore(file: file)  // the command-line tool's own store
        other.set("second", for: "openRouter")
        XCTAssertEqual(store.get("openRouter"), "second")
        other.set(nil, for: "openRouter")
        XCTAssertNil(store.get("openRouter"))
    }

    func testLoosenedPermissionsAreTightenedOnRead() throws {
        let file = makeTempURL(self, "secrets.json")
        let store = FileSecretStore(file: file)
        store.set("k", for: "openRouter")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertEqual(store.get("openRouter"), "k")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
    }
}

/// The app's shared objects come from `AppServices`, handed in: a `static let shared` or a `= .shared`
/// default lets a view or test reach your real History, settings or commands without saying so.
final class ArchitectureTests: XCTestCase {
    func testNoSharedSingletonsInTheApp() throws {
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sourcesFolder, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 30)
        let systemShared = ["URLSession", "NSWorkspace", "NSApplication"]
        for file in files {
            for (n, line) in try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines).enumerated()
            where line.contains("static let shared") || (line.contains(".shared") && !systemShared.contains { line.contains($0) }) {
                XCTFail("\(file.lastPathComponent):\(n + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
    }
}
