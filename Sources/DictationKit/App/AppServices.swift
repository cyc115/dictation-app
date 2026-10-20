import Foundation

/// What the app's features share: your settings, History, Insights, kept recordings, learned
/// prompts and commands, one of each. `live()` makes the real ones once, at launch; everything else
/// is handed what it needs from here, so nothing reaches for a global. Tests make their own with
/// temporary files and defaults (`makeServices` in TestSupport), so they can't touch yours.
final class AppServices {
    let settings: AppSettings
    let history: HistoryStore
    let insights: Insights
    let archive: RecordingArchive
    let commands: CommandMode
    /// Corrections' suggested text, from a cloud model with your API key.
    let suggester: CorrectionSuggester
    /// Corrections' Learn tile.
    let learn: LearnController

    init(settings: AppSettings, history: HistoryStore, insights: Insights, archive: RecordingArchive,
         commands: CommandMode, general: [GeneralCase] = GeneralCase.app ?? []) {
        self.settings = settings
        self.history = history
        self.insights = insights
        self.archive = archive
        self.commands = commands
        suggester = CorrectionSuggester { [weak settings] in
            settings.flatMap { s in s.openRouterKey.flatMap { CorrectionSuggester.backend(apiKey: $0, setup: s.setup) } }
        }
        // Made on the main thread, like every other user of these (launch, tests).
        learn = MainActor.assumeIsolated {
            LearnController(settings: settings, history: history, store: settings.learned, general: general)
        }
    }

    /// Yours: the files in `AppPaths`, the standard UserDefaults, secrets.json.
    static func live() -> AppServices {
        let history = HistoryStore()
        return AppServices(settings: AppSettings(learned: LearnedPromptStore()), history: history, insights: Insights(),
                           archive: RecordingArchive(), commands: CommandMode(history: history))
    }
}
