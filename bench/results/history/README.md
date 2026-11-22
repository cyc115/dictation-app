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
  dictation under test (entries you typed stay; a variant with no candidate stays). It keeps an
  entry or variant this dictation helped teach along with others, even one it tipped over the
  3-dictation line, so it leans toward *again*: read it as an upper bound for "helps on other
  dictations".
- **Part 1** polishes with the main model only (no backup model, no deadline), so its wait is the
  model's own; a failed call scores what the app would paste (the replaced transcript) and counts
  as an error. 3 rounds, arms back to back per dictation in a seeded order; mean and range.
- **Scoring.** A mishearing is fixed when the output has the wanted words at least as often as your
  fix, whole words in your case. Words are `WordDiff`'s: a Chinese character is a word, so a Chinese
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
| | | | | | |

Part 1, mishearings fixed (mean over rounds, range):

| arm | fixed | word errors vs fix | polish p50 | polish p95 |
|:--|--:|--:|--:|--:|
| off | | | | |
| terms only | | | | |
| again | | | | |
| held out | | | | |

Part 2, speech with terms (on-device):

| arm | right in transcript | after replacement | p50 | p95 |
|:--|--:|--:|--:|--:|
| off | | | | |
| again | | | | |
| held out | | | | |

Parts 3–6:

| part | number |
|:--|:--|
| 3 reach | dictations changed: · hits: · moved away from a fix: · flagged entries: |
| 4 wait | replacement p50/p95: · polish change (terms only, again vs off): · speech change: |
| 5 what learns | added proposed, rules / judge: · dismissed proposed, rules / judge: |
| 6 edit replay | readback exact: · keystrokes exact: · input method apart: · app counts: |
