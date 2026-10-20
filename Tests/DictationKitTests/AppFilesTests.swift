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
