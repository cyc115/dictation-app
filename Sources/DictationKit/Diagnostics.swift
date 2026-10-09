import Foundation
import Speech

/// Developer diagnostics, enabled by environment variables when launching the app bundle
/// (so the app's own Speech Recognition permission applies):
///
///   open -n --env DICTATIONAPP_PROBE_FILE=/path/speech.aiff \
///           --env DICTATIONAPP_PROBE_LOG=/path/log.txt /Applications/DictationApp.app
///
/// Runs the file through the real SpeechEngine (same code path as the mic, real-time pace),
/// logs every recognizer result and each finished utterance, writes the final transcript as
/// the last line ("FINAL: …"), then quits. Used by scripts/e2e-speech.sh.
///
/// Batch mode for benchmarks (bench/bench.py): DICTATIONAPP_PROBE_LIST=<file with one audio
/// path per line>, DICTATIONAPP_PROBE_LOCALE=en-US|zh-CN, DICTATIONAPP_PROBE_OUT=<jsonl path>.
/// Each clip is fed as fast as possible; one JSON line per clip: file, text, latency (seconds
/// from end of audio to final transcript).
///
/// Turnaround benchmark (bench/suite.py latency): DICTATIONAPP_LATENCY_PLAN / _OUT, see LatencyProbe.swift.
enum Diagnostics {
    private static var probe: AnyObject?  // kept alive until the app exits

    static func runIfRequested() -> Bool {
        let env = ProcessInfo.processInfo.environment
        if let plan = env["DICTATIONAPP_LATENCY_PLAN"], let out = env["DICTATIONAPP_LATENCY_OUT"] {
            let key = env["DICTATIONAPP_PROBE_KEY"] ?? KeychainStore().get(AppSettings.openRouterAccount) ?? ""
            guard let latency = LatencyProbe(planPath: plan, outPath: out, apiKey: key) else {
                try? "{\"id\": \"plan\", \"error\": \"could not read the plan\"}\n"
                    .write(toFile: out, atomically: true, encoding: .utf8)
                exit(1)
            }
            probe = latency
            latency.run()
            return true
        }
        if let list = env["DICTATIONAPP_PROBE_LIST"], let out = env["DICTATIONAPP_PROBE_OUT"] {
            let batch = BatchProbe(listPath: list, outPath: out, locale: env["DICTATIONAPP_PROBE_LOCALE"] ?? "en-US")
            probe = batch
            batch.run()
            return true
        }
        guard let file = env["DICTATIONAPP_PROBE_FILE"], let logPath = env["DICTATIONAPP_PROBE_LOG"] else { return false }
        let single = Probe(file: URL(fileURLWithPath: file), logPath: logPath)
        probe = single
        single.run()
        return true
    }
}

private final class Probe {
    let file: URL
    let logPath: String
    let engine = SpeechEngine()
    var lines: [String] = []
    let started = Date()

    init(file: URL, logPath: String) {
        self.file = file
        self.logPath = logPath
    }

    func log(_ s: String) {
        lines.append(String(format: "[%6.2fs] ", Date().timeIntervalSince(started)) + s)
        try? lines.joined(separator: "\n").write(toFile: logPath, atomically: true, encoding: .utf8)
    }

    func run() {
        log("auth=\(SFSpeechRecognizer.authorizationStatus().rawValue)")
        engine.onResult = { [weak self] result in
            self?.log("result final=\(result.isFinal) endOfUtterance=\(result.speechRecognitionMetadata != nil) text=\"\(result.bestTranscription.formattedString)\"")
        }
        engine.startFile(file,
                         onUtterance: { [weak self] chunk in self?.log("UTTERANCE: \"\(chunk)\"") },
                         onError: { [weak self] message in self?.log("error: \(message)") },
                         onEnd: { [weak self] in
                             guard let self = self else { return }
                             self.log("end of audio → stop()")
                             self.engine.stop { text in
                                 self.log("FINAL: \(text)")
                                 DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exit(0) }
                             }
                         })
    }
}

private final class BatchProbe {
    let files: [String]
    let outPath: String
    let engine = SpeechEngine()
    var index = 0
    var output = ""

    init(listPath: String, outPath: String, locale: String) {
        files = ((try? String(contentsOfFile: listPath, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        self.outPath = outPath
        engine.localeIdentifier = locale
    }

    func run() { next() }

    private func next() {
        guard index < files.count else {
            try? output.write(toFile: outPath, atomically: true, encoding: .utf8)
            exit(0)
        }
        let path = files[index]
        index += 1
        var error: String?
        engine.startFile(URL(fileURLWithPath: path), realTime: false,
                         onError: { error = $0 },
                         onEnd: { [weak self] in
                             guard let self = self else { return }
                             let ended = Date()
                             self.engine.stop { text in
                                 let line: [String: Any] = ["file": path, "text": text,
                                                            "latency": Date().timeIntervalSince(ended),
                                                            "error": error ?? NSNull()]
                                 if let data = try? JSONSerialization.data(withJSONObject: line),
                                    let json = String(data: data, encoding: .utf8) {
                                     self.output += json + "\n"
                                     try? self.output.write(toFile: self.outPath, atomically: true, encoding: .utf8)
                                 }
                                 DispatchQueue.main.async { self.next() }
                             }
                         })
    }
}
