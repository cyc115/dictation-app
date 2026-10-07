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
enum Diagnostics {
    private static var probe: Probe?  // kept alive until the app exits

    static func runIfRequested() -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let file = env["DICTATIONAPP_PROBE_FILE"], let logPath = env["DICTATIONAPP_PROBE_LOG"] else { return false }
        probe = Probe(file: URL(fileURLWithPath: file), logPath: logPath)
        probe?.run()
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
        engine.localeIdentifier = ProcessInfo.processInfo.environment["DICTATIONAPP_PROBE_LOCALE"] ?? "en-US"
        engine.vocabulary = (ProcessInfo.processInfo.environment["DICTATIONAPP_PROBE_VOCAB"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        log("auth=\(SFSpeechRecognizer.authorizationStatus().rawValue) locale=\(engine.localeIdentifier)")
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
