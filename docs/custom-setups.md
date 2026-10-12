# Custom setups

A *setup* is a speech model, an AI polish model and a polish prompt, picked together in
Settings → Model. The built-in ones are in `DictationSetup.builtInJSON`
(`Sources/DictationKit/Setups.swift`); how they compare is in [`bench/`](../bench/README.md).

To try another combination in the app, add it to
`~/Library/Application Support/DictationApp/setups.json`. Your setups appear after the built-in
ones. The file is re-read whenever Settings opens, and any problems show under Model.

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
| `speech` | `apple`, or `openrouter:<model id>` |
| `polish` | `apple`, or `openrouter:<model id>[@Provider[,Provider…]]`: only those hosts, in order, trying the next if one fails |
| `prompt` | `v1`–`v4` (from [`bench/polish_prompts/`](../bench/polish_prompts)) or the path to a text file |
| `summary` | optional: a one-line description shown in Settings |
| `backup` | optional: an OpenRouter speech model that is also asked when the main one is slow |
| `backupWait` | optional: seconds to wait before asking `backup` (default 2) |
| `polishBackup` | optional, cloud polish only: `openrouter:…`, also asked when polish is slow or fails |
| `polishBackupWait` | optional: seconds to wait before asking `polishBackup` (default 0.8) |
| `polishDeadline` | optional: seconds before you get the unpolished text instead (default 6) |
| `wrap` | optional: wrap the transcript in `<transcript>` tags (default true) |

Benchmark a setup with `bench/suite.py polish run -m setup:<id>` (quality) or
`bench/suite.py latency run -P setup:<id> --setups-file <file>` (wait time, backup included).
