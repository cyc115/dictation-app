import XCTest
@testable import DictationKit

/// The echo guard: the on-device model sometimes writes its context (your terms) back instead of
/// what was said (1 of 25 real recordings, Nov 22). `SpeechContext.isEcho` spots it;
/// `LocalSpeechModel.transcribe` then transcribes the same audio again without the context.
@MainActor
final class SpeechEchoTests: XCTestCase {
    /// Invented terms in the measured case's shape: 12 words, one with a leading "the".
    private let twelve = SpeechContext(words: ["Alpha", "Beta One", "Gamma", "the Delta 5", "Epsilon", "Zeta", "Eta Prime",
                                               "Theta", "Iota", "Kappa Nine", "Lambda", "Mu"])

    // MARK: Detecting

    /// The measured shape: the terms in reverse order, full-width commas, one final 。, and one
    /// without its leading "the". With 11 terms too.
    func testTheMeasuredEchoIsCaught() {
        let reversed = twelve.words.reversed().map { $0 == "the Delta 5" ? "Delta 5" : $0 }
        XCTAssertTrue(twelve.isEcho(reversed.joined(separator: "，") + "。"))
        let eleven = SpeechContext(words: Array(twelve.words.dropLast()))
        XCTAssertTrue(eleven.isEcho(eleven.words.reversed().joined(separator: "，") + "。"))
    }

    func testAsciiCommasAndOneStrayPiece() {
        XCTAssertTrue(twelve.isEcho("Alpha, Beta One, Gamma, Epsilon."))
        XCTAssertTrue(twelve.isEcho("alpha, beta one, gamma, theta, iota, something else"), "5 of 6 pieces: 83%")
        XCTAssertTrue(twelve.isEcho("Alpha；Beta One、Gamma\nZeta!"), "the other separators, any case, a trailing !")
        XCTAssertTrue(twelve.isEcho("Alpha\r\nGamma\r\nZeta"), "Windows line ends")
        XCTAssertTrue(twelve.isEcho("The Alpha, the Gamma, a Zeta"), "an article on the transcript's side")
        XCTAssertTrue(SpeechContext(words: ["Smith, Inc.", "Alpha", "Gamma"]).isEcho("Gamma, Alpha, Smith, Inc."), "a term with a comma in it")
        XCTAssertTrue(SpeechContext(words: ["克劳德", "心率变异", "番茄钟"]).isEcho("番茄钟、心率变异、克劳德。"), "Chinese terms")
    }

    func testWhatIsNotAnEcho() {
        XCTAssertFalse(twelve.isEcho("Can you ask Alpha to send the Gamma report to Beta One today?"), "a sentence with terms in it")
        XCTAssertFalse(twelve.isEcho("Alpha, the new one, needs Gamma, and also a review by Friday."), "a minority of pieces are terms")
        XCTAssertFalse(twelve.isEcho("Alpha, Gamma."), "two terms alone stay as heard")
        XCTAssertFalse(twelve.isEcho(""))
        XCTAssertFalse(SpeechContext.none.isEcho("Alpha, Gamma, Zeta"), "no context, no echo")
        XCTAssertFalse(SpeechContext(words: ["Alpha", "Gamma"]).isEcho("Alpha, Gamma, Alpha"), "a 2-word context never")
        XCTAssertFalse(twelve.isEcho("Alpha, Gamma, Zeta, one, two"), "3 of 5 pieces: 60%")
    }

    // MARK: Transcribing again

    private final class Lines {
        var all: [(level: CloudLog.Level, text: String)] = []
        lazy var log = CloudLog { [weak self] level, text in self?.all.append((level, text)) }
    }

    private func model(_ answers: [Result<String, Error>]) -> (LocalSpeechModel, FakeSpeechRuntime, Lines, () -> Int) {
        let runtime = FakeSpeechRuntime()
        runtime.directory = URL(fileURLWithPath: "/tmp/fake-model")
        runtime.answers = answers
        let model = LocalSpeechModel(repo: "test/qwen", runtime: runtime)
        model.onBattery = { false }
        let lines = Lines()
        model.log = lines.log
        var decoded = 0
        model.readSamples = { _ in decoded += 1; return [Float](repeating: 0.1, count: 32_000) }
        return (model, runtime, lines, { decoded })
    }

    private var echo: String { twelve.words.reversed().joined(separator: "，") + "。" }
    private let said = "我们明天把 Alpha 的 demo 发给 Gamma 看一下。"

    func testAnEchoIsTranscribedAgainWithoutTheContext() async throws {
        let (model, runtime, lines, decoded) = model([.success(echo), .success(said)])
        let result = try await model.transcribe(wav: URL(fileURLWithPath: "/tmp/clip.wav"), context: twelve)
        XCTAssertEqual(result.text, said)
        XCTAssertTrue(result.echoed)
        XCTAssertEqual(runtime.contexts, [twelve.prompt, ""], "once with the context, once without")
        XCTAssertEqual(decoded(), 1, "the samples are read once")
        XCTAssertEqual(lines.all.map(\.level), [.notice])
        let line = try XCTUnwrap(lines.all.first?.text)
        XCTAssertTrue(line.contains("12 words") && line.contains("again"), line)
        for word in twelve.words + [said] { XCTAssertFalse(line.contains(word), "never the terms or the transcript: \(line)") }
    }

    func testAnswersThatAreNotEchoesAreAskedOnce() async throws {
        let (model, runtime, lines, _) = model([.success(said)])
        let result = try await model.transcribe(wav: URL(fileURLWithPath: "/tmp/clip.wav"), context: twelve)
        XCTAssertEqual(result.text, said)
        XCTAssertFalse(result.echoed)
        XCTAssertEqual(runtime.contexts.count, 1)
        XCTAssertTrue(lines.all.isEmpty)

        // With the hint off there's no context, so nothing can be an echo of it.
        let (plain, plainRuntime, _, _) = self.model([.success(echo)])
        let off = try await plain.transcribe(wav: URL(fileURLWithPath: "/tmp/clip.wav"))
        XCTAssertEqual(off.text, echo)
        XCTAssertFalse(off.echoed)
        XCTAssertEqual(plainRuntime.contexts, [""])
    }

    /// Never loops: one more pass, without the context, and its answer stands even if it's the same list.
    func testOneRetryOnly() async throws {
        let (model, runtime, _, _) = model([.success(echo), .success(echo)])
        let result = try await model.transcribe(wav: URL(fileURLWithPath: "/tmp/clip.wav"), context: twelve)
        XCTAssertEqual(result.text, echo)
        XCTAssertTrue(result.echoed)
        XCTAssertEqual(runtime.contexts.count, 2)
    }

    func testAFailedRetryFailsTheDictationNotDeliversTheEcho() async throws {
        let (model, _, _, _) = model([.success(echo), .failure(LocalSpeechError.notLoaded)])
        do {
            _ = try await model.transcribe(wav: URL(fileURLWithPath: "/tmp/clip.wav"), context: twelve)
            XCTFail("the echo must not be delivered")
        } catch {
            XCTAssertEqual(error.localizedDescription, LocalSpeechError.notLoaded.localizedDescription)
        }
    }

    // MARK: Through the dictation's own path

    func testLocalEngineDeliversTheSecondPass() throws {
        let (model, runtime, lines, _) = model([.success(echo), .success(said)])
        model.readSamples = LocalSpeechModel.samples  // the recording the engine really wrote
        let engine = LocalEngine(model: model)
        engine.context = twelve
        XCTAssertTrue(engine.beginRecording())
        feedSpeech(engine)
        let result = stopAndWait(engine, timeout: 5)
        XCTAssertEqual(result.text, said)
        XCTAssertNil(result.error)
        XCTAssertTrue(engine.lastEchoed)
        XCTAssertEqual(runtime.contexts, [twelve.prompt, ""])
        XCTAssertEqual(lines.all.count, 1)
        XCTAssertEqual(engine.lastAnswer, ModelAnswer(main: "local:test/qwen"))

        // The next dictation starts clean, even one that fails before it could say.
        runtime.answers = [.failure(LocalSpeechError.notLoaded)]
        XCTAssertTrue(engine.beginRecording())
        feedSpeech(engine)
        XCTAssertNotNil(stopAndWait(engine, timeout: 5).error)
        XCTAssertFalse(engine.lastEchoed)
    }

    func testLocalEngineFailsWhenTheRetryFails() throws {
        let (model, _, _, _) = model([.success(echo), .failure(LocalSpeechError.notLoaded)])
        model.readSamples = LocalSpeechModel.samples
        let engine = LocalEngine(model: model)
        engine.context = twelve
        XCTAssertTrue(engine.beginRecording())
        feedSpeech(engine)
        let result = stopAndWait(engine, timeout: 5)
        XCTAssertNil(result.text, "never the echo")
        XCTAssertEqual(result.error, LocalSpeechError.notLoaded.localizedDescription)
        XCTAssertEqual(engine.lastAnswer?.failed, true)
        XCTAssertTrue(engine.lastEchoed, "the echo happened, though the second pass failed")
    }
}
