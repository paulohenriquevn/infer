---
name: autoscaling-and-observability
description: Use when deciding how GLM-5.3-Flash replicas scale up or down, choosing the metric or threshold that triggers scaling, planning a scheduled floor, removing a replica, writing Prometheus queries, dashboards or alerts for vLLM or the llm-d EPP, mapping engine metrics to the SLO, or designing the phase 5 autoscaling test in docs/06. Also use before trusting a vLLM metric name on the fork image or quoting KEDA, WVA or llm-d autoscaling guidance.
---

# Autoscaling and observability

How the serving fleet grows and shrinks, which signals drive it, and what to graph and page on. The short version: a replica is 4 GPUs and takes 21 to 23 minutes to start cold, so capacity for the daily peak is scheduled; reactive scaling covers drift, not bursts; and the signal that tracks our SLO is concurrency against measured capacity, not GPU utilization, queue length or KV usage.

Evidence labels: Observed (we measured it, path or section given), Reported (a named source says it, URL and read date given in the reference), Inferred (derived, reasoning shown), Hypothesis (to be validated), Unknown. "§N" points to `ARQUITETURA.md`, the Portuguese working journal kept outside this repository. "docs/0N" points to `docs/` in this repository. Raw results are cited as `f3/resultados/...` in the published results archive. Project research notes (`NOTAS.md`, `reports/`, `research_notes/`) are cited as "project research notes, not published". Pinned versions: vLLM fork image `karmic-kraken-20261016`, LMCache `0.5.3.dev453+lil`, llm-d `v1.0.0`.

Nothing in this skill has been deployed. No autoscaler, dashboard or alert has run against our model. Every threshold is a Hypothesis anchored on one or two measured runs.

## When to use

- Someone proposes a scaling rule, a KEDA ScaledObject, an Auto Scaling group policy, or WVA.
- You need the trigger metric or threshold for scale-up, or a procedure for scale-in.
- You are about to scale on GPU utilization, on `vllm:num_requests_waiting`, or on KV usage alone.
- You write a Prometheus query, dashboard or alert for vLLM or the EPP, or quote a metric name.
- You need to know whether a metric exists on the fork image or only upstream.
- You plan or review phase 5 of `docs/06-aws-implementation-plan.md` (EKS or not, autoscaling, observability).
- A replica shows a full queue with low throughput and you need to tell a broken host from a busy one.

Use `capacity-and-cost` for fleet size and cost per user, `llm-d-routing` for the EPP configuration itself, `aws-g7e-deployment` for the cold start breakdown and AMI work, and `inference-benchmarking` for running the harness.

## Decisions and why

| # | Decision | Why | Evidence |
|---|---|---|---|
| 1 | The unit of scale is one replica: 4 GPUs, one `g7e.24xlarge` | The model needs 4 GPUs per serving engine (TP or DCP across 4); one `g7e.24xlarge` has exactly 4 RTX PRO 6000. Scaling below a replica is not possible; scaling by 8-GPU instances doubles the step | Observed (profiles in `vllm-fork-serving`); docs/06 |
| 2 | Scheduled floor for the daily peak, reached 15 to 20 min before it; reactive scaling only on top | Cold start is 21 to 23 min from an empty VM to serving; 8 to 12 min is the target with seeded caches. A reactive rule that fires when load arrives delivers the replica after the peak has started | Observed §17.2, §18.3; target Inferred; AWS lead time Unknown until phase 1 |
| 3 | Reactive scale-up on in-flight requests per replica against measured capacity `C`, secondary on prefill backlog seconds; never on GPU utilization | In our runs the SLO broke with the engine queue averaging 0.07 and KV at 16%; running requests sat at the measured limit. GPU utilization stays high under any batch and llm-d calls it the wrong signal | Observed (`references/signals-and-thresholds.md`); Reported (llm-d, `references/llm-d-autoscaling.md`) |
| 4 | KV usage is a ceiling guard, not a load signal | KV peaked at 0.73 inside the SLO with DCP1 and at 0.28 with DCP4 even when DCP4 failed | Observed, one run per profile |
| 5 | Bursts are absorbed by the engine queue, flow control and headroom, not by scaling | A sub-agent group arrives in seconds (p90 47, p99 175 requests); a replica takes 8 to 23 min. Scale-up uses minute-long sustain windows and adds at most one replica per lead time | Observed in the Weka corpus §24.1; Inferred |
| 6 | Scale-in is slow and drains | Removing a replica discards its HBM KV, so each of its sessions pays a cold prefill on the next turn (a 120K session is about 11.7 s at 10,300 tok/s, over the 5 s target). Remove from the router, wait for running requests to finish (5 to 10 min bound), SIGTERM with a shutdown timeout; scale-down window 30 to 60 min | Inferred from §12.2; §20.1; Reported in project research notes, not published |
| 7 | The SLO is computed from gateway request records, not engine histograms | `vllm:time_to_first_token_seconds` mixes cold and cached turns (p90 54.7 s in a run whose cached p95 was 4.93 s), and the ITL histogram counts MTP steps (3.2 tokens per observation) | Observed (`examples/fork-metrics-observed.md`) |
| 8 | KEDA with EPP metrics if the cell runs on EKS; an ASG plus a small controller on plain EC2; not WVA | llm-d v1.0.0 recommends KEDA plus EPP metrics and declares WVA deprecated with v0.9.0 as its final release. KEDA needs Kubernetes; the no-Kubernetes llm-d path has no autoscaler | Reported, llm-d v1.0.0 (`references/llm-d-autoscaling.md`) |
| 9 | Every threshold is re-derived when the profile changes | `C` differs between DCP1 (24) and DCP4 (16 once, below 16 on the repeat); llm-d states thresholds do not transfer across model, accelerator or TP | Observed; Reported |

## How to

### Derive the scale-up trigger

1. Take `C` from phase 2: the highest agents level that passed the SLO in two runs of the chosen profile (two-run rule, `capacity-and-cost`). Today only DCP1 at 24 (one run) and DCP4 at 16 (passed once, failed the repeat) exist.
2. Take the lead time `L` from phase 1 on AWS (instance request to first token served, with the AMI and caches as deployed).
3. Measure `r`, the p95 growth of streams per replica per minute during the morning ramp, from gateway telemetry. Until it exists, start at `0.75 x C`.
4. Trigger at `C - r x L` in-flight requests per serving replica, sustained 2 min. Worked numbers: `examples/capacity-planning-worked.md`.
5. Add the prefill backlog trigger once `V_P` is calibrated: `sum(llm_d_epp_inflight_tokens) / V_P` per replica above about `5 s - P/V_P` (about 4.1 s with P = 3,700 and V_P = 4,100, Inferred).

### Set the scheduled floor

`ceil(expected peak streams / C) + 1` serving replicas, reached 15 to 20 min before the peak, requested one lead time earlier still. On EKS this is a KEDA `cron` trigger (inside the window `desiredReplicas` acts as a floor and the other triggers add to it, Reported); on EC2 an Auto Scaling scheduled action. Example: `examples/keda-scaledobject.illustrative.yaml`.

### Remove a replica

Follow the scale-in procedure in `references/signals-and-thresholds.md`: pick the least loaded replica, remove it from the EPP inventory (`endpoints.yaml` by atomic rename on EC2, pool selector on Kubernetes), wait for `vllm:num_requests_running` to reach 0 within 5 to 10 min, SIGTERM with `--shutdown-timeout` (fork support Unknown, check `vllm serve --help` on the image), release the instance, and check that no stream was cut.

### Confirm a metric name on the fork

```bash
curl -s http://<replica>:8000/metrics | grep -E '^vllm:' | sed 's/{.*//; s/ .*//' | sort -u > fork-metrics.txt
```

Save the file with the run's results and move the names in `references/vllm-metrics.md` from Unknown to Observed. Until that runs, only the names the harness parsed are proven on the fork.

### Tell a broken host from a busy one

Both show many requests waiting and few running. A busy replica in a burst of cold prefills keeps prompt throughput high (4,265 tok/s mean over the intervals with more than 10 waiting on host 157204); a degraded host stays low (1,015 tok/s on host 48294) and keeps that shape after the burst. Replace the host; do not scale out. Observed, `references/signals-and-thresholds.md`.

## Invariants

1. No scaling rule fires on GPU utilization.
2. The scheduled floor is computed from `C` and the demand curve, never left to the reactive rule.
3. Never more than one replica added per lead time for one demand step, and never one removed within the scale-down window.
4. A replica leaves the router before it stops serving, and stops serving before the instance is released.
5. SLO dashboards and alerts read gateway records; engine histograms are diagnosis only.
6. Every metric name in a query is either Reported with its source or Observed on the image that runs it.
7. Every threshold carries its label and the test that would change it.
8. `/metrics` of engines and the EPP stays on the private network (unauthenticated on vLLM, project research notes, not published).

## Pitfalls

- Scaling on `vllm:num_requests_waiting`: it stayed near 0 while the SLO failed (Observed). It spikes in cold bursts and would buy replicas that arrive after the burst.
- Reading `vllm:kv_cache_usage_perc` as a percentage: it is a fraction from 0 to 1 (Observed in raw lines). One of two names exists depending on the version; `references/vllm-metrics.md` has both.
- Alerting on `vllm:time_to_first_token_seconds` p95 as the SLO: it includes cold turns and turn 0.
- Computing tok/s as `1 / ITL` with MTP on: each observation is one engine step of about 3.2 tokens.
- Assuming `--shutdown-timeout` exists on the fork image: Unknown.
- Expecting KEDA on plain EC2: it needs Kubernetes. The llm-d no-Kubernetes guide covers routing and metrics only.
- Copying llm-d defaults (in-flight 16, saturation 0.7, token backlog 1.5 s, KV 0.8): they were set for other models on H100 and llm-d says they do not transfer.
- Scale-to-zero: with a 21 to 23 min cold start, the first user of the day waits that long. Keep a floor of 2 per cell.
- EPP restarts lose the approximate prefix index and in-memory flow-control queues. With `FailOpen`, Envoy keeps routing without affinity while the EPP is down (Reported).
- Fairness IDs per user on EPP metrics: cardinality grows with users (project research notes, not published).

## Open questions

- `C` under the two-run rule for the chosen profile (phase 2).
- Lead time `L` on AWS, cold and with a seeded AMI (phase 1).
- `r`, the ramp rate of the morning curve (needs phase 0 gateway telemetry).
- `V_P` calibrated on the fork with `CHUNK_SIZE` 4096 (the R1 4,100 tok/s value is from another profile).
- The fork's full `/metrics` list, including `vllm:prompt_tokens_by_source_total` and the cached-tokens counter.
- Whether the fork accepts `--shutdown-timeout`.
- Where preemptions start for DCP1 (32 agents was never run).
- Whether llm-d v1.0.0 includes the fix for stale per-endpoint series after endpoint removal (`references/llm-d-autoscaling.md`).
- EKS or plain EC2 for phase 5 (docs/06).

## Index

References:

- `references/signals-and-thresholds.md`: read first when choosing a trigger, a threshold or the scale-in steps; holds the measured operating points.
- `references/vllm-metrics.md`: read before writing any query on vLLM; upstream list, what the fork proved, histogram traps, SLO mapping.
- `references/llm-d-autoscaling.md`: read before using KEDA, WVA or EPP metrics; digest of the llm-d v1.0.0 workload-autoscaling guide with URLs.
- `references/dashboards-and-alerts.md`: read when building panels or alert rules per replica, cell and fleet.

Examples:

- `examples/fork-metrics-observed.md`: real server blocks, time-series samples and log lines from the fork, with the script that computes steady-state gauges.
- `examples/prometheus-queries.md`: queries for load, ceiling, health, cache and routing; illustrative, not run.
- `examples/keda-scaledobject.illustrative.yaml`: a ScaledObject with cron floor and three triggers; illustrative, not deployed.
- `examples/capacity-planning-worked.md`: from `C`, demand and price to floor, launch time and trigger for 1,000 users.
- `examples/phase5-acceptance-test.md`: scenarios and pass criteria for the phase 5 autoscaling test.
