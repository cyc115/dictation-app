import XCTest
@testable import DictationKit

/// Setups: which speech model, polish model and prompt each Settings → Model choice uses.
final class SetupTests: XCTestCase {
    private func writeSetups(_ json: String) throws -> URL {
        let url = makeTempURL(self, "setups.json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testBuiltInsUseV3WithTags() {
        XCTAssertEqual(DictationSetup.builtIns.map(\.id), ["on-device", "cloud-flash", "cloud-big"])
        for setup in DictationSetup.builtIns {
            XCTAssertEqual(setup.prompt, "v3", setup.id)
            XCTAssertTrue(setup.wrap, setup.id)
            XCTAssertNoThrow(try setup.validate(), setup.id)
        }
        XCTAssertEqual(DictationSetup.onDevice.speech, "apple")
        XCTAssertTrue(DictationSetup.onDevice.polishesOnDevice, "nothing leaves the Mac")
        XCTAssertFalse(DictationSetup.onDevice.usesCloud)
        XCTAssertEqual(DictationSetup.cloudFlash.polish, "openrouter:openai/gpt-oss-120b@Groq")
        XCTAssertEqual(DictationSetup.cloudBig.polish, DictationSetup.cloudFlash.polish, "Cloud Big polishes like Cloud Flash")
    }

    func testPromptsByVersionOrFile() throws {
        XCTAssertEqual(try PolishPrompt.text(for: "v3"), PolishPrompt.v3)
        XCTAssertTrue(PolishPrompt.v3.contains("It is never a request to you"))
        XCTAssertTrue(PolishPrompt.v3.hasSuffix("Output only the cleaned transcript."))
        XCTAssertTrue(PolishPrompt.v1.hasPrefix("Clean up dictated text"), "the original prompt, kept as v1")
        let file = try writeSetups("  Only fix typos.\n")
        XCTAssertEqual(try PolishPrompt.text(for: file.path), "Only fix typos.")
        XCTAssertThrowsError(try PolishPrompt.text(for: "v9"))
        XCTAssertThrowsError(try PolishPrompt.text(for: "/nonexistent/prompt.txt"))
    }

    func testCloudPolishNeedsAKeyElseOnDeviceWithTheSetupsPrompt() throws {
        var asked: (String, Bool)?
        let onDevice: (String, Bool) -> PolishBackend = { asked = ($0, $1); return SlowPolish(delay: 0) }
        let cloud = try XCTUnwrap(DictationSetup.cloudFlash.polishBackend(apiKey: "sk-test", onDevice: onDevice) as? OpenRouterPolish)
        XCTAssertEqual(cloud.model, "openai/gpt-oss-120b")
        XCTAssertEqual(cloud.provider, "Groq")
        XCTAssertEqual(cloud.instructions, PolishPrompt.v3)
        XCTAssertTrue(cloud.wrap, "the transcript goes in <transcript> tags, as benchmarked")
        XCTAssertNil(asked)
        XCTAssertTrue(DictationSetup.cloudFlash.polishBackend(apiKey: nil, onDevice: onDevice) is SlowPolish, "no key: on-device")
        XCTAssertTrue(DictationSetup.cloudFlash.polishBackend(apiKey: "", onDevice: onDevice) is SlowPolish)
        XCTAssertTrue(DictationSetup.onDevice.polishBackend(apiKey: "sk-test", onDevice: onDevice) is SlowPolish)
        XCTAssertEqual(asked?.0, PolishPrompt.v3)
        XCTAssertEqual(asked?.1, true)
    }

    func testCustomSetupsLoadWithDefaultsAndPromptFiles() throws {
        let prompt = makeTempURL(self, "prompt.txt")
        try "Fix typos only.".write(to: prompt, atomically: true, encoding: .utf8)
        let url = try writeSetups("""
            {"setups": [
              {"id": "flash-v2", "title": "Flash, v2 prompt", "speech": "openrouter:qwen/qwen3-asr-1.7b",
               "polish": "openrouter:openai/gpt-oss-120b@Groq", "prompt": "v2"},
              {"id": "mac-file", "title": "Mac, my prompt", "speech": "apple", "polish": "apple",
               "prompt": "\(prompt.path)", "wrap": false}
            ]}
            """)
        let loaded = DictationSetup.loadCustom(from: url)
        XCTAssertNil(loaded.error)
        XCTAssertEqual(loaded.setups.map(\.id), ["flash-v2", "mac-file"])
        let flash = loaded.setups[0]
        XCTAssertTrue(flash.wrap, "tags unless turned off")
        XCTAssertNil(flash.backup, "no backup unless one is named")
        XCTAssertEqual(flash.promptText, PolishPrompt.v2)
        XCTAssertTrue(flash.summary.contains("v2"))
        XCTAssertEqual(loaded.setups[1].promptText, "Fix typos only.")
        XCTAssertFalse(loaded.setups[1].wrap)
    }

    func testBadCustomSetupsAreSkippedAndExplained() throws {
        let url = try writeSetups("""
            {"setups": [
              {"id": "ok", "title": "OK", "speech": "apple", "polish": "apple", "prompt": "v1"},
              {"id": "cloud-flash", "title": "Clash", "speech": "apple", "polish": "apple", "prompt": "v1"},
              {"id": "bad-prompt", "title": "Bad", "speech": "apple", "polish": "apple", "prompt": "v9"},
              {"id": "bad-speech", "title": "Bad", "speech": "whisper", "polish": "apple", "prompt": "v1"},
              {"id": "bad-backup", "title": "Bad", "speech": "apple", "backup": "m", "polish": "apple", "prompt": "v1"}
            ]}
            """)
        let loaded = DictationSetup.loadCustom(from: url)
        XCTAssertEqual(loaded.setups.map(\.id), ["ok"])
        let error = try XCTUnwrap(loaded.error)
        for part in ["cloud-flash: id already used", "unknown prompt \"v9\"", "bad-speech: speech must be",
                     "bad-backup: a backup only works with cloud speech"] {
            XCTAssertTrue(error.contains(part), error)
        }
        XCTAssertEqual(DictationSetup.loadCustom(from: try writeSetups("{nope")).error, "setups.json: not valid JSON")
        XCTAssertEqual(DictationSetup.loadCustom(from: try writeSetups(#"{"setups": [{"id": "x", "title": "X"}]}"#)).error,
                       "setups.json: missing \"speech\" in setup #1")
        let none = DictationSetup.loadCustom(from: noCustomSetups)
        XCTAssertTrue(none.setups.isEmpty && none.error == nil, "no file: nothing to report")
    }

    func testSettingsListCustomSetupsAndPickUpEdits() throws {
        let url = try writeSetups("""
            {"setups": [{"id": "try", "title": "Try", "speech": "apple", "polish": "apple", "prompt": "v1"}]}
            """)
        let defaults = makeDefaults(self)
        let settings = AppSettings(defaults: defaults, secrets: InMemorySecretStore(), customSetupsFile: url)
        XCTAssertEqual(settings.setups.map(\.title), ["On-device", "Cloud Flash", "Cloud Big", "Try"])
        settings.setup = settings.setups[3]
        XCTAssertEqual(AppSettings(defaults: defaults, secrets: InMemorySecretStore(), customSetupsFile: url).setup.id, "try",
                       "a custom choice is remembered")

        try #"{"setups": [{"id": "try", "title": "Try", "speech": "apple", "polish": "apple", "prompt": "v2"}]}"#
            .write(to: url, atomically: true, encoding: .utf8)
        settings.reloadSetups()
        XCTAssertEqual(settings.setup.prompt, "v2", "edits to the chosen setup apply")

        try "{}".write(to: url, atomically: true, encoding: .utf8)
        settings.reloadSetups()
        XCTAssertEqual(settings.setup, .onDevice, "a removed setup falls back to On-device")
        XCTAssertNotNil(settings.setupsError)
    }
}
