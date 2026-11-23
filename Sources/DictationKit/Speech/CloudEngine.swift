import AVFoundation
import Foundation

/// Records the mic to WAV while dictating, then uploads it for transcription when you stop.
final class CloudEngine: RecordingEngine, DictationEngine {
    /// The speech model and the hosts it may run on.
    var model = DictationSetup.cloudFlash.speechRoute!
    var apiKey = ""
    var client: TranscriptionClient = OpenRouterClient()
    /// "Backup model when slow": the model also asked when `model` is slow, after `backupWait`
    /// (the setup's `backup` / `backupWait`); nil asks only `model`.
    var backupModel: SpeechRoute?
    var backupWait: TimeInterval = 2
    /// When to ask the backup; the app shares one, so a slow spell carries over between dictations.
    var backup = AdaptiveBackup()
    /// Which model gave the last dictation's transcript, main or backup (set before `completion`).
    private(set) var lastAnswer: ModelAnswer?
    /// The model whose transcript the last dictation used (the backup, if it answered first): its
    /// stored name, and the route itself.
    var lastAnsweredBy: String? { lastAnswer?.model }
    private(set) var lastAnsweredRoute: SpeechRoute?

    /// The stopped dictation being uploaded (deleted or kept when its upload finishes).
    private(set) var uploading: DictationRecording?
    private var race: UploadRace?
    /// Not used: OpenRouter's transcription endpoint takes no prompt.
    var context = SpeechContext.none

    /// Set up for `setup`'s speech model as the app runs it; `backupWhenSlow` is the "Backup model
    /// when slow" setting.
    func use(_ setup: DictationSetup, apiKey: String, backupWhenSlow: Bool) {
        model = setup.speechRoute ?? model
        backupModel = backupWhenSlow ? setup.backupRoute : nil
        backupWait = setup.backupWait
        self.apiKey = apiKey
    }

    func stop(completion: @escaping (String) -> Void, failure: @escaping (String) -> Void) {
        lastAnswer = nil  // before silence can fail it: never the last dictation's answer
        lastAnsweredRoute = nil
        guard let recording = finishRecording(completion: completion, failure: failure) else { return }
        let url = recording.url
        let info = RecordingInfo(date: Date(), model: ModelSpec.openRouter(model).description, transcript: "", seconds: recording.duration)
        uploading = recording
        let main = model, wait = backupWait, policy = backup, backupModel = backupModel
        race = UploadRace(wav: url, apiKey: apiKey, client: client, main: main,
                          backup: backupModel.map { policy.plan(for: main, backup: $0, wait: wait) },
                          judgeMain: backupModel.map { _ in (wait, { onTime in policy.learn(main, onTime: onTime) }) }) { [weak self] report in
            var heard = info
            switch report.outcome {
            case .text(let text, let model):
                heard.transcript = text
                heard.model = ModelSpec.openRouter(model).description
                self?.lastAnswer = ModelAnswer(main: main.name, backup: report.backupAsked ? backupModel?.name : nil, byBackup: model != main,
                                               failures: report.failures.isEmpty ? nil : report.failures)
                self?.lastAnsweredRoute = model
                completion(text)
            case .failed(let message):
                heard.error = message
                self?.lastAnswer = ModelAnswer(main: main.name, backup: report.backupAsked ? backupModel?.name : nil,
                                               failures: report.failures, failed: true)
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
}

// MARK: - Backup model

/// On by default (Settings → Model → "Backup model when slow"); off asks the chosen model only. Cloud Flash usually answers in
/// about a second, but in slow spells lasting minutes it takes 3–50 s (bench/results/latency/). This
/// also asks the setup's backup (`DictationSetup.backup`: Voxtral Mini for Cloud Flash); the first
/// answer wins. The backup runs on another host: Cloud Flash's Qwen is pinned to PrimeIntellect
/// (DeepInfra, its other host, hung on 8 of 8 calls on Nov 22), and Voxtral runs on Mistral. Grok
/// STT, the backup until Nov 22, left OpenRouter in early November and answered every ask with a 404
/// in 0.1 s, so slow dictations waited out the main model (27–44 s).
///  - Normally the backup is asked only once the main model hasn't answered within its wait
///    (`DictationSetup.backupWait`), or failed.
///  - After the main model was late, both are asked at once for `spell`: the next answers would
///    likely be late too. The main model answering on time ends the spell early.
///  - Late or on time is the main model's own answer within the wait, whoever won: the backup is
///    faster, so judging by the winner kept a spell going for as long as the backup kept winning
///    (43% of real dictations went to the less accurate backup).
/// The backup is less accurate on mixed Chinese/English with technical terms (84% vs 90%, bench/).
/// The app keeps one instance, so a slow spell carries over between dictations.
final class AdaptiveBackup {
    var spell: TimeInterval = 5 * 60
    private let clock: () -> TimeInterval
    /// When each main model (with its hosts) was last late.
    private var lateAt: [SpeechRoute: TimeInterval] = [:]

    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) { self.clock = clock }

    /// When to ask `backup` in a dictation with `model`: after `wait`, or at once in a slow spell.
    func plan(for model: SpeechRoute, backup: SpeechRoute, wait: TimeInterval) -> UploadRace.Backup {
        UploadRace.Backup(model: backup, delay: inSlowSpell(model) ? 0 : wait)
    }

    func inSlowSpell(_ model: SpeechRoute) -> Bool {
        guard let at = lateAt[model] else { return false }
        return clock() - at < spell
    }

    /// Learns whether `model` answered within its wait (`UploadRace`'s `judgeMain`); failing is late.
    func learn(_ model: SpeechRoute, onTime: Bool) {
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
    /// An answer this late is logged as a notice, not info.
    static let slow: TimeInterval = 2

    struct Backup: Equatable {
        let model: SpeechRoute
        let delay: TimeInterval
    }

    enum Outcome {
        case text(String, model: SpeechRoute)
        case failed(String)
    }

    struct Report {
        let outcome: Outcome
        /// Upload start → outcome.
        let seconds: TimeInterval
        /// The backup was asked too (the main model was late or failed).
        var backupAsked = false
        /// The requests that failed before the outcome (a backup's 404 while the main model ran on).
        var failures: [ModelAnswer.Failure] = []
    }

    private let wav: URL
    private let apiKey: String
    private let client: TranscriptionClient
    private let main: SpeechRoute
    private let backup: Backup?
    private let judgeMain: (wait: TimeInterval, verdict: (Bool) -> Void)?
    private let onDone: (Report) -> Void
    /// Why the backup was asked and whose answer was used (`CloudLog`; each request's own HTTP
    /// outcome is the client's line).
    private let log: CloudLog
    private let clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private var startedAt: TimeInterval = 0
    private var tasks: [SpeechRoute: URLSessionTask] = [:]
    private var pending = 0
    private var backupAsked = false
    private var firstError: String?
    private var failures: [ModelAnswer.Failure] = []
    private var finished = false
    private var judged = false
    private var timer: DispatchWorkItem?
    private var judgeTimer: DispatchWorkItem?

    init(wav: URL, apiKey: String, client: TranscriptionClient, main: SpeechRoute, backup: Backup?,
         judgeMain: (wait: TimeInterval, verdict: (Bool) -> Void)? = nil, log: CloudLog = .speech,
         onDone: @escaping (Report) -> Void) {
        self.wav = wav
        self.log = log
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
        guard backup.delay > 0 else { return askBackup(because: "at once: \(main.name) was late in the last few minutes") }
        let timer = DispatchWorkItem { [self] in askBackup(because: "\(main.name) hasn't answered in \(CloudLog.seconds(backup.delay))") }
        self.timer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + backup.delay, execute: timer)
    }

    private func askBackup(because reason: String) {
        guard let backup = backup, !backupAsked, !finished else { return }
        log.notice("asking backup \(backup.model.name): \(reason)")
        backupAsked = true
        timer?.cancel()
        ask(backup.model)
    }

    private func ask(_ model: SpeechRoute) {
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
                failures.append(.init(model: model.name, message: error.localizedDescription))
                if backup != nil && !backupAsked {
                    askBackup(because: "\(model.name) failed: \(error.localizedDescription)")  // don't wait out the delay
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
        let seconds = clock() - startedAt, took = CloudLog.seconds(seconds)
        switch outcome {
        case .text(_, let model) where model == main && !backupAsked:
            // Slow without a backup to ask (setting off) is a notice too: kept long enough to find.
            seconds < Self.slow ? log.info("transcript from \(model.name) in \(took)")
                : log.notice("transcript from \(model.name) in \(took), slow; no backup asked")
        case .text(_, let model):
            log.notice("transcript from \(model.name) in \(took)" + (model == main ? "; backup \(backup?.model.name ?? "") was slower or failed" : " (backup)"))
        case .failed(let message):
            log.error("transcription failed after \(took), every model asked: \(message)")
        }
        timer?.cancel()
        // Stops the other request (a finished task ignores it); a main request still being judged runs on.
        for (model, task) in tasks where model != main || judged { task.cancel() }
        onDone(Report(outcome: outcome, seconds: clock() - startedAt, backupAsked: backupAsked, failures: failures))
    }
}
