# Command mode's decision model

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
```

`LAYA_TOURNAMENT_GROUP` lets Laya take `open`'s 135 apps (it caps a question at 100 options otherwise).
