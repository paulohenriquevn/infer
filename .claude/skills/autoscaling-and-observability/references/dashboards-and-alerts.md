# Dashboards and alerts per replica, cell and fleet

What to graph and what to page on, tied to the SLO as `bench/summarize.py` defines it. Metric names follow `vllm-metrics.md` (upstream and fork status) and `llm-d-autoscaling.md` (EPP). Thresholds are Hypothesis unless a measured value is cited.

## The SLO the dashboards must reproduce

From `bench/summarize.py` (`Slo` dataclass and `evaluate_agents`, Observed in code; targets are §20 Hypothesis):

| Term | Definition in code | Target |
|---|---|---|
| Turn errors | `metrics.turn_errors` of the level | 0 |
| TTFT p95 | 95th percentile of `ttft_s` over turns with `turn >= 1` sent after the last agent finished turn 0, excluding turns cut by the end of the level | at most 5.0 s |
| Per-stream speed p50 | median of `completion_tokens / (seconds - ttft_s)` over the same turns | at least 30 tok/s |
| Cache % | `sum(cached_tokens) / sum(prompt_tokens)` over the same turns | reported, no target |
| Recomputed tokens | `prompt_tokens - cached_tokens` per turn, p50 and p90 | reported, no target |

Production equivalent (Inferred): the gateway logs one record per request with session id, turn index, `usage.prompt_tokens`, `usage.prompt_tokens_details.cached_tokens` (the engine reports it when started with `--enable-prompt-tokens-details`, as `summarize.py` requires), first-byte time, last-byte time and output tokens. "Cached turn" becomes "turn index at least 1 of a session that already has a turn 0 in this cell". The engine histograms cannot reproduce this split (`vllm-metrics.md`, trap 1).

Two more §20 Hypothesis rows to graph next to the code's SLO: TTFT p95 for a cold 256K context at most 60 s, and availability 99% per month where a failing 5-minute window has 5xx above 1%, TTFT p95 above target, or a stream cut after the first token.

## Per replica

| Panel | Query sketch | Why |
|---|---|---|
| Running and waiting | `vllm:num_requests_running`, `vllm:num_requests_waiting_by_reason` | concurrency against measured capacity (24 DCP1, 16 DCP4, Observed one run each) |
| KV usage | `vllm:kv_cache_usage_perc` | ceiling; 0.73 was the highest steady value inside the SLO (DCP1) |
| Prompt and generation throughput | `rate(vllm:prompt_tokens_total[1m])`, `rate(vllm:generation_tokens_total[1m])` | separates a full replica from a broken host (`signals-and-thresholds.md`) |
| Prefix cache share | `rate(vllm:prefix_cache_hits_total[5m]) / rate(vllm:prefix_cache_queries_total[5m])` | the router's value; 93.7% in the DCP1 24-agent run (Observed) |
| External (LMCache) share | `rate(vllm:external_prefix_cache_hits_total[5m]) / rate(vllm:external_prefix_cache_queries_total[5m])` | only with the LMCache tier; 0 without it (Observed) |
| Preemptions | `increase(vllm:num_preemptions_total[5m])` | 0 in every measured run |
| Prefill against decode compute | `rate(vllm:scheduler_compute_seconds_total[5m])` by `class` (fork-only) | prefill share was 0.47 at 24 agents (Observed) |
| Engine queue time | `histogram_quantile(0.95, rate(vllm:request_queue_time_seconds_bucket[5m]))` | diagnosis, not SLO |
| Ready time of the last start | from the instance bootstrap log, not Prometheus | phase 1 baseline (`docs/06` criterion 5) |
| GPU power and clocks | DCGM exporter (not tested by us) | the degraded host drew about 116 W per GPU under load (§29.10) |

## Per cell (one EPP, its replicas, the gateway in front)

| Panel | Source | Why |
|---|---|---|
| SLO: TTFT p95 of cached turns, per-stream speed p50, error rate | gateway records | the only faithful SLO view |
| TTFT p95 by context range (0 to 32K, 32K to 128K, 128K to 256K) | gateway records | §18.7 asks for per-range targets; one target cannot serve 2K and 200K prompts |
| Active sessions and in-flight requests per serving replica | gateway; `sum(llm_d_epp_inflight_requests) / llm_d_epp_ready_endpoints` | the scale-up signal |
| Prefill backlog seconds | `sum(llm_d_epp_inflight_tokens) / V_P / llm_d_epp_ready_endpoints` | secondary scale-up signal; `V_P` from calibration |
| Ready endpoints | `llm_d_epp_ready_endpoints` | capacity actually serving |
| Routing accuracy | `rate(llm_d_epp_prefix_predicted_cached_tokens_sum[5m]) / rate(llm_d_epp_prefix_prompt_tokens_sum[5m])` next to the engines' prefix share | a gap means the approximate index believes prefixes the engines evicted (`llm-d-routing` skill, decision 3). The `_sum` suffix assumes these are histograms; check their type on `/metrics` |
| Affinity overrides | `rate(llm_d_epp_prefix_cache_affinity_filter_decisions_total[5m])` by outcome | how often load broke stickiness |
| Imbalance | `llm_d_epp_std_dev_running_requests`, `llm_d_epp_std_dev_kv_cache_utilization` | hot-spotting under bursts |
| EPP itself | `llm_d_epp_scheduler_e2e_duration_seconds`, process CPU, `llm_d_epp_info` | EPP CPU grows with endpoints and req/s (project research notes, not published) |
| Flow control (only with the `flowControl` gate) | `llm_d_epp_flow_control_queue_size`, `llm_d_epp_flow_control_pool_saturation`, `llm_d_epp_flow_control_requests_total{outcome="RejectedCapacity"}` | queued demand and shedding |
| Gateway 429 against 503 | gateway | quota 429 must stay separate from capacity 503 (§18.3) |

## Per fleet

| Panel | Why |
|---|---|
| Serving replicas, starting replicas, floor and ceiling over the day | shows whether the scheduled floor led the peak by 15 to 20 min |
| Active sessions against serving replicas times `C` | utilization in the unit the product sells (sessions per US$/h) |
| Cost per hour and sessions per US$/h | the primary metric (docs/01) |
| Lead time per scale-up (request to first token served) | `L` in the scaling rule; target 8 to 12 min, 21 to 23 min cold |
| Scale-in events followed by scale-out within `L` | flapping cost |
| Quota headroom and capacity errors per region | quota was the first bottleneck on Nebius (§16.4); `InsufficientInstanceCapacity` on AWS |

## Alerts

Page (someone acts now):

| Alert | Condition (Hypothesis) | Reasoning |
|---|---|---|
| SLO burn, TTFT | cached-turn TTFT p95 above 5 s for 10 min in a cell | the code's SLO target |
| SLO burn, errors | 5xx or SSE `error` above 1% for 5 min | §20 availability failure definition |
| Replica down | `llm_d_epp_ready_endpoints` below the scheduled floor for 5 min | capacity loss with a 21 to 23 min replacement time |
| Broken host | waiting above 10 for 10 min while `rate(vllm:prompt_tokens_total[5m])` stays below about 1,500 tok/s | the degraded host averaged 1,015 prompt tok/s with a full queue against 4,265 on the good host (Observed, `signals-and-thresholds.md`) |
| Preemption | `increase(vllm:num_preemptions_total[5m]) > 0` | never observed inside the SLO |
| EPP down | EPP scrape target down for 1 min | with `FailOpen` Envoy keeps routing with no affinity and no flow control (Reported, llm-d flow-control doc) |

Ticket (fix in working hours):

| Alert | Condition (Hypothesis) |
|---|---|
| KV ceiling | `vllm:kv_cache_usage_perc` above 0.9 for 5 min |
| Cache share drop | cell prefix share below 85% for 30 min (93.7% measured with agents, 98.3% in the Weka corpus, §24.1) |
| Routing drift | predicted cached tokens exceed delivered hits by more than 10 points for 30 min |
| Floor late | serving replicas below the floor at peak start minus 5 min |
| Flapping | a scale-in followed by a scale-out within 30 min |
| Metrics gap | `llm_d_epp_flow_control_stale_endpoints > 0` or vLLM scrape errors |

## Topology

One Prometheus per cell with `remote_write` to a central store, critical alerts evaluated inside the cell (Hypothesis, project research notes, not published). Watch label cardinality: a `fairness_id` per user on EPP metrics with 10,000 users is expensive; aggregate per tenant or with recording rules, and meter per user at the gateway (Inferred, same notes). Keep `/metrics` of engines and the EPP on the private network.
