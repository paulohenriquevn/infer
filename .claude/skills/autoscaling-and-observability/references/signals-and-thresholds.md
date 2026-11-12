# Scaling signals, starting thresholds and the scale-in procedure

Which metric drives which decision, the measured operating points the thresholds are anchored to, the thresholds we propose to start with (every one a Hypothesis), how to validate each, and how to remove a replica without breaking the SLO.

## Measured operating points of one replica (Observed)

Steady-state server gauges while the agents scenario ran, computed from the harness time series (one sample every 2 s, only samples after the last agent finished turn 0, the same steady-state rule `summarize.py` uses). Source files are under `f3/resultados/vast-20261111/vllm/` (old Portuguese names `agentes-16.json`, `agentes-24.json`). Vast host 157204, fork image `karmic-kraken-20261016`, one run per row. The calculation script is reproduced in `../examples/fork-metrics-observed.md`.

| Profile, agents | SLO verdict (TTFT p95, tok/s p50) | Running p50 / max | Waiting mean / max | KV usage p50 / max |
|---|---|---|---|---|
| DCP1, 16 (`vast-vllm-dcp1`) | pass (4.71 s, 70.8) | 15 / 16 | 0.15 / 2 | 0.39 / 0.51 |
| DCP1, 24 (`vast-vllm-dcp1`) | pass (4.93 s, 55.3) | 23 / 24 | 0.10 / 2 | 0.56 / 0.73 |
| DCP4, 16, run 1 (`vast-vllm-r1`) | pass (4.77 s, 57.2) | 15 / 16 | 0.14 / 3 | 0.16 / 0.19 |
| DCP4, 16, run 2 (`vast-vllm-r1-rep2`) | fail (5.20 s, 57.8) | 15 / 16 | 0.07 / 2 | 0.16 / 0.19 |
| DCP4, 24, run 2 (`vast-vllm-r1-rep2`) | fail (5.97 s, 47.1) | 23 / 24 | 0.08 / 2 | 0.23 / 0.28 |

What the table shows:

1. The engine queue does not move before the SLO is lost. The two failing rows had a mean waiting count below 0.1. A scale-up rule on `vllm:num_requests_waiting` would not have fired (Observed). llm-d reports the same for its own stacks (Reported, `llm-d-autoscaling.md`).
2. KV usage is not the binding limit at these levels. DCP4 failed the TTFT target at 16 to 28% KV usage. DCP1 passed at a maximum of 73%. KV usage is a ceiling to watch, not a load signal (Observed for this workload shape: 40K to 100K starting context, agents with 0 to 3 s think).
3. What tracks the SLO is concurrency against measured capacity. In this scenario the agents were almost always in flight (client in-flight mean 23.1 of 24), so running requests per replica equal active sessions. The limit sits between 16 and 24 for DCP4 and at 24 or above for DCP1 (24 is the highest level that passed; 32 was not run).
4. Prefill share is high. The DCP1 24-agent run spent 361 s of compute on prefill against 406 s on decode (`compute_seconds`, prefill share 0.471), with the fork's prefill compute share capped at 0.4 (`prefill_compute_share_mean`). New tokens per turn drive TTFT, which is why token backlog is a better signal than request count (Inferred).

A diagnostic case from a degraded host (Observed, §29.10, Vast host 48294, `f3/resultados/vast-20261112/vllm/vast-vllm-dcp1-rep/`): with 16 agents the server ran only 2 or 3 requests at a time, 21 waited, KV usage was 5%, and GPUs drew about 116 W. The same shape appears on a healthy replica during a burst of cold prefills: at the start of the DCP1 24-agent level on the good host, the harness printed `running 2 waiting 22 | KV 3%` for about 6 minutes (Observed, `vast-vllm-dcp1/agentes-24.log`), because the profile runs one prefill at a time (`--max-parallel-prefills 1`). Tell them apart by prompt throughput (the server log's `Avg prompt throughput`, or `rate(vllm:prompt_tokens_total[1m])`): in the 10 s log intervals with more than 10 requests waiting, the healthy host averaged 4,265 prompt tok/s over 14 intervals, the degraded host 1,015 tok/s over 88 intervals (Observed, `servidor-direto.log` of `vast-20261111/vllm/vast-vllm-dcp1` and `vast-20261112/vllm/vast-vllm-dcp1-rep`; whether that figure includes cached tokens is Unknown, so treat it as a coarse signal). The degraded host also stayed in that state after the cold phase, with turns timing out. A replica that stays with waiting high, running low and low prompt throughput is broken, not full; scaling out does not help, replacing the host does (Inferred).

## Signal table

Labels: Reported for upstream names, Observed for names proven on our servers (`vllm-metrics.md`), Unknown where the fork status is not proven.

| Purpose | Signal | Source metric | Why this one |
|---|---|---|---|
| Scale up (primary, reactive) | in-flight requests per serving replica against measured capacity | `llm_d_epp_inflight_requests` (Reported, emitted by `inflight-load-producer`, which our config has) or `vllm:num_requests_running` (Observed) | rises with load before latency degrades; item 3 above |
| Scale up (secondary) | seconds of prefill backlog per replica | `llm_d_epp_inflight_tokens` divided by calibrated `peakPrefillThroughput` (Reported) | prefill work, not request count, drives TTFT; item 4 |
| Scale up (scheduled) | time of day | KEDA cron trigger or ASG scheduled action | reactive scaling cannot cover a 21 to 23 min cold start |
| Ceiling guard | KV usage per replica | `vllm:kv_cache_usage_perc` (Observed, fraction) | when it fills, vLLM stops admitting and preempts |
| Confirm the SLO | TTFT p95 of cached turns, per-stream speed p50, turn errors | gateway per-request records | the engine histograms mix cold and cached turns and count MTP steps (`vllm-metrics.md`) |
| Diagnose | waiting by reason, preemptions, prefill backlog, queue time | `vllm:num_requests_waiting_by_reason`, `vllm:num_preemptions_total`, `vllm:scheduler_local_prefill_backlog_tokens` (fork), `vllm:request_queue_time_seconds` (all Observed) | explain why the SLO broke after the fact |
| Diagnose routing | predicted against delivered cache hits | `llm_d_epp_prefix_predicted_cached_tokens`, `llm_d_epp_prefix_prompt_tokens` (Reported) next to `vllm:prefix_cache_hits_total` (Observed) | a drop in delivered hits with stable predictions means the EPP index is stale |
| Fleet capacity | serving replicas times measured sessions per replica, against active sessions | `llm_d_epp_ready_endpoints` (Reported) and gateway session counts | planning and the scheduled floor |

GPU utilization is not in the table. During batching it stays high whether a replica is lightly loaded or saturated (Reported, llm-d); the degraded host above shows the opposite failure, low power with a full queue (Observed).

## Starting thresholds (all Hypothesis)

Measured capacity per replica, `C`: 24 agent sessions for DCP1 (one run, Observed), 16 for DCP4 in run 1 and below 16 in run 2 (Observed). Phase 2 of `docs/06` replaces `C` with the lower of two runs of the chosen profile. Lead time to a serving replica, `L`: 21 to 23 min cold (Observed on Nebius), 8 to 12 min target with seeded caches (Inferred, §17.2), Unknown on AWS until phase 1 records it.

| Rule | Starting value | Reasoning | How to validate | What would falsify it |
|---|---|---|---|---|
| Reactive scale-up trigger | sustained in-flight per serving replica above `C - r x L` for 2 min, where `r` is the p95 growth rate of active sessions per replica per minute | a new replica must be serving before load reaches `C`; with no data on `r`, start at `0.75 x C` (18 for DCP1) | replay a ramp (phase 5 test, `../examples/phase5-acceptance-test.md`) and check TTFT p95 stays under 5 s while the new replica starts; measure `r` from gateway telemetry | TTFT p95 above 5 s during a ramp with the trigger firing on time |
| Scale-up rate | 1 replica per `L` with credit for replicas still starting | avoids overshoot while a replica loads (Reported, llm-d); in-transit credit idea from the SLO-aware path | count replicas requested against replicas that end up serving during the ramp test | more than one replica added for a demand step of less than `C` |
| Prefill backlog trigger | backlog seconds per replica above `5 s - P/V_P` | llm-d's rule `threshold ~= TTFT_SLO - ISL/V_P` (Reported); with mean new tokens P = 3,700 (Weka corpus, §24.3) and V_P = 4,100 tok/s under decode (R1, DCP4) this gives about 4.1 s (Inferred) | calibrate `V_P` with `calibrate.sh` on the chosen profile, `CHUNK_SIZE` equal to `--max-num-batched-tokens` (4096 in our profile) | backlog trigger fires with TTFT p95 well under target, or never fires before it is missed |
| KV ceiling alert | `vllm:kv_cache_usage_perc` above 0.9 for 5 min on any replica, or any increase of `vllm:num_preemptions_total` | the highest steady value seen inside the SLO was 0.73 (DCP1); preemptions were 0 in every run | run DCP1 at 32 agents (never measured) and record where preemptions start | preemptions start below 0.9 |
| Scheduled floor | serving replicas at `ceil(expected peak sessions / C)` plus one for N+1, reached 15 to 20 min before the daily peak (§18.3, §20.1) | lead time exceeds any reactive window | first month of gateway telemetry gives the daily curve (§19.4) | floor reached late, or TTFT p95 above target in the first 30 min of the peak |
| Scale-down window | 30 to 60 min below `0.5 x C` per replica before removing one | node scale-down took about 11 min on Nebius and a cold start costs 21 to 23 min, so flapping is expensive (Inferred, project research notes, not published) | count scale-in events followed by a scale-out within one `L` | any such reversal in a normal day |

These numbers come from 4-GPU replicas of this model in one workload shape. llm-d says thresholds do not transfer between model, accelerator or TP degree (Reported). Re-derive `C` whenever the profile (DCP, MTP, `max-num-seqs`, image) changes.

## Bursts are absorbed by queueing, not by scaling

- A sub-agent fan-out arrives in seconds: per-session request starts in 10 s have p90 11 and p99 19; groups have median 16, p90 47, p99 175 requests (Observed in the Weka corpus, §24.1). A replica takes 8 to 23 min to start. No scaling rule can react inside a burst (Inferred).
- What absorbs a burst: the engine's own waiting queue (`max-num-seqs` 32 slots), EPP flow control where available, admission control at the gateway, and the scheduled headroom. The cold-start phase of every agents level shows what a burst of cold prefills does to one replica: at the start of the DCP1 24-agent level, 22 requests waited, and the TTFT p99 over all turns of the level was 347 s (Observed, `agentes-24.log`, headline `turn_ttft_p99_s 346.87`), while the cached steady-state p95 of the same level was 4.93 s.
- Scaling rules must ignore burst-length spikes. Use a sustain period of minutes on the reactive trigger so a burst does not buy a replica that arrives after the burst has drained (Inferred; the llm-d token-aware ScaledObject adds at most one pod per 180 s for the same reason, Reported).

## Scale-in procedure

Removing a replica discards its HBM KV. Every session whose prefix lived there pays a cold prefill on its next turn: a 120K-token session at 10,300 tok/s is about 11.7 s (Inferred from R1 cold prefill, §12.2), over the 5 s TTFT target. LMCache L1 does not survive the host either (kv-cache-tiers skill). So scale-in is planned, slow and done at troughs.

1. Pick the replica with the fewest active sessions (gateway) or the lowest `vllm:num_requests_running`. Never remove the last N+1 replica of a cell.
2. Stop new work. Remove its entry from the EPP endpoint inventory: on plain EC2 rewrite `endpoints.yaml` with an atomic rename so the `file-discovery` plugin reloads (Reported, llm-d no-Kubernetes guide); on Kubernetes remove the pod from the InferencePool selector or let the Deployment scale down. In-flight requests continue.
3. Drain. Wait until `vllm:num_requests_running` is 0 on that replica, bounded by a drain timeout of 5 to 10 min (§20.1; reasoning: p99 output of 7,551 tokens at about 45 tok/s is about 170 s plus prefill, Inferred in project research notes, not published).
4. Stop the server with SIGTERM. vLLM's `--shutdown-timeout N` keeps serving in-flight requests up to N s, and without it SIGTERM aborts them; `terminationGracePeriodSeconds` must exceed N plus any preStop (Reported, llm-d graceful-shutdown doc via project research notes, not published). Whether the fork image accepts `--shutdown-timeout` is Unknown; check `vllm serve --help` on the image.
5. Release the instance only after the server exited; record the time from step 2 to release.
6. Verify: gateway 5xx and SSE errors stayed at zero during the drain (V4 in §21.2), and the TTFT p95 of the moved sessions' next turns, which will show the recompute cost.

The gateway retries a request on another replica only before the first token; after the first token a failure becomes an SSE `error` event, never a silent close (§18.3, Reported for Claude Code client behaviour in project research notes, not published).
