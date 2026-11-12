# Needle-checksum: a passing run and a failing run

Two real `needle.json` files from the `llm-inference-bench` harness (version 0.8.0), trimmed with `...`. Both ran the same prompt (`prompt_sha256` identical) at C8 with 500 requests on the same Vast host 157204. The probe and the gate are explained in `../references/quality-alarm.md`.

## Passing: the fork reference, 497 of 500

Source: `f3/resultados/vast-20261111/vllm/vast-vllm-r1-rep2/needle.json` (fork image `karmic-kraken-20261016`, QAD checkpoint `dec48abd...`, TP4 + DCP4, MTP3).

```json
"metadata": {
  "version": "0.8.0",
  "engine": "openai_proxy",
  "model": "GLM-5.3-Flash-NVFP4",
  "test_profile": "needle-checksum",
  "fixed_concurrency": 8,
  "requested_runs": 500,
  "expected_answer": "alpha=478 beta=788 gamma=426 checksum=3332",
  "prompt_sha256": "3a1eccf0ec1f204631e65b68eea5fee8b320332dd7f56231cc8c73ae29cf3685",
  "temperature": 0.0,
  ...
},
"all_summary": {
  "attempted": 500,
  "completed": 500,
  "errors": 0,
  "correct": 497,
  "wrong": 3,
  "score_counts": { "exact": 497, "near_miss": 3 },
  ...
  "correct_rate": 0.994,
  ...
  "completion_tokens": { "avg": 99.084, "min": 99.0, "max": 113.0, "p50": 99.0, ... },
  ...
}
```

One of the three wrong runs, from `wrong_runs`:

```json
{
  "run_index": 97,
  "concurrency": 8,
  "correct": false,
  "completion_tokens": 99,
  "prompt_tokens": 8192,
  "finish_reason": "tool_calls",
  "final_answer": "submit_context_check({\"alpha\": 478, \"beta\": 788, \"checksum\": 3330, \"gamma\": 426})",
  "score_label": "near_miss",
  "score_detail": "checksum 3330, expected 3332",
  ...
}
```

How to read it:

- The facts are right (478, 788, 426); only the last digit of the checksum slipped. That is the model's known near tie, not a retrieval failure.
- 3 in 500 is the reference rate. `summarize.py --needle-ref 3/500` compares every other arm against exactly this count.
- `finish_reason` is `tool_calls`: the server parsed the tool call, so tool calling is correctly configured.

## Failing: SGLang with the NVIDIA NVFP4 PTQ checkpoint, 440 of 500

Source: `f3/resultados/vast-20261111/sglang/vast-sglang-nvfp4-1d00738/needle.json` (SGLang, `nvidia/GLM-5.3-Flash-NVFP4` revision `1d00738`, W4A4 MoE).

```json
"metadata": {
  "version": "0.8.0",
  "engine": "sglang",
  "model": "GLM-5.3-Flash",
  "test_profile": "needle-checksum",
  "fixed_concurrency": 8,
  "requested_runs": 500,
  "expected_answer": "alpha=478 beta=788 gamma=426 checksum=3332",
  "prompt_sha256": "3a1eccf0ec1f204631e65b68eea5fee8b320332dd7f56231cc8c73ae29cf3685",
  "temperature": 0.0,
  ...
},
"all_summary": {
  "attempted": 500,
  "completed": 500,
  "errors": 0,
  "correct": 440,
  "wrong": 60,
  "score_counts": { "exact": 440, "near_miss": 60 },
  ...
  "correct_rate": 0.88,
  ...
  "completion_tokens": { "avg": 191.798, "min": 99.0, "max": 259.0, "p50": 188.0, ... },
  ...
}
```

First wrong run:

```json
{
  "run_index": 2,
  "concurrency": 8,
  "correct": false,
  "completion_tokens": 189,
  "prompt_tokens": 8192,
  "finish_reason": "tool_calls",
  "final_answer": "submit_context_check({\"alpha\": 478, \"beta\": 788, \"checksum\": 3330, \"gamma\": 426})",
  "score_label": "near_miss",
  "score_detail": "checksum 3330, expected 3332",
  ...
}
```

How to read it:

- Same failure mode (NEAR_MISS 3330), 20 times as often: 60/500 against 3/500. The one-sided Fisher test against the reference gives p far below 0.05, so `summarize.py` marks the arm `FAIL` (the journal reports p down to 2·10⁻¹⁵ for the SGLang NVFP4 arms, `ARQUITETURA.md §29.5`).
- gsm8k in the same directory scored 95/96 (Observed, `gsm8k.json`), inside the interval of the passing arm. Without the needle this arm would have looked fine.
- The output is about twice as long (p50 188 tokens against 99). Cause Unknown.

## The same check by hand

```bash
python3 -I -c "
import json, sys
s = json.load(open(sys.argv[1]))['all_summary']
print(s['attempted'], s['exact'], s['near_miss'], s['correct_rate'])
" f3/resultados/vast-20261111/vllm/vast-vllm-r1-rep2/needle.json
# 500 497 3 0.994
```

The output line is what the command printed on 2026-11-12 (Observed). For a verdict use `bench/summarize.py --needle-ref 3/500`, which applies the Fisher test.
