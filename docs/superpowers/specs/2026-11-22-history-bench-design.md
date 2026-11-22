# History bench: what vocabulary does on your own dictations

`bench/suite.py history run`. One run answers, on your real History: do the words the app misheard
now come out right, what does that cost in wait, and does it break anything. Cap: 50¢ a run
(`--max-cost`, default 0.50); expected about 5¢.

## What it reads

Read-only, at run time, from `~/Library/Application Support/DictationApp/` (`--data` for another
folder): `history.json`, `vocabulary.json`, `edit-watch.json`, `Recordings/`. The run copies the
three JSON files into a temporary folder first, so the app can keep writing; recordings are read in
place. Nothing is written there.

- **Test set:** dictations with a fix (a correction, or a captured edit you accepted) whose word
  changes have the judge's verdicts. A *mishearing* is a change judged `misheard`. Nov 22: 28 fixes,
  139 changes, 33 mishearings; 26 have a kept recording (matched by time and text; 1,705 s of audio).
- **Subset:** the test set is the subset (28 of 1,337). `--limit N` takes the newest N.

## Privacy

- Nothing real goes in the repo: no dictation, no term, no snippet. Result files hold real text and
  stay in `bench/results/history/` (ignored; never `git add -f`). The committed write-up
  (`bench/results/history/README.md`) has totals only.
- Only fixed dictations go to the cloud (Learn and the judge already send them). Dictations you
  never fixed are only read on this Mac.
- The bench's own key (`$OPENROUTER_BENCH_API_KEY`), never the app's.
- Tests run on a written fixture (`bench/history_fixture/`), never on real data.

## Parts

| # | Part | What runs | Headline number | Cost |
|---|---|---|---|---|
| 1 | Mishearings fixed | stored `raw` → replace → polish with terms → replace, 3 rounds, three arms | mishearings that come out as you wanted, of 33, per arm | cloud polish, ~5¢ |
| 2 | Speech with terms | each recording through the on-device speech model, no terms vs terms, interleaved | mishearings right in the transcript; seconds | $0 |
| 3 | Reach and wrong hits | replacement alone on every stored `raw` and `text` | dictations it would change; hits per entry; hits that move a fixed dictation away from its fix | $0 |
| 4 | Wait | replacement timed on every `raw`; polish wait from part 1; speech wait from part 2 | change in stop-to-text, typical and p95 | $0 |
| 5 | What learns | candidates by the rules alone vs by the judge, against your Add and Dismiss | of the terms you added, share each would have proposed; same for dismissed | $0 |
| 6 | Edit replay | each real fix replayed through the watcher's two trackers | fixes rebuilt exactly, per tracker; the app's own counts from `edit-watch.json` | $0 |

### Arms (parts 1 and 2)

- **off:** no vocabulary (no replacement, no terms in polish, no speech terms).
- **again:** your vocabulary as it is. "If I said the same thing again." Circular on purpose: a term
  learned from a dictation is tested on that dictation.
- **held out:** your vocabulary without the variants and learned entries whose only source is the
  dictation under test (`candidates[].heard[].dictations`; entries you typed in stay). The honest
  number for "does it help on other dictations". Expect it near zero until terms repeat.

### Scoring

- **A mishearing is fixed** when the output has the wanted words (`new`; whole words, case as you
  wrote it) at least as often as your fix does.
- **Word errors against your fix**, whole text: second number only. 100 of 139 changes are style and
  polish differs run to run, so report the mean and the range over rounds.
- Part 1 uses the app's current setup when its polish is in the cloud, else `cloud-flash`
  (`--setup`); the write-up names it.
- Part 3 can't score right or wrong where you made no fix: it counts, lists the hits in the local
  result file, and flags entries whose variant differs only in case or is an ordinary word
  (`CandidateTally`'s test).
- Part 6 synthesizes the keys (per change, last first: arrows, backspaces, the new text). It shows
  the trackers rebuild your real edits, not how you really edit. Text that needs an input method
  (Chinese) is counted apart for the keystroke tracker.

## How it's built

- **The app's own code does the work:** `Vocabulary` replacement, the polish request
  (`OpenRouterPolish`, the setup's prompt and the terms block), `LocalEngine`, `TypedEdit`,
  `SpanTracker`, `CandidateTally`. An XCTest that runs only when asked (`HistoryBenchTests`, like
  `--live` and `--local`) takes a job file and writes rows.
- **Python** (`bench/suites/history.py`) picks the test set, builds the held-out vocabularies,
  writes the job, runs the test, scores, reports.
- **Cost:** `--dry-run` prints calls and an estimate and sends nothing. A run refuses to start above
  `--max-cost`, and the harness stops sending once what the answers report passes it.
- **Not in it:** the tuner's teacher wording. Before and after is two tunes, 54¢, and one pair
  can't resolve a difference inside the tuner's ±1.5 noise.
