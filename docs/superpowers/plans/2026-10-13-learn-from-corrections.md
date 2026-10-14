# Learn from corrections Implementation Plan

Spec: `docs/superpowers/specs/2026-10-13-learn-from-corrections-design.md`. Executed inline in one
session, task by task, `./test.sh` green at each commit.

**Goal:** one click in Corrections tunes the setup's polish prompt from your corrections, with a
cross-validated score and a general-set guard, and keeps it as a new prompt version.

**Architecture:** pure pieces first (`PolishScore`, `PromptDiff`, `PromptTuner` driven by injected
student/teacher closures), then storage (`LearnedPromptStore`, applied to setups by `AppSettings`),
then the UI (`LearnView` in the Corrections tab, fit chips on cards, prompt picker in Settings).

**Constraints (from the spec):** scores and checks equal `bench/harness.py` / `suites/polish.py`;
versions number on from the built-ins across setups; Keep only on verdict pass (mine ≥ before + 1,
general ≥ before − 2); learned = held-out error ≤ 0.15; Learn at ≥ 10 corrections with ≥ 1
unlearned; cloud setups only.

## Tasks

1. **Score** (`PolishScore.swift` new, `ScoreTests.swift` new, `bench/score_fixture.json` new,
   `bench/test_polish.py`)
   - `PolishScore.tokens`, `editDistance`, `errorRate(reference:hypothesis:)`, `contains(_:phrase:)`,
     `check(case:output:) -> Check(missing, kept, error, passed)`; `GeneralCase: Decodable` (id, raw,
     expected, must, must_not) and `GeneralCase.load(_ url: URL)` for `{"cases": [...]}`.
   - Fixture: ~12 rows `{reference, hypothesis, error, must, must_not, passed}` covering NFKC, case,
     apostrophes, CJK per character, empty reference, the 25% bar. Swift and Python both assert.
   - `assertFaster` for `errorRate` on 2,000 tokens.
2. **Prompt diff** (`PromptDiff.swift` new, tests in `ScoreTests.swift`): `PromptDiff.hunks(old:new:)
   -> [Hunk]`, `Hunk.lines: [Line(kind: .context/.removed/.added, text)]`, one line of context,
   adjacent changes merged; identical prompts → `[]`. Perf budget for 60-line prompts.
3. **Tuner** (`PromptTuner.swift` new, `PromptTunerTests.swift` new, `PolishService.swift`)
   - `OpenRouterPolish.reasoning: [String: Any]?` override (nil: today's rule).
   - Types: `TuneCase(id: UUID, input, wanted, learned: Bool)`, `Lens` (rules/examples/both, with
     title, blurb and teacher instruction), `TunePhase` (reading, racing(fold, of, scores), checking,
     done), `TuneResult(prompt text, lens, mine, mineBefore, general, generalBefore, errors,
     errorsBefore, tokens, teacherInputs for tests)`, `TuneError`.
   - `PromptTuner(student: (String) -> PolishBackend, teacher: (system, user) async throws -> String,
     general: [GeneralCase], folds: 5, repeats: 2, seed: 1, concurrency: 6)`;
     `func tune(cases:, prompt:, promptName:, progress:) async throws -> TuneResult`.
   - Teacher prompt builder `PromptTuner.teacherMessage(prompt:lens:examples:)`, answer parsed from
     `<prompt>` tags (`PromptTuner.extractPrompt`).
   - Tests with a scripted student (`FakeStudent`: output per (instructions contains marker, input))
     and fake teacher recording inputs: held-out isolation, winner, baseline, guard, verdict both
     ways, learned exclusion, bad teacher answer, student error.
4. **Store + setups** (`LearnedPrompts.swift` new, `Setups.swift`, `Settings.swift`,
   `LearnedPromptTests.swift` new, `build.sh`, `bench/suites/polish.py`, `bench/test_polish.py`)
   - `LearnedPrompt: Codable` (spec fields); `LearnedPromptStore(fileURL:)`: `prompts`, `active`,
     `keep(_:)` (writes JSON and `prompts/<version>.txt`), `activate(_ version: String?, for setup:)`,
     `active(for:)`, `nextVersion`, `error(for entry: UUID, setup:) -> (before, now)?`,
     `isLearned(_ id: UUID, setup:)`, `versions(for setup:)`.
   - `PolishPrompt.learned: (String) -> String?` hook; `DictationSetup.prompt` becomes `var`;
     `DictationSetup.applying(_ learned: LearnedPromptStore) -> DictationSetup`.
   - `AppSettings(learned: LearnedPromptStore = .shared)` applies the active version in
     `reloadSetups`, and reloads on the store's `objectWillChange`.
   - `GeneralCase.appURL` = `Bundle.main.resourceURL/polish_cases*.json`; `build.sh` copies the two
     bench files there.
   - bench: `prompt_text("v5")` reads `learned-prompts.json`; test.
5. **Learn UI** (`Learn.swift` new: `LearnController`, `LearnView`; `Corrections.swift`;
   `SettingsView.swift`; `UITests.swift`; snapshots `learn-ready`, `learn-done`)
   - `LearnController(settings:, history:, store:, general:, makeTuner:)`: `gate` (.needMore(n),
     .onDeviceOnly, .noKey, .ready(n), .allLearned, .running), `phase`, `result`, `error`, `learn()`,
     `keep()`, `discard()`, `scores` (mine/general shown, from the active version or the result).
   - `LearnView`: score panel (rings via `Circle().trim`, numbers with `.contentTransition(.numericText())`),
     button / gate bar, status, candidate rows, diff hunks, result row. Identifiers `learn.*`.
   - `CorrectionCard` fit chip (`corrections.fit`) and "learned" tag from the store; the sweep
     over the cards during `.reading`.
   - Settings: "Polish prompt" row with a picker of `versions(for: setup)`.
6. **Live + ship**: live test (teacher returns a prompt in tags; two general cases through the
   tuner), `./test.sh`, `./test.sh --live`, bench pytest, `./build.sh --keep-running`, README
   paragraph, commit, push to main.
