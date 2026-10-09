# Latency baseline — before optimization

Recorded 2026-10-09 by the app's owner on a MacBook Pro (MacBookPro18,2, macOS 27.0.1), home network.
Run: `bench/suite.py latency run` with all three speech models (On-device en-US, Cloud Flash, Cloud Big)
× {no polish, Apple on-device polish}, default 9 clips × 5 rounds + 1 warm-up per model. Seconds.
Pasted from the terminal report; the full JSON stayed on the Mac (`results/latency/`).

## Transcription — stop pressed → raw text

| speech model | n | errors | best | p50 | p90 | p95 | worst | cold |
|:--|--:|--:|--:|--:|--:|--:|--:|--:|
| On-device en-US | 45 | | 0.05 | 1.10 | 2.10 | 2.11 | 2.22 | 0.27 |
| Cloud Flash (qwen/qwen3-asr-1.7b) | 42 | 3 | 0.49 | 2.01 | 14.86 | 28.40 | 49.84 | 1.39 |
| Cloud Big (meta/muse-voice-transcribe-1.0) | 45 | | 1.16 | 2.35 | 6.37 | 6.82 | 7.58 | 1.75 |

## AI polish — raw text → polished text

| polish model | n | errors | best | p50 | p90 | p95 | worst | cold |
|:--|--:|--:|--:|--:|--:|--:|--:|--:|
| Apple on-device | 132 | | 0.79 | 2.42 | 3.87 | 4.03 | 4.22 | 2.40 |

## Turnaround — stop pressed → text ready to paste

| speech model + polish | n | errors | best | p50 | p90 | p95 | worst | cold |
|:--|--:|--:|--:|--:|--:|--:|--:|--:|
| On-device + no polish | 45 | | 0.05 | 1.10 | 2.10 | 2.11 | 2.22 | 0.27 |
| Cloud Flash + no polish | 42 | 3 | 0.49 | 2.01 | 14.86 | 28.40 | 49.84 | 1.39 |
| Cloud Big + no polish | 45 | | 1.16 | 2.35 | 6.37 | 6.82 | 7.58 | 1.75 |
| Cloud Big + Apple on-device | 45 | | 2.05 | 3.58 | 10.27 | 10.57 | 11.29 | 2.90 |
| Cloud Flash + Apple on-device | 42 | 3 | 1.50 | 4.06 | 17.64 | 30.80 | 52.32 | 2.31 |
| On-device + Apple on-device | 45 | | 0.85 | 4.75 | 6.04 | 6.17 | 6.21 | 2.66 |

## What stands out (optimization targets)

1. **On-device piles up at ~2.1 s**: p90 2.10, p95 2.11, worst 2.22. That's `SpeechEngine.finalResultTimeout`
   (2.0 s). On many clips the recognizer never sends `isFinal` after `endAudio()`, so stop() waits out the
   timeout. The text is usually already complete by then, so this is mostly avoidable wait.
2. **Apple polish is ~2.4 s typical, 4 s at p95**, not the "~1 s" the Settings copy claims. `PolishService`
   creates a new `LanguageModelSession` per dictation and never prewarms it.
3. **Cloud Flash has a long tail plus 3 errors**: p50 2.0 s but p95 28 s and worst 50 s. Cloud Big is
   steadier (p95 6.8 s). Nothing currently caps how long a dictation can wait on a slow upload (60 s request
   timeout).

## Fixes since (re-run to compare)

- **#1** `SpeechEngine.stop()` now finishes once the recognizer has gone quiet: no new words for 0.35 s,
  at least 0.2 s after stop, never past 2 s. A real final result still finishes immediately. Expect
  On-device p50/p95 well under the old 1.10 / 2.11 s. Check On-device accuracy didn't drop
  (`bench.py run -m apple:en-US`).
- **#2** Apple polish is created and prewarmed when dictation starts (`PolishService.prepare()`),
  so loading overlaps with speaking. The benchmark prepares it at trial start the same way. The
  Settings copy now says "about 2 seconds"; update it once the new numbers are in.
- **#3** Cloud Flash (qwen3-asr-1.7b) has a single OpenRouter provider (DeepInfra), so there's no faster
  provider to route to. Instead, if it hasn't answered within 3 s, or fails, qwen3-asr-0.6b is asked too
  and the first transcript wins (`UploadRace`). The report says how many dictations the fallback answered.
  *Since then:* this is the "Backup model when slow" setting (`AdaptiveBackup`): it waits 2 s, not 3,
  and after a late answer asks both models at once for 5 min; off, only Cloud Flash is asked. It's on
  by default since an interleaved run cut Cloud Flash's p95 from 9.35 s to 1.20 s (3 of 27 answers
  came from the backup). Measure it with `bench/suite.py latency run --backup`.
  OpenRouter's STT `provider` object doesn't document `sort`, and 0.6b is also DeepInfra-only, so no
  routing preference is sent.
