import XCTest
@testable import DictationKit

/// "apple-tail" (bench latency suite): how long polish takes if only the newest phrase is left to
/// rewrite after you stop, with everything before it as read-only context.
final class TailPolishTests: XCTestCase {
    func testSplitsBeforeTheLastWordsCountingChineseCharactersAndEnglishWords() throws {
        let split = try XCTUnwrap(PolishService.splitTail("帮我写一个 Python script, then run it's tests.", words: 4))
        XCTAssertEqual(split.context, "帮我写一个 Python script,")
        XCTAssertEqual(split.tail, "then run it's tests.")
        let chinese = try XCTUnwrap(PolishService.splitTail("我们明天开会，然后发邮件。", words: 3))
        XCTAssertEqual(chinese.context, "我们明天开会，然后")
        XCTAssertEqual(chinese.tail, "发邮件。")
    }

    func testShortTextHasNoEarlierPart() {
        XCTAssertNil(PolishService.splitTail("just five words here ok", words: 5))
        XCTAssertNil(PolishService.splitTail("", words: 15))
        XCTAssertEqual(PolishService.tailPrompt("um so yes", words: 15), "um so yes", "short: polished whole")
    }

    func testPromptKeepsContextReadOnlyAndAsksForTheTailOnly() {
        let prompt = PolishService.tailPrompt("one two three four five six", words: 2)
        XCTAssertEqual(prompt, "Earlier part (already written):\none two three four\n\n"
                       + "Newest part (clean up and output only this):\nfive six")
        XCTAssertTrue(PolishService.tailInstructions.hasPrefix(PolishPrompt.v1))
        XCTAssertTrue(PolishService.tailInstructions.contains("never repeat the earlier part"))
    }
}
