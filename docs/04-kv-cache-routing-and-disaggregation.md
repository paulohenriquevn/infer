# KV cache, routing and prefill/decode disaggregation

## Summary

- KV lives in tiers: HBM, host RAM (LMCache L1), a shared file tier per region (L2), and recompute as the last resort. Restoring from RAM is one to two orders of magnitude cheaper than recomputing a long prompt, but the risk is the fixed cost per hit, synchronous loading, convoys and lock TTLs. Bandwidth is not the constraint (ARQUITETURA.md §17.4).
- LMCache, in the fork shipped with the local-inference-lab vLLM image, is the planned host RAM tier. The fork's LMCache publishes `BlockStored` but not `BlockRemoved`. Upstream PR #5307 adds both, and the image predates it (§25.1).
- Our only LMCache run on the real model (§29.8, Observed) showed that it restores recurrent state and prefixes, but it does not raise concurrent capacity: restored KV has to fit in HBM again. That test was overloaded by design, and the corrected test is still pending.
- The llm-d EPP with prefix affinity routed correctly on the mini model in light load, in a burst of 51 and in a warmed A/B (§7.1, §9.1). Index capacity, saturation calibration and precise KV-event routing are untested.
- Do not start with prefill/decode (P/D) disaggregation. On the mini model it improved TPOT and cut throughput by about 46% (§9.2). Build cells per region, route by session to a cell and by prefix inside it, with one LMCache server per engine (§16 as corrected by §17).

## How to read this document

Evidence labels follow the source: Observed (we measured it, or read it in a primary source where noted), Reported (a named third party says it), Inferred (our arithmetic or deduction, with the link stated), Hypothesis (to validate), Unknown.

Two different models appear in our measurements:

- The mini model (`glm5next` mini): random weights, 2 full attention layers, 1 RTX PRO 6000 per replica, vLLM 0.32.0, llm-d v1.0.0, on Nebius `uk-south2`. Its KV is about 1.95 KB per token. Results transfer as mechanisms, not as numbers (§7, §7.2).
- The real model, GLM-5.3-Flash (11 full attention layers with sparse MLA, 34 KDA layers), served by the fork image on 4 RTX PRO 6000 (TP4) on Nebius (R1, §12.2) or Vast.ai (§29).

The infrastructure findings in the sources (filesystem quotas, RDMA availability, spot capacity, image pull times) are about Nebius. None of them was checked on AWS. Treat every platform number here as Unknown for AWS until measured there.

`ARQUITETURA.md` is the main source. Later sections and notes marked "Correção posterior" replace earlier text. Section 17 replaces §13.2, §15 and §16 where they conflict. Only the current position is presented below; superseded figures are named only where an engineer might otherwise find and reuse them.

## 1. KV tiers and design principles

### 1.1 How much KV the real model holds

| Quantity | Value | Label and source |
|---|---|---|
| KV per token, vLLM accounting | about 8.7 KB (39.05 GiB for 4,807,959 tokens on 1 B300) | Observed, §9.3 |
| KV per token, from the architecture | 6.0 to 6.3 KB | Inferred, §14 and `reports/Projetos de KV cache e benchmarks.md` |
| KV per token if each chunk also stores a KDA snapshot | about 20 KB | Inferred from HelixML numbers, report "Arquitetura escalável de KV cache", correction 6 |
| One 256K session | about 2.3 GB of KV plus about 0.15 GB of KDA state | Inferred from the 8.7 KB figure, §2 correction note |
| KV pool, TP4 + DCP4, 4 RTX PRO 6000 | 23,249,576 tokens, 88.7 sessions of 262,144 tokens | Observed, §12.2 (R1) |
| KV pool, TP4 + DCP1, 4 RTX PRO 6000 | 6.79 million tokens | Observed, §29.6 |
| Host RAM of the 8-GPU Nebius VM | 1,716 GiB | Observed, §12.2 |

The gap between 8.7 KB and 6.0 to 6.3 KB per token is Unknown. Candidates are scales and page padding, the BF16 tail ring, the sparse indexer cache and amortised KDA state (§14). The DCP choice is still open (§29.7), and it changes the HBM pool by 3.4 times (§29.6).

MLA KV is not partitioned by tensor parallelism: with TP each rank holds a full copy (§2, Reported from the llm-d GLM-5.2 blog). Do not add the memory of 4 GPUs as if it were one pool.

### 1.2 Restore against recompute

| Path | Cost | Label and source |
|---|---|---|
| Cold prefill of 256K on R1 (TP4 + DCP4) | TTFT 25.2 s, 10,381 tok/s | Observed, §12.2 |
| Prefill while decode is active | about 4.1k tok/s, 40% of the cold rate | Observed, §12.2 |
| Recompute 256K under active decode | about 63.9 s | Inferred from the line above, KV report |
| Fork LMCache, 1M tokens cold vs restored from RAM | 99.3 s cold, 0.855 s restored, 0.970 s after restarting server and cache, same greedy output | Reported, rtx6kpro wiki, Max-Q and Workstation editions, not Server Edition (§15) |
| Fork LMCache, edit at the end of a 520K prompt | 516,096 tokens restored in 1.66 s, against 70.07 s | Reported, same source (§15) |
| Fork LMCache, 32,768-token prompt under RAM pressure | restored in 0.082 s | Reported, same source (§15) |
| Native vLLM offload on the mini | 12.1 GB moved CPU to GPU in 0.27 s of summed transfer time | Observed on the mini, §7.2; sums of small transfers, not sustained bandwidth |
| llm-d with GLM-5.2 on H200 | restore at about 26 ms per GB, against a recompute of about 45K tokens that pushed client TTFT to 59 s through the prefill queue | Reported, llm-d GLM-5.2 blog, cited in the KV report |

Break-even bandwidth is B* = bytes per token × prefill rate. At 8.7 KB and 10.3k tok/s that is about 0.09 GB/s (0.7 Gbps); at 20 KB per token it is about 1.7 Gbps (Inferred, §17.4). Fetching KV beats recomputing by 5x to 100x depending on the source (Inferred, §17.4). The KV report's estimates for one 256K session (2.28 GB) against 25.4 s of recompute:

| Source | Assumed bandwidth | Restore time | Label |
|---|---|---|---|
| L1 in host RAM | about 10 GB/s (from the 0.855 s figure) | 0.22 s | Inferred |
| L2 shared filesystem, documented ceiling | 3.97 GB/s ("up to", Nebius docs) | 0.57 s | Inferred |
| L2 shared filesystem, pessimistic | 1 GB/s | 2.3 s | Hypothesis |
| TCP between nodes, per flow | 0.55 to 4.9 GB/s (llm-d on a 100 Gbps NIC) | 4.1 to 0.47 s | Inferred from Reported bandwidth |

What can still go wrong, per §17.4: the fixed cost per hit (about 0.33 s in the GLM-5.3 LMCache paper, arXiv 2610.21500, Reported), synchronous loading (p99 of 83 s in the same paper), convoys, and lock TTLs. Restored prompts shorter than R × T0 lose to recompute; with T0 = 0.33 s that is about 3.4K tokens, or 1.4K under decode (Inferred, KV report).

The "about 700 times cheaper" figure in §2 used a superseded per-session size and a different prefill rate; do not reuse it.

### 1.3 Tiers

| Tier | Role | Status |
|---|---|---|
| HBM | Active sessions and the local prefix cache | Sizes concurrent capacity (§29.8) |
| Host RAM (LMCache L1) | Idle sessions and recovery on the same engine | One LMCache server per engine (§17.2) |
| Shared file tier (LMCache L2) | Persistence, recovery after node replacement, warming a new replica; kept off the hot path | Read bandwidth Unknown; never measured with the page cache dropped (§17.2) |
| Recompute | Last resort and the failover path between cells | Measured cost in §1.2 |

### 1.4 Principles

1. Keep KV in the cheapest tier that serves it: HBM, then host RAM, then the regional file tier, then recompute (§16.1).
2. Bring the request to the KV. Session and prefix affinity in the router; KV transfer between nodes only if the network proves it pays (§16.1).
3. Cells per region, no KV shared across regions. The reason is the absence of documented private networking between regions, unmeasured latency and egress, and the loss of the L2 together with the cell. Bandwidth alone does not justify it (§17.2).
4. HBM bounds concurrent capacity. LMCache only helps sessions that are really idle (§29.8, Inferred).
5. Platform: treat the network as TCP (§17.2). The §16.1 principle of a spot-based burst is refuted for Nebius by §17.2 (no preemptible capacity for the 8-GPU RTX VM in two regions, list price in the third, 60 s SIGTERM, no recovery).

## 2. LMCache

### 2.1 Why it was chosen

- It is already the cache layer of the fork. The image starts it with `CACHE_MODE=lmcache`, `LMCACHE_L1_GB` and `LMCACHE_L2_ENABLED`; the default profile is GPU only (§15). The connector used in our run is `LMCacheRecurrentCheckpointConnector` (§29.8).
- The community qualified it on our configuration: TP4 + DCP4, FP8 KV, MTP3, engine-driven LMCache (Reported, rtx6kpro wiki, §15).
- Upstream has recipes for KDA plus MLA models (Kimi K3 on 8 B300 and 8 MI355X, TP8 + DCP8) and PR #5042 for GLM-5.3-Flash (Reported, §15; #5042 is a merged PR, §17.2).
- §29.7: the engine decision kept vLLM partly because the LMCache layer was qualified on it; switching engines would mean revalidating the KV layer (Inferred).

The native vLLM `OffloadingConnector` stays as the control and plan B (§15, §17.6). On the mini model it started on the hybrid KDA + MLA layout and recovered up to 97.1% of prompt tokens where HBM alone gave 0% (Observed on the mini, §7.2). Under DCP4 plus MTP it has no proof: vLLM #58618 merged on 2026-11-02 after v0.33.0rc3 and #58619 is still open (§17.6, KV report correction 18).

### 2.2 What the image contains (§25.1, Observed by extraction from the image)

- LMCache version string `0.5.3.dev453+lil...g8ef537d6481b`, dated 2026-10-11.
- The fork has its own DCP implementation (`dcp_size`, per-rank fragments, `_get_dcp_rank` in `vllm_multi_process_adapter.py`). Its history diverges from upstream: of the upstream PRs checked, only #4679 is an ancestor. #4834, #4936, #5042, #5076 and #5307 are not, and the `KpoolTailSpec` symbol from #5042 does not exist in the image.
- KV events: `BlockStored` is present (one file); `BlockRemoved` is absent. Inferred: the precise llm-d indexer would not see evictions from the CPU tier.
- The vLLM fix #931 for issue #726 (MTP with structured output) is in the image (`.lil/changes/vllm-931.json`).
- The fork starts one LMCache server per vLLM instance, with ports derived from the API port (§17.2).

### 2.3 Upstream PR #5307

Update of 2026-11-12, Reported (§25.1): upstream LMCache closed the eviction gap in multi-process mode with PR #5307, merged on 2026-10-12. It publishes `BlockStored` and `BlockRemoved` with `medium="CPU"` through vLLM's KV event pipeline, and a test with the llm-d EPP got 6 of 6 routes right. The image's LMCache is from 2026-10-11, so it does not have the PR (Inferred from dates).

Limits of the PR: it covers only L1, does not publish while the engine is idle, does not accept salted hashes, and was validated with Qwen2.5-7B, chunk size 16, no DCP and no recurrent state. Later fixes #6119 and #6122 are merged; #6564 (TP-replicated groups) and #5695 (multiple L1s) are open. For GLM-5.3-Flash with recurrent checkpoints and DCP, working is a Hypothesis.

§17.5 says LMCache events were validated with Dynamo and not with llm-d. The §25.1 update about PR #5307 is later and reports an llm-d test; the §17.5 statement is outdated on that point.

### 2.4 Risks that still apply

| Risk | Detail | Label and source |
|---|---|---|
| Default TTLs under a deep queue | `--l1-read-ttl-seconds` 300 and `--session-ttl-seconds` 600 expire and fail the retrieve with `KEY_NOT_READABLE` on hybrid models; the Kimi K3 recipe uses 7200 | Reported, Kimi K3 recipe (§15, §17.2) |
| Lazy L1 | The fork script uses `--l1-use-lazy` with a 2 GB initial size, the setting the Kimi K3 recipe warns against | Observed in the fork script, §17.5 |
| Load failure policy | vLLM's `kv_load_failure_policy` defaults to `fail`; set `recompute` | Reported, §17.5 |
| Chunk granularity | Only whole chunks are stored; the tail is recomputed each turn. The final chunk is the LCM of the group spans, and under DCP the attention span is block × DCP. The fork script defaults to 4096; #5042 negotiated 1152 for Flash without DCP. The value under DCP4 is Unknown | §17.2 and KV report correction 5 |
| Sidecar GPU memory | Applies to upstream lmcache-driven mode (on H100, 0.90 failed and 0.85 worked). The fork lock describes the sidecar as CPU only in engine-driven mode, but the build script defaults to `lmcache_driven`. Which mode the image runs must be confirmed | §15 correction note, KV report correction 9 |
| Structured output with MTP | #726 is closed and #931 is in the image. A test with DCP4 is still needed | §17.2, §25.1 |
| Non-identical output | Cached and fresh runs are not bit identical on KDA backends; validate by score, not token diff | Reported, §15 |
| Text only | Requests with images run, but their recurrent state is not restored | Reported, §15 |
| Restart | L1 in RAM is lost on restart; a persistent L2 survives | Inferred, KV report correction 17 |
| Two-layer fork maintenance | Fork LMCache on fork vLLM. Upstream LMCache's GLM-5.3 recipe marks the Flash variant as not covered and MTP as not yet validated | §15, KV report correction 13 |

### 2.5 Sizing rules

- One LMCache server, and one L1, per engine (one TP4 group). A shared L1 per node has no documented case with TP above 1, and an L1 per rank is impossible under DCP because all DCP ranks of an engine must use the same server (§17.2).
- About 700 to 800 GB of L1 per engine when two engines share an 8-GPU VM with about 1.7 TiB of RAM (KV report, revised design). At about 800 GB, that holds about 350 sessions of 256K at 8.7 KB per token, or about 150 at 20 KB per token (Inferred).
- Set `--l1-init-size-gb` equal to `--l1-size-gb` (§17.5).
- L1 lives in `/dev/shm`. With `--kv-offloading-size 32` and a 16 GiB `/dev/shm`, vLLM failed at start on the mini (Observed, §7.2). Size `/dev/shm`, the pod memory limit and the node RAM to the L1. The fork script checks for a private `/dev/shm` of at least 96 GiB per container (KV report).
- TTLs of 7200 s (§15, §17.6).
- L2 entries need a cache identity key: weight revision, dtype, chunk size, connector version, TP and DCP layout (§17.5). Do not share entries between engines with different attention backends or block sizes (§16.5, Reported from the GLM-5.3 recipe). Write chunks immutably and publish the name after close, because the Nebius filesystem guarantees close-to-open content consistency and only eventual metadata consistency (§16.5, KV report correction 35).
- The fork uses the `fs_native` L2 adapter; whether it honours `"shared": true` across nodes is Unknown (KV report correction 10).
- In the KV report's Base scenario, L2 writes are about 54 MB/s per VM, below the 218 MiB/s we measured on a 1 TiB Nebius filesystem, as long as dense snapshots are not written for every session (Inferred).
- HBM, not L1, sizes concurrent sessions (§29.8).

### 2.6 Corrections from §17 that change the LMCache design

| Earlier claim | Current position |
|---|---|
| One LMCache server per node with about 900 GB of L1 shared by 2 replicas (§16.2) | One server per engine. Shared L1 per node becomes test E1 |
| Chunk of 8,192 tokens from the R1 log (§16.4) | Unknown under DCP4 until read from the LMCache server log |
| vLLM #726 unresolved (§15) | Closed 2026-09-28; fix #931 is in the image (§25.1) |
| L2 of 16 TiB serving 2 to 4 nodes (§16.3) | Nebius filesystem quota is 5 TiB per region; the 2 GiB/s read we measured was probably page cache; real L2 read bandwidth is Unknown |
| P2P between nodes only with RDMA (§16.3) | Expect TCP; LMCache P2P does not require RDMA (`mooncake_te` uses TCP by default). P2P stays off until per-flow TCP bandwidth is measured |
| Dynamo KVBM disk tier "22 times worse than recompute" | The issue says fragmentation costs about 10x of achievable NFS throughput; "22x" does not appear (Dynamo #12750) |
| `lruCapacityPerServer` via `autoTune` | `autoTune: false` with a fixed value; `autoTune` ignores the offload tier |

## 3. LMCache under HBM pressure: the §29.8 experiment

Real model, fork image, 4 RTX PRO 6000 on Vast.ai, 2026-11-12. All Observed. Results in the results archive: `f3/resultados/vast-20261111/vllm/vast-vllm-lmcache*`.

Two arms of the harness:

- `vllm/lmcache`: the server started by the image's own launcher (`bench/server-vllm-lmcache-direct.sh`) with our vLLM profile and `LMCacheRecurrentCheckpointConnector`. L1 of 200 GB in `/dev/shm`.
- `vllm/lmcache-control`: same server, cache in HBM only.

Both ran DCP4, with KV limited to 5 GiB per GPU (about 2.5 million tokens), and 48 agents with 20 to 60 s of think time between turns.

| | HBM only | LMCache |
|---|---|---|
| Duration | 1,076 s (interrupted; numbers from the log) | 1,520 s |
| Turns completed / timed out | 42 / 24 | 118 / 21 |
| Prefix hit on cached turns | 0% | 65.6% |
| TTFT p50 / p95, cached turns | minutes | 391 s / 502 s |
| Active requests on the server | 2 | 4 |

Findings:

- The mechanism works. The log shows 62 recurrent-state restores started and 1 that failed and was recomputed.
- LMCache does not raise concurrent capacity. 90 restores waited for GPU space, and 9 gave up after 133 to 185 s and recomputed the prompt. Restored KV has to fit in HBM again.
- Design flaw: the test assumed think time would keep about 23 agents active (Inferred). With turns queued for minutes, queue time became activity, all 48 sessions competed for HBM, and both arms collapsed. The run measures overload behaviour, not the TTFT of a restore in steady state.
- The control arm has no complete `agentes-48.json` (the file name the harness used then), because the bench writes only finished scenarios and the run was interrupted (§29.8, §29.9 item 3).

Design consequence (Inferred, §29.8): capacity per replica is HBM divided by the context of active sessions. With DCP1, 6.8 million tokens hold about 60 active sessions of 100K tokens, more than the 24 that the SLO computation allows.

Pending corrected test (§29.8, §29.9 item 2): DCP1 with normal KV, 24 active agents and idle sessions with minutes of think time, LMCache against HBM only. It measures the TTFT of a restored turn without a queue. It has not run.

## 4. Router: llm-d EPP

### 4.1 Configuration tested

Observed in `router-mini.values.yaml` (§4): `approx-prefix-cache-producer` (the EPP's own index, fed only by its routing decisions, with no feedback from the engine), `prefix-cache-affinity-filter` with the guide's values, and `token-load-scorer` on uncached in-flight tokens. Upstream calls this default "sticky until saturated"; its blog reports 2.9x input throughput on code generation, 46k against 16k tok/s (Reported, KV report).

### 4.2 Results on the mini model

All rows are Observed on the mini model (2 replicas, 1 RTX PRO 6000 each, random-token prompts). Data in `f3/resultados/exp-20261105/` and `f3/resultados/ab-aquecido-20261105/`.

Affinity correctness, serial, 21 prefix groups × 3 repetitions, 17,408-token prefix (§7.1):

| | Affinity | Load only |
|---|---|---|
| Repetitions that returned to the same replica | 100% | 52.4% (chance: 50%) |
| Prompt tokens from cache on repetitions | 97.1% (ceiling 97.1%) | 55.5% |

A first round with 20 groups gave 85% same-replica routing for the load-only control. That was an artefact of the tie-breaker alternating replicas with an even number of groups; the `rot-*.json` files from it must not be cited (§7.1).

Bursts with the same prefix:

- 8 concurrent requests: affinity spread them 3 and 5 (load only 4 and 4), 72.9% hit in both modes (§7.1).
- 51 concurrent requests, 17,408-token prefix, 3 repetitions per mode with cache reset: both modes gave 27 and 24 requests per replica (load: 25 and 26), 93.3% hit, TTFT p50 about 0.5 s and max about 1.0 s. Affinity does not pile up even at 51. The single unrepeated first run had shown a max of 2.16 s against 1.14 s; that was a cold start (§9.1).

Warmed A/B at 3 req/s (§9.1):

| | Affinity | Load only |
|---|---|---|
| Requests | 240 | 240 |
| Prompt tokens from cache | 69.7% | 50.7% |
| Prompt tokens computed | 1,311,296 | 2,129,472 |
| TTFT p50 | 0.135 s | 0.174 s |
| TTFT p99 | 0.324 s | 0.304 s |
| TTFT max | 0.387 s | 0.315 s |

Affinity cut computed prefill by 38% and median TTFT by 22% with no tail cost in this regime. The 2.18 s p99 from the original A/B was an artefact of run order and cold start, not of affinity or calibration (§9.1, confirmed in §17.2). Demand-limited load does not measure capacity.

Not proven: behaviour under memory pressure, with more than 2 replicas, or with load that saturates (§1, §7.1). Nothing here ran on the real model.

### 4.3 Risks and open items

1. Index capacity. `lruCapacityPerServer` defaults to 31,250 blocks. With 8,704-token blocks that assumes 272 million tokens per replica (§4). The approximate index does not see evictions, so under pressure it claims prefixes that are gone. The real pool of 23.2M tokens is about 2,665 such blocks (Inferred, KV projects report). Set it by hand in the producer's block unit with `autoTune: false`; `autoTune` ignores the offload tier (§17.5; Reported, llm-d-router #1650). The llm-d GLM-5.2 guide uses about 3,700 GPU blocks plus about 27,300 CPU blocks with `blockSizeTokens` 64 (KV report correction 30).
2. Saturation threshold. τ = `peakPrefillThroughput` × `maxTTFTPenaltyMs`, calibrated per model and GPU (Reported, "Sticky Until Saturated" blog). We use the guide's default, calibrated for another model and GPU. Copying it from other hardware gives a 1.3x to 1.9x error (Reported, same blog, KV report). Calibration with `calibrate.sh` on TP4 is test E10 (§17.6).
3. Burst against slots. A burst of 51 sub-agents exceeds the 32 slots of one replica (`max_num_seqs` 32); pure affinity would queue about 19 requests (Inferred, §17.3 and KV report). §17.4 asks for single-flight: one fetch or one prefill per uncached prefix, the rest wait for it. No project read documents request coalescing, so this is our own design (KV report).
4. Precise KV-event routing (`precise-prefix-cache-routing`) is not tested (§4, §7.4). It consumes vLLM events over ZMQ. Upstream says hybrid-attention-aware scoring is work in progress, and the only open PR (llm-d-router #3875) indexes sliding-window groups, not KDA (Reported, KV report). The indexer may overestimate hits when the KDA checkpoint for that point was evicted (Hypothesis). With the image's LMCache lacking `BlockRemoved`, §25.1 recommends a fixed `lruCapacityPerServer` and not depending on LMCache events (Inferred).
5. Running outside Kubernetes. The llm-d EPP can run outside Kubernetes as a standalone EPP with Envoy and file-based endpoint discovery (Reported, LMCache PR #5307 validation). Our experiments ran the EPP in standalone mode inside a cluster (§7); we have not run it outside Kubernetes.

## 5. Prefill/decode disaggregation

### 5.1 What we tested on the mini (§9.2)

Same 2 RTX GPUs and same load: 1 prefill + 1 decode replica with NIXL over TCP (`router/pd/pd.yaml`, vLLM reference proxy) against 2 aggregated replicas. Cold unique prompts of 17,408 tokens, output 128, closed loop, warm-up discarded. Data in `f3/resultados/pd-20261105/`. All Observed on the mini.

- P/D works on the hybrid KDA + MLA mini. The decode side computed 1 token and received 17,707 (and 40,299) tokens via `external_kv_transfer`. Logprobs of P/D and aggregated differed by at most 0.0235, the same order as aggregated with and without prefix cache (up to 0.0234), so there is no sign of error in KDA state transfer.
- Recipe gaps on SM120: `VLLM_KV_CACHE_LAYOUT=HND` failed (`valid layouts: ['BLHNC']`); UCX tried the RDMA device `mlx5_0` and failed; `UCX_NET_DEVICES=eth0` with `UCX_TLS=tcp,cuda_copy` worked.

| | Aggregated (2 replicas), c8 | P/D 1P1D, c8 | Aggregated, c32 | P/D 1P1D, c32 |
|---|---|---|---|---|
| Requests per second | 8.39 | 5.01 | 12.81 | 6.94 |
| TTFT p50 / p95 | 0.21 / 0.50 s | 1.28 / 1.92 s | 0.34 / 1.62 s | 3.50 / 6.04 s |
| TPOT p50 / p95 | 4.9 / 8.2 ms | 3.1 / 3.5 ms | 14.1 / 32.5 ms | 4.4 / 19.3 ms |
| Prompt tokens per second | 146k | 87k | 223k | 121k |

P/D smoothed TPOT and cut throughput by about 46%, because throughput was bound to one prefill GPU while the decode GPU sat nearly idle (decode on the mini costs almost nothing). This shows the mechanism, not the real-model outcome (Inferred). A model with expensive decode, or a tuned P:D ratio, could reverse it; 2P1D was not tested. The source of the extra TTFT (proxy hops, `--enforce-eager` prefill, NIXL handshake, queue) is Unknown.

### 5.2 Why not to start with P/D

- vLLM docs: "disaggregated prefill DOES NOT improve throughput"; it tunes TTFT and ITL separately (Reported, KV projects report).
- The llm-d GLM-5.2 sweep has no matched aggregated control, and its "54% more output with 1/3 fewer GPUs" came from offload plus MTP, not P/D (Reported, same report). Our §9.2 run is a matched control, but on the mini over TCP.
- P/D shrinks the KV pool per GPU. With about 96% prefix reuse, new prefill per turn is small, which is where prefilling on the decode replica is preferred (Inferred, same report).
- The replica unit is already a multi-GPU group; P/D doubles the smallest useful deployment (§3, Inferred).
- On Nebius, the RTX PRO 6000 has no InfiniBand, and llm-d calls NIXL over TCP "extremely slow, for local development" (Reported, §3). Whether this holds for the AWS instance chosen is Unknown.
- Mixing GPU types for P and D requires matching KV layouts across SM120 and SM100; Hypothesis, untested (§3).

Recommendation (§3, current): start aggregated with prefix cache and a host RAM tier. Adopt P/D only if measurement shows TPOT degraded by long prefills and NIXL works with the real model. If ITL tail from long sub-agent prefills is the problem, try a smaller `max-num-batched-tokens` and prefill chunk first (Hypothesis, KV projects report).

### 5.3 SGLang P/D constraints (§29.7)

An external proposal recommended SGLang with llm-d, P/D over RDMA, DCP, Unified Memory and the QAD checkpoint. It was not adopted. Per SGLang's own documentation (Observed in `docs.sglang.io/docs/advanced_features/unified_memory`):

- Unified Memory with P/D refuses speculative decoding and `--dcp-size` above 1.
- DCP with Unified Memory accepts only the `flashinfer`, `trtllm_mla` and `cutedsl_mla` backends; GLM-5.3-Flash on SM120 uses `dsa` with `flashinfer_sparse_mla`.
- The GLM-5.3-Flash cookbook says P/D was validated only with fake weights and that speculative decoding does not start under P/D.
- The Unified Memory roadmap (#49944) lists both cases as pending.
- Unified Memory refuses LMCache and FP4 KV.

The proposal also summed the memory of 4 GPUs as one pool (MLA KV is replicated under TP) and did not address NVFP4 quality.

## 6. Cell design (§16 as corrected by §17)

### 6.1 Layout

```
Global gateway: hash of session-id chooses the cell only. Cell failover = recompute,
                with admission control and rate limiting at the destination cell.
 |
 +-- Cell = 1 region, 1 Kubernetes cluster, 1 project (Nebius terms in the source)
      |
      +-- llm-d EPP per cell (1 active, warm standby): prefix affinity + token load,
      |   approximate mode, fixed lruCapacityPerServer, calibrated tau, flow control,
      |   single-flight for uncached shared prefixes
      |
      +-- Node(s): vLLM fork engines, TP4 on 4 RTX PRO 6000 each
      |     +-- 1 LMCache server per engine, L1 in host RAM (/dev/shm)
      |
      +-- L2: shared filesystem per cell, fs_native adapter, immutable chunks,
      |   identity key in the path; persistence and recovery, off the hot path
      |
      +-- P2P between nodes: off; treat the network as TCP
      +-- No KV across regions
```

Sources: §17.1, §17.2, §17.5, and the KV report's revised design table, which replaces §16.2 and §16.7.

- Two levels of key. Sub-agents share the parent's prefix under different session IDs; MemServe measured a 59% better P99 TTFT with a prompt tree than with intra-session affinity (Reported, §17.2). The session hash picks the cell; inside the cell the key is the prefix.
- No reference architecture publishes a global session gateway on top of a per-cell prefix router. Two stickiness levels could conflict when a cell saturates (Inferred, KV report).
- Minimum two VMs per cell (N+1), from a 99.5% per-VM SLA and 8 to 21 min startup on Nebius (§17.3). The equivalent for AWS is Unknown.

### 6.2 Capacity per replica (§17.3, Inferred)

Cycle time T = P / 4,100 + O / 44.5, with P new tokens prefilled at 4.1k tok/s under decode and O output tokens at 44.5 tok/s per stream (constants measured on R1). Decode ceiling N_dec = 32 × (T + think) / T; prefill ceiling N_pf = 4,100 × (T + think) / P. The lower one applies, and the joint limit is lower still.

| Scenario | P | O | Think | Per replica | Per 8-GPU VM (2 replicas) |
|---|---|---|---|---|---|
| Low | 8,500 | 4,000 | 5 s | about 25 | about 50 |
| Base | 4,000 | 1,500 | 17 s | about 40 | about 80 |
| High | 1,100 | 690 | 24 s | about 80 (ceiling) | about 160 |

- P, set by the KV retention policy, decides capacity more than decode does (§17.3).
- O for GLM-5.3-Flash in a real agent loop is the dominant Unknown. Weka trace replay does not measure it, because AIPerf uses the trace's `out` as `max_tokens` (§17.3). Test E9 runs a real agent.
- These constants are DCP4 R1 numbers. DCP1 decodes 6% to 24% faster and holds 3.4 times less KV (§29.6), so the table needs recomputing once the DCP choice is made.
- The §16.4 table (39 to 117 sessions per replica, 7,800 new tokens per turn, 2,000 output tokens) is superseded and must not be used (§17.2).

### 6.3 Failure and burst costs (§17.4, Inferred)

- 51 sub-agents fetching 2.28 GB each from L2 independently total 116 GB, 29 s at 3.97 GB/s, more than a 25 s cold prefill. Use single-flight.
- Cold case: 51 independent prefills of 256K cost about 22 min of one replica.
- Cell failover: 64 sessions of 256K cost about 27 min of prefill on one replica (13.5 min on two). The destination cell needs admission control.

### 6.4 Scaling

- Startup on Nebius: about 21 to 23 min cold (VM 2, image pull 7.5, weights about 2.2, JIT and graphs about 8.4 to 9 min). Target for a new VM is 8 to 12 min; 5 to 8 min only for a replica on an existing VM with image and JIT cache in place (§17.2, Inferred). Reactive autoscaling alone cannot cover this; plan headroom and scheduled scaling (§16.4).
- The 7.5 min pull is not explained by disk speed: it took the same time with Docker's `data-root` on a 1.9 GB/s disk, about 29 MB/s over 12.9 GB compressed (Observed, §17.2). The bottleneck is the registry, decompression or layer concurrency.
- Autoscaling per the KV report: KEDA on EPP signals (in-flight, backlog tokens over `peakPrefillThroughput`), credit for replicas that are starting, a scheduled floor before the peak, slow scale-down. WVA is deprecated (Reported, llm-d guide).
- Quotas were the first bottleneck on Nebius (§16.4); on AWS they are Unknown.

### 6.5 Gaps the design still has (§17.5)

Admission and flow control in the cell; single-flight; retention and pinning of active sessions beyond LRU (only Dynamo's experimental ThunderAgent prototypes it); router visibility into L1 and L2; cache warming; the cache identity key; `kv_load_failure_policy: recompute`; equal L1 init and max size; fixed `lruCapacityPerServer`.

## 7. Specialised KV projects researched (§14, §15)

Desk research only; nothing ran on a GPU (§14). Sources: `reports/Projetos de KV cache e benchmarks.md` and `research_notes/Projetos de KV cache e benchmarks/`.

| Project | Verdict | Reason |
|---|---|---|
| kvpress | Discard for serving | HuggingFace only, no vLLM, no KDA or MLA; leaderboard is RULER at 4K on 8B models; head-wise presses do not free HBM (Reported and Observed in its code) |
| kvcached | Discard | Shares a GPU between models, adds no capacity to one model; vLLM patch accepts `>=0.17,<0.31`, so 0.32.0 is out; no DSA, DCP or CUDA graphs tested |
| Eviction and KV quantisation below FP8 | Discard for now | Not validated in multi-turn with prefix reuse; NVFP4 latent (1.58x tokens on full GLM-5.3 on B300) rejects DCP and needs `qk_rope_head_dim` 64 |
| CPU offload: LMCache multi-process or vLLM native `OffloadingConnector` | Prioritise | Preserves exact prefixes; both depended on hybrid-under-DCP fixes still in open PRs on 2026-11-05 |
| llm-d prefix-affinity routing | Prioritise | With corrected `lruCapacityPerServer` and calibrated `peakPrefillThroughput` |
| Mooncake Store | Discard | Hybrid support is an RFC; a reuse bug cited GLM-5.3-Flash, though its stated cause was later refuted (§16.6, KV report correction 26) |
| SGLang HiCache | Discard | Requires switching engines |
| Dynamo KVBM | Discard | No longer supported per a maintainer |
| CacheBlend, CacheGen | Not applicable | Hybrid groups are opaque |

Recommended benchmark: AgentX/AIPerf on the Weka Claude Code traces, server restarted per point, 3 to 5 runs with confidence intervals, plus the quality gates already in use (§14). The numeric pass criteria proposed in that research have no source and need local baselines (§14).

## 8. Known inconsistencies in the sources

- LMCache version in the fork. §15 gives `0.5.5.dev0+glm53checkpoints.<commit>`; the KV report gives 0.5.5.dev0 with a 2026-09-10 commit; §25.1, extracted from the image, gives `0.5.3.dev453+lil...g8ef537d6481b` dated 2026-10-11. This document uses §25.1.
- LMCache events and llm-d. §17.5 says events were validated with Dynamo, not llm-d; the §25.1 update reports PR #5307's test with the llm-d EPP (6 of 6). §25.1 is later.
- §29.7 says "llm-d reads vLLM's KV events" as a reason to stay on vLLM, but our router config is the approximate mode, which uses no events, and precise mode is untested (§4, §7.4).
- Default τ inputs. §4 cites 20,480 tok/s × 14 s = 286,720; the KV projects report cites defaults of 15,928 tok/s and 18 s (about 287K). The products agree; the inputs differ.
- Recompute time for 256K. §2 uses about 44 s (Helix, TP2, Reported); §12.2 measured 25.2 s on TP4 + DCP4. Different configurations; this document uses ours.

## Open questions

1. What is the TTFT of a restored turn without a queue, LMCache against HBM only, with DCP1, 24 active agents and idle sessions (the corrected §29.8 test)?
2. DCP1 or DCP4? The choice sets the HBM pool (6.79M against 23.1M tokens) and so the number of active sessions per replica (§29.6, §29.7).
3. What makes up the 8.7 KB per token, and is the reuse hit limited by the KDA snapshot pool or by the token pool (§14, KV report)?
4. What is the final LMCache chunk under DCP4, and is the image running engine-driven or lmcache-driven mode?
5. Does an LMCache build with PR #5307 publish usable `BlockRemoved` events for GLM-5.3-Flash with recurrent checkpoints and DCP, and does the llm-d indexer consume KDA groups?
6. Does the router stay correct under memory pressure, with more than 2 replicas, and with saturating load, on the real model? What τ does `calibrate.sh` give on TP4?
7. Do the default LMCache TTLs, or a convoy, break a burst of 51 with the prefix outside HBM, with and without single-flight (E6)?
8. What output length O does GLM-5.3-Flash produce in a real agent loop (E9)?
9. What are the real L2 read bandwidth and fixed cost per hit with the page cache dropped, and does `fs_native` honour `shared` across nodes (E2, E3)?
10. Does the native `OffloadingConnector` work under DCP4 plus MTP as a plan B?
11. Does P/D with NIXL work on the real model, and does it ever beat aggregated serving at a tuned P:D ratio?
12. Which AWS instance types, quotas, shared filesystems, network bandwidth per flow and startup times apply? None of the Nebius findings were checked on AWS.
