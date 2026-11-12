# Fork metrics observed in the agents runs

Real excerpts from the fork image runs on Vast host 157204 (`karmic-kraken-20261016`, reported version `0.1.dev21830+g8244d1c44`), and the script that turns the harness time series into the operating points used in `../references/signals-and-thresholds.md`. Old result files keep their Portuguese names (`agentes-24.json`, `servidor-direto.log`).

## 1. Server summary block of the DCP1 24-agent level

Source: `f3/resultados/vast-20261111/vllm/vast-vllm-dcp1/agentes-24.json`, path `scheduler.scenarios[0].server` (histograms trimmed to three):

```json
{
 "metrics_available": true,
 "samples": 600,
 "scrape_errors": 0,
 "max_running": 24.0,
 "max_waiting": 23.0,
 "max_waiting_capacity": 23.0,
 "max_waiting_deferred": 0.0,
 "max_kv_usage_pct": 72.6,
 "max_prefill_backlog_tokens": 0.0,
 "prefill_compute_share_mean": 0.4,
 "preemptions": 0,
 "prompt_tokens": 48301690,
 "generation_tokens": 877863,
 "requests_finished": 385,
 "prefix_hit_pct": 93.7,
 "compute_seconds": {"decode": 406.24, "prefill": 361.46, "prefill_share": 0.471},
 "histograms": {
  "ttft": {"count": 409, "mean_s": 24.8014, "p50_s": 2.8164, "p90_s": 54.6667, "p99_s": 567.2889},
  "inter_token_latency": {"count": 274062, "mean_s": 0.0638, "p50_s": 0.0537, "p90_s": 0.0733, "p99_s": 0.6235},
  "queue_time": {"count": 385, "mean_s": 22.5758, "p50_s": 0.2204, "p90_s": 64.2857, "p99_s": 422.25}
 }
}
```

Reading it:

- `max_waiting_capacity` exists, so the fork exports `vllm:num_requests_waiting_by_reason` with `reason="capacity"` (Observed through the harness parser, see `../references/vllm-metrics.md`).
- `max_waiting` 23 happened in the cold phase, when all 24 agents sent turn 0 together. In steady state the waiting mean was 0.10 (section 3).
- TTFT p90 of 54.7 s and p99 of 567 s are the whole level, cold phase included. The same run passed the SLO with cached steady-state TTFT p95 4.93 s (`summarize.py`). Never alert on this histogram as if it were the SLO.
- 877,863 generated tokens over 274,062 ITL observations is 3.2 tokens per observation: with MTP the ITL is per step.

## 2. One time-series sample

Same file, `scheduler.scenarios[0].timeseries[1]` (the harness scrapes every 2 s; `t` is seconds since the level started, counters are cumulative since server start):

```json
{"running": 1.0, "waiting": 0.0, "prefill_compute_share": 0.4, "compute_pressure_decode": 1.0, "compute_pressure_prefill": 1.0, "prefill_backlog_tokens": 0.0, "compute_seconds_decode": 316.54974037071224, "compute_seconds_prefill": 275.7543718061643, "waiting_capacity": 0.0, "waiting_deferred": 0.0, "kv_usage": 0.0, "prefix_queries": 37168895.0, "prefix_hits": 34624209.0, "external_prefix_queries": 0.0, "external_prefix_hits": 0.0, "preemptions": 0.0, "prompt_tokens": 37168895.0, "generation_tokens": 736023.0, "requests_finished": 614.0, "t": 0.01, "client_in_flight": 1}
```

## 3. Steady-state operating points

The script uses `evaluate_agents` from `bench/summarize.py` to find the steady-state start, then summarizes the server gauges after it. Run from the root of this repository after `scripts/fetch_evidence.sh`:

```python
# steady_state_gauges.py: server gauges after the last agent finished turn 0
import json, statistics, sys
sys.path.insert(0, "bench")
from summarize import Slo, evaluate_agents

for path in sys.argv[1:]:
    scenario = json.load(open(path))["scheduler"]["scenarios"][0]
    verdict = evaluate_agents(scenario, Slo())
    start = verdict["steady_start_s"] or 0
    samples = [x for x in scenario["timeseries"] if x["t"] >= start]

    def summary(key):
        values = sorted(x[key] for x in samples if x.get(key) is not None)
        return dict(p50=values[len(values) // 2], max=values[-1], mean=round(statistics.mean(values), 2))

    print(path, "pass", verdict["passes"], "ttft_p95", round(verdict["ttft_p95_s"], 2),
          "tps_p50", round(verdict["tps_p50"], 1), "samples", len(samples))
    for key in ("running", "waiting", "kv_usage", "client_in_flight"):
        print("   ", key, summary(key))
```

```bash
python3 steady_state_gauges.py \
  f3/resultados/vast-20261111/vllm/vast-vllm-dcp1/agentes-24.json \
  f3/resultados/vast-20261111/vllm/vast-vllm-r1-rep2/agentes-16.json
```

Output as run on 2026-11-12:

```text
f3/resultados/vast-20261111/vllm/vast-vllm-dcp1/agentes-24.json pass True ttft_p95 4.93 tps_p50 55.3 samples 365
    running {'p50': 23.0, 'max': 24.0, 'mean': 22.37}
    waiting {'p50': 0.0, 'max': 2.0, 'mean': 0.1}
    kv_usage {'p50': 0.5589887640449438, 'max': 0.7258426966292135, 'mean': 0.55}
    client_in_flight {'p50': 23, 'max': 24, 'mean': 23.13}
f3/resultados/vast-20261111/vllm/vast-vllm-r1-rep2/agentes-16.json pass False ttft_p95 5.2 tps_p50 57.8 samples 257
    running {'p50': 15.0, 'max': 16.0, 'mean': 14.69}
    waiting {'p50': 0.0, 'max': 2.0, 'mean': 0.07}
    kv_usage {'p50': 0.1582250766311487, 'max': 0.1915048897971099, 'mean': 0.16}
    client_in_flight {'p50': 16, 'max': 16, 'mean': 15.27}
```

The second block is the failing case: TTFT p95 5.20 s with a waiting mean of 0.07 and KV at 16%. Neither signal would have scaled out before the SLO was lost; running requests at the measured capacity would.

## 4. The same gauges in the server log

Source: `f3/resultados/vast-20261111/vllm/vast-vllm-dcp1/servidor-direto.log` (UTC timestamps), two lines from the 24-agent level:

```text
(APIServer pid=62899) INFO 11-12 00:58:01 [loggers.py:315] Engine 000: Avg prompt throughput: 756.2 tokens/s, Avg generation throughput: 1336.0 tokens/s, Running: 24 reqs, Waiting: 0 reqs, GPU KV cache usage: 54.5%, Prefix cache hit rate: 90.9%
(APIServer pid=62899) INFO 11-12 01:06:01 [loggers.py:315] Engine 000: Avg prompt throughput: 1770.6 tokens/s, Avg generation throughput: 939.4 tokens/s, Running: 24 reqs, Waiting: 0 reqs, GPU KV cache usage: 72.5%, Prefix cache hit rate: 93.4%
```

And the harness progress during the cold phase of the same level (`agentes-24.log`), the burst shape that looks like a broken host but is not:

```text
  agents:    48s in flight 24, done 2, errors 0 | running 2 waiting 22 | KV 3% |
...
  agents:   353s in flight 24, done 20, errors 0 | running 2 waiting 22 | KV 3%
```
