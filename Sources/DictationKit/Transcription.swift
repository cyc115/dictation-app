import AVFoundation
import Foundation
import Security

/// Recognition language for the local (Apple) model.
enum LocalLanguage: String, CaseIterable {
    case english = "en-US"
    case mandarin = "zh-CN"

    var title: String {
        switch self {
        case .english: return "English"
        case .mandarin: return "中文（普通话）"
        }
    }
}

// MARK: - Engine interface

/// A dictation backend: records while active, then produces the transcript.
protocol DictationEngine: AnyObject {
    /// True when text only arrives after you stop (upload + transcribe), so the UI shows a wait state.
    var isBatch: Bool { get }
    func start(inputUID: String, onLevel: @escaping (Float) -> Void,
               onUtterance: ((String) -> Void)?, onError: @escaping (String) -> Void)
    /// Ends recording; exactly one of `completion` / `failure` is called on the main queue.
    func stop(completion: @escaping (String) -> Void, failure: @escaping (String) -> Void)
    func cancel()
}

extension SpeechEngine: DictationEngine {
    var isBatch: Bool { false }
    func stop(completion: @escaping (String) -> Void, failure: @escaping (String) -> Void) {
        stop(completion: completion)
    }
}

// MARK: - Secrets

protocol SecretStore: AnyObject {
    func get(_ account: String) -> String?
    func set(_ value: String?, for account: String)
    /// Whether a value is saved, without reading it (reading can ask for the Keychain password).
    func has(_ account: String) -> Bool
}

extension SecretStore {
    func has(_ account: String) -> Bool { !(get(account) ?? "").isEmpty }
}

/// API keys live in the macOS Keychain, never in UserDefaults.
///
/// Items are written with a decrypt ACL that doesn't pin the app's cdhash. Without that,
/// macOS ties the item to the exact build (apps with no Apple team ID get a per-cdhash
/// partition), so every rebuild asked for the login password again. Our own signed app
/// reads silently across rebuilds; other apps and the `security` CLI are still prompted.
final class KeychainStore: SecretStore {
    private let service: String
    /// Marks items written with the rebuild-proof ACL, so older items get rewritten once.
    static let aclMarker = "acl:v2"

    init(service: String = "com.mikechen.DictationApp") { self.service = service }

    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func get(_ account: String) -> String? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let attrs = item as? [String: Any], let data = attrs[kSecValueData as String] as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        if attrs[kSecAttrComment as String] as? String != Self.aclMarker { set(value, for: account) }
        return value
    }

    /// Attributes only: no decrypt, so no Keychain password prompt (unlike `get`).
    func has(_ account: String) -> Bool {
        var query = base(account)
        query[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func comment(_ account: String) -> String? {
        var query = base(account)
        query[kSecReturnAttributes as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return (item as? [String: Any])?[kSecAttrComment as String] as? String
    }

    func set(_ value: String?, for account: String) {
        SecItemDelete(base(account) as CFDictionary)
        guard let value = value, !value.isEmpty else { return }
        var add = base(account)
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrComment as String] = Self.aclMarker
        if let access = Self.rebuildProofAccess() { add[kSecAttrAccess as String] = access }
        SecItemAdd(add as CFDictionary, nil)
    }

    /// An access object whose decrypt ACL lists no specific apps (so no cdhash to go stale).
    private static func rebuildProofAccess() -> SecAccess? {
        var access: SecAccess?
        guard SecAccessCreate("DictationApp" as CFString, nil, &access) == errSecSuccess, let access else { return nil }
        for acl in (SecAccessCopyMatchingACLList(access, kSecACLAuthorizationDecrypt) as? [SecACL]) ?? [] {
            SecACLSetContents(acl, nil, "DictationApp" as CFString, [])
        }
        return access
    }
}

final class InMemorySecretStore: SecretStore {
    private var values: [String: String] = [:]
    func get(_ account: String) -> String? { values[account] }
    func set(_ value: String?, for account: String) { values[account] = (value?.isEmpty ?? true) ? nil : value }
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

struct TranscriptionResult: Equatable {
    let text: String
    let audioSeconds: Double?
    let cost: Double?
}

/// Uploads a finished WAV for transcription (OpenRouterClient; a fake in tests).
protocol TranscriptionClient {
    @discardableResult
    func transcribe(wav: URL, model: String, apiKey: String,
                    completion: @escaping (Result<TranscriptionResult, Error>) -> Void) -> URLSessionTask?
}

/// Minimal client for OpenRouter's speech-to-text endpoint (multipart WAV upload).
final class OpenRouterClient: TranscriptionClient {
    static let endpoint = URL(string: "https://openrouter.ai/api/v1/audio/transcriptions")!
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    @discardableResult
    func transcribe(wav: URL, model: String, apiKey: String,
                    completion: @escaping (Result<TranscriptionResult, Error>) -> Void) -> URLSessionTask? {
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
            let result: Result<TranscriptionResult, Error>
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

    static func parse(data: Data, status: Int) -> Result<TranscriptionResult, Error> {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if (200..<300).contains(status), let text = json?["text"] as? String {
            let usage = json?["usage"] as? [String: Any]
            return .success(TranscriptionResult(text: cleanup(text), audioSeconds: usage?["seconds"] as? Double,
                                                cost: usage?["cost"] as? Double))
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
    /// "Backup model when slow"; nil asks only `modelID`.
    var backup: AdaptiveBackup?
    /// The model `backup` also asks, and after how long (the setup's `backup` / `backupWait`).
    var backupModelID: String?
    var backupWait: TimeInterval = 2
    /// The model whose transcript the last dictation used (the backup, if it answered first).
    private(set) var lastAnsweredBy: String?

    let mic = MicCapture()
    private var recorder: WAVRecorder?
    private var race: UploadRace?
    private let lock = NSLock()

    /// Starts a new recording file. Called by `start`; tests call it directly with `record(_:)`
    /// to run the real stop/upload path without a microphone.
    func beginRecording() -> Bool {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-\(UUID().uuidString).wav")
        guard let recorder = try? WAVRecorder(url: url) else { return false }
        lock.lock(); self.recorder = recorder; lock.unlock()
        return true
    }

    /// Appends audio to the current recording (from the mic tap's thread, or a test).
    func record(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); recorder?.append(buffer); lock.unlock()
    }

    func start(inputUID: String, onLevel: @escaping (Float) -> Void,
               onUtterance: ((String) -> Void)?, onError: @escaping (String) -> Void) {
        guard beginRecording() else { return onError("Couldn't create a recording file.") }
        do {
            try mic.start(inputUID: inputUID, onBuffer: { [weak self] buffer in
                guard let self = self else { return }
                self.record(buffer)
                let level = SpeechEngine.level(of: buffer)
                DispatchQueue.main.async { onLevel(level) }
            }, onError: onError)
        } catch {
            onError("could not open microphone: \(error.localizedDescription)")
        }
    }

    func stop(completion: @escaping (String) -> Void, failure: @escaping (String) -> Void) {
        mic.stop()
        lock.lock(); let recorder = self.recorder; self.recorder = nil; lock.unlock()
        guard let recorder = recorder, recorder.duration >= 0.3 else {
            if let url = recorder?.url { try? FileManager.default.removeItem(at: url) }
            return completion("")  // too short to be speech
        }
        recorder.finish()
        let url = recorder.url
        let archive = self.archive, note = self.note
        let info = RecordingInfo(date: Date(), model: "openrouter:\(modelID)", transcript: "", seconds: recorder.duration)
        lastAnsweredBy = nil
        let main = modelID, wait = backupWait
        let backup = backupModelID == nil ? nil : self.backup
        race = UploadRace(wav: url, apiKey: apiKey, client: client, main: main,
                          backup: backupModelID.flatMap { backup?.plan(for: main, backup: $0, wait: wait) }) { [weak self] report in
            backup?.learn(main, wait: wait, from: report)
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
            if let archive = archive { archive.keep(wav: url, info: heard, note: note) } else { try? FileManager.default.removeItem(at: url) }
        }
        race?.start()
    }

    func cancel() {
        mic.stop()
        lock.lock(); let url = recorder?.url; recorder = nil; lock.unlock()
        if let url = url { try? FileManager.default.removeItem(at: url) }
    }
}

// MARK: - Backup model (experimental)

/// On by default (Settings → Speech model → "Backup model when slow"); off asks the chosen model only. Cloud Flash usually answers in
/// about a second, but in slow spells lasting minutes it takes 3–50 s (bench/results/latency/); Cloud
/// Big's tail reaches 7 s. This also asks the setup's faster backup (`DictationSetup.backup`:
/// a smaller sibling for Cloud Flash, Cloud Flash for Cloud Big); the first answer wins.
///  - Normally the backup is asked only once the main model hasn't answered within its wait
///    (`DictationSetup.backupWait`), or failed.
///  - After the main model was late, both are asked at once for `spell`: the next answers would
///    likely be late too. The main model answering on time ends the spell early.
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

    /// Learns from a finished upload whose main model was `model`.
    func learn(_ model: String, wait: TimeInterval, from report: UploadRace.Report) {
        if report.mainFailed || report.seconds > wait {
            lateAt[model] = clock()  // late: start (or extend) a slow spell
        } else if report.answeredBy == model {
            lateAt[model] = nil  // on time: back to normal
        }
        // Otherwise the backup answered within the wait, before the main model: nothing learned about it.
    }
}

/// One dictation's upload: the main model, plus an optional backup asked after `Backup.delay` (or
/// as soon as the main model fails). The first transcript wins and the other request is cancelled;
/// if every model fails, the first error is reported. Runs on the main queue (clients call back
/// there), and keeps itself alive until it's done.
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
        let mainFailed: Bool
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
    private let onDone: (Report) -> Void
    private let clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private var startedAt: TimeInterval = 0
    private var tasks: [URLSessionTask] = []
    private var pending = 0
    private var backupAsked = false
    private var mainFailed = false
    private var firstError: String?
    private var finished = false
    private var timer: DispatchWorkItem?

    init(wav: URL, apiKey: String, client: TranscriptionClient, main: String, backup: Backup?,
         onDone: @escaping (Report) -> Void) {
        self.wav = wav
        self.apiKey = apiKey
        self.client = client
        self.main = main
        self.backup = backup
        self.onDone = onDone
    }

    func start() {
        startedAt = clock()
        ask(main)
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
            guard !finished else { return }  // the loser, or cancelled after the winner answered
            switch result {
            case .success(let r):
                finish(.text(r.text, model: model))
            case .failure(let error):
                firstError = firstError ?? error.localizedDescription
                if model == main { mainFailed = true }
                if backup != nil && !backupAsked {
                    askBackup()  // don't wait out the delay after a failure
                } else if pending == 0 {
                    finish(.failed(firstError ?? "Transcription failed."))
                }
            }
        }
        if let task = task { tasks.append(task) }
    }

    private func finish(_ outcome: Outcome) {
        finished = true
        timer?.cancel()
        tasks.forEach { $0.cancel() }  // stops the other request; a finished task ignores it
        onDone(Report(outcome: outcome, seconds: clock() - startedAt, mainFailed: mainFailed))
    }
}
