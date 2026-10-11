# Corrections: fix a dictation, keep it as a polish test case

Mockup: https://claude.ai/artifact/MH8xe55ZnjYwztgHtc79Dz

## Goal

When a dictation comes out wrong, you fix it once in the app. The fix is kept as a test case:
the speech model's raw text, what the app wrote, and what you wanted. `bench/suite.py polish run`
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
  - Footer: "Corrections are saved in corrections.json" — the file name shows it in Finder.
- **Clear All** in History keeps corrections; the dialog says "Your corrections are kept."

## Data

`HistoryEntry` gains three optional fields, filled from now on (older entries decode without them):

| field | what |
|---|---|
| `raw` | text before polish; nil when polish didn't run (then it equals `text`) |
| `setup` | setup id, e.g. `cloud-flash` |
| `prompt` | prompt version used for polish, e.g. `v3`; nil when not polished |

`~/Library/Application Support/DictationApp/corrections.json`, same folder and style as
`history.json`, in the polish bench's case format so `--cases-file` reads it as is:

```json
{"about": "Your corrections (DictationApp › Corrections).",
 "cases": [{
   "id": "<history entry id>",
   "date": "2026-10-08T03:18:00Z",
   "raw": "can you install cloud code so i can …",
   "output": "Can you install Cloud Code so I can …",
   "expected": "Can you install Claude Code so I can …",
   "setup": "cloud-flash", "prompt": "v3",
   "must": [], "must_not": []
 }]}
```

- `raw` falls back to `output` for entries saved before this change (the bench then tests
  whether polish leaves your text as you want it).
- `id` is the history entry's id: one correction per dictation, and how History knows to show the check.
- Corrections are their own store (`CorrectionStore`), not part of `HistoryStore`, so history
  retention and Clear All never touch them.
- Setting `expected` equal to `output` is allowed (a "this was right" case).

## Bench

`bench/suite.py polish run --cases-file ~/Library/Application\ Support/DictationApp/corrections.json`
works with no other change, if case loading tolerates the extra fields and empty `must` lists.
A test covers that. Add a `--corrections` shortcut for that path. README gets a line.

## Not in step 1

- Feeding corrections into the polish prompt (step 2).
- Keeping or linking audio for speech-model tests.
- Editing the left side, or correcting a dictation that isn't in History.

## Tests

- `CorrectionStore`: add, edit, delete, reload from an injected file URL; one per history id;
  survives `HistoryStore.clear()`.
- `HistoryEntry` decodes old JSON without the new fields; `deliver` records raw, setup, prompt.
- UI (`HostedView`): pencil on a history row creates a correction and switches to the tab; check
  shown afterwards; editing the right side saves.
- Snapshots for the Corrections tab and the History row with the new button.
- Bench: a `corrections.json` loads as cases and scores.
