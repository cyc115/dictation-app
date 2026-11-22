# Vocabulary on your own History

`bench/suite.py history run` (spec: `docs/superpowers/specs/2026-11-22-history-bench-design.md`).
Totals only: no dictation, term or snippet goes in this file. The result files beside it hold your
text and are git-ignored; never `git add -f` one.

## Method

- **Reads** a snapshot of `history.json`, `vocabulary.json`, `edit-watch.json` (and
  `learned-prompts.json`, `setups.json` for the setup's prompt), copied to a temporary folder;
  `Recordings/` is read in place. Nothing is written to the app's folder.
- **Test set:** dictations with a correction of yours or a captured edit you accepted (not `auto`
  captures, not waiting ones) whose word changes, worked out from that fix, have the judge's
  verdicts. A *mishearing* is a change judged `misheard`. Polish's input is the stored `raw`, or the
  pasted text for entries saved before `raw` was kept (Learn does the same).
- **Recordings** are matched to dictations by time and text: a sidecar that ended at most 90 s
  before the entry was saved, with the same polished text, or the same transcript as the entry's
  `raw` (or text). The nearest wins; each recording goes to one dictation.
- **The app's code does the work** (`HistoryBenchTests`): `DictationController.refine` (replace,
  polish, replace), the setup's `OpenRouterPolish` with the terms block, `LocalEngine` with
  `DictationController.speechHint`, the real `EditWatcher` (readback: `SpanTracker`; keystrokes:
  `TypedEdit`) with a fake Mac, `CandidateTally`.
- **Arms.** *off*: no vocabulary. *terms only* (part 1): the terms block in polish, no replacement
  before or after. *again*: your vocabulary as it is (circular: a term learned from a dictation is
  tested on it). *held out*: without the variants and learned entries whose only source is the
  dictation under test. A source is a fixed dictation whose word changes have that heard and term
  (edges trimmed, any case), together with the candidates' `dictations`: a candidate that stops
  counting is kept with `heard: []`, so History is read too. Entries you typed stay; a learned
  entry with no known source stays, and the report counts those on their own line. It keeps an
  entry or variant this dictation helped teach along with others, even one it tipped over the
  3-dictation line, so it leans toward *again*: read it as an upper bound for "helps on other
  dictations".
- **Part 1** polishes with the main model only (no backup model, no deadline), so its wait is the
  model's own; a failed call scores what the app would paste (the replaced transcript) and counts
  as an error. 3 rounds; mean and range.
- **Two prompts.** Every arm runs under the setup's active *learned* prompt (tuned on these same
  fixes, so it may name the terms already: "off" there is Learn's prompt without vocabulary) and
  under its *base* prompt (the setup as read, before any learned prompt: what vocabulary does on its
  own). Prompts and arms run back to back per dictation in a seeded order. With no learned prompt
  active, base only. `--prompts` and `--arms` pick a subset. Since the built-in prompt can be a
  promoted learned one that names terms (v7 does), `--prompts` also takes an older built-in version
  by name (`--prompts learned,base,v4`): the setup's model and wrap with that version as its prompt,
  reported as `prompt: v4 (built-in)`; one that is the base or learned prompt runs once.
- **Scoring.** A mishearing is fixed when the output has the wanted words at least as often as your
  fix, whole words in your case; *fixed, any case* is the same rule compared case-insensitively
  ("Ticketmaster" for your "ticketmaster"). Words are `WordDiff`'s: a Chinese character is a word, so a Chinese
  term counts wherever its characters stand in a row; a Latin term needs whole words, with only
  `FixIntake`'s edge punctuation around them. Word errors against the whole fix are the bench's
  token error rate (second number: most changes are style).
- **Part 2** scores the transcript as heard and after the arm's replacement.
- **Part 3** counts what replacement alone changes in every stored raw and pasted text; hits are
  counted on the raw transcript (else the text). A fixed dictation is moved *away* from its fix when
  replacement raises its word distance to the fix (words as written, so a case fix counts).
- **Part 4**'s replacement time is from a debug build (`swift build --build-tests`): it overstates
  the shipped app.
- **Part 5**: *rules* is `CandidateTally.support` with every verdict taken off; *judge* is the
  verdicts as they are (an unjudged change waits). *Proposed*: the term is a candidate; *learns*: seen
  in 3+ dictations. Compared with your candidates marked added and dismissed. `vocabulary.json`
  doesn't say whether you added a term (Add now) or the 3-dictation rule did, so "added: learns" is
  partly circular for the rules.
- **Part 6** is tracker fidelity with synthesized keys (per change, last first: arrows, backspaces,
  the new text; a change is a run of differing characters), not how you edit. Fixes whose new text
  isn't ASCII would need an input method, which makes keystroke mode give up: counted apart. Text a
  fix adds before or after the paste is never part of the span (by design), so those misses are
  named apart too.

## Results

| date | commit | setup, prompt | fixed dictations | mishearings | cost |
|:--|:--|:--|--:|--:|--:|
| Nov 22 | `3c3d8f3` | cloud-flash, learned (v8); all six parts | 27 | 33 | $0.0557 |
| Nov 22 | `23f1bed` | cloud-flash, v4 (built-in); part 1 | 27 | 33 | $0.0569 |

Part 1, mishearings fixed of 33 (mean over 3 rounds, range). The first run predates the any-case
score. When these were dictated, 0–1 of the 33 came out right (they are the ones that were fixed).

| prompt | arm | fixed | fixed, any case | word errors vs fix | polish p50 | polish p95 |
|:--|:--|--:|--:|--:|--:|--:|
| learned (v8) | off | 15.7 (15–16) | — | 20.3% | 0.25 s | 0.97 s |
| learned (v8) | terms only | 15 | — | 20.8% | 0.26 s | 0.87 s |
| learned (v8) | again | 15 | — | 20.6% | 0.26 s | 0.88 s |
| learned (v8) | held out | 15.3 (14–16) | — | 20.6% | 0.26 s | 0.86 s |
| v4 (built-in) | off | 4 | 5 | 28.4% | 0.28 s | 0.95 s |
| v4 (built-in) | terms only | 10.3 (10–11) | 14.3 (14–15) | 26.9% | 0.25 s | 0.99 s |
| v4 (built-in) | again | 10.3 (10–11) | 14.3 (14–15) | 26.4% | 0.27 s | 0.94 s |
| v4 (built-in) | held out | 4.7 (4–5) | 7.7 (7–8) | 29.4% | 0.29 s | 1.10 s |

- **On its own, vocabulary fixes more of them, mostly where the term came from.** Under a prompt
  that names none of the terms: 4 → 10.3 of 33 with the vocabulary as it is (any case 5 → 14.3),
  which is circular (each term is scored on the dictation it was learned from), and 4 → 4.7 held
  out (any case 5 → 7.7), the honest number for other dictations.
- **The gain is the terms told to polish:** *terms only* equals *again*, so replacement added
  nothing to the count. (How often replacement fired isn't recorded per row; part 3 shows it
  changes 11 raw transcripts.)
- **On top of the learned prompt it adds nothing** (15.7 → 15, inside the range). The learned prompt
  was tuned on these fixes and names most of the terms itself; so does the built-in v7 (not run:
  it is that learned prompt promoted). Learn's prompt alone beats vocabulary alone (15.7 vs 10.3):
  it carries terms the vocabulary doesn't hold, some of which are ordinary words when misheard and
  can't be replacement variants.
- **Held out is close to off** under v4 (4.7 vs 4; any case 7.7 vs 5): the gain on other
  dictations is the few terms that recur.
- **The wait doesn't move** under either prompt (p50 within 0.03 s, no direction).
- Not run: the base prompt (v7). One vocabulary (12 entries), one model, 27 dictations.
- Bearing on the tuner: its teacher was told on Nov 22 to leave misheard terms to the vocabulary
  (`bf628c8`). These runs say the prompt's own term list is what fixes most of them today, so a
  tune under that wording may lose fixes unless those terms are in the vocabulary first.

Part 2, speech with terms (on-device, 25 recordings, 32 mishearings; one pass):

| arm | right in transcript | after replacement | p50 | p95 |
|:--|--:|--:|--:|--:|
| off | 5 | 5 | 3.12 s | 15.75 s |
| again | 11 | 11 | 3.37 s | 13.54 s |
| held out | 5 | 5 | 3.02 s | 13.44 s |

The hint fixes 6 more of 32 on the dictations its terms came from, none on the others, for about
+0.25 s typical on recordings with a median of 44 s of speech (one pass; held out measured −0.10 s,
so the noise is of that size). Replacement added nothing to any arm's count.

Parts 3–6 (first run):

| part | number |
|:--|:--|
| 3 reach | dictations changed: 15 of 1,346 (11 raw of 1,002, 12 pasted text) · hits: 16 from 8 of 12 entries · fixed dictations changed: 10, toward the fix 10, away 0 · flagged entries: 2 case-only (1 hit), 0 ordinary-word |
| 4 wait | replacement p50/p95: 45 µs / 197 µs (debug build, n=1,002) · polish change vs off, learned prompt: +0.01 s p50 (terms only and again) · speech change with the hint: +0.25 s p50 |
| 5 what learns | of 13 terms added, proposed by rules / judge: 10 / 7 · of 29 dismissed, proposed by rules / judge: 29 / 8 · neither learns any at 3 dictations |
| 6 edit replay | readback exact: 27 of 27 · keystrokes exact: 12 of 12 · input method apart: 15 · app counts: 13 armed, 4 probes failed, 1 keystroke give-up, 0 captures |
