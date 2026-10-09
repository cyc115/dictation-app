import AVFoundation
import Foundation

// Turnaround benchmark (bench/suite.py latency). Times dictations through the app's real code
// paths, the same steps `AppDelegate.stopDictation` → `deliver` chains:
//   transcribe: stop pressed → raw transcript (cloud: `CloudEngine.stop()` finishes the WAV and
//               uploads it; on-device: `SpeechEngine.stop()` waits for the final result)
//   polish:     raw transcript → polished text (`PolishService.polished`)
//
// Launched by bench/suite.py with:
//   DICTATIONAPP_LATENCY_PLAN=<plan.json>  {"pause": 0.3, "timeout": 90, "trials": [LatencyTrial]}
//   DICTATIONAPP_LATENCY_OUT=<out.jsonl>   one LatencySample per line, written as each finishes
//   DICTATIONAPP_PROBE_KEY=<key>           optional; otherwise the cloud key saved in Settings

/// One dictation to time.
struct LatencyTrial: Decodable, Equatable {
    let id: String
    /// Audio clip (16 kHz mono WAV from bench/audio).
    let file: String
    /// "apple:<locale>" or "openrouter:<model id>".
    let stt: String
    /// Polish backends to time on this trial's transcript, in order: "apple" or "openrouter:<model id>".
    let polish: [String]
}

struct LatencyPlan: Decodable {
    /// Seconds between trials.
    let pause: Double
    /// Seconds before a trial that hasn't answered is recorded as timed out.
    let timeout: Double
    let trials: [LatencyTrial]
}

/// What one trial measured, in seconds; nil when that step failed (see `error`).
struct LatencySample: Encodable, Equatable {
    struct Polish: Encodable, Equatable {
        let model: String
        var seconds: Double?
        var text = ""
        var error: String?
    }

    let id: String
    var transcribe: Double?
    var raw = ""
    var error: String?
    var polish: [Polish] = []
}

/// Runs trials one at a time and reports each one's sample on the main queue.
final class LatencyRunner {
    var apiKey = ""
    var transcriptionClient: TranscriptionClient = OpenRouterClient()
    /// Polish backends by spec, overriding the real ones (tests).
    var polishers: [String: PolishBackend] = [:]

    private let speech = SpeechEngine()
    private var cloud: CloudEngine?
    private let clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    func run(_ trial: LatencyTrial, completion: @escaping (LatencySample) -> Void) {
        transcribe(trial) { [weak self] sample in
            self?.polish(sample, with: trial.polish, completion: completion)
        }
    }

    func polisher(for spec: String) -> PolishBackend? {
        if let fake = polishers[spec] { return fake }
        if spec == "apple" { return OnDevicePolish() }
        if spec.hasPrefix("openrouter:") {
            return OpenRouterPolish(model: String(spec.dropFirst("openrouter:".count)), apiKey: apiKey)
        }
        return nil
    }

    /// Plays the clip into the engine like the mic would, then times `stop()` → transcript.
    private func transcribe(_ trial: LatencyTrial, completion: @escaping (LatencySample) -> Void) {
        let url = URL(fileURLWithPath: trial.file)
        let clock = self.clock
        var sample = LatencySample(id: trial.id)
        let finish = { (raw: String, started: TimeInterval, error: String?) in
            sample.transcribe = clock() - started
            sample.raw = raw
            if raw.isEmpty { sample.error = error ?? "empty transcript" }
            completion(sample)
        }
        if trial.stt.hasPrefix("openrouter:") {
            let engine = CloudEngine()
            engine.client = transcriptionClient
            engine.modelID = String(trial.stt.dropFirst("openrouter:".count))
            engine.apiKey = apiKey
            cloud = engine
            // Recording happens before you press stop, so the clip goes in at full speed.
            guard engine.beginRecording(), Self.read(url, into: engine.record) else {
                engine.cancel()  // deletes the recording file
                sample.error = "could not read \(url.path)"
                return completion(sample)
            }
            let started = clock()
            engine.stop(completion: { raw in finish(raw, started, nil) },
                        failure: { message in
                            sample.error = message
                            completion(sample)
                        })
        } else if trial.stt.hasPrefix("apple:") {
            // Real-time pace, so the recognizer has kept up by the time you press stop, as with the mic.
            let speech = self.speech
            speech.localeIdentifier = String(trial.stt.dropFirst("apple:".count))
            var error: String?
            speech.startFile(url, realTime: true, onError: { error = $0 }, onEnd: {
                let started = clock()
                speech.stop { raw in finish(raw, started, error) }
            })
        } else {
            sample.error = "unknown speech model \(trial.stt)"
            completion(sample)
        }
    }

    /// Times each polish backend on the transcript, one after another.
    private func polish(_ sample: LatencySample, with specs: [String], completion: @escaping (LatencySample) -> Void) {
        guard !specs.isEmpty else { return completion(sample) }
        let clock = self.clock
        let backends = specs.map { polisher(for: $0) }
        Task {
            var sample = sample
            for (spec, backend) in zip(specs, backends) {
                var result = LatencySample.Polish(model: spec)
                if sample.raw.isEmpty {
                    result.error = "no transcript to polish"
                } else if let backend = backend {
                    let started = clock()
                    do {
                        result.text = try await PolishService(backend: backend).polished(sample.raw)
                        result.seconds = clock() - started
                    } catch {
                        result.error = error.localizedDescription
                    }
                } else {
                    result.error = "unknown polish model \(spec)"
                }
                sample.polish.append(result)
            }
            let done = sample
            await MainActor.run { completion(done) }
        }
    }

    /// Feeds a clip to `record` in mic-sized buffers. False if it can't be read.
    static func read(_ url: URL, into record: (AVAudioPCMBuffer) -> Void) -> Bool {
        guard let file = try? AVAudioFile(forReading: url) else { return false }
        let chunk: AVAudioFrameCount = 1024
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk),
                  (try? file.read(into: buffer, frameCount: chunk)) != nil, buffer.frameLength > 0 else { break }
            record(buffer)
        }
        return true
    }
}

/// Runs a plan, appending each sample to the output file as it finishes, then quits.
final class LatencyProbe {
    let plan: LatencyPlan
    let outPath: String
    let runner = LatencyRunner()
    /// Called after the last trial (tests replace it).
    var onFinish: () -> Void = { exit(0) }
    private var index = 0
    private var output = ""
    /// Identifies the trial in flight, so a result arriving after its timeout is dropped.
    private var token = 0

    init?(planPath: String, outPath: String, apiKey: String) {
        guard let data = FileManager.default.contents(atPath: planPath),
              let plan = try? JSONDecoder().decode(LatencyPlan.self, from: data) else { return nil }
        self.plan = plan
        self.outPath = outPath
        runner.apiKey = apiKey
    }

    func run() { next() }

    private func next() {
        guard index < plan.trials.count else { return onFinish() }
        let trial = plan.trials[index]
        index += 1
        token += 1
        let id = token
        DispatchQueue.main.asyncAfter(deadline: .now() + plan.timeout) { [weak self] in
            guard let self = self, id == self.token else { return }
            self.record(LatencySample(id: trial.id, error: String(format: "timed out after %g s", self.plan.timeout)))
        }
        runner.run(trial) { [weak self] sample in
            guard let self = self, id == self.token else { return }
            self.record(sample)
        }
    }

    private func record(_ sample: LatencySample) {
        token += 1
        if let data = try? JSONEncoder().encode(sample), let line = String(data: data, encoding: .utf8) {
            output += line + "\n"
            try? output.write(toFile: outPath, atomically: true, encoding: .utf8)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + plan.pause) { [weak self] in self?.next() }
    }
}
