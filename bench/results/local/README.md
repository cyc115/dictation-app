# Local speech models (Oct 18, 2026)

Can a model running on this Mac (MLX, M-series GPU) replace the cloud for the speed and
predictability of the wait, without losing accuracy? Prompted by Cloud Flash's slow spells: on the
evening of Oct 18 its main model answered 6 of 21 dictations in time, and one waited 47.8 s.

Runner: `bench/local_stt.py` (`parakeet:` = NVIDIA Parakeet TDT through parakeet-mlx, as
zisshh/computer-use runs it; `mlx:` = any mlx-audio model). Model loaded and warmed once; each clip
decoded straight from memory. Machine: this Mac, other apps running as usual.

## Accuracy on the test set (`bench.py run`, 46 TTS clips × 3)

| model | mixed | EN recall | chinese | english | p50 wait |
|:--|--:|--:|--:|--:|--:|
| cloud `qwen/qwen3-asr-1.7b` (Cloud Flash, Oct 7) | 90% | 81% | 100% | 100% | 0.57 s |
| **local `Qwen3-ASR-1.7B-8bit`** | **90%** | **81%** | **100%** | **100%** | 0.46 s |
| cloud `qwen/qwen3-asr-0.6b` (Cloud Flash's backup) | 85% | 73% | 100% | 97% | 0.54 s |
| local `Qwen3-ASR-0.6B-8bit` | 86% | 77% | 100% | 97% | 0.24 s |
| local Parakeet TDT 0.6B v2 | 9% | 38% | 0% | 98% | 0.12 s |
| local Parakeet TDT 0.6B v3 | 12% | 51% | 0% | 95% | 0.13 s |
| Apple on-device `en-US` | 9% | 34% | 0% | 79% | 0.69 s |

Parakeet doesn't know Chinese (v2 is English-only, v3 European languages): it turns mixed speech
into English-sounding words ("帮我 build 一个…" → "Bangwa built eager young ho…"). 43% of your
dictations have Chinese in them (29% mixed, 13% Chinese, of 529).

## Your recordings (`recordings_compare.py`, 460 kept dictations, 1 s – 4.7 min)

Stop to text, seconds: typical / p95 / worst. Cloud = what the dictation took when you made it.

| clip length | cloud (as dictated) | local 1.7B | local 0.6B |
|:--|--:|--:|--:|
| 0–10 s (183) | 1.02 / 3.60 / 56.6 | 0.51 / 0.89 / 1.1 | 0.22 / 0.42 / 0.6 |
| 10–20 s (117) | 1.34 / 3.48 / 29.6 | 0.99 / 1.48 / 2.2 | 0.44 / 0.61 / 1.1 |
| 20–30 s (54) | 1.38 / 3.27 / 3.6 | 1.73 / 2.03 / 2.6 | 0.70 / 0.91 / 1.4 |
| 30–60 s (62) | 1.78 / 5.46 / 17.7 | 2.55 / 4.07 / 4.7 | 1.11 / 1.75 / 1.9 |
| 60+ s (44) | 3.28 / 34.1 / 47.2 | 5.80 / 12.5 / 22.3 | 2.63 / 7.29 / 112.3 |
| all (460) | 1.49 / 5.20 / 56.6 | 0.95 / 5.67 / 22.3 | 0.43 / 2.61 / 112.3 |

- Local Qwen decodes token by token, so its time grows with the dictation: the 1.7B is faster than
  the cloud's typical wait up to ~20 s and slower beyond, but never has the cloud's 30–57 s stalls.
  The 0.6B is 2–3× faster than the 1.7B at every length.
- The 0.6B's 112 s: a 2.3-minute dictation where it looped "ah, ah, ah…" for 16,000 characters.
  An app version needs an output cap (tokens per second of audio). The cloud loops too ("No, no,
  no…" on 2 clips, "Ahora" on silence).
- Agreement with the cloud's transcript (fillers removed): local 1.7B vs cloud 1.7B 90%, local
  0.6B vs cloud 0.6B 89%: same models, 8-bit weights; most differences are punctuation and fillers.

English-only recordings (261), with Parakeet v2:

| clip length | cloud (as dictated) | local 1.7B | local 0.6B | Parakeet v2 |
|:--|--:|--:|--:|--:|
| 0–10 s (116) | 0.94 / 3.63 / 56.6 | 0.52 / 0.89 / 1.1 | 0.24 / 0.47 / 0.6 | 0.12 / 0.28 / 0.5 |
| 10–20 s (79) | 1.35 / 3.26 / 29.6 | 0.99 / 1.42 / 2.2 | 0.45 / 0.60 / 1.1 | 0.26 / 0.53 / 1.1 |
| 30–60 s (21) | 1.77 / 14.1 / 17.7 | 2.55 / 3.85 / 4.4 | 1.14 / 1.63 / 1.9 | 0.75 / 1.12 / 1.6 |
| all (261) | 1.33 / 4.29 / 56.6 | 0.87 / 3.09 / 11.0 | 0.39 / 1.33 / 112 | 0.22 / 1.09 / 3.4 |

Quality on your English voice, judged by two independent referees (Deepgram Nova-3 and Grok STT,
fillers removed; the referees agree with each other 84.7%, so that's the noise floor):
Parakeet v2 85.6%, the cloud as dictated 84.8% (on clips the cloud's 1.7B answered: 86.5% vs 86.9%;
where its 0.6B backup answered: 84.6% vs 82.2%). Parakeet keeps every "uh"/"um" (polish removes
them), returns nothing on silence where the cloud invented text, and misses a few terms the cloud
got ("client order flow" → "Klein Orderflow"). Referee run: $0.43.

## In the app (Oct 18, after On-device switched to it)

`bench/suite.py latency run --alongside --local -P none` on the installed build (b154761): the app's
own `LocalEngine.stop()`, interleaved with Cloud Flash as the app runs it, 9 clips × 5 rounds:

| speech model | p50 | p90 | p95 | worst | cold |
|:--|--:|--:|--:|--:|--:|
| On-device, Qwen3-ASR 1.7B 8-bit | 0.42 s | 1.21 s | 1.36 s | 1.45 s | 7.87 s |
| Cloud Flash + backup | 0.53 s | 1.42 s | 1.75 s | 3.02 s | 2.54 s |

Cloud Flash's backup (the 0.6B) answered 41 of 45: a slow spell. "Cold" is a fresh process loading
the model as the first clip arrives; the app preloads it on power and loads it while you speak on
battery. In the app process the model takes 2.5–2.6 GB (peak 2.9 GB while loading). The first decode
in a process compiles GPU kernels (6.4 s), so loading ends with a warm-up decode; the very first
load on a Mac took 9 s more while macOS compiled MLX's GPU code, once.

## Verdict

- **Parakeet v2**: fastest and most predictable (worst 3.4 s), as good as Cloud Flash on English,
  but useless on Chinese. Only for English-only dictation.
- **Local Qwen3-ASR**: the same models as Cloud Flash with the same accuracy, Chinese included, and
  no network stalls. The 0.6B beats the cloud's typical wait at every length (0.43 s vs 1.49 s
  overall, p95 2.6 s vs 5.2 s) at Cloud Flash's backup's accuracy; the 1.7B matches Cloud Flash's
  accuracy and wins up to ~20 s dictations.
