---
name: kv-cache-tiers
description: Use when configuring, sizing, testing or debugging where GLM-5.3-Flash KV lives (HBM, the LMCache host RAM tier, a shared file tier, recompute), when starting the fork with CACHE_MODE=lmcache, when sizing /dev/shm and memory limits, or when the router needs KV events (BlockStored, BlockRemoved) from LMCache.
---

# KV cache tiers for GLM-5.3-Flash

This skill covers where KV lives for one replica (4x RTX PRO 6000 Server Edition, local-inference-lab vLLM fork, TP4 + MTP3), what each tier costs, how the fork's LMCache runs, how to size it, what our one real-model LMCache experiment taught us, and the corrected test that is still pending.

Conventions:

- Section references such as §29.8 point to `ARQUITETURA.md` (Portuguese journal). Later sections and notes marked "Correção posterior" replace earlier text; §17 replaces §13.2, §15 and §16 where they conflict.
- `ARQUITETURA.md` lives outside this repository. Harness paths (`bench/`, `router/`) are relative to the root of this repository; raw results are cited as `results archive: f3/resultados/...`, a path inside the published results archive.
- Evidence labels: Observed (we measured it), Reported (a named source says it), Inferred (derived, link stated), Hypothesis (to validate), Unknown.
- "Mini" means the `glm5next` mini test model: random weights, 2 full attention layers, about 1.95 KB of KV per token, 1 GPU per replica, upstream vLLM 0.32.0. Mini results transfer as mechanisms, never as numbers. Every row without the word "mini" is the real model.
- Nothing in this skill was measured on AWS.

## When to use

- You are enabling or sizing the LMCache RAM tier (`CACHE_MODE=lmcache`, `LMCACHE_L1_GB`), `/dev/shm`, or container and node memory.
- Turns after think time are slow, restores fail, or the log shows restores waiting for GPU capacity.
- You are designing or running the LMCache test (AWS plan phase 4).
- You are wiring the llm-d router to KV events, or setting `lruCapacityPerServer`.
- You are planning a shared file tier (L2), cache warming, or failover between replicas or cells.

## Decisions and why

### 1. Keep KV in the cheapest tier that serves it, and let HBM set concurrency

| Tier | Role | Status |
|---|---|---|
| HBM | Active sessions and the local prefix cache | Sizes concurrent capacity (§29.8) |
| Host RAM, LMCache L1 | Idle sessions and recovery on the same engine | One LMCache server per engine (§17.2) |
| Shared file tier, LMCache L2 | Persistence, recovery after node replacement, warming a new replica; off the hot path | Read bandwidth Unknown; never measured with the page cache dropped (§17.2) |
| Recompute | Last resort and the failover path between cells | Costs in decision 2 |

How much KV the model holds:

| Quantity | Value | Label and source |
|---|---|---|
| KV per token | about 8.7 KB (39.05 GiB for 4,807,959 tokens on 1 B300) | Observed, §9.3; 8.3 KB Reported by rtx6kpro, §10.1 |
| KDA state per sequence | about 0.15 GB, constant with context | Inferred from config geometry, §2 |
| One 256K session | about 2.3 GB of KV plus 0.15 GB of KDA state | Inferred, §2 correction note |
| HBM pool, TP4 + DCP4 | 23.1 to 23.2 million tokens (88.7 sessions of 262,144) | Observed, §12.2, §29.6 |
| HBM pool, TP4 + DCP1 | 6.79 million tokens | Observed, §29.6 |

Why HBM bounds concurrency: a restored session has to come back into HBM before it can run (Observed, §29.8, decision 6). The RAM tier helps only sessions that are really idle (Inferred, §29.8). Capacity per replica is HBM divided by the context of active sessions: with DCP1, 6.8 million tokens hold about 60 active sessions of 100K tokens, more than the 24 the SLO allowed in our run (Inferred, §29.8).

Without DCP, MLA KV is replicated on every TP rank (Reported, llm-d GLM-5.2 blog, §2). Never add the memory of 4 GPUs as one pool.

### 2. Restore beats recompute by one to two orders of magnitude; bandwidth is not the risk

| Path | Cost | Label and source |
|---|---|---|
| Cold prefill of 256K, TP4 + DCP4 | TTFT 25.2 s (10,381 tok/s) | Observed, R1, §12.2 |
| Prefill while decode is active | about 4.1k tok/s | Observed, R1, §12.2 |
| Recompute 256K under active decode | about 63.9 s | Inferred from the line above |
| Fork LMCache, 1M tokens | 99.3 s cold, 0.855 s restored from RAM, 0.970 s after restarting server and cache, same greedy output | Reported, rtx6kpro wiki, Max-Q and Workstation cards, §15 |
| Fork LMCache, edit at the end of a 520K prompt | 516,096 tokens restored in 1.66 s against 70.07 s | Reported, same source, §15 |
| Fork LMCache, 32,768-token prompt under RAM pressure | restored in 0.082 s | Reported, same source, §15 |
| Native vLLM offload, mini | 12.1 GB CPU to GPU in 0.27 s of summed transfer time (sums of small transfers, not sustained bandwidth) | Observed on the mini, §7.2 |

Break-even bandwidth is bytes per token times prefill rate: 8.7 KB x 10.3k tok/s is about 0.09 GB/s (0.7 Gbps); at 20 KB per token (if each chunk also stores a KDA snapshot) about 1.7 Gbps (Inferred, §17.4). What can still go wrong (§17.4): the fixed cost per hit (about 0.33 s in the GLM-5.3 LMCache paper, arXiv 2610.21500, Reported), synchronous loading (p99 of 83 s in the same paper, Reported), convoys and lock TTLs. Restored prompts shorter than about 3.4K tokens, or 1.4K under decode, lose to recompute with a 0.33 s fixed cost (Inferred, KV report, doc 04 §1.2).

Do not reuse the "about 700 times cheaper" figure in §2: it used a superseded session size and another prefill rate.

### 3. Use the fork's own LMCache, started by the image launcher, with the native offload connector as control

Why LMCache:

- It is already the fork's cache layer. The image starts it with `CACHE_MODE=lmcache`, `LMCACHE_L1_GB` and `LMCACHE_L2_ENABLED`; the default profile is GPU only (§15).
- The community qualified it on TP4 + DCP4, FP8 KV, MTP3, engine-driven LMCache (Reported, rtx6kpro, §15).
- The engine decision kept vLLM partly because this layer was qualified on it (Inferred, §29.7).

How it runs (Observed in `bench/server-vllm-lmcache-direct.sh` and §29.8):

- The image launcher (`python3 -m runtime.launcher --profile glm53-flash --hardware rtx-pro-6000-pcie`, run from `/opt/lil`) starts and supervises both vLLM and the LMCache service. It refuses `--print-command` in this mode because it starts a second process.
- LMCache runs as a separate multi-process (MP) server, one per vLLM instance, with ports derived from the API port (§17.2).
- The connector in our run was `LMCacheRecurrentCheckpointConnector`, which restores KDA recurrent state together with prefixes (Observed, §29.8).
- L1 lives in `/dev/shm`.

What is inside the image (Observed by extraction, §25.1): LMCache `0.5.3.dev453+lil...g8ef537d6481b`, dated 2026-10-11, with its own DCP implementation (`dcp_size`, per-rank fragments, `_get_dcp_rank` in `vllm_multi_process_adapter.py`). Its history diverges from upstream: of the upstream PRs checked only #4679 is an ancestor, and #4834, #4936, #5042, #5076 and #5307 are not. Earlier version strings in §15 and the KV report (`0.5.5.dev0`) are superseded.

The native vLLM `OffloadingConnector` is the control and plan B. On the mini it started on the hybrid KDA + MLA layout and recovered up to 97.1% of prompt tokens where HBM alone gave 0% (Observed on the mini, §7.2). Under DCP4 plus MTP it has no proof; vLLM #58618 merged on 2026-11-02 after v0.33.0rc3 and #58619 is open (§17.6).

### 4. One LMCache server and one L1 per engine

A shared L1 per node has no documented case with TP above 1, the fork starts one server per vLLM instance, and an L1 per rank is impossible under DCP because all DCP ranks of an engine must use the same server (§17.2). A shared L1 would only save 0.4 to 2 s per session that changes replica, at the cost of an undocumented topology and a single point of failure per node (Inferred, §17.4). The §16.2 design with one ~900 GB L1 shared by two replicas is superseded; a shared L1 per node is test E1.

On AWS: `g7e.24xlarge` (4 GPUs, 1,024 GiB RAM) is one engine; `g7e.48xlarge` (8 GPUs, 2,048 GiB) is two engines, so two LMCache servers (Inferred from this rule and the instance table in `docs/06-aws-implementation-plan.md`).

### 5. Size L1, `/dev/shm`, the container memory limit and node RAM together

- L1 lives in `/dev/shm`. On the mini, `--kv-offloading-size 32` with a 16 GiB `/dev/shm` failed at start with `32758 MiB required, 16384 MiB free` (Observed on the mini, §7.2). `/dev/shm`, the pod or container memory limit and node RAM must all cover the L1.
- The fork script checks for a private `/dev/shm` of at least 96 GiB per container (Reported, KV report, doc 04 §2.5).
- Set `--l1-init-size-gb` equal to `--l1-size-gb`. The fork script uses `--l1-use-lazy` with a 2 GB initial size, which the Kimi K3 recipe warns against (Observed in the fork script and Reported from the recipe, §17.5).
- Sizing reference: about 700 to 800 GB of L1 per engine when two engines share a 1.7 TiB VM; 800 GB holds about 350 sessions of 256K at 8.7 KB per token, or about 150 at 20 KB per token (Inferred, KV report, doc 04 §2.5). §6 asks for 300 GiB or more of host RAM tier per replica (as cited in `docs/05-capacity-cost-and-providers.md`). Our only real-model run used 200 GB. The right L1 size on a `g7e.24xlarge` is Unknown; derive it from the session count you want idle and leave room for the OS and vLLM processes.
- Chunk size. Only whole chunks are stored, and the tail is recomputed each turn. The final chunk is the LCM of the group block spans, and under DCP the attention span is block x DCP. The fork script defaults to 4096; upstream #5042 negotiated 1152 for Flash without DCP; the value under DCP4 is Unknown (§17.2, KV report correction 5). The 8,192 read from the R1 vLLM log in §16.4 is superseded.
- L2 writes in the KV report's Base scenario are about 54 MB/s per VM, below the 218 MiB/s we measured writing a 1 TiB Nebius filesystem, as long as dense snapshots are not written for every session (Inferred, doc 04 §2.5).

### 6. Set long TTLs and `recompute` on load failure

- LMCache defaults `--l1-read-ttl-seconds 300` and `--session-ttl-seconds 600` expire under a deep queue and fail the retrieve with `KEY_NOT_READABLE` on hybrid models. Use 7200, as the Kimi K3 recipe does (Reported, §15, §17.2).
- vLLM's `kv_load_failure_policy` defaults to `fail`; set `recompute` so a failed load costs latency instead of an error (Reported, §17.5).
- How to pass these settings through the image launcher is not documented in the sources (Unknown). Find it before the production cell, and confirm in the LMCache server log that they took effect.

### 7. Keep L2 off the hot path and key every entry by identity

- L2 is for persistence, node replacement and warming. Our shared-filesystem read of 2 GiB/s was probably page cache; real L2 read bandwidth is Unknown (§17.2). Our runs set `LMCACHE_L2_ENABLED=0`.
- Every L2 entry needs a cache identity key: weight revision, dtype, chunk size, connector version, TP and DCP layout (§17.5). Do not share entries between engines with different attention backends or block sizes (Reported, GLM-5.3 recipe, §16.5).
- Write chunks immutably and publish the name after close. The Nebius filesystem guarantees close-to-open content consistency and only eventual metadata consistency (§16.5). The AWS service for L2 and its consistency model are Unknown (`docs/06-aws-implementation-plan.md` open question 5).
- The fork uses the `fs_native` L2 adapter; whether it honours `"shared": true` across nodes is Unknown (KV report correction 10).
- No KV across regions. Reasons: no documented private network between regions, unmeasured latency and egress, and the L2 is lost together with the cell (§17.2). P2P between nodes stays off until per-flow bandwidth is measured; LMCache P2P does not require RDMA (`mooncake_te` uses TCP by default, §17.2). EFA on `g7e` would offer RDMA, untested (`docs/05-capacity-cost-and-providers.md`).

### 8. Do not make routing depend on LMCache KV events with this image

- The image's LMCache publishes `BlockStored` (one file) and has no `BlockRemoved` (Observed by extraction, §25.1). Inferred: the precise llm-d indexer would never see evictions from the CPU tier.
- Upstream PR #5307, merged 2026-10-12, publishes `BlockStored` and `BlockRemoved` with `medium="CPU"` through vLLM's KV event pipeline in MP mode, and its llm-d EPP test routed 6 of 6 correctly (Reported, PR text, §25.1 update of 2026-11-12). The image's LMCache is from 2026-10-11, so it lacks the PR (Inferred from dates).
- Limits of #5307: L1 only, no events while the engine is idle, no salted hashes, validated with Qwen2.5-7B, chunk size 16, no DCP and no recurrent state. Later fixes #6119 and #6122 are merged; #6564 (TP-replicated groups) and #5695 (multiple L1s) are open (Reported, §25.1). For GLM-5.3-Flash with recurrent checkpoints and DCP, working is a Hypothesis.
- §17.5 says LMCache events were validated with Dynamo and not llm-d. The §25.1 update is later and reports the llm-d test; §17.5 is outdated on that point.
- Our router runs `approx-prefix-cache-producer`, which uses no engine events at all (Observed in `router-mini.values.yaml`, §4). Precise KV-event routing is untested (§4, §7.4).
- So: keep the approximate mode, set `lruCapacityPerServer` by hand in the producer's block unit with `autoTune: false` (`autoTune` ignores the offload tier), and do not depend on LMCache events (§17.5, §25.1). The default of 31,250 blocks assumes about 272 million tokens per replica at 8,704-token blocks, and the approximate index does not see evictions, so under pressure it claims prefixes that are gone (§4, doc 04 §4.3).

## How to

### Start the fork with the RAM tier (and the control arm)

Inside the fork image (`ghcr.io/local-inference-lab/vllm:karmic-kraken-20261016`):

```bash
cd bench
# LMCache arm: HBM prefix cache plus L1 in /dev/shm
PIDFILE=srv.pid LOGFILE=srv.log CACHE_MODE=lmcache DCP=1 LMCACHE_L1_GB=200 \
  KV_CACHE_BYTES=30064771072 bash server-vllm-lmcache-direct.sh
# Control arm: same server and KV size, HBM only
PIDFILE=srv.pid LOGFILE=srv.log CACHE_MODE=vram DCP=1 \
  KV_CACHE_BYTES=30064771072 bash server-vllm-lmcache-direct.sh
```

What the script does (Observed in the script): it runs `python3 -m runtime.launcher --profile glm53-flash --hardware rtx-pro-6000-pcie` from `LAUNCHER_DIR` (default `/opt/lil`) with `--env DCP=... --env CACHE_MODE=... --env NCCL_NET_PLUGIN=none`, adds `--env LMCACHE_L1_GB=... --env LMCACHE_L2_ENABLED=0` in lmcache mode, and passes `--kv-cache-memory-bytes "$KV_CACHE_BYTES"` (default 5 GiB per GPU). It starts the launcher under `setsid`, so killing the PID in `PIDFILE` stops vLLM and LMCache together. `KV_CACHE_BYTES` is per GPU: 5 GiB is about 2.5 million tokens under DCP4, and under DCP1 the same bytes hold about a quarter of that because every GPU holds the whole KV (script comment). 28 GiB under DCP1 is about 3.5 million tokens (comment in `bench/vast/vast.sh`).

Before starting, check that `/dev/shm` is larger than `LMCACHE_L1_GB` (`df -h /dev/shm`), and that the container memory limit and node RAM cover it.

### Confirm in the logs what is running

```bash
grep -n -i 'chunk' <result_dir>/server.log | head             # chunk size the LMCache server negotiated
grep -c 'waiting for GPU capacity' <result_dir>/server.log   # restores blocked on HBM (AWS plan phase 4)
grep -c 'KEY_NOT_READABLE' <result_dir>/server.log           # TTL expiry on retrieve
```

The `waiting for GPU capacity` line is the one `docs/06-aws-implementation-plan.md` phase 4 counts. In §29.8 the same log showed 62 recurrent-state restores started, 1 failed and recomputed, 90 that waited for GPU space and 9 that gave up after 133 to 185 s (Observed).

Also confirm which mode the image runs (engine-driven or lmcache-driven). The fork lock describes the sidecar as CPU only in engine-driven mode, but the build script defaults to `lmcache_driven`, and upstream lmcache-driven mode used GPU memory (on H100, `--gpu-memory-utilization` 0.90 failed and 0.85 worked) (§15 correction note, KV report correction 9). Compare `nvidia-smi` memory with and without LMCache.

### Check KV events in a new image

§25.1 found `BlockStored` and no `BlockRemoved` by searching the LMCache package inside the image. Repeat it on every new image:

```bash
LMC=$(python3 -c 'import lmcache, os; print(os.path.dirname(lmcache.__file__))')
grep -rl 'BlockStored' "$LMC"; grep -rl 'BlockRemoved' "$LMC"
python3 -c 'import importlib.metadata as m; print(m.version("lmcache"))'
```

If the distribution name differs, find it with `pip list | grep -i lmcache`. Only when `BlockRemoved` exists, and a test with GLM-5.3-Flash, DCP and recurrent checkpoints passes, consider precise KV-event routing.

### Run the corrected LMCache test (AWS plan phase 4)

Design (§29.8, §29.9 item 2, `docs/06-aws-implementation-plan.md` phase 4): DCP1, KV pool cut so that active sessions fit and idle ones are evicted, many agents with long think time, LMCache against HBM only. It measures the TTFT of a restored turn without a queue.

The sources describe it two ways. §29.8 says "DCP1 with normal KV, 24 active agents and idle sessions with minutes of think time". The arms in `vast.sh` and AWS phase 4 cut the KV to 28 GiB per GPU (about 3.5 million tokens), think 60 to 100 s, and docs 03 and 06 say 48 agents. Both aim at the same condition: about 24 or fewer sessions active at once, the rest idle. Phase 4 acceptance criterion 3 checks it.

On Vast.ai (arms `vllm/lmcache-dcp1` and `vllm/lmcache-dcp1-control`; renting GPUs costs money, get approval first):

```bash
cd bench/vast
bash vast.sh create vllm <offer_id>
bash vast.sh wait vllm && bash vast.sh send vllm && bash vast.sh prepare vllm
AGENT_LEVELS="48:<seconds>" bash vast.sh run vllm lmcache-dcp1
# when it finishes, on the same instance:
AGENT_LEVELS="48:<seconds>" bash vast.sh run vllm lmcache-dcp1-control
bash vast.sh fetch vllm && bash vast.sh destroy vllm
```

On AWS, inside the fork container, the same arm is:

```bash
cd bench
AGENTS_ONLY=1 AGENT_LEVELS="48:<seconds>" AGENT_THINK=60-100 DCP=1 KV_CACHE_BYTES=30064771072 CACHE_MODE=lmcache \
  ENGINE=vllm LAUNCH_MODE=direct IMAGE=ghcr.io/local-inference-lab/vllm:karmic-kraken-20261016 \
  SERVER_SCRIPT=server-vllm-lmcache-direct.sh OUT=results/lmcache-dcp1 bash run_benchmark.sh
# control: same command with CACHE_MODE=vram and OUT=results/lmcache-dcp1-control
```

`AGENTS_ONLY=1` skips the quality gate and speed tests; run the gate once on the same server profile first. The level duration is not fixed by the sources. `run_benchmark.sh` sizes a level as the cold phase (about 25 s per agent, measured on Vast) plus about 7 min of steady state, which for 48 agents suggests about 20 min of cold phase alone (Inferred). Pick a duration, write it down, and use the same value in both arms.

Acceptance (phase 4):

1. Both arms write `agents-48.json`. Never interrupt a level: the bench only saves finished scenarios (§29.9 item 3).
2. Report per arm: prefix-cache hit rate, external (LMCache) hit rate, TTFT p95 of cached turns, and the count of `waiting for GPU capacity` lines.
3. Read from the server log how many requests ran at once. If more than about 24 ran together, the test repeated the §29.8 overload and its TTFT is not used.

Decision rule (phase 4): keep the LMCache tier if its arm has a lower TTFT p95 than the HBM-only arm with no more turn errors.

### What to monitor in production

- External prefix cache hit rate (KV served from LMCache) next to the local HBM prefix hit rate. On the mini these were reported separately as "local hit" and "from the external tier" (§7.2).
- Count of restores waiting for GPU capacity, restores that gave up and recomputed, and `KEY_NOT_READABLE` errors.
- HBM KV usage and running requests per replica, to see when active context, not idle context, is the limit.
- Re-prefilled tokens per turn (prompt minus cached), which `summarize.py` prints as p50 and p90.

The exact Prometheus metric names for these on the fork are not in the sources (Unknown). Find them on a running server before building dashboards.

## Invariants

- Never count L1 or L2 toward concurrent sessions. Reason: restored KV must fit in HBM again; in §29.8, 90 restores waited for GPU space (Observed).
- One LMCache server and one L1 per engine. Reason: all DCP ranks of an engine must use the same server, and a shared L1 with TP above 1 has no documented case (§17.2).
- `/dev/shm`, the container memory limit and node RAM are sized to the L1, and `--l1-init-size-gb` equals `--l1-size-gb`. Reason: the mini failed at start with a too small `/dev/shm` (§7.2); the lazy L1 is the setting the Kimi K3 recipe warns against (§17.5).
- TTLs at 7200 s and `kv_load_failure_policy: recompute`. Reason: the defaults fail retrieves under a deep queue and turn a failed load into an error (§15, §17.5).
- Never share cache entries across a different weight revision, dtype, chunk size, connector version, TP, DCP, attention backend or block size. Reason: those entries are not compatible (§16.5, §17.5).
- Validate cached against fresh output by score (needle-checksum, gsm8k), never by token diff. Reason: on KDA backends cached and fresh runs are not bit identical (Reported, §15).
- Expect requests with images to recompute. Reason: their recurrent state is not restored (Reported, §15).
- Treat L1 as lost on restart; only a persistent L2 survives (Inferred, KV report correction 17).
- In an LMCache test, keep active agents at or below the replica's SLO capacity (about 24 with DCP1 in our only run) and verify it in the log. Reason: in §29.8 queued turns became activity and both arms collapsed (Observed).
- Do not depend on LMCache KV events with the current image; keep `lruCapacityPerServer` fixed with `autoTune: false`. Reason: no `BlockRemoved` in the image (§25.1), and `autoTune` ignores the offload tier (§17.5).
- No KV across regions or cells; cell failover recomputes behind admission control. Reason: decision 7 and the failover cost of about 27 min of prefill per 64 sessions of 256K (Inferred, §17.4).
- Write the DCP setting next to every KV number. Reason: DCP changes the HBM pool 3.4 times (§29.6).

## Pitfalls we hit

- The §29.8 run (DCP4, KV cut to 5 GiB per GPU, 48 agents, 20 to 60 s think) assumed think time would keep about 23 agents active (Inferred). Turns queued for minutes, the queue became activity, all 48 sessions competed for HBM, and both arms collapsed: HBM-only finished 42 turns with 24 timeouts and 0% prefix hit; LMCache finished 118 turns with 21 timeouts, 65.6% prefix hit and TTFT p50/p95 of 391 s / 502 s on cached turns (Observed). It measures overload, not the TTFT of a restore.
- The control arm of §29.8 was interrupted and its `agentes-48.json` (the name used then) is incomplete; numbers came from the log (§29.8, §29.9).
- On the mini, a working set larger than the pool, visited cyclically, drove the LRU prefix hit to 0%: LRU evicts exactly what comes next. With a RAM tier the hit came back to 97.1% (Observed on the mini, §7.2).
- On the mini, a 1 GiB pool capped `--max-num-seqs` at 86 (`exceeds available Mamba cache blocks (86)`): KDA state blocks limit decode concurrency (Observed on the mini, §7.2).
- On the mini, 34,816-token prompts with a 1 GiB pool crashed with `illegal memory access` twice; 17,408-token prompts did not. Cause Unknown; reproduce at 35K and 256K on the real model before scaling long contexts (§7.3).
- Our shared-filesystem read of 2 GiB/s was taken right after writing 40 GiB and was probably page cache (§17.2). Measure L2 with the cache dropped.
- Superseded figures still visible in the journal: 1.62 GB per 256K session (§2), "700 times cheaper" (§2), one L1 of about 900 GB shared per node (§16.2), chunk 8,192 from the R1 log (§16.4), LMCache `0.5.5.dev0` (§15), vLLM #726 unresolved (§15). Use the current values above.
- The default `lruCapacityPerServer` (31,250 blocks) made the router believe evicted prefixes were still on the replicas in the mini pressure test (§7.4).

## Open questions

1. TTFT of a restored turn without a queue, LMCache against HBM only, DCP1 (the corrected test, AWS phase 4).
2. DCP1 or DCP4? It sets the HBM pool (6.79M against 23.1M tokens) and so how many sessions can be active (§29.6, §29.7).
3. Final LMCache chunk size under DCP4 and DCP1, and whether the image runs engine-driven or lmcache-driven mode.
4. How to pass TTLs, `--l1-init-size-gb` and `kv_load_failure_policy` through the image launcher.
5. What makes up the 8.7 KB per token against 6.0 to 6.3 KB from the architecture, and is the hit limited by the KDA snapshot pool or the token pool (§14)?
6. Does an LMCache build with PR #5307 and its follow-ups publish usable `BlockRemoved` events for GLM-5.3-Flash with recurrent checkpoints and DCP, and does the llm-d indexer consume KDA groups?
7. Do default TTLs or a convoy break a burst of 51 with the prefix outside HBM, with and without single-flight (test E6)?
8. Real L2 read bandwidth and fixed cost per hit with the page cache dropped, the AWS service for L2, and whether `fs_native` honours `shared` across nodes (E2, E3).
9. Does the native `OffloadingConnector` work under DCP4 plus MTP as plan B?
10. Does EFA on `g7e` make P2P KV transfer between replicas worth it? (Untested anywhere.)

## Sources

- `docs/04-kv-cache-routing-and-disaggregation.md` §1 to §3, §4.3, §6, §8
- `docs/02-model-hardware-and-checkpoints.md` §1.2, §1.3, §5, §6
- `docs/03-serving-engine-and-benchmarks.md` §3, §7, open questions
- `docs/05-capacity-cost-and-providers.md` (G7e RAM, EFA) and `docs/06-aws-implementation-plan.md` (phase 4)
- `ARQUITETURA.md` §2, §7.2 to §7.4, §9.3, §10.1, §12.2, §15, §16, §17, §25.1 (including the 2026-11-12 PR #5307 update under "Eventos de KV"), §29.6 to §29.9
- Harness: `bench/server-vllm-lmcache-direct.sh`, `bench/vast/vast.sh`, `bench/run_benchmark.sh`, `bench/summarize.py`
