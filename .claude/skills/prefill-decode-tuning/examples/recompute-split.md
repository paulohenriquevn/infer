# Splitting the per-turn recompute into new input and cache tail

Real evidence, run on 2026-11-12 against the agent-level files of the results archive. It answers §26.5 point 3 ("how many tokens does each turn recompute for lack of state?") and shows that on the vLLM fork the answer is one token per turn.

## Why this works

The bench (`llm-inference-bench` at commit `52216d70`, file `llm_decode_bench.py`, function `sched_run_agents`) builds the next prompt of an agent as:

```python
tool = rng.randint(*s.agent_tool)            # AGENT_TOOL=1k-6k -> (1024, 6144)
prompt = prompt + list(out) + ctx.prompts.make(tool)
```

`out` is the exact output token IDs on vLLM (`exact_history: True` in the JSON). So for two consecutive turns of one agent:

```
tool block   = prompt_tokens(n+1) - prompt_tokens(n) - completion_tokens(n)
recomputed   = prompt_tokens(n+1) - cached_tokens(n+1)
cache tail   = recomputed - tool block
```

## Script

Save as `recompute_split.py` anywhere and run it with the agent JSON files as arguments. It reads only the `turn_log` written by the bench.

```python
import json, sys, statistics

def pct(values, p):
    v = sorted(values)
    k = (len(v) - 1) * p / 100
    f = int(k); c = min(f + 1, len(v) - 1)
    return v[f] + (v[c] - v[f]) * (k - f)

for path in sys.argv[1:]:
    d = json.load(open(path))
    turns = d["scheduler"]["scenarios"][0]["metrics"]["turn_log"]
    by_agent = {}
    for t in turns:
        by_agent.setdefault(t["agent"], []).append(t)
    rec, tool, extra, out = [], [], [], []
    for ts in by_agent.values():
        ts.sort(key=lambda t: t["turn"])
        for prev, cur in zip(ts, ts[1:]):
            if cur["turn"] != prev["turn"] + 1:
                continue
            if None in (prev.get("prompt_tokens"), cur.get("prompt_tokens"),
                        cur.get("cached_tokens"), prev.get("completion_tokens")):
                continue
            t = cur["prompt_tokens"] - prev["prompt_tokens"] - prev["completion_tokens"]
            if t < 0 or t > 7000:      # skip conversation resets
                continue
            r = cur["prompt_tokens"] - cur["cached_tokens"]
            rec.append(r); tool.append(t); extra.append(r - t); out.append(prev["completion_tokens"])
    print(path, "pairs", len(rec))
    for name, v in (("recomputed", rec), ("tool block", tool),
                    ("recomputed minus tool", extra), ("previous output", out)):
        print(f"  {name}: p10 {pct(v,10):.0f} p50 {pct(v,50):.0f} p90 {pct(v,90):.0f} mean {statistics.mean(v):.0f}")
```

## Real output

Command (from `f3/resultados/vast-20261111/vllm/`; files keep their Portuguese names):

```bash
python3 recompute_split.py vast-vllm-r1/agentes-8.json vast-vllm-r1/agentes-16.json vast-vllm-r1/agentes-32.json \
  vast-vllm-dcp1/agentes-16.json vast-vllm-dcp1/agentes-24.json ../sglang/vast-sglang-ormandj/agentes-8.json
```

Output (the run grouped the files in three calls; the lines are copied exactly):

```
agentes-8.json pairs 77
  recomputed: p10 1641 p50 3420 p90 5282 mean 3419
  tool block: p10 1640 p50 3419 p90 5281 mean 3418
  recomputed minus tool: p10 1 p50 1 p90 1 mean 1
  previous output: p10 505 p50 1945 p90 3496 mean 1921
vast-vllm-r1/agentes-16.json pairs 183
  recomputed: p10 1569 p50 3518 p90 5863 mean 3641
  tool block: p10 1568 p50 3517 p90 5862 mean 3640
  recomputed minus tool: p10 1 p50 1 p90 1 mean 1
  previous output: p10 574 p50 2068 p90 3554 mean 2039
agentes-32.json pairs 375
  recomputed: p10 1515 p50 3637 p90 5725 mean 3630
  tool block: p10 1514 p50 3636 p90 5724 mean 3629
  recomputed minus tool: p10 1 p50 1 p90 1 mean 1
  previous output: p10 621 p50 2071 p90 3597 mean 2104
vast-vllm-dcp1/agentes-24.json pairs 361
  recomputed: p10 1529 p50 3419 p90 5491 mean 3460
  tool block: p10 1528 p50 3418 p90 5490 mean 3459
  recomputed minus tool: p10 1 p50 1 p90 1 mean 1
  previous output: p10 671 p50 2208 p90 3648 mean 2183
vast-vllm-dcp1/agentes-16.json pairs 243
  recomputed: p10 1588 p50 3475 p90 5821 mean 3608
  tool block: p10 1587 p50 3474 p90 5820 mean 3607
  recomputed minus tool: p10 1 p50 1 p90 1 mean 1
  previous output: p10 645 p50 2106 p90 3554 mean 2076
vast-sglang-ormandj/agentes-8.json pairs 116
  recomputed: p10 1584 p50 3492 p90 5425 mean 3526
  tool block: p10 1381 p50 3410 p90 5283 mean 3402
  recomputed minus tool: p10 21 p50 116 p90 230 mean 124
  previous output: p10 548 p50 2056 p90 3586 mean 2048
```

## Reading

- vLLM fork, DCP4 and DCP1, every level: the cache tail is exactly 1 token (Observed). The previous prompt and the whole previous output come from cache.
- SGLang (ormandj v0.6.1 profile, FP8): 116 tokens at the median, 230 at p90 (Observed). That is a real hybrid cache tail, and still small next to the 3.4K tool block.
- The pair counts differ from `summarize.py`'s steady-turn counts because this script uses every consecutive pair, including turns inside the cold queue.

The server log line that explains the vLLM result, present in every run (`servidor.log`):

```
Request-boundary recurrent checkpoint caching is enabled. Supported chat requests retain leading instructions, the complete prompt, and the response endpoint.
```

and in the non-default args of the same log: `'recurrent_checkpoint_policy': 'request_boundaries'`, `'mamba_cache_mode': 'align'`.

## Passing and failing cases for the next measurement

- Passing (tail is not the problem): `recomputed minus tool` at p90 below one block (2,048 tokens with the default split target block size `VLLM_GLM53_SPLIT_TARGET_BLOCK_SIZE=2048`). All vLLM runs above pass with 1.
- Failing (a tail exists): p50 of `recomputed minus tool` in the hundreds or more, as SGLang shows. On vLLM this would mean the request-boundary checkpoint stopped working, for example a new image without `--recurrent-checkpoint-policy request_boundaries`, or a real agent whose chat template re-renders earlier turns differently (Hypothesis, untested).
