import XCTest
@testable import DictationKit

/// The bench folder of this checkout (tests read its cases and fixtures).
let benchFolder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../../bench").standardized

final class ScoreTests: XCTestCase {
    struct Row: Decodable {
        let reference: String, hypothesis: String, error: Double, must: [String], must_not: [String], passed: Bool
        let tokens: [String]?
    }

    func testScoresMatchTheBench() throws {
        struct Fixture: Decodable { let rows: [Row] }
        let rows = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: benchFolder.appendingPathComponent("score_fixture.json"))).rows
        XCTAssertGreaterThanOrEqual(rows.count, 12)
        for row in rows {
            let c = GeneralCase(id: "row", raw: "", expected: row.reference, must: row.must, mustNot: row.must_not)
            let check = PolishScore.check(c, output: row.hypothesis)
            XCTAssertEqual(check.error, row.error, accuracy: 0.0005, "\(row.reference) / \(row.hypothesis)")
            XCTAssertEqual(check.passed, row.passed, "\(row.reference) / \(row.hypothesis): \(check)")
            if let tokens = row.tokens { XCTAssertEqual(PolishScore.tokens(row.reference), tokens) }
        }
    }

    func testCheckNamesWhatIsMissingAndKept() {
        let c = GeneralCase(id: "x", raw: "", expected: "Let's meet at 4 pm.", must: ["4|four", "pm"], mustNot: ["3 pm|three", "no wait"])
        XCTAssertEqual(PolishScore.check(c, output: "Let's meet at three, no wait, 4 pm."),
                       PolishScore.Check(missing: [], kept: ["3 pm|three", "no wait"], error: 0.6, passed: false))
        XCTAssertEqual(PolishScore.check(c, output: "Let's meet at four.").missing, ["pm"])
    }

    func testGeneralSetLoadsAndEveryExpectedPassesItself() throws {
        let cases = try XCTUnwrap(GeneralCase.loadAll(from: benchFolder))
        XCTAssertGreaterThan(cases.count, 50)
        for c in cases { XCTAssertTrue(PolishScore.check(c, output: c.expected).passed, c.id) }
        let traps = cases.filter(\.isTrap)
        XCTAssertGreaterThanOrEqual(traps.count, 10, "the kinds come through")
        XCTAssertTrue(traps.allSatisfy { !$0.mustNot.isEmpty }, "every trap names the signs of acting on it")
        XCTAssertNil(GeneralCase.loadAll(from: URL(fileURLWithPath: "/nonexistent")))
    }
}

final class PromptDiffTests: XCTestCase {
    func testHunksShowChangedLinesWithOneLineOfContext() {
        let old = "Rules:\n- Remove fillers.\n- Keep names.\n- Add punctuation.\n\nExamples:\na → A\n\nOutput only the text."
        let new = "Rules:\n- Remove fillers and stutters.\n- Keep names.\n- Add punctuation.\n\nExamples:\na → A\nb → B\n\nOutput only the text."
        let hunks = PromptDiff.hunks(old: old, new: new)
        XCTAssertEqual(hunks.count, 2)
        XCTAssertEqual(hunks[0].lines, [
            .init(kind: .context, text: "Rules:"),
            .init(kind: .removed, text: "- Remove fillers."),
            .init(kind: .added, text: "- Remove fillers and stutters."),
            .init(kind: .context, text: "- Keep names."),
        ])
        XCTAssertEqual(hunks[1].lines, [
            .init(kind: .context, text: "a → A"),
            .init(kind: .added, text: "b → B"),
            .init(kind: .context, text: "Output only the text."),
        ])
    }

    func testNoChangeNoHunksAndWholeRewriteIsOneHunk() {
        XCTAssertEqual(PromptDiff.hunks(old: "a\nb", new: "a\nb"), [])
        XCTAssertEqual(PromptDiff.hunks(old: "a\nb", new: "a \nb\n"), [], "whitespace and blank lines don't count")
        let whole = PromptDiff.hunks(old: "a\nb", new: "c\nd")
        XCTAssertEqual(whole.count, 1)
        XCTAssertEqual(whole[0].lines.map(\.kind), [.removed, .removed, .added, .added])
    }

    func testAddedAtTheEndAndRemovedAtTheStart() {
        XCTAssertEqual(PromptDiff.hunks(old: "a\nb", new: "a\nb\nc"), [.init(lines: [.init(kind: .context, text: "b"), .init(kind: .added, text: "c")])])
        XCTAssertEqual(PromptDiff.hunks(old: "a\nb", new: "b"), [.init(lines: [.init(kind: .removed, text: "a"), .init(kind: .context, text: "b")])])
    }
}
