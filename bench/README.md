# Benchmarks

One entry point, one suite per question. Results land in `results/<suite>/` (accuracy: `results/`).
Only the latest run per suite (per model for accuracy) and runs a write-up cites are kept in the
tree; older ones are in git history.

```sh
bench/suite.py list
bench/suite.py latency run        # how long after you press stop until text is ready (p50/p90/p95)
bench/suite.py accuracy run -m …  # how right the transcript is, and what it costs (= bench/bench.py)
```

Tab completion (zsh): `source bench/completion.zsh` in your `.zshrc`. It completes suites, options
(with their help), models and setups, case ids, prompt and case files, and result files.

Adding a suite: write `suites/<name>.py` with `NAME`, `HELP`, `main(argv)` and `parser()` (for tab
completion), list it in `suites/__init__.py`. `harness.py` has the shared parts: percentiles, interleaved scheduling,
run metadata (commit, Mac model, macOS), result files and tables.
Tests: `uv run --with pytest --with opencc-python-reimplemented==0.1.7 pytest bench`.

## Turnaround latency (`suite.py latency`)

What you wait for after pressing stop, measured **inside the installed app through its real code
paths** (`Sources/DictationKit/LatencyProbe.swift`), so it includes everything the app does:

| stage | from → to | |
|:--|:--|:--|
| transcription | stop pressed → raw text | cloud: close the WAV, upload, wait for the API (`CloudEngine.stop()`); on-device: clip plays in real time like the mic, then `SpeechEngine.stop()` waits for the final result |
| AI polish | raw text → polished text | `PolishService`; every polish model runs on the same transcript, in shuffled order |
| turnaround | stop pressed → text ready to paste | transcription + polish **of the same dictation**; the percentiles are of those sums (adding separate p95s overstates the tail). Paste (~10 ms) not included |

```sh
./build.sh                                            # the suite drives /Applications/DictationApp.app
bench/suite.py latency run --dry-run                  # plan + estimated time (default ≈ 2 min)
bench/suite.py latency run                            # Cloud Flash (+backup, as the app) × {no polish, Apple polish}
bench/suite.py latency run --local --big              # … plus On-device and Cloud Big (opt-in)
bench/suite.py latency run --backup                   # Cloud Flash with vs without the backup model
bench/suite.py latency run -s flash -s big -r 10      # cloud only, 10 rounds → 90 samples per model
bench/suite.py latency run -P none -P apple \
    -P openrouter:anthropic/claude-haiku-5.5 -P openrouter:google/gemini-3.8-flash   # compare polish models
bench/suite.py latency report --by-length --markdown  # latest result again; Markdown for notes/PRs
bench/suite.py latency polish-cost                    # polish time vs words read / written (no new run)
bench/suite.py latency run --simulate                 # fake timings: try the report without a Mac/key
```

- **Models.** Speech: `local` (apple:en-US), `local-zh` (apple:zh-CN), `flash`, `flash+backup`,
  `big`, or any `apple:<locale>` / `openrouter:<id>`. `+backup` has the "Backup model when slow"
  setting on (the app's default) for those dictations; `--backup` interleaves `flash` and `flash+backup`
  in one run, so both see the same network, and the report counts how often the backup answered. Polish: `none`, `apple`, or any OpenRouter chat model
  `openrouter:<id>` (the app only offers on-device polish today; the benchmark tells you whether a
  cloud one is worth adding). Cloud models use the key saved in Settings (`--key-env VAR` to override).
- **Method.** 9 clips by default: per language, the shortest, median and longest clean clip,
  including `long-mixed-01` (28 s) and `long-english-01` (22 s), since cloud latency grows with
  length (`--by-length` shows it). Each round plays every clip × model once in a fresh shuffled
  order, so a slow minute on the network hits every model alike. The first dictation per model is a
  warm-up (connection setup, model load), shown as **cold**, not in the percentiles. On-device
  models only get clips in their language (repeated to the same count). Failed dictations are
  counted under *errors* and never timed: a failed polish is not a fast polish.
- **Reading it.** best / p50 / p90 / p95 / worst per model. p50 is the typical wait, p95 the
  "1 in 20 feels slow" wait. With fewer than 20 samples p95 is marked `*`: raise `--rounds`.
  Cloud numbers are your network at that moment: compare models within one run, and re-run at a
  different time of day before deciding on a small gap.
- **Cost** per default run: about **$0.003**. Cloud Flash hears ~7 min of audio (9 clips × 5
  rounds + warm-up) at the rate measured in `results/`; Apple polish is free. `--local` adds
  On-device (free, but plays each clip in real time: ≈ +7 min); `--big` adds Cloud Big,
  ≈ $0.02 more. A cloud polish model adds under $0.01. It scales with `--rounds` and clip length.
- **Your own voice** (`--recorded`): turn on Settings → Keep recordings, dictate as usual, then
  `bench/bench.py import-recordings`. Real speech beats TTS for both suites; see below.
- **Polish cost** (`polish-cost`): fits polish time to the transcript's length (words in) and the
  polished text's (words out) from a saved run, and compares the same clip across speech models.
  If the time follows what the model writes, polishing earlier phrases while you're still speaking
  would cut the wait; if words in and out move together (polish keeps your wording), it says it
  can't tell them apart.
- Results: `results/latency/<time>_<models>.json` with every dictation (text included), config
  and machine, so any run can be re-reported or compared later.

## AI polish models (`suite.py polish`)

How well and how fast a model cleans up tricky dictations, with the app's prompt or a candidate one.
The results and the reasoning behind the cloud polish choice are in `results/polish/README.md`.

```sh
bench/suite.py polish cases                                              # the test set
bench/suite.py polish run -m apple -m openai/gpt-oss-120b@Groq --quick     # 20 cases, ≈ 1–2 min
bench/suite.py polish run -m openai/gpt-oss-120b@Groq -m google/gemini-3.1-flash-lite   # any OpenRouter model
bench/suite.py polish run -m apple -m openai/gpt-oss-120b@Groq \
    --prompt-file bench/polish_prompts/v3.txt -r 2                       # Apple (via the app) vs cloud
bench/suite.py polish report --failures openai/gpt-oss-120b@Groq         # what one model got wrong
bench/suite.py polish run -m setup:cloud-flash --cases-file bench/polish_cases_holdout.json   # held-out set
bench/suite.py polish run -m setup:cloud-flash --corrections --prompt-file ~/Library/Application\ Support/DictationApp/prompts/v5.txt  # a learned prompt on your corrections
```

- **Cases:** one main set, `polish_cases.json` (54), and one held-out set, `polish_cases_holdout.json`
  (34), for checking a prompt tuned on the main set. Each mixes the hand-written cases — fillers,
  self-corrections, already-clean text, and traps (dictations that ask or instruct, which a polish
  model must clean up, not carry out) — with hard ones from real dictations (ids `hard-…`, `hhard-…`):
  long Chinese stammers, cut-up sentences, Traditional characters from the speech model, noise words,
  spoken numbers, and misheard terms that context makes clear (kind `term`, the "terms" column:
  "cloud code" → Claude Code). On Oct 11 the hard sets were merged in and the 12 cases every model
  passed (≥95% over every run) were dropped; results before that name the old files. A pass needs
  every check to hold and the words within 25% of the expected cleanup.
- **Report:** each column is explained under the table; in a terminal, cells are green, yellow or
  red against fixed bars (e.g. pass ≥ 90% green, < 70% red) so a run reads at a glance. `NO_COLOR=1`
  turns it off; `--markdown` marks cells with 🟢🟡🔴.
- **Quick set** (`--quick`): 20 of the main cases, mostly the ones models disagreed on (17–86% pass
  across the first study), over every language and kind (one misheard term), three of them long. For a fast check; use the
  full set (and the held-out one) before changing a default.
- **Models:** `apple` runs Apple's model inside the installed app (Mac only, after `./build.sh`);
  `openrouter:<id>[@Provider]` pins a host (`@Groq`, `@Cerebras`), else `--sort latency` asks
  OpenRouter to pick. Reasoning is off or at its lowest. `setup:<id>` (e.g. `setup:on-device`, or
  one of yours in `setups.json`) runs a Settings → Model setup's polish exactly as the app does.
- **Key:** `$OPENROUTER_API_KEY`, else the key saved in the app's Settings (`secrets.json`).
- **Prompts:** each model gets the prompt its setup uses in the app (`apple`: On-device's; cloud
  models: Cloud Flash's), or `--prompt-file` (see `polish_prompts/`, versions `v1`–`v3`, identical to
  `PolishPrompt` in `Setups.swift`; a test checks). The transcript goes in `<transcript>` tags, as
  the app sends it; `--no-wrap` sends it bare, to compare. Built-in setups all use `v3` + tags.
- **Teacher bake-off:** which model should write learned prompts (`LearnController.teacherModel`)?
  `Tests/DictationKitTests/TeacherBakeoffTests.swift` runs one real tune per teacher through the
  tuner's own code path (Cloud Flash's student, `PolishPrompt.v4`, a copy of your corrections) and
  writes scores, verdict, the prompt, and every teacher call's time to a JSON file. Build the tests
  once, then run the teachers side by side:
  ```sh
  swift build --build-tests
  cp ~/Library/Application\ Support/DictationApp/history.json /tmp/bakeoff/history.json   # a copy, never the live file
  for m in openai/gpt-6.1-sol anthropic/claude-sonnet-5.5; do
    BAKEOFF_TEACHER=$m BAKEOFF_HISTORY=/tmp/bakeoff/history.json BAKEOFF_OUT=/tmp/bakeoff/${m//\//_}.json OPENROUTER_API_KEY=… \
      xcrun xctest -XCTest DictationKitTests.TeacherBakeoffTests/testLiveTeacherBakeoff .build/debug/DictationKitTests.xctest &
  done; wait
  ```
  Compare `result.mine` (cross-validated, so a teacher that memorised its fold gets no credit),
  `result.general`, `result.acted` (must not rise) and `elapsed`. One tune is 16 teacher calls and
  about 300 student calls. Oct 14 results: `results/polish/README.md`.

## Speech-to-text accuracy (`suite.py accuracy` = `bench.py`)

Compares dictation models on the same audio: **Chinese with English mixed in**, **Chinese only**,
and **English only**, at three levels (L1 easy, L2 hard jargon/idioms, L3 hard + fast + noisy).

**Latest results:** [`results/report.html`](results/report.html) — open it in a browser (self-contained, works offline).

```sh
bench/bench.py synth                                   # generate missing audio (macOS `say`)
bench/bench.py run -r 3 -m openrouter:<model-id>       # 3 runs per clip → min/median/max wait
bench/bench.py run -m apple:en-US -m apple:zh-CN        # Apple on-device (needs ./build.sh)
bench/bench.py run -m "openrouter:deepgram/nova-3?language=zh"   # extra API fields after "?"
bench/bench.py report                                  # terminal table, latest run per model
bench/bench.py html                                    # visual comparison → results/report.html
bench/bench.py add clip.m4a --id mixed-real-01 --category mixed --text "帮我 build 一下"
uv run --with pytest --with opencc-python-reimplemented==0.1.7 pytest bench   # scoring tests
```

- **Trying a new OpenRouter model:** list them with
  `curl -s "https://openrouter.ai/api/v1/models?output_modalities=all"` (transcription models don't
  show in the default list), then `bench/bench.py run -r 3 -m openrouter:<id>` and `bench/bench.py html`.
  To offer it in the app, add one case to `TranscriptionModel` in `Sources/DictationKit/Transcription.swift`.
- **Key:** `$OPENROUTER_API_KEY` by default (`--key-env` to change). The account needs credits, and some
  models (Meta Muse) need the 18+ confirmation in OpenRouter's preferences.
- **Scoring:** token error rate where a token is one Chinese character or one English word. Speaker
  tags are removed and Traditional is converted to Simplified first (flagged separately).
  "EN recall" = English words in mixed sentences that came back right.
- **Cost** is what OpenRouter charged per audio second, shown in the page as a multiple of Meta Muse.
- **Audio** is TTS, so it's cleaner than real speech. Add real recordings with `add` for a truer picture;
  keep case ids stable so results stay comparable.

## Your own recordings as a test set

1. Settings → **Keep recordings** (off by default). Every finished dictation is saved on this Mac
   as a 16 kHz WAV plus a JSON of what the model heard, in
   `~/Library/Application Support/DictationApp/Recordings/`. Cancelled dictations aren't kept;
   failed cloud uploads are (with the error), since they're the cases worth testing.
2. `bench/bench.py import-recordings` copies new ones in as cases `rec-<time>`, with the category
   guessed from the transcript. They go to `recorded.json` and `audio/rec-*.wav`, both **git-ignored**
   so your voice and what you said never get committed by accident.
3. Latency needs no more than that: `bench/suite.py latency run --recorded`.
4. Accuracy needs the right answer. The imported text is only what one model heard, so the cases
   start `verified: false` and `bench.py run` skips them (scoring against one model's guess would
   favour that model). Fix each one with `bench/bench.py verify rec-… --text "what I actually said"`.
