# The fix judge

## First run (Nov 22, 2026)

`bench/suite.py edits run` on the 45 written fixes (54 word changes) in `edit_cases.json`, three
models, batches of 1 and 10, at commit a2fa672: `20261122-045602_judge-first.json`, 6.9¢ in all.
Sonnet 5.5 and Gemini 3.8 Flash refused "reasoning off" and ran at the lowest effort, as the app
falls back to; DeepSeek ran with it off.

| model | batch | right | misheard precision | p50 | per 1,000 fixes |
|:--|--:|--:|--:|--:|--:|
| **Claude Sonnet 5.5** (the app's) | **10** | **98%** | **95%** | 1.62 s | $0.34 |
| Claude Sonnet 5.5 | 1 | 94% | 87% | 1.00 s | $0.57 |
| DeepSeek V4.1 Flash | 10 | 93% | 83% | 1.38 s | $0.02 |
| DeepSeek V4.1 Flash | 1 | 93% | 83% | 0.62 s | $0.05 |
| Gemini 3.8 Flash | 10 | 89% | 82% | 1.84 s | $0.12 |
| Gemini 3.8 Flash | 1 | 89% | 86% | 1.42 s | $0.42 |

Every answer covered every change. *Right*: verdicts that match the label. *Misheard precision*:
of the changes called misheard, the share that were (a wrong one would teach vocabulary a bad
variant). p50 is per request.

- **The misses.** Every miss by Sonnet and DeepSeek was an `unclear` case called misheard ("Ben" →
  "Ken", "fifteen" → "fifty", "ship" → "shift"): Sonnet 1 of 4 in batches of 10, 3 of 4 one at a
  time; DeepSeek all 4 both ways. Gemini also called two misheard names style ("neo vim" →
  "Neovim", "Jo Ann" → "Joanne") and, one at a time, one unclear case a change of mind. No model called a change
  of mind or a style fix misheard.
- **Batching held accuracy** for all three, so the app keeps batches of 10 and Sonnet 5.5 as the
  default `judgeModel`.
- **One run, 54 changes:** a change is about 2 points, so differences of a few points are noise.
- **The set shares examples with the prompt:** 14 of the 54 changes are pairs the judge's
  instructions give as examples ("open router" → "OpenRouter", "deep sea" → "DeepSeek", "Amerspoon"
  → "Hammerspoon", "克劳德" → "Claude", "Tuesday" → "Thursday", "GPT" → "Claude"), and the cases and
  the prompt were written together, so the table flatters every model. Rescored from the saved
  result without those 14 (40 changes), the order is the same:

  | model | batch | right | misheard precision |
  |:--|--:|--:|--:|
  | **Claude Sonnet 5.5** | **10** | **98%** (39/40) | **91%** (10/11) |
  | Claude Sonnet 5.5 | 1 | 92% (37/40) | 77% (10/13) |
  | DeepSeek V4.1 Flash | 10 | 90% (36/40) | 71% (10/14) |
  | DeepSeek V4.1 Flash | 1 | 90% (36/40) | 71% (10/14) |
  | Gemini 3.8 Flash | 10 | 85% (34/40) | 67% (8/12) |
  | Gemini 3.8 Flash | 1 | 85% (34/40) | 73% (8/11) |

  Before the next run, change the examples in `JudgeFixes.txt` or the cases so none is shared.

## Apple Intelligence (the On-device setup), Nov 22

This was measured in a one-off test on this Mac, not with the suite: the app's former
`OnDeviceJudge`, one fix a call, on the same 45 cases, free.

- 20 of 54 changes right (37%), and only 36 of 54 covered.
- Misheard precision 11 of 24.
- By label: changed mind 3 of 12 right, style 6 of 18, unclear 0 of 4.
- 1.7 s a fix (p50).

It called changes of mind misheard (GPT → Claude, Sarah → Daniel, three → five), so the On-device
setup has no judge: it uses the rules and sends nothing.
