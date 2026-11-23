import XCTest
@testable import DictationKit

/// What a cloud dictation sends and keeps, pinned through the real `CloudEngine.stop()` path with a
/// stubbed network: the transcription request byte for byte (model, `provider`, the rest), for the
/// main model and the backup, with and without hosts; and every model string it stores or shows
/// (`ModelAnswer`, the kept recording's model, the client's log lines). The model id and its hosts
/// travel apart inside the app; none of this may change when they do.
final class SpeechRouteTests: XCTestCase {
    /// One request as OpenRouter gets it, with the multipart boundary and the WAV's file name made
    /// stable (`B`, `F`) and the audio itself checked apart.
    struct Sent: Equatable {
        var url: String
        var method: String
        var headers: [String: String]
        /// The body before the audio, and after it.
        var head: String
        var tail: String
    }

    private func sent(_ request: URLRequest) throws -> Sent {
        var headers = request.allHTTPHeaderFields ?? [:]
        let type = try XCTUnwrap(headers["Content-Type"])
        let boundary = try XCTUnwrap(type.components(separatedBy: "boundary=").last)
        XCTAssertTrue(boundary.hasPrefix("DictationApp-"), boundary)
        headers["Content-Type"] = type.replacingOccurrences(of: boundary, with: "B")
        let body = try XCTUnwrap(rawBody(request))
        // URLSession adds the length of the body it uploads; it must be that body's.
        XCTAssertEqual(headers.removeValue(forKey: "Content-Length"), String(body.count))
        let riff = try XCTUnwrap(body.range(of: Data("RIFF".utf8)), "the WAV is in the body")
        let end = try XCTUnwrap(body.range(of: Data("\r\n--\(boundary)--\r\n".utf8), options: .backwards))
        XCTAssertGreaterThan(end.lowerBound - riff.lowerBound, 44, "audio after the WAV header")
        var head = String(decoding: body[..<riff.lowerBound], as: UTF8.self).replacingOccurrences(of: boundary, with: "B")
        head = head.replacingOccurrences(of: #"filename="[^"]+""#, with: #"filename="F""#, options: .regularExpression)
        let tail = String(decoding: body[end.lowerBound...], as: UTF8.self).replacingOccurrences(of: boundary, with: "B")
        return Sent(url: request.url?.absoluteString ?? "", method: request.httpMethod ?? "", headers: headers, head: head, tail: tail)
    }

    /// A model and its hosts, as the race takes them.
    static func route(_ owner: String, _ name: String, _ hosts: String?) -> SpeechRoute { SpeechRoute(id: "\(owner)/\(name)", hosts: hosts) }

    private func rawBody(_ request: URLRequest) -> Data? {
        guard let stream = request.httpBodyStream else { return request.httpBody }
        stream.open()
        defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        while stream.hasBytesAvailable, case let n = stream.read(&buffer, maxLength: buffer.count), n > 0 { data.append(buffer, count: n) }
        return data
    }

    private func expected(model: String, provider: String?) -> Sent {
        let field = { (name: String, value: String) in "--B\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n" }
        return Sent(url: "https://openrouter.ai/api/v1/audio/transcriptions", method: "POST",
                    headers: ["Authorization": "Bearer k", "Content-Type": "multipart/form-data; boundary=B",
                              "HTTP-Referer": "http://dictation-app.mac/", "X-OpenRouter-Title": "DictationApp", "X-Title": "DictationApp",
                              "X-OpenRouter-App-Visibility": "hidden"],
                    head: field("model", model) + (provider.map { field("provider", $0) } ?? "")
                        + "--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"F\"\r\nContent-Type: audio/wav\r\n\r\n",
                    tail: "\r\n--B--\r\n")
    }

    private func setup(speech: String, backup: String?) throws -> DictationSetup {
        let backupField = backup.map { #", "backup": "\#($0)""# } ?? ""
        let json = #"{"id": "custom", "title": "Custom", "speech": "\#(speech)"\#(backupField), "polish": "apple", "prompt": "v3"}"#
        return try JSONFile.decoder.decode(DictationSetup.self, from: Data(json.utf8))
    }

    /// A dictation through `CloudEngine` set up by `use(_:)`, as the app does: `answer` says, by the
    /// request's model field, what OpenRouter answers. The requests, the result, the engine, the kept
    /// recording's info and the client's log lines (seconds masked).
    private func dictate(_ setup: DictationSetup, backup: Bool,
                         answer: @escaping (String) -> (Int, String)) throws -> (sent: [Sent], text: String?, error: String?, engine: CloudEngine,
                                                                                kept: RecordingInfo?, log: [String]) {
        let lines = CloudLogTests.Lines()
        StubURLProtocol.respond = { request in
            let body = String(decoding: self.rawBody(request) ?? Data(), as: UTF8.self)
            let model = body.components(separatedBy: "name=\"model\"\r\n\r\n").last?.components(separatedBy: "\r\n").first ?? ""
            return .success(answer(model))
        }
        let engine = CloudEngine()
        engine.client = OpenRouterClient(session: StubURLProtocol.session(), log: lines.log)
        engine.use(setup, apiKey: "k", backupWhenSlow: backup)
        engine.backup = AdaptiveBackup()
        let archive = RecordingArchive(directory: makeTempURL(self, "Recordings"))
        engine.archive = archive
        XCTAssertTrue(engine.beginRecording())
        feedSpeech(engine)
        let result = stopAndWait(engine, timeout: 5)
        waitUntil { archive.infos.count == 1 }
        let log = lines.all.map { "\($0.level): " + $0.text.replacingOccurrences(of: #"in \d+(\.\d+)? s"#, with: "in T", options: .regularExpression) }
        return (try StubURLProtocol.sent.map(sent), result.text, result.error, engine, archive.infos.first, log)
    }

    // MARK: Main model

    func testCloudFlashAsksItsModelOnItsPinnedHost() throws {
        let r = try dictate(.cloudFlash, backup: false) { _ in (200, #"{"text":"hello"}"#) }
        XCTAssertEqual(r.text, "hello")
        XCTAssertEqual(r.sent, [expected(model: "qwen/qwen3-asr-1.7b", provider: #"{"allow_fallbacks":false,"order":["PrimeIntellect"]}"#)])
        XCTAssertEqual(r.engine.lastAnswer, ModelAnswer(main: "qwen/qwen3-asr-1.7b@PrimeIntellect"))
        XCTAssertEqual(r.engine.lastAnsweredBy, "qwen/qwen3-asr-1.7b@PrimeIntellect")
        XCTAssertEqual(r.kept?.model, "openrouter:qwen/qwen3-asr-1.7b@PrimeIntellect")
        XCTAssertEqual(r.log, ["info: qwen/qwen3-asr-1.7b@PrimeIntellect: HTTP 200 in T"])
    }

    func testAModelWithoutHostsSendsNoProvider() throws {
        let r = try dictate(setup(speech: "openrouter:meta/muse-voice-transcribe-1.0", backup: nil), backup: true) { _ in (200, #"{"text":"hi"}"#) }
        XCTAssertEqual(r.sent, [expected(model: "meta/muse-voice-transcribe-1.0", provider: nil)])
        XCTAssertEqual(r.engine.lastAnswer, ModelAnswer(main: "meta/muse-voice-transcribe-1.0"))
        XCTAssertEqual(r.kept?.model, "openrouter:meta/muse-voice-transcribe-1.0")
        XCTAssertEqual(r.log, ["info: meta/muse-voice-transcribe-1.0: HTTP 200 in T"])
    }

    func testSeveralHostsAreAskedInOrder() throws {
        let r = try dictate(setup(speech: "openrouter:a/b@H1,H2", backup: nil), backup: false) { _ in (200, #"{"text":"hi"}"#) }
        XCTAssertEqual(r.sent, [expected(model: "a/b", provider: #"{"allow_fallbacks":false,"order":["H1","H2"]}"#)])
        XCTAssertEqual(r.engine.lastAnswer, ModelAnswer(main: "a/b@H1,H2"))
        XCTAssertEqual(r.kept?.model, "openrouter:a/b@H1,H2")
    }

    // MARK: Backup race

    /// The main model fails: the backup is asked at once; both requests, and what's kept, as today.
    func testCloudFlashsBackupIsAskedWhenItsModelFails() throws {
        let r = try dictate(.cloudFlash, backup: true) { model in
            model == "qwen/qwen3-asr-1.7b" ? (500, #"{"error":{"message":"down"}}"#) : (200, #"{"text":"from backup"}"#)
        }
        XCTAssertEqual(r.text, "from backup")
        XCTAssertEqual(r.sent, [expected(model: "qwen/qwen3-asr-1.7b", provider: #"{"allow_fallbacks":false,"order":["PrimeIntellect"]}"#),
                                expected(model: "mistralai/voxtral-mini-transcribe", provider: nil)])
        XCTAssertEqual(r.engine.lastAnswer, ModelAnswer(main: "qwen/qwen3-asr-1.7b@PrimeIntellect", backup: "mistralai/voxtral-mini-transcribe",
                                                        byBackup: true, failures: [.init(model: "qwen/qwen3-asr-1.7b@PrimeIntellect", message: "down")]))
        XCTAssertEqual(r.engine.lastAnsweredBy, "mistralai/voxtral-mini-transcribe")
        XCTAssertEqual(r.kept?.model, "openrouter:mistralai/voxtral-mini-transcribe")
        XCTAssertEqual(r.log, ["error: qwen/qwen3-asr-1.7b@PrimeIntellect: HTTP 500 in T: down",
                               "info: mistralai/voxtral-mini-transcribe: HTTP 200 in T"])
    }

    /// A custom setup's backup with its own hosts: they're sent as the backup's `provider`.
    func testABackupWithHostsIsAskedOnThem() throws {
        let r = try dictate(setup(speech: "openrouter:a/b@H1,H2", backup: "c/d@H3"), backup: true) { model in
            model == "a/b" ? (500, #"{"error":{"message":"down"}}"#) : (200, #"{"text":"ok"}"#)
        }
        XCTAssertEqual(r.sent, [expected(model: "a/b", provider: #"{"allow_fallbacks":false,"order":["H1","H2"]}"#),
                                expected(model: "c/d", provider: #"{"allow_fallbacks":false,"order":["H3"]}"#)])
        XCTAssertEqual(r.engine.lastAnswer, ModelAnswer(main: "a/b@H1,H2", backup: "c/d@H3", byBackup: true,
                                                        failures: [.init(model: "a/b@H1,H2", message: "down")]))
        XCTAssertEqual(r.kept?.model, "openrouter:c/d@H3")
        XCTAssertEqual(r.log, ["error: a/b@H1,H2: HTTP 500 in T: down", "info: c/d@H3: HTTP 200 in T"])
    }

    /// Odd but valid setup strings, sent and named as before: "a/b@" names no host; "c/d@X@Y" pins "X@Y".
    func testEdgeSetupStringsAreSentAndNamedAsBefore() throws {
        let r = try dictate(setup(speech: "openrouter:a/b@", backup: "c/d@X@Y"), backup: true) { model in
            model == "a/b" ? (500, #"{"error":{"message":"down"}}"#) : (200, #"{"text":"ok"}"#)
        }
        XCTAssertEqual(r.sent, [expected(model: "a/b", provider: nil), expected(model: "c/d", provider: #"{"allow_fallbacks":false,"order":["X@Y"]}"#)])
        XCTAssertEqual(r.engine.lastAnswer, ModelAnswer(main: "a/b@", backup: "c/d@X@Y", byBackup: true, failures: [.init(model: "a/b@", message: "down")]))
        XCTAssertEqual(r.kept?.model, "openrouter:c/d@X@Y")
    }

    /// Every model failing keeps both failures under their stored names.
    func testEveryModelFailingKeepsTheirNames() throws {
        let r = try dictate(setup(speech: "openrouter:a/b@H1", backup: "c/d"), backup: true) { _ in (500, #"{"error":{"message":"down"}}"#) }
        XCTAssertEqual(r.error, "down")
        XCTAssertEqual(r.engine.lastAnswer, ModelAnswer(main: "a/b@H1", backup: "c/d",
                                                        failures: [.init(model: "a/b@H1", message: "down"), .init(model: "c/d", message: "down")],
                                                        failed: true))
        XCTAssertEqual(r.kept?.model, "openrouter:a/b@H1", "a failed recording keeps the main model's name")
    }

    /// The race's own lines name the models as they're stored.
    func testTheRaceLogsTheModelsByTheirStoredNames() {
        let lines = CloudLogTests.Lines()
        let client = FakeTranscriptionClient()
        client.scripts["a/b@H1"] = .init(delay: 0.3, result: FakeTranscriptionClient.text("late"))
        client.scripts["c/d@H3"] = .init(delay: 0, result: FakeTranscriptionClient.text("ok"))
        let wav = makeTempURL(self, "a.wav")
        try? Data([0]).write(to: wav)
        var report: UploadRace.Report?
        UploadRace(wav: wav, apiKey: "k", client: client, main: Self.route("a", "b", "H1"),
                   backup: .init(model: Self.route("c", "d", "H3"), delay: 0.05), log: lines.log) { report = $0 }.start()
        waitUntil { report != nil }
        XCTAssertEqual(lines.all.map(\.text).map { $0.replacingOccurrences(of: #"in \d+(\.\d+)? s"#, with: "in T", options: .regularExpression) },
                       ["asking backup c/d@H3: a/b@H1 hasn't answered in T", "transcript from c/d@H3 in T (backup)"])
        XCTAssertEqual(client.asked.map(\.model), ["a/b@H1", "c/d@H3"])
    }

    // MARK: The route itself

    /// A setup's "<id>[@Provider,…]" read once into its parts; `name` is the one string form, as written.
    func testARouteIsReadFromItsSetupStringAndNamedAsWritten() {
        XCTAssertEqual(SpeechRoute(stored: "a/b@H1,H2"), SpeechRoute(id: "a/b", hosts: "H1,H2"))
        XCTAssertEqual(SpeechRoute(stored: "a/b"), SpeechRoute(id: "a/b"))
        for stored in ["a/b@H1,H2", "a/b", "a/b@", "a/b@X@Y"] {
            XCTAssertEqual(SpeechRoute(stored: stored).name, stored)
            XCTAssertEqual(ModelSpec("openrouter:" + stored)?.description, "openrouter:" + stored, "setups read and shown as written")
        }
        XCTAssertNil(SpeechRoute(stored: "a/b@").pinned, "\"a/b@\" names no host: no provider sent, as before")
        XCTAssertEqual(SpeechRoute(stored: "a/b@X@Y").pinned, "X@Y")
        XCTAssertEqual(DictationSetup.cloudFlash.backupRoute, SpeechRoute(id: "mistralai/voxtral-mini-transcribe"))
    }
}
