# Agent levels from `summarize.py` on real runs

Real output of `bench/summarize.py`, run on 2026-11-12 over three archived vLLM result directories of Vast.ai host 157204 (4 RTX PRO 6000 Server Edition, US$ 5.61/h). It shows TTFT p95 of cached turns rising with the number of agents while per-stream decode stays above the SLO floor.

## Command

```bash
cd bench
python3 summarize.py --price 5.61 --needle-ref 3/500 \
  <archive>/f3/resultados/vast-20261111/vllm/vast-vllm-r1 \
  <archive>/f3/resultados/vast-20261111/vllm/vast-vllm-r1-rep2 \
  <archive>/f3/resultados/vast-20261111/vllm/vast-vllm-dcp1
```

`vast-vllm-r1` and `vast-vllm-r1-rep2` are DCP4 (`server-vllm-direct.sh`); `vast-vllm-dcp1` is DCP1. These directories predate the translation and use `agentes-<N>.json`, `servidor.log` and `motor.txt`; `summarize.py` reads both naming schemes.

## Output (exact)

```
| Engine | Needle | gsm8k | Sessions in SLO | Sessions per US$/h |
|---|---|---|---|---|
| vllm | 100.0% ok | 97.9% | 16 | 2.85 |
| vllm | 99.4% ok | 100.0% | 0 | 0.00 |
| vllm | 97.5% ok | 99.0% | 24 | 4.28 |

| Engine | Agents | Errors | Steady since (s) | Steady turns | TTFT p95 (s) | tok/s p50 per stream | Cache % | Recomputed p50 | Recomputed p90 | SLO |
|---|---|---|---|---|---|---|---|---|---|---|
| vllm | 8 | 0 | 167 | 65 | 3.37 | 90.3 | 96.5 | 3,219 | 5,272 | pass |
| vllm | 16 | 0 | 416 | 159 | 4.77 | 57.2 | 96.9 | 3,731 | 5,840 | pass |
| vllm | 24 | 0 | n/a | 0 | n/a | n/a | n/a | n/a | n/a | short sample |
| vllm | 32 | 0 | 724 | 325 | 6.08 | 37.7 | 96.8 | 3,705 | 5,785 | fail |
| vllm | 16 | 0 | 390 | 178 | 5.20 | 57.8 | 97.0 | 3,715 | 5,814 | fail |
| vllm | 24 | 0 | 491 | 268 | 5.97 | 47.1 | 97.0 | 3,314 | 5,445 | fail |
| vllm | 16 | 0 | 380 | 212 | 4.71 | 70.8 | 97.2 | 3,566 | 5,804 | pass |
| vllm | 24 | 0 | 470 | 326 | 4.93 | 55.3 | 97.2 | 3,432 | 5,559 | pass |
```

Rows 1 to 4 are DCP4 run 1, rows 5 and 6 DCP4 run 2, rows 7 and 8 DCP1.

## How to read it

- "Sessions in SLO" is the largest level that passes with every smaller level passing. DCP4 run 1: 16. DCP4 run 2 tested only 16 and 24 and failed 16, so 0. DCP1: 24 (one run).
- The 24-agent row of DCP4 run 1 says "short sample": that level came from the first 7-minute attempt, which never left the cold first-turn queue, so it has no steady turns (§29.3). `summarize.py` counts it as not passing (the level fails, so sessions inside the SLO stop below it), which matches `inference-benchmarking/references/slo-and-summary.md`.
- TTFT p95 rises with agents on DCP4: 3.37 s (8), 4.77 s (16), 6.08 s (32), while per-stream decode stays at 37.7 tok/s or more. The SLO fails on TTFT first.
- DCP4 passed 16 with 0.23 s of margin and failed the repeat at 5.20 s (§29.6). Decide on two runs.
- "Recomputed" is new input, not a cache tail: see `recompute-split.md`.

## Steady-state load behind the rows

Script (save as `level_load.py`; run with agent JSON files as arguments):

```python
import json, sys
for path in sys.argv[1:]:
    d = json.load(open(path)); m = d["scheduler"]["scenarios"][0]["metrics"]; tl = m["turn_log"]
    t0 = [t for t in tl if t["turn"] == 0]
    if any(t.get("seconds") is None for t in t0):
        print(path, "cold queue never ended"); continue
    ss = max(t["send_s"] + t["seconds"] for t in t0)          # same rule as summarize.py
    st = [t for t in tl if t["turn"] >= 1 and t["send_s"] >= ss
          and t.get("seconds") is not None and t.get("cached_tokens") is not None]
    wall = m["wall_s"] - ss
    pre = sum(t["prompt_tokens"] - t["cached_tokens"] for t in st)
    out = sum(t["completion_tokens"] for t in st)
    ts = sorted(t["seconds"] for t in st)
    print(f"{path}: agents {m['agents']} steady_from {ss:.0f}s window {wall:.0f}s turns {len(st)} "
          f"turn_rate {len(st)/wall:.3f}/s prefill_needed {pre/wall:.0f} tok/s output {out/wall:.0f} tok/s "
          f"turn_s_p50 {ts[len(ts)//2]:.1f}")
```

Real output:

```
vast-vllm-r1/agentes-8.json: agents 8 steady_from 167s window 253s turns 65 turn_rate 0.257/s prefill_needed 857 tok/s output 505 tok/s turn_s_p50 25.2
vast-vllm-r1/agentes-16.json: agents 16 steady_from 416s window 484s turns 159 turn_rate 0.329/s prefill_needed 1226 tok/s output 637 tok/s turn_s_p50 36.0
vast-vllm-r1/agentes-32.json: agents 32 steady_from 724s window 778s turns 325 turn_rate 0.418/s prefill_needed 1549 tok/s output 864 tok/s turn_s_p50 62.1
vast-vllm-dcp1/agentes-16.json: agents 16 steady_from 380s window 520s turns 212 turn_rate 0.407/s prefill_needed 1497 tok/s output 814 tok/s turn_s_p50 30.2
vast-vllm-dcp1/agentes-24.json: agents 24 steady_from 470s window 732s turns 326 turn_rate 0.445/s prefill_needed 1557 tok/s output 977 tok/s turn_s_p50 43.8
```

"Output" counts only steady turns that started and finished inside the window, so it underestimates the true decode rate (Inferred). Prefill demand stayed below 1.6k tok/s, well under the 4.1k tok/s prefill-under-decode rate: the failing levels were latency bound, not prefill-throughput bound (Inferred; discussion in `../references/cost-model.md`, example 3).
