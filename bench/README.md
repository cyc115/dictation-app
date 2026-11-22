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
paths** (`Sources/DictationKit/Debug/LatencyProbe.swift`), so it includes everything the app does:

| stage | from → to | |
|:--|:--|:--|
| transcription | stop pressed → raw text | cloud: close the WAV, upload, wait for the API (`CloudEngine.stop()`); on-device: clip plays in real time like the mic, then `SpeechEngine.stop()` waits for the final result |
| AI polish | raw text → polished text | `PolishService`; every polish model runs on the same transcript, in shuffled order |
| turnaround | stop pressed → text ready to paste | transcription + polish **of the same dictation**; the percentiles are of those sums (adding separate p95s overstates the tail). Paste (~10 ms) not included |

```sh
./build.sh                                            # the suite drives /Applications/DictationApp.app
bench/suite.py latency run --dry-run                  # plan + estimated time (default ≈ 2 min)
bench/suite.py latency run                            # Cloud Flash (+backup, as the app) × {no polish, Apple polish}
bench/suite.py latency run --local                    # … plus On-device (opt-in)
bench/suite.py latency run --backup                   # Cloud Flash with vs without the backup model
bench/suite.py latency run -s flash -r 10             # Cloud Flash only, 10 rounds → 90 samples
bench/suite.py latency run -P none -P apple \
    -P openrouter:anthropic/claude-haiku-5.5 -P openrouter:google/gemini-3.8-flash   # compare polish models
bench/suite.py latency report --by-length --markdown  # latest result again; Markdown for notes/PRs
bench/suite.py latency polish-cost                    # polish time vs words read / written (no new run)
bench/suite.py latency run --simulate                 # fake timings: try the report without a Mac/key
```

- **Models.** Speech: `local` (On-device: Qwen3-ASR on this Mac), `flash`, `flash+backup`,
  `apple` / `apple-zh` (Apple Speech, en-US / zh-CN), or any `local:<Hugging Face id>` /
  `apple:<locale>` / `openrouter:<id>`. `+backup` has the "Backup model when slow"
  setting on (the app's default) for those dictations; `--backup` interleaves `flash` and `flash+backup`
  in one run, so both see the same network, and the report counts how often the backup answered. Polish: `none`, `apple`, or any OpenRouter chat model
  `openrouter:<id>` (the app only offers on-device polish today; the benchmark tells you whether a
  cloud one is worth adding). Cloud models use the bench's key, passed to the app (`--key-env VAR` to override; see **Key** below).
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
  On-device (free, but plays each clip in real time: ≈ +7 min). A cloud polish model adds under $0.01. It scales with `--rounds` and clip length.
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
- **Key:** the bench's own, `$OPENROUTER_BENCH_API_KEY` (in `~/.secrets`, chezmoi), never the app's.
- **Prompts:** each model gets the prompt its setup uses in the app (`apple`: On-device's; cloud
  models: Cloud Flash's), or `--prompt-file` (see `polish_prompts/`, versions `v1`–`v4` and `v7`, identical to
  `PolishPrompt` in `Setups.swift`; a test checks). The transcript goes in `<transcript>` tags, as
  the app sends it; `--no-wrap` sends it bare, to compare. On-device uses `v3`, Cloud Flash `v7` (both in tags);
  `v7` on Apple's model left 2 of 11 traps alone vs `v3`'s 8 (Oct 31).
- **Teacher bake-off:** which model should write learned prompts (`LearnController.teacherModel`)?
  `Tests/DictationKitTests/TeacherBakeoffTests.swift` runs one real tune per teacher through the
  tuner's own code path (the app's teacher call, `PromptTuner.openRouterTeacher`; Cloud Flash's
  student; a copy of your corrections) and writes scores, verdict, the prompt, every teacher call's
  time, tokens and cost, and the tune's cost to a JSON file. Build the tests once, then run the
  teachers side by side:
  ```sh
  swift build --build-tests
  mkdir -p /tmp/bakeoff
  cp ~/Library/Application\ Support/DictationApp/history.json /tmp/bakeoff/history.json   # a copy, never the live file
  for m in anthropic/claude-sonnet-5.5 openai/gpt-6.2-sol openai/gpt-6-luna; do
    BAKEOFF_TEACHER=$m BAKEOFF_HISTORY=/tmp/bakeoff/history.json BAKEOFF_OUT=/tmp/bakeoff/${m//\//_}.json OPENROUTER_API_KEY=… \
      xcrun xctest -XCTest DictationKitTests.TeacherBakeoffTests/testLiveTeacherBakeoff .build/debug/DictationKitTests.xctest &
  done; wait
  ```
  Optional: `BAKEOFF_PROMPT` (starting prompt: a version such as `v7`, or a file path; default `v4`)
  and `BAKEOFF_FOLDS` (default the tuner's, 3).
  Compare `result.mine` (cross-validated, so a teacher that memorised its fold gets no credit),
  `result.general`, `result.acted` (must not rise), `elapsed` and `cost.total` (US dollars;
  `cost.teacher` and `cost.student` split it, each with calls, prompt, cached, cache-write,
  completion and reasoning tokens). Each of `teacherCalls` has its `usage` and its `session`: the
  fold (the call's OpenRouter `session_id`) or `final`. In a fold the first call writes the prompt
  cache and the other two should show `cachedTokens` near the prompt size. One tune is 10 teacher
  calls (3 folds × 3 lenses, then the final prompt) and about 300 student calls. Oct 14 results:
  `results/polish/README.md`.

## Command mode's decision model (`suite.py commands`)

Does what you said run the right command (`command_cases.json`: English, Chinese, mixed, fillers,
speech-model errors, and things that aren't commands), how fast and how cheaply. `jev` is asked
exactly as the app's `JevDecider` asks; `openrouter:<id>` as its `ChatDecider`; `local:<name>` is an
on-device decision model behind its own server (Decider, Kev, Laya: how to start them is in the
results). `--catalog` adds 29 more commands to choose from. Results, the on-device comparison and
Jev's limits: [`results/commands/`](results/commands/README.md).

```sh
bench/suite.py commands run                       # Jev and six chat models
bench/suite.py commands run -m jev -m openrouter:deepseek/deepseek-v4.1-flash -r 3 --catalog
bench/suite.py commands run -m jev -m local:decider -r 3 --workers 1 --min-confidence 0   # + cut-off table
bench/suite.py commands run -m local:decider -m local:decider+bare+lean-choice -r 1 --workers 1   # trimmed requests
bench/suite.py commands resources -m local:decider   # memory, idle CPU, CPU/GPU time and energy per decision
bench/suite.py commands run -m jev -m jev+bare+warm -r 2 --workers 1   # variants of Jev's request (JEV_MODIFIERS), interleaved
bench/suite.py commands report --failures jev
```

The app uses the model in its `commandModel` setting (default `jev`; any OpenRouter chat model id
works): `defaults write com.mikechen.DictationApp commandModel <id>`.

## Writing a command (`suite.py create`)

Does "create command …" get a working script in one go (`create_cases.json`: 16 new commands, 4
that already exist)? The model is asked exactly as the app's `CommandWriter` asks
(`Sources/DictationKit/Commands/WriteCommand.txt`), and each reply is checked like the app checks
it: the format, finding the existing command, the name, the docstring, Python syntax. `--try` also
runs the scripts of the "safe" cases (they only read: battery, time, Wi-Fi) as the app would.

```sh
bench/suite.py create run --try                   # the app's model: DeepSeek V4.1 Flash
bench/suite.py create run -m openrouter:deepseek/deepseek-v4.1-flash+think -r 2
bench/suite.py create show 窗口                    # what it wrote for a case
```

Oct 20, 2026, DeepSeek V4.1 Flash, reasoning off, 2 rounds: every case right, and 13 of 14 safe
scripts ran (the other reported, correctly, that this Mac wasn't on Wi-Fi); 0.7 s, $0.23 per 1000.
Reasoning on scored the same, twice as slow and dear.

## Judging your fixes (`suite.py edits`)

Does a model tell a misheard word from style and a change of mind, and does batching cost it
accuracy? `edit_cases.json` has 45 fixes written for the bench (English, Chinese and mixed; none is
a real dictation), with each word change exactly as the app works it out (a Swift test checks) and
the verdict it should get. The model is asked as the app's `FixJudge` asks
(`Sources/DictationKit/Vocabulary/JudgeFixes.txt`, then the sample terms, then the numbered fixes;
`judge_message_fixture.json` pins the format for both). Each model runs batch sizes 1 and 10 on the
same seeded shuffle. A change scores when its verdict matches; one the answer didn't cover scores as
wrong (coverage is shown apart). The report adds misheard precision: a change wrongly called
misheard would teach vocabulary a bad variant.

```sh
bench/suite.py edits run --dry-run                # plan and estimated cost; reads no key, sends nothing
bench/suite.py edits run -m openrouter:<cheap model> --price <id>=IN,OUT -b 10   # cheap ones first
bench/suite.py edits run                          # the app's model, Claude Sonnet 5.5, batches of 1 and 10
bench/suite.py edits report --failures anthropic/claude-sonnet-5.5@10
```

Each request's cost is recorded and the run's total printed. The estimate prices tokens from
`PRICES` in `suites/edits.py` (only models a saved result gives a price for: Claude Sonnet 5.5, $2 /
$10 per million) or `--price`; the default run is estimated at about 6¢. Batching stays in the app
only if batches of 10 score as well as one at a time; then the cheapest model that ties the best
becomes `judgeModel`'s default.

Nov 22, 2026 (`results/edits/README.md`, 6.9¢ for three models): Claude Sonnet 5.5 98% in batches
of 10, 94% one at a time; DeepSeek V4.1 Flash 93%; Gemini 3.8 Flash 89%. Sonnet and batches of 10
stay the defaults. Apple Intelligence, tried once outside the suite, got 37%, so the On-device
setup has no judge.

## Vocabulary on your own History (`suite.py history`)

Do the words the app misheard now come out right, what does that cost in wait, and does it break
anything, on your real History (spec: `docs/superpowers/specs/2026-11-22-history-bench-design.md`;
method and results: [`results/history/`](results/history/README.md), totals only).

```sh
bench/suite.py history run --dry-run          # calls per part and the estimated cost; reads no key, sends nothing
bench/suite.py history run                    # all six parts (cap --max-cost, default $0.50)
bench/suite.py history run --parts 3,4,5,6    # only the free, local parts
bench/suite.py history run --limit 10 --rounds 1 --setup cloud-flash
bench/suite.py history run --parts 1 --prompts base --arms off,again   # a cheap part-1 rerun
bench/suite.py history run --parts 1 --prompts v4                      # a term-free built-in prompt
bench/suite.py history report [--markdown]    # totals only, safe to paste
bench/suite.py history report --details       # hits and misses WITH your text: local only
```

- **Reads** `~/Library/Application Support/DictationApp` (`--data`) read-only: `history.json`,
  `vocabulary.json`, `edit-watch.json` (and `learned-prompts.json`, `setups.json` for the setup's
  prompt) are copied to a temporary folder first; `Recordings/` is read in place.
- **Test set:** your corrections and accepted captured edits whose word changes have the judge's
  verdicts; a mishearing is a change judged misheard. `--limit N`: the newest N.
- **Parts:** 1 mishearings fixed (stored raw → replace → cloud polish with the terms → replace, 3
  rounds); 2 the same recordings through the on-device speech model with and without your terms
  (skipped when the model isn't downloaded); 3 what replacement alone changes across all of History;
  4 wait (replacement, polish and speech); 5 candidates by the rules vs the judge against your Add and
  Dismiss; 6 each fix replayed through the edit watcher's two trackers with synthesized keys.
- **Arms:** off, terms only (part 1: the terms told to polish, nothing replaced), again (your
  vocabulary as it is), held out (without what only the dictation under test taught it). `--arms`
  picks a subset.
- **Prompts (part 1):** every arm runs under the setup's active learned prompt (tuned on these fixes,
  so it may know the terms already) and its base prompt (before any tune), reported side by side;
  base only when no learned prompt is active. `--prompts learned,base` (the default); it also takes any
  built-in version by name, the setup's model with that version's text (`--prompts learned,base,v4`:
  v7, the built-in, names terms itself, so v4 is the term-free baseline). A version that is the base or
  learned prompt runs once. Prompts and arms run back to
  back per dictation (arms per clip in part 2), in a seeded order.
- **Scores:** fixed (whole words, your case) and fixed, any case (same rule, case-insensitive).
- **How:** this module snapshots, picks, matches recordings, builds the held-out vocabularies and
  writes a job; `HistoryBenchTests` (skipped unless `HISTORY_BENCH_JOB` is set) runs it through the
  app's own code and writes rows; the module scores them. `history_fixture/job.json` is the job for
  the written fixture: the harness runs it in every `./test.sh` with a stubbed network, and
  `test_history.py` checks it is what `run` builds (`bench/suite.py history fixture-job` rewrites it).
- **Cost:** part 1 only. The estimate prices tokens from `PRICES` (DeepSeek V4.1 Flash on Together,
  from a saved result) or `--price`; a run refuses above `--max-cost`, and the harness stops sending
  once the answers' reported cost reaches it (rows so far are kept; the report says it stopped).
  The Nov 22 run (27 fixes × 4 arms × 3 rounds, one prompt) cost 5.6¢, about a third of its estimate, so both prompts
  come to about 11¢; the dry run prints an upper estimate. About 15–20 minutes plus the test build.
- **Privacy:** only fixed dictations go to the cloud, with the bench's key
  (`$OPENROUTER_BENCH_API_KEY`, passed to the test as `HISTORY_BENCH_KEY`, never written to the job).
  Result files (`results/history/<time>.json`) hold your text and are git-ignored: never `git add -f`
  one. The printed report has totals only.

## Speech-to-text accuracy (`suite.py accuracy` = `bench.py`)

Compares dictation models on the same audio: **Chinese with English mixed in**, **Chinese only**,
and **English only**, at three levels (L1 easy, L2 hard jargon/idioms, L3 hard + fast + noisy).

**Latest results:** [`results/report.html`](results/report.html) — open it in a browser (self-contained, works offline).

```sh
bench/bench.py synth                                   # generate missing audio (macOS `say`)
bench/bench.py run -r 3 -m openrouter:<model-id>       # 3 runs per clip → min/median/max wait
bench/bench.py run -m apple:en-US -m apple:zh-CN        # Apple on-device (needs ./build.sh)
bench/bench.py run -m "openrouter:deepgram/nova-3?language=zh"   # extra API fields after "?"
bench/bench.py run -r 3 -m parakeet:mlx-community/parakeet-tdt-0.6b-v2 -m mlx:mlx-community/Qwen3-ASR-1.7B-8bit   # local, on this Mac's GPU
bench/recordings_compare.py -m mlx:mlx-community/Qwen3-ASR-0.6B-8bit   # a local model vs the cloud on your kept recordings
bench/bench.py report                                  # terminal table, latest run per model
bench/bench.py html                                    # visual comparison → results/report.html
bench/bench.py add clip.m4a --id mixed-real-01 --category mixed --text "帮我 build 一下"
uv run --with pytest --with opencc-python-reimplemented==0.1.7 pytest bench   # scoring tests
```

- **Trying a new OpenRouter model:** list them with
  `curl -s "https://openrouter.ai/api/v1/models?output_modalities=all"` (transcription models don't
  show in the default list), then `bench/bench.py run -r 3 -m openrouter:<id>` and `bench/bench.py html`.
  To offer it in the app, add a setup to `builtInJSON` in `Sources/DictationKit/Polish/Setups.swift`
  (or to your own `setups.json`, see [`docs/custom-setups.md`](../docs/custom-setups.md)).
- **Key:** `$OPENROUTER_BENCH_API_KEY` from `~/.secrets` by default (`--key-env` to change). The account needs credits, and some
  models (Meta Muse) need the 18+ confirmation in OpenRouter's preferences.
- **Local models** (`parakeet:<hf-id>`, `mlx:<hf-id>`) run on this Mac's GPU through `local_stt.py`
  (its own uv environment, downloaded from Hugging Face on first use). Their wait is decode time from
  memory after a warm-up, with no network. Results and verdict: [`results/local/README.md`](results/local/README.md).
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
