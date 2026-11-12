# Prometheus queries for scaling and diagnosis

Illustrative, not run against a live Prometheus. Metric names come from the vLLM docs and our result files (`../references/vllm-metrics.md`) and from the llm-d v1.0.0 router metrics reference (`../references/llm-d-autoscaling.md`). Label selectors (`job`, `namespace`, `instance`) depend on your scrape configuration; on plain EC2 the llm-d no-Kubernetes guide scrapes the EPP on `--metrics-port` 9090 and each vLLM worker on `:8000/metrics` with static targets (Reported). Replace `job="vllm-workers"` and `job="llm-d-epp"` with your job names.

## Scrape configuration on plain EC2 (from the llm-d no-Kubernetes guide, Reported)

```yaml
scrape_configs:
  - job_name: 'llm-d-epp'
    static_configs:
      - targets: ['localhost:9090']
  - job_name: 'vllm-workers'
    static_configs:
      - targets:
        - '10.0.0.10:8000'  # vllm-0
        - '10.0.0.11:8000'  # vllm-1
    metrics_path: '/metrics'
```

## Load against capacity

```promql
# Running requests per replica (Observed name on the fork)
sum by (instance) (vllm:num_requests_running{job="vllm-workers"})

# In-flight requests per serving replica, from the EPP (Reported name)
sum(llm_d_epp_inflight_requests{job="llm-d-epp", producer_name="inflight-load-producer"})
  / max(llm_d_epp_ready_endpoints{job="llm-d-epp"})

# Same, as a fraction of measured capacity C = 24 (DCP1, one run; replace after phase 2)
sum(vllm:num_requests_running{job="vllm-workers"})
  / (24 * count(up{job="vllm-workers"} == 1))

# Seconds of uncached prefill backlog per replica, V_P = 4100 tok/s (R1 DCP4 under decode;
# recalibrate for the chosen profile)
(sum(llm_d_epp_inflight_tokens{job="llm-d-epp", producer_name="inflight-load-producer"}) / 4100)
  / max(llm_d_epp_ready_endpoints{job="llm-d-epp"})
```

## Ceiling and health

```promql
# KV usage per replica, a fraction 0 to 1 despite the name
max by (instance) (vllm:kv_cache_usage_perc{job="vllm-workers"})

# Preemptions in the last 5 min (0 in every measured run)
sum by (instance) (increase(vllm:num_preemptions_total{job="vllm-workers"}[5m]))

# Waiting by reason (fork exports reason="capacity" and "deferred", Observed through the harness)
sum by (instance, reason) (vllm:num_requests_waiting_by_reason{job="vllm-workers"})

# Broken-host pattern: many waiting, little prompt throughput (thresholds Hypothesis,
# anchored on 4,265 vs 1,015 prompt tok/s, references/signals-and-thresholds.md)
(sum by (instance) (vllm:num_requests_waiting{job="vllm-workers"}) > 10)
  and on (instance)
(sum by (instance) (rate(vllm:prompt_tokens_total{job="vllm-workers"}[5m])) < 1500)
```

## Cache and routing

```promql
# Local prefix cache share per replica
sum by (instance) (rate(vllm:prefix_cache_hits_total{job="vllm-workers"}[5m]))
  / sum by (instance) (rate(vllm:prefix_cache_queries_total{job="vllm-workers"}[5m]))

# External (LMCache) share, only with the KV tier
sum(rate(vllm:external_prefix_cache_hits_total{job="vllm-workers"}[5m]))
  / sum(rate(vllm:external_prefix_cache_queries_total{job="vllm-workers"}[5m]))

# Prompt tokens by source (Observed on upstream 0.32.0; fork status Unknown)
sum by (source) (rate(vllm:prompt_tokens_by_source_total{job="vllm-workers"}[5m]))

# Affinity filter decisions by outcome (Reported name; check the label name on /metrics)
sum by (outcome) (rate(llm_d_epp_prefix_cache_affinity_filter_decisions_total{job="llm-d-epp"}[5m]))
```

## Fork-only scheduler series (Observed through the harness; meaning Inferred)

```promql
# Share of engine compute spent on prefill
sum(rate(vllm:scheduler_compute_seconds_total{job="vllm-workers", class="prefill"}[5m]))
  / sum(rate(vllm:scheduler_compute_seconds_total{job="vllm-workers"}[5m]))

# Local prefill backlog in tokens (0 in every agents run we have)
max by (instance) (vllm:scheduler_local_prefill_backlog_tokens{job="vllm-workers"})
```

## What not to use as the SLO

```promql
# Mixes cold and cached turns; on the DCP1 24-agent run its p90 was 54.7 s while the cached
# steady-state p95 was 4.93 s. Diagnosis only.
histogram_quantile(0.95, sum by (le) (rate(vllm:time_to_first_token_seconds_bucket{job="vllm-workers"}[5m])))

# Per engine step under MTP (about 3.2 tokens per observation measured); 1/ITL is not tok/s
histogram_quantile(0.5, sum by (le) (rate(vllm:inter_token_latency_seconds_bucket{job="vllm-workers"}[5m])))
```

The SLO comes from gateway request records (`../references/dashboards-and-alerts.md`).
