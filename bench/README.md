# Speech-to-text benchmark

Compares dictation models on the same audio: **Chinese with English mixed in**, **Chinese only**,
and **English only**, at three levels (L1 easy, L2 hard jargon/idioms, L3 hard + fast + noisy).

```sh
bench/bench.py synth                                   # generate missing audio (macOS `say`)
bench/bench.py run -r 3 -m openrouter:<model-id>       # 3 runs per clip → min/median/max wait
bench/bench.py run -m apple:en-US -m apple:zh-CN        # Apple on-device (needs ./build.sh)
bench/bench.py run -m "openrouter:deepgram/nova-3?language=zh"   # extra API fields after "?"
bench/bench.py report                                  # terminal table, latest run per model
bench/bench.py html                                    # visual comparison → results/report.html
bench/bench.py add clip.m4a --id mixed-real-01 --category mixed --text "帮我 build 一下"
uv run --with pytest --with opencc-python-reimplemented==0.1.7 pytest bench   # scoring tests
```

- **Trying a new OpenRouter model:** list them with
  `curl -s "https://openrouter.ai/api/v1/models?output_modalities=all"` (transcription models don't
  show in the default list), then `bench/bench.py run -r 3 -m openrouter:<id>` and `bench/bench.py html`.
  To offer it in the app, add one case to `TranscriptionModel` in `Sources/DictationKit/Transcription.swift`.
- **Key:** `$OPENROUTER_KEY` by default (`--key-env` to change). The account needs credits, and some
  models (Meta Muse) need the 18+ confirmation in OpenRouter's preferences.
- **Scoring:** token error rate where a token is one Chinese character or one English word. Speaker
  tags are removed and Traditional is converted to Simplified first (flagged separately).
  "EN recall" = English words in mixed sentences that came back right.
- **Cost** is what OpenRouter charged per audio second, shown in the page as a multiple of Meta Muse.
- **Audio** is TTS, so it's cleaner than real speech. Add real recordings with `add` for a truer picture;
  keep case ids stable so results stay comparable.
