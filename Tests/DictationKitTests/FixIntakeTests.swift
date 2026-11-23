import XCTest
@testable import DictationKit

/// `FixIntake`: a fix (what the app wrote, what it should have been) as word changes.
final class FixIntakeTests: XCTestCase {
    private func changes(_ text: String, _ target: String) -> [[String]] {
        FixIntake.changes(from: text, to: target).map { [$0.old, $0.new] }
    }

    func testEachReplacedRunIsAChange() {
        XCTAssertEqual(changes("Can you install Cloud Code?", "Can you install Claude Code?"), [["Cloud", "Claude"]])
        XCTAssertEqual(changes("two cats and a cloud", "2 cats and a Claude"), [["two", "2"], ["cloud", "Claude"]])
        XCTAssertEqual(changes("ask g four snow now", "ask GeForce Now"), [["g four snow now", "GeForce Now"]], "a run, as one change")
        XCTAssertEqual(changes("Same text.", "Same text."), [])
    }

    func testInsertionsAndDeletionsAreNotChanges() {
        XCTAssertEqual(changes("I want the app.", "I really want the app."), [], "insert only")
        XCTAssertEqual(changes("No, so I want the app.", "I want the app."), [], "delete only")
        XCTAssertEqual(changes("那你让我看干什么？", "那你让我看什么？"), [], "a Chinese deletion")
        XCTAssertEqual(changes("Hello", ""), [])
    }

    func testPunctuationAtTheEdgesIsNotPartOfTheWord() {
        XCTAssertEqual(changes("I use cloud.", "I use Claude."), [["cloud", "Claude"]])
        XCTAssertEqual(changes("“cloud,” he said", "“Claude,” he said"), [["cloud", "Claude"]])
        XCTAssertEqual(changes("Hello world", "Hello world."), [], "only punctuation changed")
        XCTAssertEqual(changes("I use C plus plus", "I use C++"), [["C plus plus", "C++"]], "symbols that are part of a name stay")
        XCTAssertEqual(changes("I use C sharp.", "I use C#."), [["C sharp", "C#"]])
    }

    func testChineseAndMixedText() {
        XCTAssertEqual(changes("我在用克劳德写代码", "我在用Claude写代码"), [["克劳德", "Claude"]], "Chinese kept as written, no spaces added")
        XCTAssertEqual(changes("我用 cloud code 写的", "我用 Claude Code 写的"), [["cloud code", "Claude Code"]])
        XCTAssertEqual(changes("我的而差v一般", "我的HRV一般"), [["而差v", "HRV"]])
    }

    func testIntakeRemembersItsTarget() {
        let intake = FixIntake.intake(of: "I use cloud.", target: "I use Claude.")
        XCTAssertEqual(intake.of, "I use Claude.")
        XCTAssertEqual(intake.changes, [WordChange(old: "cloud", new: "Claude")])
        XCTAssertNil(intake.changes.first?.verdict, "no verdict until the judge gives one")
    }

    /// `WordDiff.changed` (Corrections' orange highlight) is built on the same hunks.
    func testHunksPairRemovalsWithInsertions() {
        let old = "No, I. So I want cloud.", new = "I want Claude."
        let hunks = WordDiff.hunks(from: old, to: new)
        XCTAssertEqual(hunks.map { $0.removed.map { String(old[$0]) } }, [["No,", "I.", "So"], ["cloud."]])
        XCTAssertEqual(hunks.map { $0.inserted.map { String(new[$0]) } }, [[], ["Claude."]])
    }
}
