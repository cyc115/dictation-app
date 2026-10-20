import AppKit
import AVFoundation

/// What the app heard for one kept recording (the JSON next to its WAV).
struct RecordingInfo: Codable, Equatable {
    var date: Date
    /// Speech model that heard it, e.g. "apple:en-US" or "openrouter:qwen/qwen3-asr-1.7b".
    var model: String
    /// The model's transcript — nobody has checked it, so correct it before scoring accuracy against it.
    var transcript: String
    var seconds: Double
    var error: String?
    /// Whether AI polish ran on this dictation (off in the settings).
    /// nil in recordings kept before polish was recorded.
    var polishEnabled: Bool?
    /// Polish model, e.g. "openrouter:openai/gpt-oss-120b" or "apple:on-device".
    var polishModel: String?
    /// What polish made of `transcript` — the text that was typed. nil if polish was off or never finished.
    var polished: String?
    /// Why polish failed; `transcript` was typed instead.
    var polishError: String?
    /// Round trip, polish: transcript in hand → polished text (before it's typed).
    var polishSeconds: Double?
    /// Round trip, speech model: you stop dictating → transcript (upload and back for cloud models,
    /// the recognizer catching up for on-device ones).
    var transcribeSeconds: Double?
}

/// The polish half of one kept recording's JSON. The engine keeps the audio with the raw transcript
/// as soon as it's heard; polish usually finishes after that, rarely before. Whichever comes second
/// writes the JSON, so it ends up with both.
final class RecordingNote {
    private let lock = NSLock()
    /// The polish model, or nil when this dictation isn't polished.
    let polishModel: String?
    private var polished: String?
    private var polishError: String?
    private var polishSeconds: Double?
    private var transcribeSeconds: Double?
    private var json: URL?

    init(polishModel: String?) { self.polishModel = polishModel }

    /// Records how long the speech model took after you stopped.
    func transcribed(seconds: Double) {
        update { $0.transcribeSeconds = seconds }
    }

    /// Records the polish result.
    func polished(_ text: String, seconds: Double, error: String?) {
        update {
            $0.polished = text
            $0.polishSeconds = seconds
            $0.polishError = error
        }
    }

    /// Changes the note, then rewrites the JSON if the recording is already kept.
    private func update(_ change: (RecordingNote) -> Void) {
        lock.lock(); defer { lock.unlock() }
        change(self)
        guard let json = json, var info = JSONFile.read(RecordingInfo.self, from: json) else { return }
        apply(to: &info)
        JSONFile.save(info, to: json, pretty: true)
    }

    /// Called by the archive: writes `info` with the polish so far to `json`.
    func keep(_ info: RecordingInfo, at json: URL) throws {
        lock.lock(); defer { lock.unlock() }
        var info = info
        apply(to: &info)
        try JSONFile.write(info, to: json, pretty: true)
        self.json = json
    }

    private func apply(to info: inout RecordingInfo) {
        info.polishEnabled = polishModel != nil
        info.polishModel = polishModel
        info.polished = polished
        info.polishError = polishError
        info.polishSeconds = polishSeconds
        info.transcribeSeconds = transcribeSeconds
    }
}

/// One dictation's audio: a 16 kHz WAV in the temp folder until it's kept in the archive ("Keep
/// recordings") with what was heard, or deleted.
final class DictationRecording {
    /// Shorter than this isn't speech (a tap of the key): never uploaded or kept.
    static let minimumSeconds: TimeInterval = 0.3
    private let recorder: WAVRecorder
    private let archive: RecordingArchive?
    /// The polish half of its JSON, as it was when this recording started (the next dictation may
    /// set a new one before this one is kept).
    private let note: RecordingNote?

    init?(archive: RecordingArchive?, note: RecordingNote?) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-\(UUID().uuidString).wav")
        guard let recorder = try? WAVRecorder(url: url) else { return nil }
        self.recorder = recorder
        self.archive = archive
        self.note = note
    }

    var url: URL { recorder.url }
    var duration: TimeInterval { recorder.duration }
    var isSpeech: Bool { duration >= Self.minimumSeconds }

    /// From the mic tap's thread (or a test).
    func append(_ buffer: AVAudioPCMBuffer) { recorder.append(buffer) }

    /// Closes the WAV so it can be read (uploaded).
    func finish() { recorder.finish() }

    /// Keeps it with what was heard when recordings are kept and it's speech; else deletes it.
    func done(_ info: RecordingInfo) {
        recorder.finish()
        if let archive, isSpeech { archive.keep(wav: url, info: info, note: note) } else { discard() }
    }

    func discard() {
        recorder.finish()
        try? FileManager.default.removeItem(at: url)
    }
}

/// Keeps dictation audio for building benchmark sets (Settings → Keep recordings, off by default):
/// 16 kHz mono WAVs, each with a JSON of what the app heard (`bench/bench.py import-recordings`).
/// Stays on this Mac. Cancelled dictations are never kept.
final class RecordingArchive {
    static let defaultDirectory = AppPaths.directory("Recordings")

    let directory: URL

    init(directory: URL = RecordingArchive.defaultDirectory) { self.directory = directory }

    private static let nameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f
    }()

    /// Moves a finished recording into the archive and writes its JSON. Returns the kept WAV,
    /// or nil (and deletes the recording) if it couldn't be stored.
    @discardableResult
    func keep(wav: URL, info: RecordingInfo, note: RecordingNote? = nil) -> URL? {
        let fm = FileManager.default
        var name = Self.nameFormatter.string(from: info.date)
        var n = 2
        while fm.fileExists(atPath: directory.appendingPathComponent(name + ".wav").path) {
            name = Self.nameFormatter.string(from: info.date) + "-\(n)"
            n += 1
        }
        let dest = directory.appendingPathComponent(name + ".wav")
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try fm.moveItem(at: wav, to: dest)
            let json = directory.appendingPathComponent(name + ".json")
            if let note = note { try note.keep(info, at: json) } else { try JSONFile.write(info, to: json, pretty: true) }
            return dest
        } catch {
            try? fm.removeItem(at: wav)
            return nil
        }
    }

    /// What was heard for each kept recording.
    var infos: [RecordingInfo] {
        recordings.compactMap { wav in
            JSONFile.read(RecordingInfo.self, from: wav.deletingPathExtension().appendingPathExtension("json"))
        }
    }

    /// Kept recordings, oldest first.
    var recordings: [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func showInFinder() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }
}

// MARK: - WAV recording

/// Converts mic buffers (any rate/channels) to 16 kHz mono 16-bit WAV, the format cloud
/// transcription expects (Meta's endpoint rejects compressed audio).
final class WAVRecorder {
    static let sampleRate: Double = 16_000
    let url: URL
    private let file: AVAudioFile
    private let converter = FormatKeeper(format: AVAudioFormat(standardFormatWithSampleRate: WAVRecorder.sampleRate, channels: 1)!)
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
        guard let out = converter.conform(buffer), out.frameLength > 0 else { return }
        try? file.write(from: out)
        framesWritten += AVAudioFramePosition(out.frameLength)
    }
}
