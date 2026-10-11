# Corrections: fix a dictation, keep it as a polish test case

Mockup: https://claude.ai/artifact/MH8xe55ZnjYwztgHtc79Dz

## Goal

When a dictation comes out wrong, you fix it once in the app. The fix is kept as a test case:
the speech model's raw text, what the app wrote, and what you wanted, all on the dictation's
entry in `history.json`. `bench/suite.py polish run`
can then test any setup or prompt against your own dictations.

Step 1 (this spec) only collects the data. Step 2, adding corrections to the polish prompt so the
app learns from them, comes later, once step 1 data shows it helps.

## What you see

- **History:** each row gets a pencil button beside Copy. Clicking it adds a correction (the right
  side starts as a copy of the text) and opens it in Corrections, ready to edit. A row that already
  has a correction shows a blue check instead; clicking it opens that correction.
- **Sidebar:** a new "Corrections" tab between History and Settings, with a count badge.
- **Corrections tab:** headline "Corrections", line "Teach the app the way you speak." Search box.
  Newest first. Each card:
  - date, time, setup title and prompt version (e.g. "Cloud Flash · prompt v3"), delete button;
  - left: what the app wrote, read-only, the words you changed highlighted orange;
  - right: what you want, editable, saved as you type;
  - "Before polish" disclosure with the raw text, when known.
  - Footer: "Corrections are saved in history.json" — the file name shows it in Finder.
- **Clear All** in History deletes corrections too; when there are any, the dialog says how many
  ("Delete all dictation history, including 3 corrections?").

## Data

Everything stays in `history.json`. `HistoryEntry` gains optional fields (older entries decode
without them; nil fields aren't written):

| field | what |
|---|---|
| `raw` | text before polish; nil when polish didn't run (then it equals `text`) |
| `setup` | setup id, e.g. `cloud-flash` |
| `prompt` | prompt version used for polish, e.g. `v3`; nil when not polished |
| `correction` | what you wanted; nil = no correction |

- A dictation has a correction when `correction` is set. Emptying the right side removes it
  (empty is saved as nil). One correction per dictation, by construction.
- The Corrections tab is `HistoryStore.entries` filtered to those with a correction; no second store.
- Keep history (7 / 30 days) never prunes an entry with a correction: it's kept until you delete it.
  With Keep history off nothing is saved, so there's nothing to correct (the pencil isn't shown).
- `correction` equal to `text` is allowed (a "this was right" case).

## Bench

`bench/suite.py polish run --corrections` reads `history.json` and turns each corrected entry into
a case: `raw` (falling back to `text` for entries saved before this change), `expected` =
`correction`, id = the entry id, no `must`/`must_not`. Optional path argument for another file.
README gets a line.

## Not in step 1

- Feeding corrections into the polish prompt (step 2).
- Keeping or linking audio for speech-model tests.
- Editing the left side, or correcting a dictation that isn't in History.

## Tests

- `HistoryStore`: set, edit, clear (empty → nil) a correction; reload from an injected file URL;
  pruning keeps corrected entries.
- `HistoryEntry` decodes old JSON without the new fields; `deliver` records raw, setup, prompt.
- UI (`HostedView`): pencil on a history row creates a correction and switches to the tab; check
  shown afterwards; editing the right side saves.
- Snapshots for the Corrections tab and the History row with the new button.
- Bench: a `history.json` with corrections loads as cases and scores.
