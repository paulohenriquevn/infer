# Cold first-turn queue at 16 agents

Real evidence: the first turn of each of 16 agents, vLLM fork DCP4 on Vast.ai host 157204, level `16:900` (results archive: `f3/resultados/vast-20261111/vllm/vast-vllm-r1/agentes-16.json`, field `scheduler.scenarios[0].metrics.turn_log`, rows with `turn == 0`). One run, Observed.

## Data

Extraction command:

```bash
python3 -c "
import json; d = json.load(open('agentes-16.json'))
tl = d['scheduler']['scenarios'][0]['metrics']['turn_log']
for t in [t for t in tl if t['turn'] == 0]:
    print(t['agent'], t['send_s'], t['prompt_tokens'], t['ttft_s'], t['seconds'])
print('steady start', max(t['send_s'] + t['seconds'] for t in tl if t['turn'] == 0))"
```

| Agent | Sent at (s) | Prompt tokens (all cold) | TTFT (s) | Turn duration (s) |
|---|---|---|---|---|
| 0 | 0.002 | 54,655 | 7.485 | 43.474 |
| 1 | 2.006 | 90,351 | 32.558 | 92.245 |
| 2 | 4.009 | 89,685 | 56.182 | 67.244 |
| 3 | 6.010 | 75,682 | 77.239 | 116.154 |
| 4 | 8.010 | 49,390 | 89.698 | 125.382 |
| 5 | 10.011 | 55,735 | 103.392 | 197.895 |
| 6 | 12.013 | 93,209 | 129.452 | 153.349 |
| 7 | 14.015 | 89,668 | 154.671 | 205.577 |
| 8 | 16.016 | 93,806 | 180.718 | 218.375 |
| 9 | 18.019 | 98,964 | 208.959 | 349.794 |
| 10 | 20.019 | 92,108 | 234.950 | 241.301 |
| 11 | 22.017 | 44,536 | 244.975 | 282.166 |
| 12 | 24.020 | 99,719 | 273.545 | 307.579 |
| 13 | 26.021 | 94,676 | 299.605 | 342.689 |
| 14 | 28.020 | 50,565 | 312.139 | 374.196 |
| 15 | 30.022 | 97,056 | 339.762 | 386.388 |

`steady start 416.40999999999997`

## Reading

- The bench starts one agent every 2 s (`run.sleep(2.0)` between spawns in `sched_run_agents`), each with a fresh context drawn from `AGENT_START=40k-100k`. Every first turn is a cold prefill.
- The first tokens arrive one after another, about 25 s apart: the single prefill lane (`--max-parallel-prefills 1`) serves them in order (Observed pattern; the flag is in the server command).
- The 16 first turns carry 1,269,805 tokens. The last first token arrives at 339.8 s, so the lane delivered about 3.7k tok/s while earlier agents were already decoding (Inferred), close to the 4.1k tok/s prefill-under-decode rate of R1.
- Steady state starts at 416 s, when the last agent finishes its first turn. `summarize.py` counts TTFT only on turns sent after that point; before that fix, the 8-agent level failed with TTFT p95 of 33 s, an artefact of this queue (§29.3).

## Failing case it produced

The first attempt used 7-minute levels (`agents_duration: 420.0`, files in `vast-vllm-r1/agentes-7min/` and `vast-vllm-r1/agentes-24.json`). At 24 agents the cold queue lasted past the end of the level, so `summarize.py` reports `short sample` with 0 steady turns (see `agent-levels.md`). Size each level as about 25 s per agent of cold phase plus about 7 min of steady state; `run_benchmark.sh` defaults to `8:600 16:900 32:1500`.

## What it means in production (Inferred, §17.4)

Any synchronized arrival of new long sessions builds this queue: start of the workday, a replica restart, a cell failover (64 sessions of 256K cost about 27 min of prefill on one replica). Mitigations in the design, none tested on the real model: prefix affinity with single-flight, admission control in the cell, the LMCache RAM tier for sessions that already existed, and the llm-d ThunderAgent plugin.
