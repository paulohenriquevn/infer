# llm-d workload autoscaling: digest of the v1.0.0 docs

What llm-d v1.0.0 says about autoscaling model servers, which EPP metrics it scales on, and what of it applies to us. Every fact in this file is Reported from the llm-d repository at tag `v1.0.0` (commit `378b42d18dabe0b9c4ced4e6f3670d93b52db08e`, 2026-10-19), read on 2026-11-12 from a local clone of `https://github.com/llm-d/llm-d`. Paths are given as `https://github.com/llm-d/llm-d/blob/v1.0.0/<path>`. Statements about our system are labelled separately.

## Sources read

| Topic | Path at v1.0.0 |
|---|---|
| Design of KEDA with EPP metrics | `docs/architecture/autoscaling/keda-epp.md` |
| Guide index, WVA deprecation | `guides/workload-autoscaling/README.md` |
| In-flight, queue and saturation ScaledObjects | `guides/workload-autoscaling/keda-epp/optimized-baseline/overlays/k8s/{inflight,queue,saturation}/scaledobject.yaml` |
| Token-aware path | `guides/workload-autoscaling/keda-epp-token-aware/README.md`, `.../optimized-baseline/base/scaledobject.yaml` |
| SLO-aware path | `docs/architecture/autoscaling/slo-aware-keda.md`, `guides/workload-autoscaling/slo-aware/` |
| EPP metric reference | `docs/operations/observability/router-metrics.md` |
| Flow control and saturation detectors | `docs/architecture/router/flow-control.md`, `docs/architecture/router/configuration.md` |
| Running without Kubernetes | `docs/infrastructure/no-kubernetes-deployment.md`, `guides/no-kubernetes-deployment/README.md` |
| Peak prefill calibration | `guides/recipes/router/calibration/` |

## The problem as llm-d states it

- "During active token generation, GPU utilization can remain high whether a model server is lightly loaded or saturated. A utilization-based autoscaler cannot reliably distinguish spare serving capacity from an overloaded batch." (`keda-epp.md`)
- The guide index says GPU utilization "is often pegged near 100% during active batching regardless of actual load, making it an entirely unreliable signal", and asks for "queue depth, in-flight request counts, and KV cache pressure" instead (`guides/workload-autoscaling/README.md`).

## Pipeline

1. The EPP exposes metrics on its metrics endpoint (for example `llm_d_epp_flow_control_queue_size`, `llm_d_epp_request_running`).
2. Prometheus scrapes the EPP (on Kubernetes through the router's `ServiceMonitor`).
3. KEDA's Prometheus scaler evaluates one scalar PromQL result per trigger; `spec.advanced.scalingModifiers` can combine triggers into one formula.
4. KEDA publishes the values to the Kubernetes External Metrics API.
5. The HPA that KEDA generates computes the desired replica count and reconciles the Deployment.

"The user creates a `ScaledObject`, not a second HPA. Multiple HPAs targeting the same Deployment conflict with one another." Prometheus Adapter is not used; "The Prometheus Adapter path is deprecated." (`keda-epp.md`)

## WVA status

"The Workload Variant Autoscaler (WVA) is deprecated. The WVA path is no longer developed and receives no further releases; `v0.9.0` is the final version." New deployments use a KEDA + EPP path; WVA users migrate to the keda-epp guide's saturation overlay (`guides/workload-autoscaling/README.md`).

## The five signals

From the table in `keda-epp.md`, quoted:

| Signal | EPP metrics | Threshold is |
|---|---|---|
| In-flight load (default) | `llm_d_epp_inflight_requests` | An absolute per-replica target (concurrency), tuned per deployment; no Flow Control required |
| Queue depth | `llm_d_epp_flow_control_queue_size`, `llm_d_epp_request_running` | An absolute per-replica target, tuned per deployment |
| Pool saturation | `llm_d_epp_flow_control_pool_saturation`, `llm_d_epp_request_running` | A normalized ratio (0.0 to 1.0+), more portable across hardware |
| Token backlog | `llm_d_epp_inflight_tokens`, per-pod KV cache occupancy | Seconds of prefill queue wait, derived from a share of the TTFT SLO and a calibrated `peakPrefillThroughput` |
| Estimated latency | EPP predicted/actual TTFT and TPOT histograms | Latency divided by SLO, with a hysteresis band |

Key statements around it:

- Queue and saturation series exist only when the `flowControl` feature gate is on. "with it off those series are not produced and the queue and saturation triggers resolve to no data."
- The stock optimized-baseline EPP emits `llm_d_epp_inflight_requests` and `llm_d_epp_inflight_tokens` from its `inflight-load-producer` plugin with no flow control. Our router config includes that plugin (`router/router-mini.values.yaml`, Observed).
- Reactive backlog signals stay at zero until a replica is saturated: "at concurrency 40 with the decode running all 40, `num_requests_waiting` and `per_endpoint_queue_size` held 0 and KV utilization barely moved, so they trigger late; the in-flight-load signals rise immediately and are the better default."
- Token backlog exists because "request counts rate an 8192-token prompt the same as a 512-token one, while the prefill work differs by 16x."

Our own data says the same about the engine queue (Observed, see `signals-and-thresholds.md`): with the vLLM fork at the edge of the SLO, `vllm:num_requests_waiting` had a mean of 0.07 to 0.15 in steady state, including a run that failed the TTFT target.

## Dual-metric strategy and thresholds

- Most paths use two `AverageValue` triggers (unmet demand plus running requests). "roughly, the aggregate must exceed `threshold x current replicas` to scale beyond the current count. When all configured metrics are available, Kubernetes uses the largest desired replica count."
- "`minReplicaCount` is the warm floor that keeps a keep-warm replica up and damps flap, and `maxReplicaCount` is the ceiling the HPA silently caps at."
- "These values are not universal. Validate them against representative load for your deployment ... find the point where adding a replica stops relieving demand. Do not assume a value validated for one model, accelerator, or tensor-parallel degree transfers to another."

Shipped defaults, for reference only (Qwen3 reference stacks, not our model):

| Path | Trigger and threshold | Window and policy |
|---|---|---|
| keda-epp `inflight` | `sum(llm_d_epp_inflight_requests{namespace="${NAMESPACE}",producer_name="inflight-load-producer"})`, `AverageValue` 16 | `pollingInterval: 15`, `cooldownPeriod: 300`, `minReplicaCount: 1`, `maxReplicaCount: 8`, scale up and down stabilization 300 s, 100% per 15 s |
| keda-epp `queue` | queue size threshold 1, running requests threshold 16 (`keda-epp.md`) | 300 s windows |
| token-aware | `(sum(llm_d_epp_inflight_tokens{...,producer_name="inflight-load-producer"}) / 15928) or vector(0)`, threshold 1.5 (seconds); `sum(vllm:kv_cache_usage_perc{...}) or vector(0)`, threshold 0.8 | scale up 1 pod per 180 s with 0 s window; scale down 1 pod per 300 s with 300 s window |

The token-aware file explains its arithmetic: `replicas = max( ceil(prefill_backlog_s / 1.5) , ceil(kv_pods_worth / 0.8) )`, the prefill threshold is "a share of your TTFT budget ... threshold ~= TTFT_SLO - ISL/V_P", and "A wrong divisor silently changes when prefill scales: the same offered load asked for 8 replicas at 2696 tok/s and 3 replicas at 15928 tok/s on one reference stack." It uses `sum()` and not `avg()` because "`avg()` cannot exceed ~1.0 no matter how many pods are full", which would pin the Deployment.

The token-aware guide is marked "[Experimental] ... Use in development and test environments only."

## Startup time and overshoot

- "While a new replica is still coming up it serves nothing, so the demand signal it was meant to relieve stays high and the HPA keeps asking for more replicas."
- The HPA reconciles on `--horizontal-pod-autoscaler-sync-period` (about 15 s); KEDA's `pollingInterval` (default 30 s) governs activation and scale to zero.
- The queue path uses 300 s scale-up and scale-down stabilization windows: "Size the scale-up window near the target Deployment's measured cold-start time (the 300s default was validated against a ~240s Qwen3-8B TP1 cold start)." Windows "are blunt: they delay all scale-up equally".
- The SLO-aware path credits replicas that are provisioned but not yet serving, reading kube-state-metrics (`slo-aware-keda.md`, an in-flight `r/n` credit).
- "Warmup is paid at every scale-up ... Cutting pod-ready time is usually the highest-leverage tuning available."

What this means for us (Inferred): our cold start is 21 to 23 min on Nebius (Observed, ARQUITETURA.md §17.2, §18.3), about 5 times the 240 s the 300 s window was validated against. A scale-up window sized to our cold start (about 1,300 s) would leave the fleet blind to any ramp for 20 minutes; a 300 s window would add a replica every few minutes while the first is still loading. Neither works on its own, which is why the skill puts a scheduled floor first and keeps reactive scaling slow, with in-transit credit.

## Saturation detector

- `utilization-detector` is the default: "a closed-loop detector that reacts to real-time telemetry (queue depth and KV-cache pressure) ... It has known limitations under sudden bursts and in heterogeneous pools." Its buffer knob is `queueDepthThreshold`.
- `concurrency-detector` is "an open-loop detector based on in-flight request accounting ... blind to KV-cache pressure"; its knob is `maxConcurrency`, set "just above your model server's effective batch size".
- Without flow control, a saturated pool rejects only negative-priority ("sheddable") requests with HTTP 429; everything else passes to the model servers (`flow-control.md`).

Default parameter values of the two detectors are not in the files we read; they are in the plugin READMEs under `https://github.com/llm-d/llm-d-router/tree/main/pkg/epp/framework/plugins/flowcontrol/saturationdetector/` (Unknown until read for the pinned router version).

## Scale to zero

"Those requests buffer in EPP's in-memory queues, so a request queued while the pool is at zero is lost if EPP restarts before a model server becomes Ready ... Model cold-start time becomes request latency." Enable only after one to N is validated (`keda-epp.md`). For us scale to zero means a 21 to 23 min first token, so it is out of scope (Inferred).

## Endpoint removal and stale series

The token-aware README warns that `llm_d_epp_inflight_tokens` series were not pruned when an endpoint was removed (llm-d-router #2529), so `sum()` never fell after scale-down; fixed by llm-d-router #2577, which "merged after `v0.10.0`, so it is not in a tagged release yet". That sentence is in the v1.0.0 tree. Whether EPP image `v1.0.0` contains #2577 is Unknown; check by scaling a test pool down and watching the series, or read the router release notes. The README gives a workaround that intersects with `llm_d_epp_per_endpoint_queue_size` via `label_replace` and `and on (target_pod)`.

## Without Kubernetes

The no-Kubernetes path runs the EPP with the `file-discovery` plugin. "Without Kubernetes, some pieces of the llm-d stack are out of scope: `InferenceObjective`-driven FlowControl, the `InferenceModelRewrite` model-name rewriter, and `PodMonitor`-based Prometheus discovery. Scoring, prefix-cache affinity, saturation-based admission, and Prometheus metrics on `--metrics-port` all work" (`docs/infrastructure/no-kubernetes-deployment.md`). KEDA scales Kubernetes objects, so on plain EC2 (phases 1 to 3 of `docs/06`) there is no KEDA. The equivalent is a controller that reads the same PromQL and changes an EC2 Auto Scaling group or rewrites `endpoints.yaml` (Inferred; nothing of the sort exists in this repository).

## What we did not read

- The SLO-aware path in detail (`slo-aware-keda.md`, 113 lines) beyond its in-transit credit idea.
- `kueue-rebalancing` and `multi-inference-pool`.
- The upstream `docs/operations/observability/alerting.md` and `promql.md`; read them before writing production alerts.
