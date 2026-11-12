# Phase 5 acceptance test design: autoscaling and observability

A test design for the autoscaling part of phase 5 in `docs/06-aws-implementation-plan.md`. Nothing here has run. Thresholds are Hypothesis; the test exists to confirm or replace them. It assumes phases 1 to 4 passed, so `C` (sessions inside the SLO per replica, lower of two runs) and the lead time `L` are known.

## Setup

- One cell: EPP with prefix affinity (llm-d-routing skill), Envoy, a gateway that writes one record per request (session id, turn index, prompt and cached tokens, first-byte and last-byte time, output tokens, status), Prometheus scraping the EPP and every replica.
- Scaling: scheduled floor plus reactive triggers as in `keda-scaledobject.illustrative.yaml` (EKS) or the equivalent controller over an Auto Scaling group (plain EC2).
- Load: the harness agents scenario (`bench/run_benchmark.sh` with `AGENTS_ONLY=1`) pointed at the gateway, or a replay of the Weka corpus with think times. The harness alone cannot drive a time-varying ramp; a ramp driver must start agent groups on a schedule (not written yet).
- Before the timed run: warm up and discard (cold-start artefacts misled us twice, §9.1), and record the image, profile, `C`, `L`, region and instance IDs in the result directory.

## Scenarios

| # | Scenario | Load shape | Pass criteria |
|---|---|---|---|
| A1 | Scheduled floor | daily curve compressed: floor window starts at T0, load ramps from 10% to 85% of `floor x C` between T0 + 20 min and T0 + 40 min | all floor replicas serving (`llm_d_epp_ready_endpoints` = floor) before load passes 50% of `floor x C`; cached-turn TTFT p95 at most 5 s and per-stream p50 at least 30 tok/s in every 5-minute window |
| A2 | Reactive scale-up | from 70% of `C` per replica, add streams at the rate `r` used to set the trigger until load reaches `(replicas + 1) x 0.85 x C` | exactly one replica added; it serves within `L` plus 2 min of the trigger firing; SLO holds in every 5-minute window; record trigger time, request time, ready time |
| A3 | No overshoot | step of +0.5 `C` held for 2 `L` | at most one replica added |
| A4 | Burst | 51 concurrent requests with one shared prefix on top of 80% load (llm-d-routing skill, E6 shape) | no scale-up caused by the burst alone; zero errors; burst TTFT p95 reported; SLO of the other sessions holds or the violation window is reported |
| A5 | Scale-in with drain | drop load to 30% of `C` per replica and hold for the scale-down window plus 10 min | one replica removed after the window; zero 5xx and zero cut streams during the drain (V4 in §21.2); drain duration and the next-turn TTFT of moved sessions reported |
| A6 | No flapping | alternate 60% and 85% of `C` every 10 min for 2 h | no scale-in followed by a scale-out within `L` |
| A7 | Replica loss | kill one replica's server under 85% load | gateway retries only before the first token; error rate below 1% over 5 min (V1); a replacement is requested; time to recover recorded |
| A8 | Broken host detection | run one replica with throttled GPUs or on a host that fails qualification | the broken-host alert fires within 15 min; the scale rule does not treat it as load |

## Observability acceptance

| Check | Pass |
|---|---|
| Every panel in `references/dashboards-and-alerts.md` has data from the run | yes, screenshot or query output saved |
| The gateway SLO computation agrees with `bench/summarize.py` on the same requests | TTFT p95 and tok/s p50 within 2% when both read the same turn records |
| Every page alert fired at least once in A2, A5, A7 or A8, and none fired in A1 or A3 | yes |
| The fork's `/metrics` names are listed and saved (`curl -s :8000/metrics \| grep -E '^vllm:' \| sed 's/{.*//' \| sort -u`) | file present; `references/vllm-metrics.md` updated from Unknown to Observed |
| EPP metrics present: `llm_d_epp_inflight_requests`, `llm_d_epp_inflight_tokens`, `llm_d_epp_ready_endpoints`, `llm_d_epp_prefix_cache_affinity_filter_decisions_total` | listed from `:9090/metrics` |

## Failing case to keep in mind

The DCP4 16-agent repeat (`f3/resultados/vast-20261111/vllm/vast-vllm-r1-rep2/agentes-16.json`) failed with TTFT p95 5.20 s while the engine queue averaged 0.07 and KV usage 0.16 (Observed, `fork-metrics-observed.md`). A2 must show that the configured trigger fires before such a state. If the only signal that moved was the SLO itself, the trigger is too high.

## Report

Per scenario: load timeline, replica timeline (requested, starting, serving), SLO per 5-minute window, alerts fired, and the decision (keep or change each Hypothesis threshold), with the result directory path.
