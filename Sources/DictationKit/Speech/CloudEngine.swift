import AVFoundation
import Foundation

/// Records the mic to WAV while dictating, then uploads it for transcription when you stop.
final class CloudEngine: RecordingEngine, DictationEngine {
    var modelID = DictationSetup.cloudBig.openRouterID!
    var apiKey = ""
    var client: TranscriptionClient = OpenRouterClient()
    /// "Backup model when slow": the model also asked when `modelID` is slow, after `backupWait`
    /// (the setup's `backup` / `backupWait`); nil asks only `modelID`.
    var backupModelID: String?
    var backupWait: TimeInterval = 2
    /// When to ask the backup; the app shares one, so a slow spell carries over between dictations.
    var backup = AdaptiveBackup()
    /// Which model gave the last dictation's transcript, main or backup (set before `completion`).
    private(set) var lastAnswer: ModelAnswer?
    /// The model whose transcript the last dictation used (the backup, if it answered first).
    var lastAnsweredBy: String? { lastAnswer?.model }

    /// The stopped dictation being uploaded (deleted or kept when its upload finishes).
    private(set) var uploading: DictationRecording?
    private var race: UploadRace?
    /// Not used: OpenRouter's transcription endpoint takes no prompt.
    var context = SpeechContext.none

    /// Set up for `setup`'s speech model as the app runs it; `backupWhenSlow` is the "Backup model
    /// when slow" setting.
    func use(_ setup: DictationSetup, apiKey: String, backupWhenSlow: Bool) {
        modelID = setup.openRouterID ?? modelID
        backupModelID = backupWhenSlow ? setup.backup : nil
        backupWait = setup.backupWait
        self.apiKey = apiKey
    }

    func stop(completion: @escaping (String) -> Void, failure: @escaping (String) -> Void) {
        guard let recording = finishRecording(completion: completion, failure: failure) else { return }
        let url = recording.url
        let info = RecordingInfo(date: Date(), model: ModelSpec.openRouter(id: modelID, providers: nil).description, transcript: "", seconds: recording.duration)
        lastAnswer = nil
        uploading = recording
        let main = modelID, wait = backupWait, policy = backup, backupModel = backupModelID
        race = UploadRace(wav: url, apiKey: apiKey, client: client, main: main,
                          backup: backupModel.map { policy.plan(for: main, backup: $0, wait: wait) },
                          judgeMain: backupModel.map { _ in (wait, { onTime in policy.learn(main, onTime: onTime) }) }) { [weak self] report in
            var heard = info
            switch report.outcome {
            case .text(let text, let model):
                heard.transcript = text
                heard.model = ModelSpec.openRouter(id: model, providers: nil).description
                self?.lastAnswer = ModelAnswer(main: main, backup: report.backupAsked ? backupModel : nil, byBackup: model != main)
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
        /// The backup was asked too (the main model was late or failed).
        var backupAsked = false
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
        onDone(Report(outcome: outcome, seconds: clock() - startedAt, backupAsked: backupAsked))
    }
}
