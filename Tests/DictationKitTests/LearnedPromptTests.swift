import XCTest
@testable import DictationKit

func makeLearned(version: String = "v5", setup: String = "cloud-flash", basedOn: String = "v4", text: String = "Learned prompt.",
                 errors: [UUID: Double] = [:], errorsBefore: [UUID: Double] = [:]) -> LearnedPrompt {
    LearnedPrompt(version: version, setup: setup, basedOn: basedOn, date: fixedDate(2026, 10, 13, 9, 0), text: text, lens: .both,
                  corrections: 15, tokens: 412, score: .init(mine: 74.2, mineBefore: 65.1, general: 70.6, generalBefore: 70.6),
                  errors: Dictionary(uniqueKeysWithValues: errors.map { ($0.key.uuidString, $0.value) }),
                  errorsBefore: Dictionary(uniqueKeysWithValues: errorsBefore.map { ($0.key.uuidString, $0.value) }))
}

final class LearnedPromptStoreTests: XCTestCase {
    func testKeepSavesActivatesAndWritesThePromptFile() throws {
        let url = makeTempURL(self, "learned-prompts.json")
        let store = LearnedPromptStore(fileURL: url)
        XCTAssertEqual(store.nextVersion, "v5", "one past the built-in prompts")
        XCTAssertNil(store.active(for: "cloud-flash"))

        let id = UUID()
        store.keep(makeLearned(errors: [id: 0.09], errorsBefore: [id: 0.38]))
        XCTAssertEqual(store.active(for: "cloud-flash")?.version, "v5")
        XCTAssertEqual(store.nextVersion, "v6")
        XCTAssertEqual(store.text(for: "v5"), "Learned prompt.")
        XCTAssertNil(store.text(for: "v4"))
        XCTAssertEqual(try String(contentsOf: url.deletingLastPathComponent().appendingPathComponent("prompts/v5.txt"), encoding: .utf8),
                       "Learned prompt.\n", "for bench/suite.py polish run --prompt-file")

        let reloaded = LearnedPromptStore(fileURL: url)
        XCTAssertEqual(reloaded.prompts, store.prompts)
        XCTAssertEqual(reloaded.active, ["cloud-flash": "v5"])
        XCTAssertEqual(reloaded.errors(for: id, setup: "cloud-flash")?.before, 0.38)
        XCTAssertEqual(reloaded.errors(for: id, setup: "cloud-flash")?.now, 0.09)
        XCTAssertTrue(reloaded.isLearned(id, setup: "cloud-flash"))
        XCTAssertFalse(reloaded.isLearned(UUID(), setup: "cloud-flash"), "never scored")
        XCTAssertFalse(reloaded.isLearned(id, setup: "cloud-big"), "another setup's prompt")
        XCTAssertEqual(reloaded.versions(for: "cloud-flash").map(\.version), ["v5"])
        XCTAssertEqual(reloaded.versions(for: "cloud-big"), [])
        XCTAssertEqual(reloaded.prompts[0].summary, "v5 · learned from 15 corrections")
    }

    func testActivateRevertsAndReChooses() {
        let store = LearnedPromptStore(fileURL: makeTempURL(self, "learned-prompts.json"))
        let id = UUID()
        store.keep(makeLearned(version: "v5", errors: [id: 0.3], errorsBefore: [id: 0.5]))
        store.keep(makeLearned(version: "v6", basedOn: "v5", text: "Newer.", errors: [id: 0.1], errorsBefore: [id: 0.3]))
        XCTAssertEqual(store.active(for: "cloud-flash")?.version, "v6")
        XCTAssertTrue(store.isLearned(id, setup: "cloud-flash"))
        store.activate("v5", for: "cloud-flash")
        XCTAssertEqual(store.active(for: "cloud-flash")?.version, "v5")
        XCTAssertFalse(store.isLearned(id, setup: "cloud-flash"), "v5 doesn't get it right")
        store.activate(nil, for: "cloud-flash")
        XCTAssertNil(store.active(for: "cloud-flash"))
        XCTAssertEqual(store.versions(for: "cloud-flash").map(\.version), ["v5", "v6"], "versions are kept")
        XCTAssertNil(store.errors(for: id, setup: "cloud-flash"))
    }

    func testAppliedToTheSetupsSoDictationAndSuggestionsUseIt() throws {
        let store = LearnedPromptStore(fileURL: makeTempURL(self, "learned-prompts.json"))
        let settings = makeSettings(self, learned: store)
        settings.setOpenRouterKey("sk-or-v1-test")
        settings.setup = settings.setups.first { $0.id == "cloud-flash" }!
        XCTAssertEqual(settings.setup.prompt, "v4")
        XCTAssertFalse(settings.setup.usesLearnedPrompt)

        store.keep(makeLearned())
        waitUntil { settings.setup.prompt == "v5" }
        XCTAssertEqual(settings.setup.promptText, "Learned prompt.")
        XCTAssertTrue(settings.setup.usesLearnedPrompt)
        XCTAssertEqual(settings.setups.first { $0.id == "cloud-big" }?.prompt, "v4", "another setup keeps its own")
        XCTAssertEqual(settings.setups.first { $0.id == "on-device" }?.prompt, "v3")
        XCTAssertTrue(settings.setups.contains(settings.setup), "the picker's list has the applied one")

        let cloud = try XCTUnwrap(settings.setup.polishBackend(apiKey: "sk-or-v1-test", onDevice: { _, _ in FakePolish() }) as? OpenRouterPolish)
        XCTAssertEqual(cloud.instructions, "Learned prompt.", "dictation polishes with it")
        let suggester = try XCTUnwrap(CorrectionSuggester.backend(apiKey: "k", setup: settings.setup) as? OpenRouterPolish)
        XCTAssertEqual(suggester.instructions, "Learned prompt.", "so do correction suggestions")

        store.activate(nil, for: "cloud-flash")
        waitUntil { settings.setup.prompt == "v4" }
        XCTAssertEqual(settings.setup.promptText, PolishPrompt.v4)

        let fresh = makeSettings(self, defaults: nil, learned: LearnedPromptStore(fileURL: store.fileURL))
        XCTAssertEqual(fresh.setups.first { $0.id == "cloud-flash" }?.prompt, "v4", "reverted, and remembered")
    }

    func testASetupIsStillEqualToItsJSONFormWithoutLearnedText() throws {
        var setup = DictationSetup.cloudFlash
        setup.prompt = "v5"
        setup.learnedText = "Learned."
        let json = try JSONEncoder().encode(setup)
        XCTAssertFalse(String(decoding: json, as: UTF8.self).contains("learnedText"), "not in setups.json")
        let decoded = try JSONDecoder().decode(DictationSetup.self, from: json)
        XCTAssertEqual(decoded.prompt, "v5")
        XCTAssertNil(decoded.learnedText)
    }
}
