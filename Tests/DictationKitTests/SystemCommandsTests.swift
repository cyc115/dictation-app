import AppKit
import XCTest
@testable import DictationKit

/// The built-in commands that work the Mac: their logic, never their effect (no test changes this
/// Mac's brightness, volume, lock, apps or browser).
final class SystemCommandsTests: XCTestCase {
    func testALevelChangesOrSetsAndStaysInRange() {
        XCTAssertEqual(SystemCommands.level("+10", from: 42), 52)
        XCTAssertEqual(SystemCommands.level("-30", from: 20), 0)
        XCTAssertEqual(SystemCommands.level("+30", from: 90), 100)
        XCTAssertEqual(SystemCommands.level("50", from: 90), 50)
        XCTAssertEqual(SystemCommands.level("0", from: 90), 0)
        XCTAssertNil(SystemCommands.level("mute", from: 50))
        XCTAssertNil(SystemCommands.level(nil, from: 50))
        for choice in Command.brightness.choices + Command.volume.choices.dropLast(2) { XCTAssertNotNil(SystemCommands.level(choice.value, from: 50), choice.value) }
    }

    func testEveryBuiltInThatWorksTheMacHasAnAction() {
        let inApp: Set = [Command.pressReturn.name, Command.again.name, Command.create.name, Command.fix.name, Command.openApp.name]
        XCTAssertEqual(Set(SystemCommands.live.keys), Set(Command.builtIn.map(\.name)).subtracting(inApp))
    }

    @MainActor
    func testWithoutAChoiceNothingChanges() async {
        let brightness = await Brightness.set(nil)
        XCTAssertEqual(brightness.message, "No brightness given")
        XCTAssertEqual(Volume.set(nil).message, "No volume given")
        XCTAssertEqual(MediaKeys.press(nil).message, "No media key given")
        XCTAssertEqual(MediaKeys.press("rewind").message, "No media key given")
        let missing = await SwitchApp.switchTo("No Such App 1234")
        XCTAssertEqual(missing, CommandResult(ok: false, message: "No open app by that name"))
        let none = await SwitchApp.switchTo("none")
        XCTAssertFalse(none.ok)
        let nothingAsked = await AskMuse.ask("ask Muse to")
        XCTAssertEqual(nothingAsked, CommandResult(ok: false, message: "What should Muse do?"), "Muse isn't opened")
    }

    func testAskMuseSendsWhatToDoWithoutAskMuseTo() {
        let cases = [
            "Ask Muse to look up whether we can go for a movie tonight": "look up whether we can go for a movie tonight",
            "ask muse, what's on my calendar tomorrow?": "what's on my calendar tomorrow?",
            "Hey, can you ask Muse to book the vet": "book the vet",
            "tell Muse to remind me at five": "remind me at five",
            "Tell Muse: tomatoes are done": "tomatoes are done",
            "让 Muse 帮我查一下明天会不会下雨": "查一下明天会不会下雨",
            "请让muse订个餐厅": "订个餐厅",
            "问一下 Muse 今晚有什么电影": "今晚有什么电影",
            "look up movies tonight": "look up movies tonight",
            "Ask Muse to": "",
        ]
        for (said, request) in cases { XCTAssertEqual(AskMuse.request(from: said), request, said) }
        XCTAssertEqual(AskMuse.request(from: "ask museum hours"), "ask museum hours", "not Muse")
    }

    func testTheCursorNeverGoesInASearchBox() {
        for label in ["Search", "Search WeChat", "搜索", "search messages"] { XCTAssertTrue(SwitchApp.isSearchLabel(label), label) }
        for label in ["Message", "Type a message", "输入消息", ""] { XCTAssertFalse(SwitchApp.isSearchLabel(label), label) }
        XCTAssertTrue(SwitchApp.chatApps.contains("wechat") && SwitchApp.chatApps.contains("muse"))
        XCTAssertFalse(SwitchApp.chatApps.contains("obsidian") || SwitchApp.chatApps.contains("google chrome"), "the cursor is yours there")
    }

    // MARK: Media keys

    func testMediaKeysAreTheKeyboardsSystemDefinedEvents() throws {
        let events = MediaKeys.events(16)
        XCTAssertEqual(events.count, 2, "down, then up")
        let (down, up) = (try XCTUnwrap(NSEvent(cgEvent: events[0])), try XCTUnwrap(NSEvent(cgEvent: events[1])))
        XCTAssertEqual(down.type, .systemDefined)
        XCTAssertEqual(down.subtype.rawValue, 8, "NX_SUBTYPE_AUX_CONTROL_BUTTONS")
        XCTAssertEqual(down.data1, 16 << 16 | 0xA << 8)
        XCTAssertEqual(up.data1, 16 << 16 | 0xB << 8)
        XCTAssertEqual(Set(MediaKeys.keys.keys), Set(Command.media.choices.map(\.value)), "a key for every choice")
    }

    func testThisMacCanLockTheScreen() {
        XCTAssertTrue(LockScreen.available, "SACLockScreenImmediate is in login.framework")
    }

    func testBuiltInDisplayBrightnessIsReachable() {
        XCTAssertNotNil(Brightness.DisplayServices.loaded, "DisplayServices' brightness functions")
    }

    // MARK: Websites

    func testAListedSiteOpensItsAddress() {
        let (name, url) = try! XCTUnwrap(Websites.destination("hacker-news", said: "go to hacker news"))
        XCTAssertEqual(name, "Hacker News")
        XCTAssertEqual(url.absoluteString, "https://news.ycombinator.com")
        XCTAssertNil(Websites.destination("myspace", said: "go to myspace"))
        XCTAssertEqual(Set(Websites.sites.map(\.value)).count, Websites.sites.count)
        XCTAssertEqual(Command.openWebsite.choices.first?.meaning, "Hacker News (news.ycombinator.com)")
        XCTAssertEqual(Command.openWebsite.choices.last?.value, "other")
    }

    func testOtherOpensTheAddressSaidOrTheFirstResult() {
        func url(_ said: String) -> String? { Websites.destination("other", said: said)?.url.absoluteString }
        XCTAssertEqual(url("Go to weather.com."), "https://weather.com")
        XCTAssertEqual(url("open Gmail dot com"), "https://gmail.com")
        XCTAssertEqual(url("打开 docs.swift.org 网站"), "https://docs.swift.org")
        XCTAssertEqual(url("Go to the Swift forums website."), "https://duckduckgo.com/?q=!ducky%20Swift%20forums")
        XCTAssertEqual(Websites.destination("other", said: "Go to the Swift forums website.")?.name, "the first result for “Swift forums”")
        XCTAssertNil(url("open the website"), "nothing names a site")
    }

    func testTheAskingWordsAreDropped() {
        XCTAssertEqual(Websites.query("Please open up the Rust book website"), "Rust book")
        XCTAssertEqual(Websites.query("帮我打开 B站 网站"), "B站")
        XCTAssertEqual(Websites.query("take me to the New York Times."), "New York Times")
        XCTAssertNil(Websites.address("Swift forums"))
        XCTAssertNil(Websites.address("version 1.2"))
    }

    @MainActor
    func testOpeningSaysWhatOpened() {
        var opened: [URL] = []
        let result = Websites.open("gmail", said: "go to gmail") { opened.append($0); return true }
        XCTAssertEqual(result, CommandResult(ok: true, message: "Opened Gmail"))
        XCTAssertEqual(opened.map(\.absoluteString), ["https://mail.google.com"])
        let failed = Websites.open("gmail", said: "go to gmail") { _ in false }
        XCTAssertEqual(failed, CommandResult(ok: false, message: "Couldn't open Gmail", details: "https://mail.google.com"))
        XCTAssertEqual(Websites.open("other", said: "open the website") { _ in XCTFail(); return true }.message, "Which website?")
    }

    // MARK: Bench

    /// bench/built_in_commands.json is what the bench asks the deciders and the writer about: the
    /// app's built-ins, word for word (open's, switch-app's and fix's choices come from this Mac).
    func testTheBenchKnowsTheBuiltInCommands() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../bench/built_in_commands.json").standardizedFileURL
        let bench = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
        let app: [[String: Any]] = Command.builtIn.map { command in
            ["name": command.name, "summary": command.summary,
             "choices": command.choicesFromThisMac ? [] : command.choices.map { [$0.value, $0.meaning] }]
        }
        XCTAssertEqual(bench as NSArray, app as NSArray)
    }
}
