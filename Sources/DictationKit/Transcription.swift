import AVFoundation
import Foundation
import Security

// MARK: - Models

/// Which speech-to-text model dictation uses.
/// Adding another OpenRouter model = one more case with its OpenRouter id.
enum TranscriptionModel: String, CaseIterable {
    // Raw values are stored in settings, so keep them stable; order here is the menu order.
    case local
    case qwenASR = "openrouter:qwen/qwen3-asr-1.7b"
    case metaMuse = "openrouter:meta/muse-voice-transcribe-1.0"

    /// Name shown in the app. Users see product tiers, not vendors or model ids.
    var title: String {
        switch self {
        case .local: return "On-device"
        case .qwenASR: return "Cloud Flash"
        case .metaMuse: return "Cloud Big"
        }
    }

    /// One line for Settings (speeds measured in bench/).
    var summary: String {
        switch self {
        case .local: return "Runs on this Mac; nothing leaves it. One language at a time."
        case .qwenASR: return "Fastest cloud model — text in about half a second. Handles English mixed into Chinese. Audio is sent to the cloud when you stop."
        case .metaMuse: return "Larger cloud model — text in about two seconds. Handles English mixed into Chinese. Audio is sent to the cloud when you stop."
        }
    }

    /// OpenRouter model id for cloud models; nil for on-device.
    var openRouterID: String? {
        rawValue.hasPrefix("openrouter:") ? String(rawValue.dropFirst("openrouter:".count)) : nil
    }

    var isCloud: Bool { openRouterID != nil }
    /// Text appears phrase by phrase while you speak (needed for "Type as you speak").
    var supportsStreaming: Bool { !isCloud }
    /// Apple's models are one language each; cloud models detect English/Chinese themselves.
    var supportsLanguageChoice: Bool { !isCloud }
}

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
}

/// API keys live in the macOS Keychain, never in UserDefaults.
final class KeychainStore: SecretStore {
    private let service: String

    init(service: String = "com.mikechen.DictationApp") { self.service = service }

    func get(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(_ value: String?, for account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let value = value, !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
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
    var modelID = TranscriptionModel.metaMuse.openRouterID!
    var apiKey = ""
    var client: TranscriptionClient = OpenRouterClient()
    /// Set while "Keep recordings" is on: finished recordings go here instead of being deleted.
    var archive: RecordingArchive?

    private var audioEngine = AVAudioEngine()
    private var recorder: WAVRecorder?
    private var upload: URLSessionTask?
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
        audioEngine = AVAudioEngine()
        if !inputUID.isEmpty { AudioDevices.route(audioEngine, toInputUID: inputUID) }
        let input = audioEngine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            guard let self = self else { return }
            self.record(buffer)
            let level = SpeechEngine.level(of: buffer)
            DispatchQueue.main.async { onLevel(level) }
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            onError("could not open microphone: \(error.localizedDescription)")
        }
    }

    func stop(completion: @escaping (String) -> Void, failure: @escaping (String) -> Void) {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        lock.lock(); let recorder = self.recorder; self.recorder = nil; lock.unlock()
        guard let recorder = recorder, recorder.duration >= 0.3 else {
            if let url = recorder?.url { try? FileManager.default.removeItem(at: url) }
            return completion("")  // too short to be speech
        }
        recorder.finish()
        let url = recorder.url
        let archive = self.archive
        let info = RecordingInfo(date: Date(), model: "openrouter:\(modelID)", transcript: "", seconds: recorder.duration)
        upload = client.transcribe(wav: url, model: modelID, apiKey: apiKey) { result in
            var heard = info
            switch result {
            case .success(let r): heard.transcript = r.text
            case .failure(let e): heard.error = e.localizedDescription
            }
            switch result {
            case .success(let r): completion(r.text)
            case .failure(let e): failure(e.localizedDescription)
            }
            // After the text is delivered, so keeping it adds nothing to your wait. Failed uploads
            // are kept too: they're the cases a benchmark most needs.
            if let archive = archive { archive.keep(wav: url, info: heard) } else { try? FileManager.default.removeItem(at: url) }
        }
    }

    func cancel() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        lock.lock(); let url = recorder?.url; recorder = nil; lock.unlock()
        if let url = url { try? FileManager.default.removeItem(at: url) }
    }
}
