import Foundation

/// Developer diagnostics, enabled by environment variables when launching the app bundle (so the
/// app's own Speech Recognition and microphone permissions apply). Runs a plan of dictations
/// through the app's real code paths, writes one result line per dictation, then quits
/// (see LatencyProbe.swift):
///
///   open -n --env DICTATIONAPP_LATENCY_PLAN=plan.json --env DICTATIONAPP_LATENCY_OUT=out.jsonl \
///           /Applications/DictationApp.app
///
/// Used by bench/suite.py (latency, polish, accuracy) and scripts/e2e-speech.sh.
///
/// Mic warm-up (scripts/mic-warmup.sh): opens one mic through the app's real `MicCapture` and
/// writes how long it took to send audio and real (non-zero) audio, as one JSON line, then quits:
///
///   open -n --env DICTATIONAPP_MIC_PROBE_OUT=out.json [--env DICTATIONAPP_MIC_PROBE_UID=<uid>]
///           [--env DICTATIONAPP_MIC_PROBE_SECONDS=4] [--env DICTATIONAPP_MIC_PROBE_BACKUPS=1] /Applications/DictationApp.app
///
/// With BACKUPS, the other wired and built-in mics record too (Intelligent mic selection), and the
/// line says which opened and any switch (speak into a backup to see one).
enum Diagnostics {
    private static var probe: LatencyProbe?  // kept alive until the app exits
    private static var micProbe: MicProbe?

    static func runIfRequested() -> Bool {
        let env = ProcessInfo.processInfo.environment
        if let out = env["DICTATIONAPP_MIC_PROBE_OUT"] {
            let probe = MicProbe(uid: env["DICTATIONAPP_MIC_PROBE_UID"] ?? "",
                                 seconds: env["DICTATIONAPP_MIC_PROBE_SECONDS"].flatMap(Double.init) ?? 4,
                                 backups: env["DICTATIONAPP_MIC_PROBE_BACKUPS"] == "1")
            micProbe = probe
            probe.run { line in
                try? (line + "\n").write(toFile: out, atomically: true, encoding: .utf8)
                exit(0)
            }
            return true
        }
        guard let plan = env["DICTATIONAPP_LATENCY_PLAN"], let out = env["DICTATIONAPP_LATENCY_OUT"] else { return false }
        let key = env["DICTATIONAPP_PROBE_KEY"] ?? FileSecretStore().get(AppSettings.openRouterAccount) ?? ""
        guard let latency = LatencyProbe(planPath: plan, outPath: out, apiKey: key) else {
            try? "{\"id\": \"plan\", \"error\": \"could not read the plan\"}\n"
                .write(toFile: out, atomically: true, encoding: .utf8)
            exit(1)
        }
        probe = latency
        latency.run()
        return true
    }
}

/// One mic's warm-up, timed from opening it: first buffer, first real audio (`MicEvent.live`), and
/// with `backups`, which other mics opened and any switch to one.
final class MicProbe {
    let uid: String
    let seconds: TimeInterval
    let backups: Bool
    private let mic = MicCapture()

    init(uid: String, seconds: TimeInterval, backups: Bool) {
        self.uid = uid
        self.seconds = seconds
        self.backups = backups
    }

    func run(done: @escaping (String) -> Void) {
        let device = AudioDevices.activeInput(preferredUID: uid)
        var result: [String: Any] = ["device": device?.name ?? NSNull(), "bluetooth": device?.isBluetooth ?? false]
        let clock = { ProcessInfo.processInfo.systemUptime }
        let opened = clock()
        let lock = NSLock()
        var buffers = 0, firstBuffer: TimeInterval?, rate: Double?
        do {
            try mic.start(inputUID: uid, backups: backups, onBuffer: { buffer in
                lock.lock(); defer { lock.unlock() }
                buffers += 1
                if firstBuffer == nil { firstBuffer = clock() - opened; rate = buffer.format.sampleRate }
            }, onEvent: { event in
                switch event {
                case .live: result["live"] = Self.ms(clock() - opened)
                case .noAudio: result["noAudioAt"] = Self.ms(clock() - opened)
                case .switched(let device): result["switchedTo"] = device.name; result["switchedAt"] = Self.ms(clock() - opened)
                }
            }, onError: { result["error"] = $0 })
            result["openMs"] = Self.ms(clock() - opened)
        } catch {
            result["error"] = error.localizedDescription
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [mic] in
            result["mics"] = mic.openDevices.map(\.name)
            mic.stop()
            lock.lock()
            result["buffers"] = buffers
            result["firstBuffer"] = firstBuffer.map(Self.ms) ?? NSNull()
            result["sampleRate"] = rate ?? NSNull()
            lock.unlock()
            if result["live"] == nil { result["live"] = NSNull() }
            let data = (try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])) ?? Data()
            done(String(data: data, encoding: .utf8) ?? "{}")
        }
    }

    /// Seconds → whole milliseconds.
    private static func ms(_ seconds: TimeInterval) -> Int { Int((seconds * 1000).rounded()) }
}
