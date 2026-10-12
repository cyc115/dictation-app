import AVFoundation
import Foundation

// MARK: - Engine interface

/// A dictation backend: records while active, then produces the transcript.
protocol DictationEngine: AnyObject {
    /// True when text only arrives after you stop (upload + transcribe), so the UI shows a wait state.
    var isBatch: Bool { get }
    /// Set while "Keep recordings" is on: finished recordings go here instead of being deleted.
    var archive: RecordingArchive? { get set }
    /// Set with `archive`, before each dictation: the polish half of its JSON.
    var note: RecordingNote? { get set }
    func start(inputUID: String, onLevel: @escaping (Float) -> Void,
               onUtterance: ((String) -> Void)?, onError: @escaping (String) -> Void)
    /// Ends recording; exactly one of `completion` / `failure` is called on the main queue.
    func stop(completion: @escaping (String) -> Void, failure: @escaping (String) -> Void)
    func cancel()
}

extension SpeechEngine: DictationEngine {
    var isBatch: Bool { false }
    func stop(completion: @escaping (String) -> Void, failure: @escaping (String) -> Void) {
        if mic.heardOnlySilence {
            cancel()
            return failure(MicCapture.silenceMessage)
        }
        stop(completion: completion)
    }
}

// MARK: - WAV recording

/// Converts mic buffers (any rate/channels) to 16 kHz mono 16-bit WAV, the format cloud
/// transcription expects (Meta's endpoint rejects compressed audio).
final class WAVRecorder {
    static let sampleRate: Double = 16_000
    let url: URL
    private let file: AVAudioFile
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: WAVRecorder.sampleRate,
                                             channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private(set) var framesWritten: AVAudioFramePosition = 0
    private var finished = false
    /// append() runs on the audio thread, finish() on main.
    private let lock = NSLock()

    init(url: URL) throws {
        self.url = url
        file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    var duration: TimeInterval { Double(framesWritten) / Self.sampleRate }

    /// Closes the file so its header declares the real length. Must happen before the file is
    /// read: until then the header says 0 bytes of audio, which strict providers (Qwen) reject.
    func finish() {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        file.close()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
        }
        guard let converter = converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * Self.sampleRate / buffer.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0 else { return }
        try? file.write(from: out)
        framesWritten += AVAudioFramePosition(out.frameLength)
    }
}

// MARK: - OpenRouter

/// Uploads a finished WAV for transcription (OpenRouterClient; a fake in tests).
protocol TranscriptionClient {
    @discardableResult
    func transcribe(wav: URL, model: String, apiKey: String,
                    completion: @escaping (Result<String, Error>) -> Void) -> URLSessionTask?
}

/// Minimal client for OpenRouter's speech-to-text endpoint (multipart WAV upload).
final class OpenRouterClient: TranscriptionClient {
    static let endpoint = URL(string: "https://openrouter.ai/api/v1/audio/transcriptions")!
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    @discardableResult
    func transcribe(wav: URL, model: String, apiKey: String,
                    completion: @escaping (Result<String, Error>) -> Void) -> URLSessionTask? {
        guard let audio = try? Data(contentsOf: wav) else {
            completion(.failure(TranscriptionError.message("Couldn't read the recording.")))
            return nil
        }
        let (body, boundary) = Self.multipart(model: model, audio: audio, filename: wav.lastPathComponent)
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("DictationApp", forHTTPHeaderField: "X-Title")
        let task = session.uploadTask(with: request, from: body) { data, response, error in
            let result: Result<String, Error>
            if let error = error {
                result = .failure(TranscriptionError.message("Network error: \(error.localizedDescription)"))
            } else {
                result = Self.parse(data: data ?? Data(), status: (response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            DispatchQueue.main.async { completion(result) }
        }
        task.resume()
        return task
    }

    static func multipart(model: String, audio: Data, filename: String) -> (Data, String) {
        let boundary = "DictationApp-\(UUID().uuidString)"
        var body = Data()
        func add(_ s: String) { body.append(Data(s.utf8)) }
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(model)\r\n")
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: audio/wav\r\n\r\n")
        body.append(audio)
        add("\r\n--\(boundary)--\r\n")
        return (body, boundary)
    }

    static func parse(data: Data, status: Int) -> Result<String, Error> {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if (200..<300).contains(status), let text = json?["text"] as? String {
            return .success(cleanup(text))
        }
        let apiMessage = (json?["error"] as? [String: Any])?["message"] as? String
        switch status {
        case 401: return .failure(TranscriptionError.message("The cloud service rejected the API key — check it in Settings."))
        case 402: return .failure(TranscriptionError.message("The cloud account is out of credits."))
        case 403: return .failure(TranscriptionError.message("The cloud account needs to be set up before this model can be used."))
        default: return .failure(TranscriptionError.message(apiMessage ?? "Transcription failed (HTTP \(status))."))
        }
    }

    /// Tidies model quirks, e.g. "meeting??" / "meeting?." → "meeting?".
    static func cleanup(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: #"([?!？！])[.。]"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"([.?!。？！])\1+"#, with: "$1", options: .regularExpression)
        return s
    }
}

enum TranscriptionError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

// MARK: - Cloud engine

/// Records the mic to WAV while dictating, then uploads it for transcription when you stop.
final class CloudEngine: DictationEngine {
    var isBatch: Bool { true }
    var modelID = DictationSetup.cloudBig.openRouterID!
    var apiKey = ""
    var client: TranscriptionClient = OpenRouterClient()
    /// Set while "Keep recordings" is on: finished recordings go here instead of being deleted.
    var archive: RecordingArchive?
    /// Set with `archive`, before each dictation: the polish half of its JSON.
    var note: RecordingNote?
    /// "Backup model when slow": the model also asked when `modelID` is slow, after `backupWait`
    /// (the setup's `backup` / `backupWait`); nil asks only `modelID`.
    var backupModelID: String?
    var backupWait: TimeInterval = 2
    /// When to ask the backup; the app shares one, so a slow spell carries over between dictations.
    var backup = AdaptiveBackup()
    /// The model whose transcript the last dictation used (the backup, if it answered first).
    private(set) var lastAnsweredBy: String?

    let mic = MicCapture()
    private var recording: DictationRecording?
    /// The stopped dictation being uploaded (deleted or kept when its upload finishes).
    private(set) var uploading: DictationRecording?
    private var race: UploadRace?
    private let lock = NSLock()

    /// Set up for `setup`'s speech model as the app runs it; `backupWhenSlow` is the "Backup model
    /// when slow" setting.
    func use(_ setup: DictationSetup, apiKey: String, backupWhenSlow: Bool) {
        modelID = setup.openRouterID ?? modelID
        backupModelID = backupWhenSlow ? setup.backup : nil
        backupWait = setup.backupWait
        self.apiKey = apiKey
    }

    /// Starts a new recording file. Called by `start`; tests call it directly with `record(_:)`
    /// to run the real stop/upload path without a microphone.
    func beginRecording() -> Bool {
        guard let recording = DictationRecording(archive: archive, note: note) else { return false }
        lock.lock(); self.recording = recording; lock.unlock()
        return true
    }

    /// Appends audio to the current recording (from the mic tap's thread, or a test).
    func record(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); recording?.append(buffer); lock.unlock()
    }

    func start(inputUID: String, onLevel: @escaping (Float) -> Void,
               onUtterance: ((String) -> Void)?, onError: @escaping (String) -> Void) {
        guard beginRecording() else { return onError("Couldn't create a recording file.") }
        mic.start(inputUID: inputUID, onBuffer: { [weak self] in self?.record($0) }, onLevel: onLevel, onError: onError)
    }

    func stop(completion: @escaping (String) -> Void, failure: @escaping (String) -> Void) {
        mic.stop()
        lock.lock(); let recording = self.recording; self.recording = nil; lock.unlock()
        if mic.heardOnlySilence {  // don't upload it: models make up text from silence
            recording?.discard()
            return failure(MicCapture.silenceMessage)
        }
        guard let recording, recording.isSpeech else {
            recording?.discard()
            return completion("")  // too short to be speech
        }
        recording.finish()
        let url = recording.url
        let info = RecordingInfo(date: Date(), model: "openrouter:\(modelID)", transcript: "", seconds: recording.duration)
        lastAnsweredBy = nil
        uploading = recording
        let main = modelID, wait = backupWait, policy = backup, backupModel = backupModelID
        race = UploadRace(wav: url, apiKey: apiKey, client: client, main: main,
                          backup: backupModel.map { policy.plan(for: main, backup: $0, wait: wait) },
                          judgeMain: backupModel.map { _ in (wait, { onTime in policy.learn(main, onTime: onTime) }) }) { [weak self] report in
            var heard = info
            switch report.outcome {
            case .text(let text, let model):
                heard.transcript = text
                heard.model = "openrouter:\(model)"
                self?.lastAnsweredBy = model
                completion(text)
            case .failed(let message):
                heard.error = message
                failure(message)
            }
            // After the text is delivered, so keeping it adds nothing to your wait. Failed uploads
            // are kept too: they're the cases a benchmark most needs.
            recording.done(heard)
            if self?.uploading === recording { self?.uploading = nil }
        }
        race?.start()
    }

    /// Gives up on the upload in flight and deletes its recording (a benchmark trial that timed out).
    /// Not part of `cancel()`: cancelling a new dictation must not stop the last one's upload.
    func cancelUpload() {
        race?.cancel()
        race = nil
        uploading?.discard()
        uploading = nil
    }

    func cancel() {
        mic.stop()
        lock.lock(); let recording = self.recording; self.recording = nil; lock.unlock()
        recording?.discard()
    }
}

// MARK: - Backup model

/// On by default (Settings → Model → "Backup model when slow"); off asks the chosen model only. Cloud Flash usually answers in
/// about a second, but in slow spells lasting minutes it takes 3–50 s (bench/results/latency/); Cloud
/// Big's tail reaches 7 s. This also asks the setup's faster backup (`DictationSetup.backup`:
/// a smaller sibling for Cloud Flash, Cloud Flash for Cloud Big); the first answer wins.
///  - Normally the backup is asked only once the main model hasn't answered within its wait
///    (`DictationSetup.backupWait`), or failed.
///  - After the main model was late, both are asked at once for `spell`: the next answers would
///    likely be late too. The main model answering on time ends the spell early.
///  - Late or on time is the main model's own answer within the wait, whoever won: the backup is
///    faster, so judging by the winner kept a spell going for as long as the backup kept winning
///    (43% of real dictations went to the less accurate backup).
/// The backup is less accurate on mixed Chinese/English with technical terms (85% vs 90%, bench/).
/// The app keeps one instance, so a slow spell carries over between dictations.
final class AdaptiveBackup {
    var spell: TimeInterval = 5 * 60
    private let clock: () -> TimeInterval
    /// When each main model (OpenRouter id) was last late.
    private var lateAt: [String: TimeInterval] = [:]

    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) { self.clock = clock }

    /// When to ask `backup` in a dictation with `model`: after `wait`, or at once in a slow spell.
    func plan(for model: String, backup: String, wait: TimeInterval) -> UploadRace.Backup {
        UploadRace.Backup(model: backup, delay: inSlowSpell(model) ? 0 : wait)
    }

    func inSlowSpell(_ model: String) -> Bool {
        guard let at = lateAt[model] else { return false }
        return clock() - at < spell
    }

    /// Learns whether `model` answered within its wait (`UploadRace`'s `judgeMain`); failing is late.
    func learn(_ model: String, onTime: Bool) {
        lateAt[model] = onTime ? nil : clock()  // on time: back to normal; late: start (or extend) a spell
    }
}

/// One dictation's upload: the main model, plus an optional backup asked after `Backup.delay` (or
/// as soon as the main model fails). The first transcript wins and the other request is cancelled;
/// if every model fails, the first error is reported. With `judgeMain`, it also says whether the
/// main model answered within that wait: a main request the backup beat keeps going until then
/// (both were already sent, so it costs nothing). Runs on the main queue (clients call back there),
/// and keeps itself alive until it's done.
final class UploadRace {
    struct Backup: Equatable {
        let model: String
        let delay: TimeInterval
    }

    enum Outcome {
        case text(String, model: String)
        case failed(String)
    }

    struct Report {
        let outcome: Outcome
        /// Upload start → outcome.
        let seconds: TimeInterval
        var answeredBy: String? {
            if case .text(_, let model) = outcome { return model }
            return nil
        }
    }

    private let wav: URL
    private let apiKey: String
    private let client: TranscriptionClient
    private let main: String
    private let backup: Backup?
    private let judgeMain: (wait: TimeInterval, verdict: (Bool) -> Void)?
    private let onDone: (Report) -> Void
    private let clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private var startedAt: TimeInterval = 0
    private var tasks: [String: URLSessionTask] = [:]
    private var pending = 0
    private var backupAsked = false
    private var firstError: String?
    private var finished = false
    private var judged = false
    private var timer: DispatchWorkItem?
    private var judgeTimer: DispatchWorkItem?

    init(wav: URL, apiKey: String, client: TranscriptionClient, main: String, backup: Backup?,
         judgeMain: (wait: TimeInterval, verdict: (Bool) -> Void)? = nil, onDone: @escaping (Report) -> Void) {
        self.wav = wav
        self.apiKey = apiKey
        self.client = client
        self.main = main
        self.backup = backup
        self.judgeMain = judgeMain
        self.onDone = onDone
        judged = judgeMain == nil
    }

    func start() {
        startedAt = clock()
        ask(main)
        if let judgeMain {
            let late = DispatchWorkItem { [self] in judge(onTime: false) }
            judgeTimer = late
            DispatchQueue.main.asyncAfter(deadline: .now() + judgeMain.wait, execute: late)
        }
        guard let backup = backup else { return }
        guard backup.delay > 0 else { return askBackup() }
        let timer = DispatchWorkItem { [self] in askBackup() }
        self.timer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + backup.delay, execute: timer)
    }

    private func askBackup() {
        guard let backup = backup, !backupAsked, !finished else { return }
        backupAsked = true
        timer?.cancel()
        ask(backup.model)
    }

    private func ask(_ model: String) {
        pending += 1
        let task = client.transcribe(wav: wav, model: model, apiKey: apiKey) { [self] result in
            pending -= 1
            if model == main, case .success = result { judge(onTime: true) }
            if model == main, case .failure = result { judge(onTime: false) }
            guard !finished else { return }  // the loser, or cancelled after the winner answered
            switch result {
            case .success(let text):
                finish(.text(text, model: model))
            case .failure(let error):
                firstError = firstError ?? error.localizedDescription
                if backup != nil && !backupAsked {
                    askBackup()  // don't wait out the delay after a failure
                } else if pending == 0 {
                    finish(.failed(firstError ?? "Transcription failed."))
                }
            }
        }
        if let task = task { tasks[model] = task }
    }

    /// Stops both requests without reporting an outcome.
    func cancel() {
        guard !finished else { return }
        finished = true
        timer?.cancel()
        judgeTimer?.cancel()
        tasks.values.forEach { $0.cancel() }
    }

    /// The main model's verdict, once: the first of its answer, its failure, or the wait running out.
    private func judge(onTime: Bool) {
        guard !judged else { return }
        judged = true
        judgeTimer?.cancel()
        judgeMain?.verdict(onTime)
        if finished { tasks[main]?.cancel() }  // kept only to judge it
    }

    private func finish(_ outcome: Outcome) {
        finished = true
        timer?.cancel()
        // Stops the other request (a finished task ignores it); a main request still being judged runs on.
        for (model, task) in tasks where model != main || judged { task.cancel() }
        onDone(Report(outcome: outcome, seconds: clock() - startedAt))
    }
}
