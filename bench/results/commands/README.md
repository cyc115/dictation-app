# Command mode's decision model

## Tuning Jev's request (Oct 25, 2026)

Jev is hosted, so there's nothing to train: what the app controls is the request (its size, its
wording), the connection, and the confidence cut-off. Five rounds, each an interleaved run of
variants (`jev+<modifier>…`, see `suites/commands.py` `JEV_MODIFIERS`) so they shared the network;
117 cases × 2–3 rounds. Wording changes were judged on a held-out half too (odd cases), since tuning
words on 117 cases can just fit them. Run-to-run noise for the same request: about ±1 point.

**What Jev's wait depends on** (probe, 6 phrases × 3, interleaved):

| request | input tokens | wait p50 | cost per 1000 |
|:--|--:|--:|--:|
| the app's (command + 8 choice questions, `open`'s 135 apps) | 4,194 | 232 ms | $0.176 |
| options named by themselves sent bare (`"Safari": null`) | 3,083 | 225 ms | $0.129 |
| without `open`'s question | 2,063 | 232 ms | $0.087 |
| the command question alone | 701 | 213 ms | $0.029 |
| on a new connection / of which connect + TLS / on a reused one | | 232 / 51 / **166 ms** | |

Size moves the cost, not the wait; the connection moves the wait.

| round | tried (on top of the previous best) | result | kept |
|:--|:--|:--|:--|
| 1 | `bare`; `warm` (one connection kept open) | bare: same accuracy, **−26% cost**. warm: **p50 230 → 164 ms**, p90 294 → 228 | both |
| 2 | state wording: `heard-command` ("the user is speaking a command … answer none only when it can't be one"), `heard-aloud` | +0.5–0.9 pt, held-out unchanged: noise | heard-command (fewer wrong runs) |
| 3 | `none-noise` ("noise, chatter, or a request none of them does"), `ask-sound` ("go by how the words sound") | +0.9–1.3 pt, held-out +1.7 pt, 2 wrong runs | both, to confirm |
| 4 | original vs `bare+warm` vs all of it, 3 rounds; cut-offs 0.35–0.5 | see below | — |
| 5 | original vs final, fresh 3 rounds | confirms round 4 | stop: nothing left to try that wording could reach |

Rounds 4 and 5 ([`20261025-140218_3-models.json`](20261025-140218_3-models.json),
[`20261025-140523_2-models.json`](20261025-140523_2-models.json)), at the app's 0.5 cut-off:

| | right (r4 / r5) | held-out | wrong runs | wait p50 | p90 | p95 | per 1000 |
|:--|--:|--:|--:|--:|--:|--:|--:|
| `jev` (the app today) | 86.6% / 85.8% | 84.5% / 83.3% | 5 / 6 | 236–244 ms | 301–314 | 363–425 | $0.176 |
| `jev+bare+warm` | 86.9% / — | 84.5% | 4 | **156 ms** | 196 | 225 | **$0.130** |
| `jev+bare+warm+heard-command+none-noise+ask-sound` | **87.2% / 87.2%** | 85.1% / 85.6% | **3 / 3** | 157–170 ms | 211–222 | 242–283 | $0.131 |

What changed, per phrase (r4 + r5, 6 tries each): the Thai noise line no longer opens Clock (3 → 0
wrong runs), "Uh, focus on news." no longer runs a command (2 → 0), "make it brighter and turn the
volume down" and "新建命令 现在几点了" come right more often (0 → 2, 4 → 6), "A press center." less
often (5 → 3). None of the badly misheard ones moved ("Increase fitness.", "Laws of Physics.",
"In turn.", "Bring this up."): Jev answers none to them at 0.6–0.9 confidence whatever it's told.

### Learnings

- **Latency: warm the connection, nothing else helps.** Jev's own time is ~165 ms and flat in the
  request's size; a new TLS connection adds ~65 ms (reused: −30% p50, −38–43% p95). Commands
  come minutes apart, so the app's `URLSession.shared` has usually dropped its connection by then.
  Opening it when command recording starts (while you speak) would take it off the wait.
- **Cost: send options named by themselves without a meaning.** −26% at the same accuracy
  (`open`'s 135 apps were sent as `"Safari": "Safari"`). Cost is ~$0.13 per 1000 decisions after.
- **Accuracy: wording is worth ~1.5 points and half the wrong runs, no more.** The gain is on noise
  (fewer commands run on chatter), not on garbled commands; those are the speech model's to fix.
  The cut-off can trade: 0.40 adds ~1.4 points and 1–3 wrong runs per 351, so keep 0.5 (a wrong
  run costs more than a miss).
- **Misheard short commands are Jev's ceiling** (tag `heard`: 39–43% in every variant). Better
  hearing upstream, not a better decider, is where the next points are.

**In the app since Oct 25:** bare options (`CommandDecision.choiceQuestion`; the bench's `jev` sends
them too, `+full-choices` the old way) and the warm connection (`JevDecider.prepare`: a HEAD to the
endpoint as command recording starts). Live, through the app's code (`testLiveJevOnAPreparedConnection`,
4 × each): new connection 284 ms, prepared 1 s before 171 ms; `testLiveJevPicksTheBuiltInCommands`
13 / 13 right with bare options. The wording isn't: ~1.5 points is near the noise, and it would change
`CommandDecision.heard`, which ChatDecider and Decider share.

## On-device alternatives to Jev (Oct 25, 2026)

Can command mode decide on this Mac instead of asking Jev, without losing accuracy or speed, and what
does it cost on battery? Three on-device decision models that take Jev's kind of question, against Jev:

| model | what | size |
|:--|:--|:--|
| `jev` | TypeSafe's Jev on OpenRouter's decisions API (the app's default) | cloud |
| `local:decider` | Perplexity [Decider for Mac](https://docs.perplexity.ai/docs/decisions/decider-for-mac), `pplx-decider-flash-v1.2` | 4B, 5.8 GB download |
| `local:kev` | [Kev](https://github.com/jaredpalmer/kev) 0.8B (`jaredpalmer/kev-0.8b`; the 0.5B is superseded), MLX bf16 | 0.8B |
| `local:laya` | [Laya](https://huggingface.co/aac6fef/laya-mlx) English, MLX fp16 | 421M |
| `local:laya-ml` | Laya multilingual (mmBERT), MLX fp16 | 322M |

M1 Max, 64 GB, on AC power. 117 cases × 3 rounds = 351 decisions per model, one at a time and
interleaved, so every model saw the same minutes; built-in commands (`open` has 135 apps to choose
from). Run: [`20261025-130702_5-models.json`](20261025-130702_5-models.json); resources:
`*_resources-*.json`.

### Accuracy (the app's 0.5 confidence cut-off)

| model | right | wrong runs | missed | best cut-off → right |
|:--|--:|--:|--:|:--|
| jev | **86.6%** | **5** | 42 | 0.40 → 87% |
| local:decider | **88.0%** | 12 | 30 | 0.40 → 89% |
| local:kev | 17.9% | 0 | 288 | 0 → 45% (84 wrong runs) |
| local:laya-ml | 37.6% | 123 | 96 | 0.35 → 43% (138 wrong runs) |
| local:laya | 28.2% | 6 | 246 | 0 → 28% |

- **Decider is as accurate as Jev, but its mistakes are worse.** Jev's 5 wrong runs are "Presenter." →
  `switch-app none` (which runs nothing) and a line of Thai → `open Clock`. Decider's 12 are four
  cases every round: "turn the volume dawn" → **volume 100**, "I think the brightness of this idea
  is great" → brightness +10, "Laws of Physics." → open Wikipedia, "focus on news" → open BBC.
- On misheard speech (tag `heard`, 23 real cases from History), the two are close: Jev 39%,
  Decider 43%.
- **Kev 0.8B and Laya aren't usable as they are.** Kev's answers are spread thin (it serves at
  temperature 2.35), so the app's cut-off takes it from 45% right to 18%. Laya English answers
  "none" at ~99.9% to nearly everything (it isn't truncated: 236 tokens in). Laya multilingual
  guesses, and 123 of its guesses run the wrong command. Kev's own card scores the 0.8B 0.64 on its
  out-of-domain transfer set (4B: 0.79); neither is tuned on commands.

### Wait (ms, one decision: local = command question + its choice question)

| model | min | p50 | p90 | p95 | p99 | max | mean |
|:--|--:|--:|--:|--:|--:|--:|--:|
| local:laya-ml | 22 | **47** | 71 | 89 | 153 | 176 | 50 |
| local:laya | 48 | 74 | 95 | 105 | 123 | 142 | 75 |
| local:kev | 119 | 169 | 220 | 237 | 270 | 329 | 172 |
| jev | 185 | 238 | 312 | 482 | 1578 | 2660 | 296 |
| local:decider | 582 | **963** | 1619 | 2492 | 4006 | 4716 | 1148 |

Decider is 4× Jev at the median and 5× at p95 on an M1 Max; the slow end is `open` (135 apps
to weigh). Jev's long tail (p99 1.6 s) is the network. On battery the GPU may clock lower, so the
local numbers are a best case.

### Memory and energy (`bench/suite.py commands resources`)

| model | memory owned (footprint) | resident (incl. mapped weights) | idle | per decision: CPU / GPU time | energy per decision | 1000 decisions |
|:--|--:|--:|--:|:--|--:|--:|
| jev | — | — | — | one HTTPS request | ≈ 0 (Wi-Fi) | — (+ $0.18) |
| local:decider | 1.5 GB | **6.2 GB** | 0.6% CPU | 25 ms / 1109 ms | ≤ 44 J | ≤ **12%** of the battery |
| local:kev | 3.4 GB (peak 4.8) | 0.6 GB | 0.2% CPU | 23 ms / 139 ms | ≤ 5.7 J | ≤ 1.5% |
| local:laya | 3.7 GB* | 1.0 GB | 0.1% CPU | 8 ms / 41 ms | ≤ 1.7 J | ≤ 0.45% |
| local:laya-ml | 4.5 GB* | 1.1 GB | 0.1% CPU | 10 ms / 27 ms | ≤ 1.1 J | ≤ 0.3% |

- **Energy is an upper-bound estimate**, not a meter reading: CPU time × 5 W + GPU time × 40 W
  (M1 Max busy figures; `procstats.py`). A small model rarely fills the GPU, so real draw is lower.
  `sudo powermetrics --samplers cpu_power,gpu_power -i 500` measures it. Battery: 103 Wh (ioreg).
- At ~100 commands a day: Decider ≲ 1.2% of the battery, Kev ≲ 0.15%, Laya ≲ 0.05%. Idle, all
  four servers cost under 0.05 W. Decider's real cost is keeping 6 GB of a 4B model in memory (it
  needs a 16 GB Mac).
- *Laya's footprint is mostly MLX's GPU buffer cache kept after the large `open` question (3.6 GB of
  "IOAccelerator"); the weights are ~0.8 GB. Embedded in the app, `mx.set_cache_limit` would cap it.
  Kev's server holds PyTorch and MLX and a prompt-prefix cache.

### Verdict

Keep Jev. Decider is the only on-device model that's accurate enough, but it waits ~1 s
(p95 2.5 s) where Jev waits 0.24 s (p95 0.48 s), runs commands it shouldn't in ways that hurt (volume
to 100), and holds 6 GB. It's worth a second look as an **offline fallback** (no network → ask
Decider) rather than the default. Kev 0.8B and Laya would need fine-tuning on command data first.
Bigger Kev models (4B: 721 ms for five questions on an M5, per its README) would land in Decider's range.

### Tuning Decider's speed (5 rounds)

Decider for Mac is llama.cpp running the one GGUF Perplexity publishes (Q8_0); the app has no speed
settings (only its port and start at login). What's left is the request. Its wait follows the prompt:
**~1.4 ms per prompt token**, with nothing cached between requests (the same request twice takes as
long), no gain from two questions in one request, and one request at a time (two in parallel take as
long as in a row). So each round trimmed tokens, as a model modifier (`local:decider+bare+…`), the
candidates interleaved with the current best in one run so the Mac's noise hit both alike (it swung
the same request 0.7–2.7 s between runs: compare within a run, case by case).

| round | change | tokens / decision | wait vs best (paired median) | right | wrong runs | kept |
|:--|:--|--:|--:|--:|--:|:--|
| 0 | baseline (the app's questions) | 628 | — | 88.0% | 4 per round | |
| 1 | `bare`: options named by themselves sent without a meaning (`"Safari": null`) | 599 | ×1.00; `open` 1.93 → 1.25 s, p95 −1 s | 88.0% | 4 | ✓ |
| 2 | `short-choice`: choice question doesn't repeat the command's summary | 592 | ×0.99 | 85.5% | 7 | ✗ |
| 2 | `preamble-short`: one line instead of HEARD | 535 | ×0.90 | 85.5% | 6 | ✗ |
| 3 | `lean-choice`: HEARD on the command question only | 563 | ×0.96 | 88.0% | 4 | ✓ |
| 4 | warm-up ping as command mode starts, vs after 30 s idle | — | no cold start: 0.92 s idle, 0.91 s pinged | | | ✗ (no need) |
| 5 | gap since the last decision: 0 → 4 s | — | back to back 1.06 s (spikes to 2 s); ≥1 s apart 0.90 s | | | (finding) |

- **Best: `local:decider+bare+lean-choice`**: 10% fewer tokens, ~5% less wait on a typical command
  and ~1 s less on `open`, same answers as the baseline.
- **HEARD earns its tokens.** Shortening it lost "A press center." (→ Return) and made "Dear John,
  thanks for the update…" press Return, though it also stopped two bad wrong runs.
- **The bench overstates Decider's wait.** Back to back it's busy for a moment after each answer
  (round 5); commands seconds apart wait **~0.9 s** with a choice and ~0.6 s without (lock, Return)
  on this M1 Max. Jev: 0.24 s.
- **What's left is out of the request's reach:** the command question (~400 tokens, mostly the
  commands' summaries, which Jev shares), a smaller model (none published), shortlisting `open`'s
  135 apps (a name match would miss 打开微信 → WeChat and misheard names), or a newer Mac's GPU.
  The verdict stands: Decider can't get near Jev's 0.24 s here.

**In the app (Oct 25), experimental:** Settings › Experimental › Decide commands on this Mac sends
every command to Decider (`LocalDecider`), never online: `local:decider+bare+lean-choice` here. The
row under it says whether Decider is ready and links to its download (Perplexity's site serves the app
to a browser only, so the app can't install it itself) or opens it. Live (`testLiveLocalDeciderPicksTheBuiltInCommands`):
11 / 11 right, 0.7–2.3 s back to back.

### Running the on-device models

Each runs as its own local server (outside the repo; the app never starts them):

```sh
# Decider: download https://macos-download.perplexity.ai/Decider.dmg, open it; serves :8080 once "Ready"
# Kev (uv; not `pip install kev`):
curl -sL https://codeload.github.com/jaredpalmer/kev/tar.gz/refs/heads/main | tar -xz && cd kev-main
uv sync --extra serve && uv run --extra serve python -m kev.serve --run jaredpalmer/kev-0.8b --port 8009
# Laya (both checkpoints on :8010; LAYA_MODELS=english or multilingual for one):
uv venv .venv && uv pip install --python .venv/bin/python "laya-mlx[serve]"
LAYA_HOST=127.0.0.1 LAYA_PORT=8010 LAYA_TOURNAMENT_GROUP=64 .venv/bin/laya-mlx-serve

bench/suite.py commands run -m jev -m local:decider -m local:kev -m local:laya -m local:laya-ml \
    -r 3 --workers 1 --min-confidence 0       # 0: keep every pick; the report then compares cut-offs
bench/suite.py commands resources -m local:kev   # one local model at a time
bench/suite.py commands run -m local:decider+bare -m local:decider+bare+lean-choice -r 1 --workers 1 \
    --min-confidence 0                        # tuning: variants interleaved; compare case by case
```

`LAYA_TOURNAMENT_GROUP` lets Laya take `open`'s 135 apps (it caps a question at 100 options otherwise).
