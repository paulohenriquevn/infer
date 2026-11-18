# gsm8k: what a result looks like

Real `gsm8k.json` excerpts from the fork on Vast host 157204, trimmed with `...`. Why gsm8k cannot rank arms is in `../references/quality-alarm.md`.

## Run with two errors: 94 of 96

Source: `f3/resultados/vast-20261111/vllm/vast-vllm-r1/gsm8k.json` (fork, TP4 + DCP4, MTP3, C8).

```json
"accuracy": {
  "items_total": 1319,
  "items_selected": 96,
  "attempted": 96,
  "scored": 96,
  "correct": 94,
  "accuracy": 0.9791666666666666,
  "wilson95_low": 0.9271928642112758,
  "wilson95_high": 0.9942680301991423,
  "unparseable": 0,
  "truncated_no_answer": 0,
  "hit_max_tokens": 0,
  "errors": 0,
  "dataset_exhausted": false
}
```

The two wrong items, from `wrong_runs`:

```json
{ "run_index": 44, "item_id": "gsm8k-0590", "completion_tokens": 382, "finish_reason": "stop",
  "score_label": "fail", "score_detail": "expected 319, got 318", "parsed_answer": "318", "expected_answer": "319", ... }
{ "run_index": 59, "item_id": "gsm8k-0796", "completion_tokens": 374, "finish_reason": "stop",
  "score_label": "fail", "score_detail": "expected 2.88e+06, got 1.04e+06", "parsed_answer": "1.04e+06", "expected_answer": "2880000", ... }
```

## Repeat of the same configuration: 96 of 96

Source: `f3/resultados/vast-20261111/vllm/vast-vllm-r1-rep2/gsm8k.json`.

```json
"metadata": { "test_profile": "gsm8k", "fixed_concurrency": 8, "requested_runs": 96, "temperature": 0.0,
              "dataset": "gsm8k_test",
              "dataset_sha256": "3730d312f6e3440559ace48831e51066acaca737f6eabec99bccb9e4b3c39d14",
              "max_tokens": 131072, ... },
...
"accuracy": { "items_total": 1319, "items_selected": 96, "attempted": 96, "scored": 96, "correct": 96,
              "accuracy": 1.0, "wilson95_low": 0.9615244115586972, "wilson95_high": 1.0, ... }
```

## How to read it

- Same image, checkpoint, flags and host gave 94 and 96. The two intervals overlap almost entirely; the difference is noise (Inferred).
- `truncated_no_answer`, `hit_max_tokens` and `unparseable` at 0 mean every answer was scored. A nonzero value there points to a server or parser problem, not to model quality.
- Pass rule used by the AWS plan: at least 94/96 (`docs/06-aws-implementation-plan.md`, phase 1). Scoring takes the last number on the final answer line (`methodology` in the file).
