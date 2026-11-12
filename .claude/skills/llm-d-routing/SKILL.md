---
name: llm-d-routing
description: Use when configuring, sizing, testing or debugging the llm-d EPP router in front of the GLM-5.3-Flash vLLM fork replicas, including prefix affinity, lruCapacityPerServer, the saturation threshold tau, KV-event (precise) routing, cell and session-hash design, sub-agent burst handling, or reproducing the routing tests on the real model on AWS g7e.
---

# llm-d routing for GLM-5.3-Flash replicas

The router decides which 4-GPU replica serves each request. For coding-agent traffic that decision sets most of the cost: 98.6% of served tokens are input and 96% of turns reuse 90% or more of the prefix (Reported, llm-d GLM-5.2 blog, ARQUITETURA.md §8.1). A request that lands on a replica that does not hold its prefix pays a full prefill (25.2 s for a cold 256K context on TP4 + DCP4, Observed, §12.2).

Everything we know about the router was measured on the **mini model**: `glm5next` mini, random weights, 2 full attention layers, 1 RTX PRO 6000 per replica, 2 replicas, vLLM 0.32.0, llm-d v1.0.0, Nebius `uk-south2` (§7). Nothing about routing has been measured on the **real model** (GLM-5.3-Flash, TP4 on 4 RTX PRO 6000). Mini results transfer as mechanisms, not as numbers.

Harness paths (`router/`, `bench/`) are relative to the root of this repository. Raw results are cited as `results archive: f3/resultados/...`, a path inside the published results archive. `docs/` means `docs/` of this repository; `§N` points to `ARQUITETURA.md`, the Portuguese working journal kept outside this repository (later sections replace earlier ones).

Evidence labels: Observed (we measured it; "(mini)" or "(real)" says on which model), Reported (named source says it), Inferred (derived; the link is given), Hypothesis (to validate), Unknown.

## When to use

- Writing or reviewing EPP plugin configuration, Helm values or a standalone EPP + Envoy setup for this project.
- Choosing `blockSizeTokens`, `lruCapacityPerServer`, `autoTune`, `peakPrefillThroughput` or `maxTTFTPenaltyMs`.
- Deciding between approximate prefix routing and precise KV-event routing, or wiring LMCache events to the router.
- Designing the gateway in front of several cells (session hash) and the router inside a cell (prefix).
- Planning for sub-agent fan-out bursts or single-flight.
- Repeating the §7.1 and §9.1 routing tests on the real model (phase 3 of `docs/06-aws-implementation-plan.md`).

## Decisions and why

### 1. Approximate prefix affinity plus token load, the "optimized baseline" profile

What runs (Observed in `router/router-mini.values.yaml`, §4): plugins `approx-prefix-cache-producer` (with `blockSizeTokens: 8704` and `maxPrefixTokensToMatch: 262144`), `inflight-load-producer`, `prefix-cache-affinity-filter` and `token-load-scorer`. The scheduling profile `default` applies the filter, then the scorer. The values file is the last layer on top of the llm-d v1.0.0 guide files `guides/recipes/router/base.values.yaml` and `guides/optimized-baseline/router/optimized-baseline.values.yaml`, deployed with the chart `oci://ghcr.io/llm-d/charts/llm-d-router-standalone --version v1.0.0`.

- The approximate producer is the EPP's own index. It learns only from the routing decisions it makes and gets no feedback from the engine (Observed in config, §4). That is why it cannot see evictions (decision 3).
- `token-load-scorer` scores on uncached in-flight tokens. Upstream calls this default "sticky until saturated" and reports 2.9x input throughput on code generation, 46k against 16k tok/s (Reported, llm-d blog via the KV report, `docs/04-kv-cache-routing-and-disaggregation.md` §4.1).

Why this profile: it is the only one we ran, and on the mini it did what it promises (Observed (mini), §7.1, §9.1):

| Test (mini, 2 replicas) | Affinity | Load only |
|---|---|---|
| Serial, 21 groups x 3 repetitions, 17,408-token prefix: repetitions back on the same replica | 100% | 52.4% (chance 50%) |
| Same test: prompt tokens from cache on repetitions | 97.1% (ceiling 97.1%) | 55.5% |
| Warmed A/B at 3 req/s, 240 requests: prompt tokens from cache | 69.7% | 50.7% |
| Warmed A/B: prompt tokens computed | 1,311,296 | 2,129,472 |
| Warmed A/B: TTFT p50 / p99 / max | 0.135 / 0.324 / 0.387 s | 0.174 / 0.304 / 0.315 s |

Affinity cut computed prefill by 38% and median TTFT by 22% with no tail cost in that regime (Observed (mini), §9.1). Data in the results archive: `f3/resultados/exp-20261105/` and `f3/resultados/ab-aquecido-20261105/`.

Not proven on any model: behaviour under memory pressure, with more than 2 replicas, and with load that saturates the replicas (§7.1, §7.4). Demand-limited load does not measure capacity (§9.1).

### 2. `blockSizeTokens` must equal the engine's KV block

The EPP index counts prompts in blocks of `blockSizeTokens`. The engine only reuses whole blocks, so an EPP block smaller than the engine's credits prefixes the engine cannot reuse, and `lruCapacityPerServer` is counted in these blocks (Inferred). The comment in `router/router-mini.values.yaml` gives a different reason, that "the EPP hashes do not match the real cache"; in approximate mode the EPP approximates tokens from characters and never compares its hashes with the engine's (Reported, llm-d `v1.0.0` `docs/architecture/kv-management/prefix-cache-aware-routing.md`). The conclusion stands, the reason in the comment does not (`references/epp-architecture.md`).

- Mini: 8,704 tokens, read from vLLM's `cache_config_info` (Observed (mini)).
- Real model on the fork image `karmic-kraken-20261016`: every server log prints `Using split GLM-5.3 cache pages: target block size 2048 tokens, recurrent-state block size 2048 tokens`, and 1,024 in the run with LMCache, although the command asks for `--block-size 256` (Observed (real), `f3/resultados/vast-20261111/vllm/*/servidor-direto.log`; `references/scorers-and-saturation.md`). That 2,048 is also the cache-hit granularity is Inferred.
- Test prefixes must be longer than one block, or the vLLM prefix cache never hits (Observed, comment in `router/bench/inference-perf.yaml`: 17,500 tokens = 2 blocks, 17,408 reusable).

### 3. Set `lruCapacityPerServer` by hand, with `autoTune: false`

- The default is 31,250 blocks. With 8,704-token blocks that assumes 272 million tokens per replica (§4), far above any real pool.
- The approximate index does not see evictions. Under pressure it claims a prefix is on a replica after the replica dropped it (§4), and keeps sending the session there for a miss.
- The real pool with TP4 + DCP4 is 23,249,576 tokens (Observed (real), §12.2), about 11,352 blocks of 2,048 tokens. With DCP1 the pool is 6,789,052 tokens (Observed (real), §29.6 and the harness `kv_tokens_source`), about 3,315 blocks (Inferred: pool / 2,048, decision 2). Earlier notes divided by the mini's 8,704 and got about 2,665 and 780; those do not apply to the real model.
- `autoTune` ignores the offload tier (Reported, comment in the llm-d Qwen3.5-397B guide, §4; llm-d-router #1650, KV report). The llm-d GLM-5.2 guide uses about 3,700 GPU blocks plus about 27,300 CPU blocks with `blockSizeTokens` 64 (Reported, KV report correction 30). Whether our value should add LMCache L1 blocks the same way is a Hypothesis.
- §20.1 lists "fixed `lruCapacityPerServer` with `autoTune: false`" as mandatory for the MVP.

Evidence gap: on the mini we kept the default, and in the KV pressure test the router believed prefixes were still on the replicas. We did not measure the effect of changing the value (Observed (mini), §7.4).

### 4. Calibrate tau per model and GPU before relying on saturation

- tau = `peakPrefillThroughput` x `maxTTFTPenaltyMs` (Reported, llm-d blog "Sticky Until Saturated", §4). Example from the blog: 20,480 tok/s x 14 s = 286,720 tokens, 35 blocks of 8,192.
- We run the guide's default, calibrated for another model and GPU. Copying it from other hardware gives a 1.3x to 1.9x error (Reported, same blog via the KV report). The KV projects report quotes different default inputs (15,928 tok/s and 18 s, about 287K). The products agree and the inputs differ (`docs/04` §8).
- Our own prefill numbers (Observed (real), R1, TP4 + DCP4, §12.2): 10,381 tok/s cold, about 4.1k tok/s while decode is running. At those rates a 286,720-token threshold is about 28 s and 70 s of prefill (Inferred: 286,720 / 10,381 and 286,720 / 4,100), against the 14 s penalty the example assumes. If that holds, the default lets a replica stay sticky well past the TTFT penalty it is meant to cap (Inferred).
- The cold-start tail in the first A/B (p99 2.18 s) was first blamed on calibration. A warmed rerun ruled that out (Observed (mini), §9.1). Calibration is still untested and matters only under saturating load.
- Both parameters belong to `prefix-cache-affinity-filter`: `peakPrefillThroughput` in tok/s per endpoint (default 15928, measured on Qwen3-32B, H100, TP2) and `maxTTFTPenaltyMs` in ms (default 18000; 0 means always stick). The blog's `maxTokensInFlightPenalty` is not a parameter in `v1.0.0` (Reported, llm-d-router `v1.0.0` filter README, read 2026-11-12; `references/scorers-and-saturation.md`).
- Calibration is test E10 (§17.6), never run: `guides/recipes/router/calibration/calibrate.sh` with `CHUNK_SIZE` equal to `--max-num-batched-tokens` (4096 in our profile). It needs Kubernetes; on EC2 send the same 4,096-token random prompts by hand.

### 5. Precise KV-event routing stays off for now

- `precise-prefix-cache-routing` consumes vLLM KV events over ZMQ and would see evictions (Reported, §4). We have not tested it (§4, §7.4).
- The LMCache inside the fork image (`0.5.3.dev453+lil...g8ef537d6481b`, 2026-10-11) publishes `BlockStored` and has no `BlockRemoved` (Observed (image extraction), §25.1). The router would not see CPU-tier evictions (Inferred, §25.1).
- Upstream LMCache PR #5307, merged 2026-10-12, publishes both events with `medium="CPU"` through vLLM's event pipeline. Its test got 6 of 6 routes right with an unmodified llm-d EPP (`b16fa8db`), Envoy `v1.33.2`, vLLM HTTP servers and file-based endpoint discovery, with no Kubernetes (Reported, PR text, §25.1). Limits: L1 only, no events while the engine is idle, no salted hashes, validated with Qwen2.5-7B, chunk 16, no DCP and no recurrent state. Fixes #6119 (merged 2026-11-02) and #6122 (merged 2026-11-11; idle publishing, needs a vLLM companion change) are merged; #6564 (TP-replicated groups) is open; #5695 (multiple L1s) was closed without merge on 2026-11-09 (Reported, GitHub, read 2026-11-12; `docs/` still list it as open). Tracking issue #5932 is open. The image predates the PR (Inferred from dates).
- Hybrid models: upstream says hybrid-attention-aware scoring is work in progress; the only open PR (llm-d-router #3875) indexes sliding-window groups, not KDA (Reported, KV report). The indexer may overestimate hits when the KDA checkpoint for that point was evicted (Hypothesis).
- The MVP list in §20.1 requires a per-user `cache_salt` (HMAC) at the gateway, and #5307 does not accept salted hashes. Precise routing with those events would conflict with the salt (Inferred).
- §29.7 gave "llm-d reads vLLM KV events" as a reason to stay on vLLM. That was corrected on 2026-11-12: only the approximate mode, which uses no events, was tested (`docs/README.md`).

Decision (§25.1, Inferred): fixed `lruCapacityPerServer`, no dependency on LMCache events, until a build with #5307 and its fixes is validated on GLM-5.3-Flash with recurrent checkpoints and DCP.

### 6. Session hash picks the cell, prefix picks the replica

Layout (`docs/04` §6.1, from §16 as corrected by §17):

```
Global gateway: hash of session-id chooses the cell only.
  Cell failover = recompute, with admission control at the destination cell.
Cell = 1 region; llm-d EPP per cell (1 active, warm standby):
  prefix affinity + token load, approximate mode, fixed lruCapacityPerServer,
  calibrated tau, flow control, single-flight for uncached shared prefixes.
No KV shared across regions.
```

- Why two keys: sub-agents share the parent's prefix under different session IDs. Session affinity alone would scatter them. MemServe measured 59% better P99 TTFT with a prompt tree than with intra-session affinity (Reported, §17.2).
- Risk: no reference architecture publishes a global session gateway over a per-cell prefix router, and the two stickiness levels could conflict when a cell saturates (Inferred, KV report).
- Failover cost: 64 sessions of 256K cost about 27 min of prefill on one replica, 13.5 min on two (Inferred, §17.4). The destination cell needs admission control.
- Minimum two VMs per cell (N+1) came from a 99.5% per-VM SLA and 8 to 21 min startup on Nebius (§17.3). The AWS equivalent is Unknown.
- On AWS, `docs/06` recommends plain EC2 for phases 1 to 3 with the EPP outside Kubernetes (standalone EPP + Envoy + file discovery). The #5307 validation used that topology but publishes no setup; the setup is the llm-d `v1.0.0` no-Kubernetes guide (`references/standalone-epp.md`, illustrative config in `examples/standalone-ec2.illustrative.yaml`). We ran the EPP in standalone mode inside a Kubernetes cluster; we have never run it outside Kubernetes (`docs/04` §4.3 item 5).
- Cell design, flow control and turn-priority fairness in detail: `references/cells-and-bursts.md`.

### 7. Bursts: affinity did not pile up on the mini, but the real limit is slots

- Shape of the traffic: sub-agent groups have median 16, p90 47, p99 175 requests; per-session request starts in 10 s have p90 11, p99 19 (Observed in our analysis of the Weka corpus, §24.1). The llm-d blog gives a p90 fan-out of 51 (Reported, §8.1).
- Mini, burst of 8 with the same prefix: affinity split 3 and 5 (load only 4 and 4), 72.9% hit in both (Observed (mini), §7.1). About 143K tokens in flight did not exercise the saturation threshold.
- Mini, burst of 51, 17,408-token prefix, 3 repetitions per mode with cache reset: affinity 27 and 24 requests per replica in all three runs, load only 25 and 26 twice and 24 and 27 once, 93.3% hit, TTFT p50 about 0.5 s, max about 1.0 s (Observed (mini), §9.1). The single unrepeated first run had shown a max of 2.16 s; that was a cold start. Which EPP rule produced the split was not logged.
- Real model: a replica has 32 slots (`max_num_seqs` 32). A burst of 51 exceeds one replica, and pure affinity would queue about 19 requests (Inferred, §17.3, KV report).
- Single-flight (one fetch or one prefill per uncached prefix, the rest wait for it) is our own design; no project we read documents request coalescing (KV report, §17.4). 51 independent L2 fetches of 2.28 GB total 116 GB, 29 s at 3.97 GB/s, more than a 25 s cold prefill (Inferred, §17.4). Not built, not tested (E6 in §17.6, V6 in §21.2).

## How to

### Reproduce the mini routing tests (Kubernetes, as run on Nebius)

Scripts in `router/`. They assume a cluster reachable through `KUBECONFIG` (required), namespace `llm-d-optimized-baseline`, replicas labelled `app=vllm-mini`, a clone of llm-d at tag v1.0.0 in `LLMD_DIR` (required by `router_mode.sh` and `run_ab.sh`), the `make-mini` ConfigMap with `make_mini.py` (not in this repository), and the EPP service `optimized-baseline-epp:80`. Results go to `results/` at the repository root unless `OUT` is set.

```bash
cd router/exp
bash router_mode.sh affinity       # helm upgrade with affinity, then POST /reset_prefix_cache on each replica
bash run_exp.sh rot21-affinity routing --groups 21 --repetitions 3
bash run_exp.sh burst51-affinity-r1 burst --burst 51   # repeat as -r2, -r3; reset the cache between runs
bash router_mode.sh load-only      # adds router/bench/router-no-prefix.values.yaml
bash run_exp.sh rot21-load-only routing --groups 21 --repetitions 3
bash run_exp.sh burst51-load-only-r1 burst --burst 51

cd ../bench && WARMUP=1 bash run_ab.sh   # warmed A/B, both modes, inference-perf at 3 req/s
```

The `run_exp.sh` arguments are Inferred from `sessions.py` options and the result file names in `f3/resultados/exp-20261105/`; the exact command lines were not recorded. The archived runs used the Portuguese names of the time (modes `roteamento`, `ciclico`, `rajada`, `afinidade`, `so-carga`; flags `--grupos`, `--repeticoes`, `--rajada`), now `routing`, `cyclic`, `burst`, `affinity`, `load-only`, `--groups`, `--repetitions`, `--burst`. `sessions.py` defaults to `--groups 20`, so pass 21 every time (see pitfalls).

How `sessions.py` measures (Observed in code): prompts are seeded random token IDs; the client calls the EPP at `/v1/completions` with streaming; it attributes each request to a replica by the delta of `vllm:prompt_tokens_by_source_total` (`local_cache_hit`, `local_compute`, `external_kv_transfer`) scraped from each replica's `/metrics`. The `burst` mode first sends one request with the prefix to warm one replica, then fires N in parallel.

### Repeat them on the real model (phase 3 of `docs/06`, not yet run)

Acceptance in `docs/06` phase 3: the same-replica share and the cache share against its ceiling for the 21 x 3 serial test, both modes; and a burst of 51 with no errors, with the per-replica split reported.

What has to change, each item from the code or sources:

1. Two replicas need two `g7e.24xlarge` or one `g7e.48xlarge` (`docs/06`).
2. `blockSizeTokens` in the EPP config must be the real engine's block, 2,048 on the current image (decision 2). Choose the prefix as a whole number of blocks plus a short question, as the mini test did (17,408 = 2 x 8,704, question 512); with 2,048-token blocks, 18,432 is 9 blocks. `BLOCK = 8704` in `sessions.py` is not used by the code (Observed).
3. `sessions.py` hardcodes `EPP = "http://optimized-baseline-epp:80"` and model name `"mini"`, and takes replica IPs with `--pods`; `run_exp.sh` and `router_mode.sh` use `kubectl` and `helm`. Outside Kubernetes run `sessions.py` directly with the Envoy URL; commands in `examples/reproduce-on-real-model.md`.
4. Whether the fork image exports `vllm:prompt_tokens_by_source_total` is Unknown. Check `/metrics` on the real server before the run; without it, replica attribution fails.
5. Reset the prefix cache on every replica before each mode (`POST /reset_prefix_cache`, as `router_mode.sh` does), and discard a warm-up before each timed run (the 2.18 s tail was a cold start, §9.1).
6. Repeat each burst 3 times per mode. One run is not evidence (§9.1).

Tests the real model needs that the mini never ran (proposals, not yet specified in the sources beyond their names):

- Index capacity: the `cyclic` mode of `sessions.py` (S sessions visited in cyclic order for T passes) with a working set larger than the HBM pool, default `lruCapacityPerServer` against a fixed value. On the mini this pattern drove the LRU hit rate to 0% (Observed (mini), §7.2).
- More than 2 replicas, and saturating load (§7.1 "not proven").
- E10: `calibrate.sh` on TP4 for `peakPrefillThroughput` (§17.6).
- E6: burst of 51 with the prefix outside HBM, with and without single-flight, LMCache TTLs at 7200 s (§17.6).

## Invariants

1. Report every routing number with the model it ran on (mini or real). Mini numbers are mechanisms, not capacity (§7).
2. `blockSizeTokens` equals the engine's KV block, read from the server log of the image in use. Otherwise the EPP credits prefixes the engine cannot reuse and the LRU capacity is miscounted.
3. `lruCapacityPerServer` is set explicitly from the replica's KV pool and `autoTune` is false. The approximate index cannot see evictions, and the default assumes 272M tokens per replica.
4. Use an odd number of prefix groups in serial routing tests (21, not 20). With an even number the load-only tie-breaker lands repetitions on the same replica by parity and fakes affinity (§7.1).
5. Warm up and discard before each timed mode, reset the prefix cache between modes, and repeat at least 3 times. The first A/B tail and the first burst-of-51 max were cold-start artefacts (§9.1).
6. Do not enable precise KV-event routing with the image's LMCache. It never emits `BlockRemoved` (§25.1).
7. The session hash chooses only the cell; inside a cell the key is the prefix. Sub-agents share prefixes across session IDs (§17.2).
8. No KV sharing across regions. Reasons: no documented private networking between regions, unmeasured latency and egress, and the L2 is lost with the cell (§17.2). Bandwidth alone does not decide it.
9. Do not call a router setting validated on load that never saturated the replicas. Demand-limited load does not measure capacity (§9.1).

## Pitfalls we hit

- **Even group count.** A first round with 20 groups gave 85% same-replica routing for load only, because the tie-breaker alternates replicas. The `rot-*.json` files from that round must not be cited; use `rot21-*` (§7.1).
- **Cold start blamed on the router.** The original A/B showed a p99 of 2.18 s with affinity. Affinity ran first, right after the pods started. Warmed, it was 0.324 s against 0.304 s (§9.1). The run order was fixed and confounded with the cold start.
- **Wrong reason for a decision.** "llm-d reads vLLM KV events" was used to justify vLLM (§29.7) although only the approximate mode, which ignores events, was tested. Corrected 2026-11-12.
- **Default index size under pressure.** With the default `lruCapacityPerServer`, the router kept believing prefixes were on the replicas during the KV pressure test (§7.4).
- **`/dev/shm` too small for the RAM tier.** With `--kv-offloading-size 32` and a 16 GiB `/dev/shm`, vLLM failed at start (`32758 MiB required, 16384 MiB free`) (Observed (mini), §7.2). Size `/dev/shm` and memory limits for any host RAM tier behind the router.
- **Crash with 35K-token prompts on the mini.** With a 1 GiB pool and `--max-num-seqs 64`, both replicas hit `CUDA error: an illegal memory access` twice with 34,816-token prompts; 17,408-token prompts did not crash (Observed (mini), §7.3). Cause Unknown; reproduce on the real model with 35K and 256K prompts before long-context routing tests.

## Open questions

1. Does affinity stay correct on the real model under memory pressure, with more than 2 replicas and with saturating load? (`docs/04` open question 6)
2. The fork logs 2,048-token cache pages (decision 2). Is that the prefix-cache hit granularity, and does LMCache's 1,024 change what the EPP should use? Untested.
3. What tau does `calibrate.sh` give on TP4, for DCP1 and DCP4? (E10)
4. Does an LMCache build with #5307 publish usable `BlockRemoved` events for GLM-5.3-Flash with recurrent checkpoints and DCP, and does the llm-d indexer handle KDA groups? (`docs/04` open question 5)
5. How does precise routing coexist with a per-user `cache_salt`? Unknown.
6. Do the two stickiness levels (session to cell, prefix to replica) conflict when a cell saturates? Inferred risk, untested.
7. Single-flight for bursts: where to implement it (gateway, EPP plugin, engine) is not decided.
8. Does the standalone EPP + Envoy + file discovery setup work for us on EC2? Documented by llm-d `v1.0.0` and used by the #5307 validation; we have not run it. Does flow control with priority bands work without `InferenceObjective`? Unknown.
9. Does EFA on g7e change the case for P2P KV sharing between replicas (llm-d `p2p-kv-cache-sharing`, which depends on precise routing, §8.4)? Untested (`docs/06` open question 4).

## Sources

- `ARQUITETURA.md` (Portuguese working journal, outside this repository): §4, §7.1 to §7.4, §8.1, §8.4, §9.1, §12.2, §16, §17.2 to §17.6, §20.1, §24.1, §25.1, §29.7.
- `docs/04-kv-cache-routing-and-disaggregation.md` §4 and §6; `docs/06-aws-implementation-plan.md` phase 3; `docs/README.md` contradictions table.
- Code and config: `router/router-mini.values.yaml`, `router/bench/router-no-prefix.values.yaml`, `router/bench/run_ab.sh`, `router/bench/inference-perf.yaml`, `router/exp/router_mode.sh`, `router/exp/run_exp.sh`, `router/exp/sessions.py`.
- Results: `f3/resultados/exp-20261105/` (`rot21-*`, `rajada51-*-r1..r3`), `f3/resultados/ab-aquecido-20261105/`.
- Upstream read directly on 2026-11-12: the llm-d `v1.0.0` docs and guides (local clone of `llm-d/llm-d` at `v1.0.0`, commit `378b42d`), the llm-d-router `v1.0.0` plugin READMEs and release notes, LMCache PR #5307 and its follow-ups. URLs in each reference file.
- External, as Reported in the sources above: llm-d blogs "Sticky Until Saturated" and "Serving GLM-5.2 for Agentic Workloads on llm-d", llm-d GLM-5.2 and Qwen3.5-397B guides, llm-d-router #1650 and #3875, LMCache PR #5307, MemServe.

## Index

References:

- `references/epp-architecture.md`: read when you need what the EPP is, the request path, the plugin kinds, or what each line of our values files does.
- `references/scorers-and-saturation.md`: read before setting any plugin parameter: defaults, the fork's block size, `lruCapacityPerServer` sizing, tau, saturation detectors, calibration.
- `references/standalone-epp.md`: read before running the EPP on plain EC2: the llm-d no-Kubernetes setup, what #5307 validated, the limits.
- `references/cells-and-bursts.md`: read when designing cells, the session hash, burst handling, flow control or turn-priority fairness.

Examples:

- `examples/annotated-router-values.md`: both mini values files in full with per-line notes and the real-model changes.
- `examples/routing-results-excerpts.md`: real result excerpts of the 21 x 3 test, the six burst-of-51 runs and the warmed A/B.
- `examples/reproduce-on-real-model.md`: preconditions and commands to repeat the tests on the real model, on Kubernetes or EC2.
- `examples/standalone-ec2.illustrative.yaml`: an EPP config for EC2 with file discovery and our plugin set; illustrative, never run.
