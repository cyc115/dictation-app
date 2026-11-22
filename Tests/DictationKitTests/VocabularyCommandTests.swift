import XCTest
@testable import DictationKit

/// `DictationApp vocabulary …` against a throwaway file, with captured output.
final class VocabularyCommandTests: XCTestCase {
    private var out: [String] = []
    private var err: [String] = []
    private var store: VocabularyStore!

    override func setUp() {
        super.setUp()
        store = makeVocabulary(self)
    }

    @discardableResult
    private func run(_ args: String...) -> Int32 {
        out = []; err = []
        return VocabularyCommand.run(args, store: store, io: .init(out: { self.out.append($0) }, err: { self.err.append($0) }))
    }

    func testAddListAndRemove() throws {
        XCTAssertEqual(run("add", "GeForce", "Now", "--heard", "G Four Snow, g force now"), 0)
        XCTAssertEqual(out, ["added GeForce Now  (heard as: G Four Snow, g force now)"])
        XCTAssertEqual(run("add", "reMarkable"), 0)
        XCTAssertEqual(run("add", "geforce now", "--heard", "gforce"), 0, "more variants for a term you have")
        XCTAssertEqual(out, ["updated GeForce Now  (heard as: G Four Snow, g force now, gforce)"])

        XCTAssertEqual(run(), 0)
        XCTAssertEqual(out, ["GeForce Now  (heard as: G Four Snow, g force now, gforce)", "reMarkable"])
        XCTAssertEqual(run("list", "--json"), 0)
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.joined().utf8)) as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["term"] as? String }, ["GeForce Now", "reMarkable"])
        XCTAssertEqual(rows.first?["enabled"] as? Bool, true)

        XCTAssertEqual(run("remove", "remarkable"), 0)
        XCTAssertEqual(out, ["removed remarkable"])
        XCTAssertEqual(store.entries.map(\.term), ["GeForce Now"])
        XCTAssertEqual(VocabularyStore(fileURL: store.fileURL).entries.map(\.term), ["GeForce Now"], "saved for the app to read")
    }

    func testErrors() {
        XCTAssertEqual(run("remove", "Nope"), 1)
        XCTAssertTrue(err.first?.contains("no term \"Nope\"") ?? false)
        XCTAssertEqual(run("add"), 2)
        XCTAssertEqual(run("add", "X", "--heard"), 2)
        XCTAssertEqual(run("frobnicate"), 2)
        XCTAssertTrue(err.first?.hasPrefix("usage:") ?? false)
        XCTAssertEqual(run("help"), 0)
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testOnlyAVocabularyInvocationRunsIt() {
        XCTAssertNil(VocabularyCommand.runIfRequested(["DictationApp"]))
        XCTAssertNil(VocabularyCommand.runIfRequested(["DictationApp", "settings"]))
    }
}
