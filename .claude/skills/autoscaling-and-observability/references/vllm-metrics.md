# vLLM Prometheus metrics: upstream list and what the fork exports

Two layers in this file. The upstream list is Reported from the vLLM docs. The names the fork image actually exports are Observed only where a result file proves it; everything else stays Unknown until someone lists `/metrics` on a running fork server.

## Sources

- `https://docs.vllm.ai/en/stable/usage/metrics/` (stable, mapped by ReadTheDocs to v0.33.0, commit `4ba787ec`) and `https://docs.vllm.ai/en/latest/usage/metrics/` (main, dated 2026-11-12). Both list the same 71 `vllm:` names. Reported, read 2026-11-12.
- `https://docs.vllm.ai/en/latest/design/metrics/` for the V1 design and `vllm:cache_config_info`. Reported, read 2026-11-12.
- Labels from `https://github.com/vllm-project/vllm/blob/main/vllm/v1/metrics/loggers.py`; base labels are `model_name` and `engine`. Reported, read 2026-11-12.
- Our evidence: `f3/resultados/ab-aquecido-20261105/*/metricas-*.txt` (upstream vLLM 0.32.0, mini), `f3/resultados/b300-20261105/startup.txt` (upstream vLLM 0.32.0, real model on B300), and the fork runs under `f3/resultados/vast-20261111/vllm/` and `vast-20261112/vllm/` (fork image `karmic-kraken-20261016`, which reports vLLM version `0.1.dev21830+g8244d1c44`). Old result files keep Portuguese names (`metricas-antes.txt`, `agentes-24.json`).

Version caveat: the fork is built from its own branch of vLLM; the docs above are for v0.33.0 and main. A name in the upstream list is not proof that the fork exports it.

## Upstream list (Reported)

The docs table gives counters without the `_total` suffix; the Prometheus client adds it on export (the design page shows `vllm:generation_tokens_total`). Names below are written as they appear on `/metrics`.

### Counters

| Metric | Extra labels | Meaning |
|---|---|---|
| `vllm:prompt_tokens_total` | | prefill tokens processed |
| `vllm:generation_tokens_total` | | generation tokens processed |
| `vllm:prompt_tokens_by_source_total` | `source` | prompt tokens by source |
| `vllm:prompt_tokens_cached_total` | | cached prompt tokens, local plus external |
| `vllm:prompt_tokens_cached_by_source_total` | `source` (`device`, `host`, `disk`, `p2p`, `external_unspecified`) | hit tokens by tier; sums to prefix plus external prefix hits |
| `vllm:prefix_cache_queries_total` | | prefix cache queries, in tokens |
| `vllm:prefix_cache_hits_total` | | prefix cache hits, in tokens |
| `vllm:external_prefix_cache_queries_total` | | external (KV connector) prefix cache queries, in tokens |
| `vllm:external_prefix_cache_hits_total` | | external prefix cache hits, in tokens |
| `vllm:num_preemptions_total` | | cumulative preemptions |
| `vllm:request_success_total` | `finished_reason` | finished requests |
| `vllm:admission_rejections_total` | `reason` (labels `model_name`, `reason` only) | admissions rejected by a queue limit |
| `vllm:corrupted_requests_total` | | requests with NaNs in logits |
| `vllm:mm_cache_queries_total`, `vllm:mm_cache_hits_total` | | multimodal cache, in items |
| `vllm:watermark_requests_total` | `status` | finished requests by watermark status |

### Gauges

| Metric | Extra labels | Meaning |
|---|---|---|
| `vllm:num_requests_running` | | requests in model execution batches |
| `vllm:num_requests_waiting` | | requests waiting to be processed |
| `vllm:num_requests_waiting_by_reason` | `reason` (`capacity`, `deferred`) | split of the waiting count; the two sum to `num_requests_waiting` |
| `vllm:kv_cache_usage_perc` | | "KV-cache usage. 1 means 100 percent usage." A fraction despite the name |
| `vllm:num_requests_kv_fetch_by_stage` | `stage` (`waiting_to_start`, `in_progress`, `completed_waiting`) | requests fetching external KV |
| `vllm:engine_sleep_state` | `sleep_state` | sleep mode state |
| `vllm:lora_requests_info` | `max_lora`, `waiting_lora_adapters`, `running_lora_adapters` | LoRA state |
| `vllm:cache_config_info` | the CacheConfig fields as labels | info gauge, value 1. On the design page only, not in the usage table |

### Histograms

| Metric | Meaning |
|---|---|
| `vllm:time_to_first_token_seconds` | time to first token |
| `vllm:inter_token_latency_seconds` | inter-token latency |
| `vllm:request_time_per_output_token_seconds` | per-request TPOT |
| `vllm:e2e_request_latency_seconds` | end-to-end latency |
| `vllm:request_queue_time_seconds` | time in WAITING |
| `vllm:request_prefill_time_seconds` | time in PREFILL |
| `vllm:request_decode_time_seconds` | time in DECODE |
| `vllm:request_inference_time_seconds` | time in RUNNING |
| `vllm:request_prompt_tokens`, `vllm:request_generation_tokens` | tokens per request |
| `vllm:request_prefill_kv_computed_tokens` | new KV tokens computed in prefill, cached tokens excluded |
| `vllm:request_max_num_generation_tokens`, `vllm:request_params_max_tokens`, `vllm:request_params_n` | request parameters |
| `vllm:request_num_preemptions` | preemptions per request |
| `vllm:iteration_tokens_total` | tokens per engine step |
| `vllm:kv_block_lifetime_seconds`, `vllm:kv_block_idle_before_evict_seconds`, `vllm:kv_block_reuse_gap_seconds` | sampled KV block residency, needs `--kv-cache-metrics-sample` |

### Other groups

- Speculative decoding: only `vllm:spec_decode_num_accepted_tokens_per_pos_total` (label `position`) is in the docs table. The source on main also defines `vllm:spec_decode_num_drafts`, `vllm:spec_decode_num_draft_tokens` and `vllm:spec_decode_num_accepted_tokens` (`vllm/v1/spec_decode/metrics.py`). Reported.
- NIXL, HiSparse, Simple CPU Offload connector and MFU metrics exist; none applies to our profile (no NIXL, no native CPU offload connector, LMCache instead). Reported.
- Renames: neither docs page mentions `vllm:gpu_cache_usage_perc` or `vllm:gpu_prefix_cache_*`, and a code search on the default branch finds no `gpu_cache_usage_perc`. When the rename happened is Unknown. Deprecation policy (design page): a metric deprecated in X.Y is hidden in X.Y+1 (re-enable with `--show-hidden-metrics-for-version=X.Y`) and removed in X.Y+2.
- The design page names `vllm:num_requests_swapped` and `vllm:cpu_cache_usage_perc` as V0 metrics with no V1 meaning. Do not build on them.

## Names observed on our servers

### Upstream vLLM 0.32.0 (mini and B300), from raw `/metrics` lines

Quoted from `f3/resultados/ab-aquecido-20261105/afinidade/metricas-depois.txt` (mini, random weights):

```text
vllm:prefix_cache_queries_total{engine="0",model_name="mini"} 2.74134e+06
vllm:prefix_cache_hits_total{engine="0",model_name="mini"} 1.618944e+06
vllm:prompt_tokens_by_source_total{engine="0",model_name="mini",source="local_compute"} 1.122396e+06
vllm:prompt_tokens_by_source_total{engine="0",model_name="mini",source="local_cache_hit"} 1.618944e+06
vllm:prompt_tokens_by_source_total{engine="0",model_name="mini",source="external_kv_transfer"} 0.0
```

Quoted from `f3/resultados/b300-20261105/startup.txt` (real model, upstream 0.32.0, B300):

```text
vllm:kv_cache_usage_perc{engine="0",model_name="glm"} 0.0
vllm:prefix_cache_queries_total{engine="0",model_name="glm"} 3.231552e+06
vllm:prefix_cache_hits_total{engine="0",model_name="glm"} 385920.0
```

The `source` values of `prompt_tokens_by_source_total` on 0.32.0 are `local_compute`, `local_cache_hit` and `external_kv_transfer` (Observed). The router tests attribute each request to a replica by the delta of this counter (`router/exp/sessions.py`).

### The fork image, through the harness

No raw `/metrics` dump of the fork exists in the results. The harness `llm_decode_bench.py` 0.8.0 scrapes `/metrics` every 2 s (`metrics_interval: 2.0` in `agents-24.json` settings) and records named fields. Its parser (`sched_parse_metrics` in `llm_decode_bench.py`) creates a labelled field such as `waiting_capacity` only when the labelled metric is present, so a field in the recorded time series proves the source metric exists on the server. Mapping (from `SCHED_SCALAR_METRICS`, `SCHED_LABELED_METRICS` and `SCHED_HISTOGRAMS` in the harness) and status for the fork, from `f3/resultados/vast-20261111/vllm/vast-vllm-dcp1/agentes-24.json`:

| Harness field | Prometheus name | Status on the fork |
|---|---|---|
| `running` | `vllm:num_requests_running` | Observed (field present, values 0 to 24) |
| `waiting` | `vllm:num_requests_waiting` | Observed |
| `waiting_capacity`, `waiting_deferred` | `vllm:num_requests_waiting_by_reason{reason="capacity"\|"deferred"}` | Observed (labelled fields present) |
| `kv_usage` | `vllm:kv_cache_usage_perc`, else `vllm:gpu_cache_usage_perc` | Observed that one of the two exists; which one is Unknown. Values are fractions (0.0 to 0.73) |
| `preemptions` | `vllm:num_preemptions_total` | Observed (field present, 0 in every run) |
| `prompt_tokens`, `generation_tokens` | `vllm:prompt_tokens_total`, `vllm:generation_tokens_total` | Observed |
| `prefix_queries`, `prefix_hits` | `vllm:prefix_cache_queries_total`, `vllm:prefix_cache_hits_total` | Observed |
| `external_prefix_queries`, `external_prefix_hits` | `vllm:external_prefix_cache_queries_total`, `vllm:external_prefix_cache_hits_total` | Observed (0 without LMCache) |
| `requests_finished` | `vllm:request_success_total` | Observed |
| `prefill_compute_share` | `vllm:scheduler_prefill_compute_share` | Observed, fork-only (value 0.4, the `--prefill-compute-share` of the profile) |
| `prefill_backlog_tokens` | `vllm:scheduler_local_prefill_backlog_tokens` | Observed, fork-only (always 0 in these runs) |
| `compute_seconds_decode`, `compute_seconds_prefill` | `vllm:scheduler_compute_seconds_total{class=...}` | Observed, fork-only |
| `compute_pressure_decode`, `compute_pressure_prefill` | `vllm:scheduler_compute_pressure{class=...}` | Observed, fork-only |
| histograms `ttft`, `inter_token_latency`, `e2e`, `queue_time`, `prefill_time` | `vllm:time_to_first_token_seconds`, `vllm:inter_token_latency_seconds`, `vllm:e2e_request_latency_seconds`, `vllm:request_queue_time_seconds`, `vllm:request_prefill_time_seconds` | Observed (counts above zero) |
| `server/kv_tokens` from `kv_cache_size_tokens` | label of `vllm:cache_config_info` | Observed (`server-info.json` gives `"kv_tokens_source": "vllm kv_cache_size_tokens"`, 6,789,052 tokens for DCP1) |

The fork-only names do not appear in the upstream docs (Reported list above). Their meaning is Inferred from the field names and from the fork's scheduler flags (`--prefill-compute-share 0.4`, `--max-parallel-prefills 1`); read the fork's source before alerting on them.

Still Unknown for the fork: `vllm:prompt_tokens_by_source_total` and its `source` values (the router tests depend on it), `vllm:prompt_tokens_cached_by_source_total`, `vllm:request_time_per_output_token_seconds`, `vllm:request_decode_time_seconds`, spec decode counters, and any LMCache series. How to close it: start the fork server and run `curl -s localhost:8000/metrics | grep -E '^vllm:' | sed 's/{.*//' | sort -u`, then save the output in the result directory.

The fork's server log prints the same gauges every 10 s (Observed, `servidor-direto.log` in the DCP1 run): `Avg prompt throughput: 1770.6 tokens/s, Avg generation throughput: 939.4 tokens/s, Running: 24 reqs, Waiting: 0 reqs, GPU KV cache usage: 72.5%, Prefix cache hit rate: 93.4%`. In this log line KV usage is a percentage; on `/metrics` it is a fraction.

## Two traps in the engine histograms (Observed on the fork)

From the `server.histograms` block of `vast-vllm-dcp1/agentes-24.json` (24 agents, the run that passed the SLO):

```json
"ttft": {"count": 409, "mean_s": 24.8014, "p50_s": 2.8164, "p90_s": 54.6667, "p99_s": 567.2889},
"inter_token_latency": {"count": 274062, "mean_s": 0.0638, "p50_s": 0.0537, "p90_s": 0.0733, "p99_s": 0.6235},
"queue_time": {"count": 385, "mean_s": 22.5758, "p50_s": 0.2204, "p90_s": 64.2857, "p99_s": 422.25}
```

1. **The engine TTFT histogram is not the SLO.** Over the whole level it includes the cold first turns of all 24 agents, which queued for minutes because they start together. `summarize.py` measures cached steady-state turns only and gets TTFT p95 4.93 s for the same run (docs/03). An alert on `vllm:time_to_first_token_seconds` p95 against 5 s would have fired on a run that passed. The SLO needs per-turn data with `cached_tokens`, which only the client or the gateway has (Inferred).
2. **With MTP, inter-token latency is per engine step, not per token.** 274,062 ITL observations against 877,863 generated tokens is 3.2 tokens per observation (Inferred: 877,863 / 274,062). A p50 ITL of 53.7 ms read as 1/0.0537 = 18.6 tok/s per stream would be wrong; `summarize.py` reports a per-stream p50 of 55.3 tok/s for this run. Convert with the accepted tokens per step (MTP accepts 2.5 to 2.7 tokens per step on R1, §12.2) or measure speed at the client.

## Mapping to our SLO terms

SLO per replica (`bench/summarize.py`): zero turn errors, TTFT p95 of cached steady-state turns at most 5 s, per-stream decode p50 at least 30 tok/s (Hypothesis targets from §20, implemented in code).

| SLO term | Best source | Engine metric that approximates it | Gap |
|---|---|---|---|
| Turn errors | gateway status codes and SSE `error` events | `vllm:request_success_total` by `finished_reason` | the engine does not see client timeouts or cut streams |
| TTFT p95, cached turns | gateway, per request, split by cached tokens | `vllm:time_to_first_token_seconds` | mixes cold and cached turns (trap 1) |
| Per-stream decode p50 | gateway: output tokens after the first divided by time after the first | `vllm:request_time_per_output_token_seconds` (fork status Unknown), `vllm:inter_token_latency_seconds` | ITL is per step under MTP (trap 2) |
| Prefix cache share | `vllm:prefix_cache_hits_total / vllm:prefix_cache_queries_total` | same | none; this is what `summarize.py` calls cache % at the request level |
| Recomputed tokens per turn | gateway: `prompt_tokens - cached_tokens` | `vllm:request_prefill_kv_computed_tokens` (fork status Unknown) | |
| Active sessions per replica | gateway (session ids) | `vllm:num_requests_running` | running counts requests in flight, not sessions in their think time |
| KV headroom | `vllm:kv_cache_usage_perc` | same | includes cached prefix blocks of idle sessions (vLLM issue 33434, Reported in project research notes, not published) |
| Queue | `vllm:num_requests_waiting_by_reason{reason="capacity"}` | same | stays near 0 until the SLO is already lost (see `signals-and-thresholds.md`) |

## Security note

`/metrics` is not covered by `--api-key`; the vLLM security doc lists it among unauthenticated paths and recommends a reverse proxy with an endpoint allowlist (Reported, `https://github.com/vllm-project/vllm/blob/main/docs/usage/security.md`, via project research notes, not published). Keep `/metrics` on the private network; the EPP and Prometheus must reach it, clients must not.
