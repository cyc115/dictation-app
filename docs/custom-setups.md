# Custom setups

A *setup* is a speech model, an AI polish model and a polish prompt, picked together in
Settings → Model. The built-in ones are in `DictationSetup.builtInJSON`
(`Sources/DictationKit/Polish/Setups.swift`); how they compare is in [`bench/`](../bench/README.md).

To try another combination in the app, add it to
`~/Library/Application Support/DictationApp/setups.json`. Your setups appear after the built-in
ones. The file is re-read whenever Settings opens. A setup with a problem (an unknown model or
prompt, a backup with no model id, an id already used) is left out of the menu, and Settings ›
Speech model says which and why under Model; the rest of the file still loads.

```json
{"setups": [
  {"id": "flash-v2", "title": "Flash, v2 prompt",
   "speech": "openrouter:qwen/qwen3-asr-1.7b", "backup": "qwen/qwen3-asr-0.6b", "backupWait": 2,
   "polish": "openrouter:openai/gpt-oss-120b@Groq", "prompt": "v2"},
  {"id": "mac-my-prompt", "title": "On-device, my prompt",
   "speech": "apple", "polish": "apple", "prompt": "~/prompts/mine.txt", "wrap": false}
]}
```

| Field | Value |
|---|---|
| `speech` | `apple[:<locale>]`, `local:<Hugging Face id>` (on this Mac), or `openrouter:<model id>[@Provider[,Provider…]]`: only those hosts, in order |
| `polish` | `apple`, or `openrouter:<model id>[@Provider[,Provider…]]`: only those hosts, in order, trying the next if one fails |
| `prompt` | `v1`–`v4` or `v7` (from [`bench/polish_prompts/`](../bench/polish_prompts)) or the path to a text file |
| `summary` | optional: a one-line description shown in Settings |
| `backup` | optional, cloud speech only: an OpenRouter speech model also asked when the main one is slow, `<model id>[@Provider[,Provider…]]` without `openrouter:` (e.g. `mistralai/voxtral-mini-transcribe@Mistral`). It needs a model id: `""`, `"@"` or `"@Mistral"` gets the setup refused. `"<model id>@"` names no host, as for `speech` |
| `backupWait` | optional: seconds to wait before asking `backup` (default 2) |
| `polishBackup` | optional, cloud polish only: `openrouter:…`, also asked when polish is slow or fails |
| `polishBackupWait` | optional: seconds to wait before asking `polishBackup` (default 0.8) |
| `polishDeadline` | optional: seconds before you get the unpolished text instead (default 6) |
| `wrap` | optional: wrap the transcript in `<transcript>` tags (default true) |

Benchmark a setup with `bench/suite.py polish run -m setup:<id>` (quality) or
`bench/suite.py latency run -P setup:<id> --setups-file <file>` (wait time, backup included).
