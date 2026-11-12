# Cells, session hash, sub-agent bursts and flow control

How the gateway spreads sessions over cells, how a cell spreads requests over replicas, what a sub-agent fan-out does to that, and which llm-d flow-control features would absorb it. The cell design is our own and untested beyond 2 mini replicas. Upstream facts are Reported from llm-d `v1.0.0` (local clone, commit `378b42d18dabe0b9c4ced4e6f3670d93b52db08e`, read 2026-11-12).

## Sources

| Source | URL |
|---|---|
| Flow-control architecture | https://llm-d.ai/docs/architecture/router/flow-control |
| Flow-control guide | https://github.com/llm-d/llm-d/tree/v1.0.0/guides/flow-control |
| Tuning `maxConcurrency` | https://github.com/llm-d/llm-d/blob/v1.0.0/docs/operations/traffic/flow-control-tuning.md |
| Turn-priority fairness guide (Beta) | https://github.com/llm-d/llm-d/tree/v1.0.0/guides/turn-priority-fairness |
| Our cell layout | `docs/04-kv-cache-routing-and-disaggregation.md` §6.1; §16 as corrected by §17 |

## The cell

```
Global gateway: hash of session-id chooses the cell only.
  Cell failover = recompute, with admission control at the destination cell.
Cell = 1 region; llm-d EPP per cell (1 active, warm standby):
  prefix affinity + token load, approximate mode, fixed lruCapacityPerServer,
  calibrated tau, flow control, single-flight for uncached shared prefixes.
No KV shared across regions.
```

Quoted from `docs/04` §6.1. Reasons and labels:

- Two keys at two levels. The session hash keeps a session's turns in one cell, where its prefix lives. Inside the cell the key is the prefix, because sub-agents share the parent's prefix under different session IDs (Inferred, §17.2; MemServe reports 59% better P99 TTFT with a prompt tree than with intra-session affinity, Reported).
- Size. At least 2 replicas per cell for N+1 (§17.3 asked for 2 VMs of 2 replicas on Nebius; on AWS a replica is one `g7e.24xlarge`, so the minimum is 2 instances, Inferred).
- One EPP per cell. The approximate index is per EPP, so splitting a cell's replicas over two EPPs would split the index (Inferred).
- Cell failover moves sessions to a cell that holds none of their prefixes: 64 sessions of 256K cost about 27 min of prefill on one replica (Inferred, §17.4). The destination needs admission control or it breaks the SLO of its own sessions.
- Session hash at the gateway: the key must be stable for the whole session. Which header carries it for each client (Claude Code, Codex, opencode) is Unknown in our sources. llm-d's Alpha `agent-identity` plugin derives a fairness ID "from a coding agent's own session header" (Reported, turn-priority guide); which headers it reads was not checked.

## Burst shapes

| Source | Shape | Label |
|---|---|---|
| Weka corpus, our analysis | sub-agent groups: median 16, p90 47, p99 175 requests; per-session starts in 10 s: p90 11, p99 19; 42.5% of requests (42,029 of 98,827) come from sub-agents, correcting the 51.7% in §17.3 | Observed in our analysis, §24.1 |
| llm-d GLM-5.2 blog | p90 fan-out of 51 | Reported, §8.1 |
| Mini, burst of 8 | affinity 3 and 5, load only 4 and 4, 72.9% hit | Observed (mini), `f3/resultados/exp-20261105/` |
| Mini, burst of 51, 3 runs per mode | affinity 27/24 each run; load only 25/26, 25/26, 24/27; 93.3% hit | Observed (mini), `../examples/routing-results-excerpts.md` |

Why the mini burst says little about the real model (Inferred):

- A burst of 51 identical prompts with a 17,408-token prefix was about 900K tokens in flight, but each was a cache hit after the first, so per-request prefill was 512 tokens. Neither saturation nor the TTFT penalty was reached.
- On the real model a replica has 32 slots (`--max-num-seqs 32`). 51 requests on one replica means 19 wait in the engine queue. Pure affinity would do that; affinity with a working saturation gate spreads them, and each replica that receives part of the burst without the prefix pays a cold prefill (25 s at 256K on DCP4, §12.2).
- With the fork running one prefill at a time (`--max-parallel-prefills 1`), 51 cold prefills of 256K are about 22 min of one replica (§17.4). That is the scenario single-flight is for.

## Single-flight

One fetch or one prefill per uncached shared prefix; the other requests wait for it and then hit the cache. Our design, not built (§17.4). Without it, 51 independent L2 fetches of 2.28 GB are 116 GB, about 29 s at 3.97 GB/s, slower than a 25 s cold prefill (Inferred, §17.4). Where it lives (gateway, EPP plugin, engine) is undecided. Nothing in llm-d `v1.0.0` that we read documents request coalescing (Inferred by absence, KV report).

Partial substitute (Inferred): send the first request of a group, hold the others at the gateway until its first token arrives, then release them; affinity routes them to the replica that now holds the prefix.

## Flow control in llm-d v1.0.0

Turned on with the `flowControl` feature gate (in `featureGates` or `--feature-gates`). Each request gets a flow key (fairness ID from `x-llm-d-inference-fairness-id`, priority from the `InferenceObjective` named in `x-llm-d-inference-objective`, priority 0 without one). Dispatch order: priority band, then fairness policy across flows, then ordering policy inside a flow. Requests wait in EPP memory while the saturation detector says the pool is full (Reported, flow-control page).

The guide's configuration (Observed in `guides/flow-control/router/flow-control.values.yaml`, excerpt):

```yaml
        featureGates:
        - flowControl
        plugins:
...
        - type: round-robin-fairness-policy
        - type: fcfs-ordering-policy
        - type: concurrency-detector
          parameters:
            maxConcurrency: 132
            concurrencyMode: requests
            headroom: 0.0
...
        flowControl:
          maxBytes: "10Gi"
          maxRequests: "1k"
          defaultRequestTTL: "60s"
          saturationDetector:
            pluginRef: concurrency-detector
          priorityBands:
          - priority: 100
            maxRequests: "500"
...
          - priority: 0
            maxRequests: "200"
...
          - priority: -10
            maxRequests: "50"
```

`maxConcurrency` 132 is per replica and tuned only for Qwen3-32B on H100 (Reported, guide). The tuning doc frames three layers (Reported): the engine batch limit N (`--max-num-seqs`), the EPP dispatch gate `maxConcurrency` = N plus a small lookahead buffer B, and the EPP burst queue (`maxRequests`, 200 or more), which holds bursts centrally so the EPP can apply fairness and send work to whichever replica frees first. Its `tuning_wizard.py` derives the numbers from a step-load test and the KV block count read from `vllm:cache_config_info`.

For us (Inferred): N is 32; but our measured capacity inside the SLO is 24 (DCP1, one run) or 16 (DCP4), below N, because the SLO binds before the slot count. So `maxConcurrency` near `C` plus a small B, not 32 plus B. A sub-agent burst then waits in the EPP queue, where it can still be routed to the replica that frees first, instead of in one engine's queue.

Outcomes and status codes (Reported, flow-control page): rejected for saturation, TTL expiry or eviction returns 429; no endpoints, client cancelled or EPP shutting down returns 503. Queues live in EPP memory and are lost on restart. Keep the gateway's quota 429 distinguishable from the EPP's 429 (§18.3 separates quota from capacity).

Security (Reported, flow-control guide): the ingress gateway must strip client-sent `x-llm-d-*` headers and set them itself, or any client can pick its own priority.

Without Kubernetes, `InferenceObjective`-driven flow control is out of scope (`standalone-epp.md`), so priorities other than 0 need Kubernetes in `v1.0.0` (Inferred from the parity list).

## Turn-priority fairness (Beta)

A fairness strategy of the `program-aware-fairness` plugin that dispatches the deepest session first:

```
score = turnNumber + turnPriorityTimeWeight * headWaitSeconds
```

Quoted from the guide. Defaults `turnPriorityTimeWeight` 0.05 and `turnPriorityInactivitySeconds` 120. Requires one fairness ID per session; unlabelled traffic must go to another band (Reported).

Why it fits agent traffic: a deep session most likely still has its prefix in KV, so serving it costs little prefill and finishing it frees the slot. On the guide's agentic replay at concurrency 128, 200 sessions offered, it finished 17 sessions against 0 for first-come-first-served, served 5,592 requests against 2,239, and cut request latency p50 from 586.7 s to 37.8 s; at concurrency 16 the arms were indistinguishable (Reported, guide benchmark, model and hardware as in the guide).

Costs (Reported): new sessions are shed under sustained contention when the workload is deeper than `turnPriorityTimeWeight x defaultRequestTTL` (the guide uses a 9000 s TTL, so 450 turns); the weight does not transfer between workloads; an abandoned in-flight request pins a session at full depth; the guide's values file still uses the deprecated `llm-d.ai/v1alpha1` config version and needs `allow-experimental-plugins` for `agent-identity`.

For us: untested. It needs flow control, so Kubernetes or a confirmed file-config path, and a per-session fairness ID from the gateway, which also raises EPP metric cardinality (project research notes, not published).
