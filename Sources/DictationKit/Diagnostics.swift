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
enum Diagnostics {
    private static var probe: LatencyProbe?  // kept alive until the app exits

    static func runIfRequested() -> Bool {
        let env = ProcessInfo.processInfo.environment
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
