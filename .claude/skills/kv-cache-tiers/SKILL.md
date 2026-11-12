---
name: kv-cache-tiers
description: Use when configuring, sizing, testing or debugging where GLM-5.3-Flash KV lives (HBM, the LMCache host RAM tier, a shared file tier, recompute), when starting the fork with CACHE_MODE=lmcache, when sizing /dev/shm and memory limits, or when the router needs KV events (BlockStored, BlockRemoved) from LMCache.
---

# KV cache tiers for GLM-5.3-Flash

This skill covers where KV lives for one replica (4x RTX PRO 6000 Server Edition, local-inference-lab vLLM fork, TP4 + MTP3), what each tier costs, how the fork's LMCache runs, how to size it, what our one real-model LMCache experiment taught us, and the corrected test that is still pending.

Conventions:

- Section references such as §29.8 point to `ARQUITETURA.md` (Portuguese journal). Later sections and notes marked "Correção posterior" replace earlier text; §17 replaces §13.2, §15 and §16 where they conflict.
- `ARQUITETURA.md` lives outside this repository. Harness paths (`bench/`, `router/`) are relative to the root of this repository; raw results are cited as `f3/resultados/...`, a path inside the results archive. Old result files keep Portuguese names (`servidor.log`, `agentes-48.json`); the harness writes English names today.
- Evidence labels: Observed (we measured it), Reported (a named source says it), Inferred (derived, link stated), Hypothesis (to validate), Unknown.
- "Mini" means the `glm5next` mini test model: random weights, 2 full attention layers, about 1.95 KB of KV per token, 1 GPU per replica, upstream vLLM 0.32.0. Mini results transfer as mechanisms, never as numbers. Every row without the word "mini" is the real model.
- Nothing in this skill was measured on AWS.

## When to use

- You are enabling or sizing the LMCache RAM tier (`CACHE_MODE=lmcache`, `LMCACHE_L1_GB`), `/dev/shm`, or container and node memory.
- Turns after think time are slow, restores fail, or the log shows restores waiting for GPU capacity.
- You are designing or running the LMCache test (AWS plan phase 4).
- You are wiring the llm-d router to KV events, or setting `lruCapacityPerServer`.
- You are planning a shared file tier (L2), cache warming, or failover between replicas or cells.

## Index

| File | Read it when |
|---|---|
| [references/tiers-and-sizing.md](references/tiers-and-sizing.md) | sizing HBM, L1, `/dev/shm` and node RAM for a `g7e.24xlarge`, or deciding restore against recompute |
| [references/lmcache-fork.md](references/lmcache-fork.md) | changing LMCache settings, reading an LMCache doc or log line, or comparing our image with upstream and the community script |
| [references/kv-events.md](references/kv-events.md) | considering precise prefix-cache routing, checking a new image for `BlockRemoved`, or setting `lruCapacityPerServer` |
| [references/lmcache-experiment.md](references/lmcache-experiment.md) | quoting a §29.8 number, or running the corrected LMCache test |
| [examples/lmcache-log-lines.md](examples/lmcache-log-lines.md) | checking a healthy LMCache start, or counting restore outcomes in a server log |
| [examples/experiment-configs.md](examples/experiment-configs.md) | reproducing either §29.8 arm or launching the corrected DCP1 arms |
| [examples/sizing-calculation.md](examples/sizing-calculation.md) | redoing the sizing arithmetic with your own reserve or session size |

## Decisions and why

### 1. Keep KV in the cheapest tier that serves it, and let HBM set concurrency

| Tier | Role | Status |
|---|---|---|
| HBM | Active sessions and the local prefix cache | Sizes concurrent capacity (§29.8) |
| Host RAM, LMCache L1 | Idle sessions and recovery on the same engine | One LMCache server per engine (§17.2) |
| Shared file tier, LMCache L2 | Persistence, node replacement, warming a new replica; off the hot path | Read bandwidth Unknown (§17.2) |
| Recompute | Last resort and the failover path between cells | Costs in decision 2 |

| Quantity | Value | Label and source |
|---|---|---|
| KV per token | 8,721 bytes (39.05 GiB for 4,807,959 tokens on 1 B300) | Observed, §9.3; 8.3 KB Reported by rtx6kpro, §10.1 |
| KDA state per sequence | about 0.15 GB, constant with context | Inferred from config geometry, §2 |
| One 256K session | about 2.4 GB including KDA state | Inferred, `references/tiers-and-sizing.md` |
| HBM pool, TP4 + DCP4 | 23.1 to 23.2 million tokens | Observed, §12.2, §29.6 |
| HBM pool, TP4 + DCP1 | 6,789,052 tokens | Observed, §29.6 |

A restored session has to come back into HBM before it can run. In §29.8, every one of the 62 restores that started had waited at least 31 s for GPU capacity (Observed, `examples/lmcache-log-lines.md`). The RAM tier helps only sessions that are really idle. With DCP1, HBM holds about 68 active sessions of 100K, more than the 24 the SLO allowed in our run (Inferred).

Without DCP, MLA KV is replicated on every TP rank (Reported, llm-d GLM-5.2 blog, §2). Never add the memory of 4 GPUs as one pool.

### 2. Restore beats recompute by one to two orders of magnitude; bandwidth is not the risk

| Path | Cost | Label and source |
|---|---|---|
| Cold prefill of 256K, TP4 + DCP4 | TTFT 25.2 s (10,381 tok/s) | Observed, R1, §12.2 |
| Recompute 256K under active decode (4.1k tok/s) | about 63.9 s | Inferred |
| Fork LMCache, 1M tokens | 99.3 s cold, 0.855 s restored from RAM, 0.970 s after restarting server and cache | Reported, rtx6kpro wiki, §15 |
| Fork LMCache, edit at the end of a 520K prompt | 516,096 tokens restored in 1.66 s against 70.07 s | Reported, same source, §15 |
| L1 prefetch in our run | 420 prefetches, median 4.5 ms, p90 9.0 ms, all from L1 | Observed, §29.8 log |
| Native vLLM offload, mini | 12.1 GB CPU to GPU in 0.27 s of summed transfer time | Observed on the mini, §7.2 |

Break-even bandwidth is 8,721 B x 10.3k tok/s = 0.09 GB/s (0.72 Gbps) (Inferred, §17.4). What can go wrong instead: the fixed cost per hit (about 0.33 s in the GLM-5.3 LMCache paper, arXiv 2610.21500, Reported), synchronous loading (p99 83 s in the same paper, Reported), convoys, lock TTLs, and above all waiting for HBM (31 to 212 s in §29.8, Observed). Restored prompts shorter than about 3.4K tokens, or 1.4K under decode, lose to recompute with a 0.33 s fixed cost (Inferred). Details: `references/tiers-and-sizing.md`.

Do not reuse the "about 700 times cheaper" figure in §2: it used a superseded session size and another prefill rate.

### 3. Use the fork's own LMCache, started by the image launcher, with the native offload connector as control

Why LMCache: it is already the fork's cache layer (the image starts it with `CACHE_MODE=lmcache`, `LMCACHE_L1_GB`, `LMCACHE_L2_ENABLED`; the default profile is GPU only, §15); the community qualified it on TP4 + DCP4, FP8 KV, MTP3, engine-driven LMCache (Reported, rtx6kpro, §15); and the engine decision kept vLLM partly because of it (Inferred, §29.7).

How it runs in our image (Observed in the §29.8 log, `references/lmcache-fork.md`):

- The launcher (`python3 -m runtime.launcher --profile glm53-flash --hardware rtx-pro-6000-pcie`, from `/opt/lil`) starts the LMCache MP server, then vLLM, and refuses `--print-command` in this mode.
- One MP server per vLLM instance, ports derived from the API port: ZMQ 18000 and HTTP 18001 for API port 8000.
- The server runs on CPU (`accelerator available: False`) in `engine_driven` mode. This settles the risk that the sidecar uses GPU memory for this image and mode; it held for upstream lmcache-driven mode (§15 correction note).
- Connector `LMCacheRecurrentCheckpointConnector`, which restores KDA recurrent state with prefixes, keyed by `checkpoint_identity` (weight revisions).
- L1 lives in `/dev/shm`, pinned.

What is inside the image (Observed by extraction, §25.1): LMCache `0.5.3.dev453+lil...g8ef537d6481b`, dated 2026-10-11, with its own DCP implementation. Of the upstream PRs checked only #4679 is an ancestor; #4834, #4936, #5042, #5076 and #5307 are not. The `0.5.5.dev0` string in §15 is superseded.

Upstream docs and the older community script (`serve-glm53-flash-lmcache.sh`, lmcache-driven, `LMCacheMPConnector`, lazy L1 with 2 GB init) do not describe this image; compare before applying their advice (`references/lmcache-fork.md`).

The native vLLM `OffloadingConnector` is the control and plan B. On the mini it recovered up to 97.1% of prompt tokens where HBM alone gave 0% (Observed on the mini, §7.2). Under DCP4 plus MTP it has no proof; vLLM #58618 merged on 2026-11-02 after v0.33.0rc3 and #58619 is open (§17.6).

### 4. One LMCache server and one L1 per engine

All DCP ranks of an engine must use the same server, a shared L1 per node has no documented case with TP above 1, and the fork starts one server per vLLM instance (§17.2). A shared L1 would only save 0.4 to 2 s per session that changes replica, at the cost of an undocumented topology and a single point of failure per node (Inferred, §17.4). The §16.2 design with one ~900 GB L1 shared by two replicas is superseded; a shared L1 per node is test E1.

On AWS: `g7e.24xlarge` (4 GPUs, 1,024 GiB RAM) is one engine; `g7e.48xlarge` (8 GPUs, 2,048 GiB) is two engines, so two LMCache servers (Inferred).

### 5. Size L1, `/dev/shm`, the container memory limit and node RAM together

- L1 lives in `/dev/shm`; the server checks `/dev/shm` against the L1 size at start (Observed). On the mini, a 16 GiB `/dev/shm` failed a 32 GiB offload with `32758 MiB required, 16384 MiB free` (Observed on the mini, §7.2). `/dev/shm`, the pod or container memory limit and node RAM must all cover the L1.
- On `g7e.24xlarge`, an L1 of 800 to 900 GiB leaves 124 to 224 GiB for the OS and processes and holds about 840 to 945 idle sessions of 100K or 350 to 400 of 256K (Inferred; the process reserve is a guess until measured; `references/tiers-and-sizing.md`). §6 asks for 300 GiB or more per replica. Our only real-model run used 200 GB.
- Prefer `--l1-init-size-gb` equal to `--l1-size-gb`; the Kimi K3 recipe warns that a large lazy L1 stalls mappings for minutes (Reported, §17.5). Upstream defaults to lazy with a 20 GB init (Reported, LMCache MP docs). Whether our image runs lazy is Unknown.
- Chunk size: only whole chunks are stored and the tail is recomputed each turn. Under DCP4 our image used `chunk_size=4096` (Observed, `TokenHasher initialized` line, §29.8 log). The value under DCP1 is Unknown; read the same line. Upstream #5042 negotiated 1,152 for Flash without DCP (Reported). The 8,192 read from the R1 vLLM log in §16.4 is superseded.
- L2 writes in the KV report's Base scenario are about 54 MB/s per VM, below the 218 MiB/s we measured writing a Nebius filesystem (Inferred, doc 04 §2.5).

### 6. Long TTLs, and keep `recompute` on load failure

- LMCache read-lock TTL (`--l1-read-ttl-seconds`, default 300) and session TTL (`--session-ttl-seconds`, 600 per the Kimi K3 recipe) expire under a deep queue and fail the retrieve with `KEY_NOT_READABLE`, reported to vLLM as `invalid_block_ids`, "fatal for a hybrid model". The recipe uses 7200 (Reported, §15, §17.2). In §29.8 waits reached 212 s and no `KEY_NOT_READABLE` appeared (Observed). How to pass TTLs through the image launcher is Unknown.
- `kv_load_failure_policy`: vLLM's default is `fail`. Our image launcher already sets `recompute` in `CACHE_MODE=lmcache` (Observed in `non-default args`, §29.8 log), and the one failed restore in that run recomputed its prompt. Keep checking the line on new images.

### 7. Keep L2 off the hot path and key every entry by identity

- L2 is for persistence, node replacement and warming. Our shared-filesystem read of 2 GiB/s was probably page cache; real L2 read bandwidth is Unknown (§17.2). Our runs set `LMCACHE_L2_ENABLED=0`.
- Every L2 entry needs a cache identity key: weight revision, dtype, chunk size, connector version, TP and DCP layout (§17.5). The connector already carries weight revisions in `checkpoint_identity` (Observed); the rest is Unknown. Do not share entries between engines with different attention backends or block sizes (Reported, GLM-5.3 recipe, §16.5).
- Write chunks immutably and publish the name after close. The Nebius filesystem guarantees close-to-open content consistency and only eventual metadata consistency (§16.5). The AWS service for L2 is Unknown (`docs/06-aws-implementation-plan.md` open question 5).
- The community script's L2 is `fs_native`; whether it honours `"shared": true` across nodes is Unknown (KV report correction 10).
- No KV across regions: no documented private network between regions, unmeasured latency and egress, and the L2 is lost with the cell (§17.2). P2P between nodes stays off until per-flow bandwidth is measured. LMCache MP P2P needs a coordinator (`--coordinator-url`) and does not require RDMA (Reported, LMCache CLI docs; `mooncake_te` uses TCP by default, §17.2). EFA on `g7e` would offer RDMA, untested.

### 8. Do not make routing depend on LMCache KV events with this image

- The image's LMCache has `BlockStored` and no `BlockRemoved` (Observed by extraction, §25.1), so a precise indexer would never see CPU evictions (Inferred).
- Upstream #5307 (merged 2026-10-12) streams `BlockStored` and `BlockRemoved` with `medium="CPU"`; #6119 and #6122 followed (merged). #6564, which fixes committed residency for TP-replicated groups and identity-tagged objects, is open. #5695 was closed without merge on 2026-11-09 in favour of #5778 (Reported, GitHub, read 2026-11-12). For GLM-5.3-Flash with recurrent checkpoints and DCP, working events are a Hypothesis.
- llm-d indexes "only full-attention cache groups" and calls hybrid-aware scoring "work in progress" (Reported, llm-d docs). For us that is the 11 MLA layers without the KDA state a hit needs (Inferred).
- Our router runs `approx-prefix-cache-producer`, which uses no engine events (Observed in `router-mini.values.yaml`, §4).
- So: keep the approximate mode, set `lruCapacityPerServer` by hand in the producer's block unit with `autoTune: false` (llm-d-router #1650: `autoTune` ignores the offload tier, §17.5), and do not depend on LMCache events. Details and the PR table: `references/kv-events.md`.

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

The script runs the launcher under `setsid`; killing the PID in `PIDFILE` should stop vLLM and LMCache together (script comment; check with `pgrep -af lmcache`). `KV_CACHE_BYTES` is per GPU: 5 GiB is about 2.5 million tokens under DCP4, and under DCP1 the same bytes hold about a quarter of that (script comment). 28 GiB under DCP1 is about 3.5 million tokens (comment in `bench/vast/vast.sh`). Before starting, check `df -h /dev/shm` against `LMCACHE_L1_GB`, and the container memory limit.

### Confirm in the logs what is running

```bash
sed 's/\x1b\[[0-9;]*m//g' <result_dir>/server.log > server.clean.log
grep -o 'TokenHasher initialized: chunk_size=[0-9]*' server.clean.log        # chunk size
grep -o 'Supported transfer mode: [a-z_]*' server.clean.log                  # engine_driven expected
grep -o "kv_load_failure_policy='[a-z]*'" server.clean.log                   # recompute expected
grep -o 'split GLM-5.3 cache pages: [^.]*' server.clean.log | sort -u        # page size, compare arms
grep -c 'waiting for GPU capacity' server.clean.log                          # restores blocked on HBM
grep -c 'starts after waiting' server.clean.log                              # restores that ran
grep -c 'recomputing its prompt' server.clean.log                            # failed restores
grep -c 'KEY_NOT_READABLE' server.clean.log                                  # TTL expiry
```

In §29.8 these gave 90 waiting lines, 62 starts, 1 recompute and 0 `KEY_NOT_READABLE` (Observed). The journal's "9 restores gave up after 133 to 185 s" has no matching log line (see Pitfalls). The full counting command and example lines are in `examples/lmcache-log-lines.md`.

### Check KV events in a new image

```bash
LMC=$(python3 -c 'import lmcache, os; print(os.path.dirname(lmcache.__file__))')
grep -rl 'BlockStored' "$LMC"; grep -rl 'BlockRemoved' "$LMC"
python3 -c 'import importlib.metadata as m; print(m.version("lmcache"))'
```

If the distribution name differs, find it with `pip list | grep -i lmcache`. More markers in `references/kv-events.md`.

### Run the corrected LMCache test (AWS plan phase 4)

Design (§29.8, §29.9 item 2, `docs/06-aws-implementation-plan.md` phase 4): DCP1, KV pool cut to 28 GiB per GPU so active sessions fit and idle ones are evicted, 48 agents with 60 to 100 s think, LMCache against HBM only. It measures the TTFT of a restored turn without a queue. Arms `vllm/lmcache-dcp1` and `vllm/lmcache-dcp1-control` in `bench/vast/vast.sh`; renting GPUs costs money, get approval first.

Two traps found on 2026-11-12: `run_benchmark.sh` does not pass `--sched-request-timeout`, so the bench's 600 s timeout applies and late first turns time out exactly as in §29.8; and `vast.sh` uses `AGENT_LEVELS` `8:600 16:900 32:1500` unless you pass `AGENT_LEVELS="48:<seconds>"`. Exact commands, a direct bench command with a longer timeout, and acceptance criteria: `references/lmcache-experiment.md`.

Decision rule (phase 4): keep the LMCache tier if its arm has a lower TTFT p95 than the HBM-only arm with no more turn errors, and the log shows no more than about 24 requests running at once.

### What to monitor in production

- `External prefix cache hit rate` (LMCache) next to `Prefix cache hit rate` (HBM) in the vLLM `Engine 000:` stats line; also `Deferred` requests, which appear only with the connector.
- Counts of restores waiting for GPU capacity, restores that recomputed, and `KEY_NOT_READABLE`.
- HBM KV usage and running requests per replica, to see when active context, not idle context, is the limit.
- Re-prefilled tokens per turn (prompt minus cached), which `summarize.py` prints as p50 and p90.

The LMCache server does not open a metrics port in our image (`/metrics must be exposed by the caller`, Observed). The Prometheus metric names for these on the fork are Unknown; list `/metrics` on a running server before building dashboards.

## Invariants

- Never count L1 or L2 toward concurrent sessions. Reason: restored KV must fit in HBM again; in §29.8 every restore waited 31 s or more for GPU space (Observed).
- One LMCache server and one L1 per engine. Reason: all DCP ranks of an engine must use the same server (§17.2).
- `/dev/shm`, the container memory limit and node RAM are sized to the L1. Reason: the mini failed at start with a too small `/dev/shm` (§7.2).
- `kv_load_failure_policy='recompute'` present in the server log. Reason: the vLLM default `fail` turns a failed load into an error (§17.5); our launcher sets `recompute` today (Observed).
- TTLs above the longest expected queue wait (7200 s in the Kimi K3 recipe). Reason: expired read locks fail retrieves on hybrid models (Reported, §15).
- Never share cache entries across a different weight revision, dtype, chunk size, connector version, TP, DCP, attention backend or block size (§16.5, §17.5).
- Validate cached against fresh output by score (needle-checksum, gsm8k), never by token diff. Reason: on KDA backends cached and fresh runs are not bit identical (Reported, §15).
- Expect requests with images to recompute. Reason: their recurrent state is not restored (Reported, §15).
- Treat L1 as lost on restart; only a persistent L2 survives (Inferred, KV report correction 17).
- In an LMCache test, keep active agents at or below the replica's SLO capacity and verify it in the log; record the split page size of both arms. Reason: §29.8 collapsed on overload, and its arms differed in page size (Observed).
- Do not depend on LMCache KV events with the current image; keep `lruCapacityPerServer` fixed with `autoTune: false` (§25.1, §17.5).
- No KV across regions or cells; cell failover recomputes behind admission control. Reason: about 27 min of cold prefill per 64 sessions of 256K on one replica (Inferred, §17.4).
- Write the DCP setting next to every KV number. Reason: DCP changes the HBM pool 3.4 times (§29.6).

## Pitfalls we hit

- The §29.8 run (DCP4, KV cut to 5 GiB per GPU, 48 agents, 20 to 60 s think) collapsed in both arms: HBM-only finished 42 turns with 24 timeouts and 0% prefix hit; LMCache finished 118 turns with 21 timeouts and 65.6% prefix hit (Observed). The journal blames queue time becoming activity. The files add (Inferred, 2026-11-12): the 48 first turns carried 3,468,499 cold tokens, 20 of them hit the 600 s client timeout and were resent cold, the last successful first turn ended at 669 s, and the control ran 1 or 2 requests at 9% to 14% KV while 44 waited. So HBM was not the first limit; the single prefill lane and the timeout were. Full analysis: `references/lmcache-experiment.md`.
- §29.8 says 9 restores gave up after 133 to 185 s. No log line says a restore gave up; the log has 1 failed restore (the request the API server had aborted at 600 s) and 4 checkpoints "no longer cached" (Observed). Do not quote "9 gave up".
- The two §29.8 arms ran different split page sizes (1,024 tokens with LMCache, 2,048 without) and slightly different KV pools (2,589,816 against 2,519,262 tokens) (Observed). The launcher picks the page size; why it changes with `CACHE_MODE` is Unknown.
- The control arm of §29.8 was interrupted and its `agentes-48.json` is empty of scenarios; its numbers come from the log (§29.9).
- On the mini, a working set larger than the pool, visited cyclically, drove the LRU prefix hit to 0%; with a RAM tier it came back to 97.1% (Observed on the mini, §7.2).
- On the mini, a 1 GiB pool capped `--max-num-seqs` at 86 (`exceeds available Mamba cache blocks (86)`): KDA state blocks limit decode concurrency (Observed on the mini, §7.2).
- On the mini, 34,816-token prompts with a 1 GiB pool crashed with `illegal memory access` twice; 17,408-token prompts did not. Cause Unknown (§7.3).
- Our shared-filesystem read of 2 GiB/s was probably page cache (§17.2). Measure L2 with the cache dropped.
- Advice written for the community script (lazy L1 with 2 GB init, `lmcache_driven`, "set `recompute`") was applied to our image in the journal. Our image differs on all three (Observed, `references/lmcache-fork.md`).
- Superseded figures still visible in the journal: 1.62 GB per 256K session (§2), "700 times cheaper" (§2), one shared L1 of about 900 GB per node (§16.2), chunk 8,192 from the R1 log (§16.4), LMCache `0.5.5.dev0` (§15), vLLM #726 unresolved (§15).
- The default `lruCapacityPerServer` (31,250 blocks) made the router believe evicted prefixes were still on the replicas in the mini pressure test (§7.4).

## Open questions

1. TTFT of a restored turn without a queue, LMCache against HBM only, DCP1 (the corrected test, AWS phase 4).
2. DCP1 or DCP4? It sets the HBM pool (6.79M against 23.1M tokens) (§29.6, §29.7).
3. LMCache chunk size under DCP1 on our image, and why the split page size changes with `CACHE_MODE`.
4. How to pass TTLs, `--l1-init-size-gb` and other server flags through the image launcher, and what the image uses today (read the server command line on a running container).
5. What "execution headroom" means in the restore scheduler (`checkpoint_scheduler.py`, around line 955).
6. What makes up the 8.7 KB per token against 6.0 to 6.3 KB from the architecture, and whether LMCache stores one copy or one per rank under DCP1 (§14).
7. Does an LMCache build with #5307, #6119, #6122 and #6564 publish usable `BlockRemoved` events for GLM-5.3-Flash with recurrent checkpoints and DCP, and can the llm-d indexer use them without the KDA group?
8. Do default TTLs or a convoy break a burst of 51 with the prefix outside HBM, with and without single-flight (test E6)?
9. Real L2 read bandwidth with the page cache dropped, the AWS service for L2, and whether `fs_native` honours `shared` across nodes (E2, E3).
10. Does the native `OffloadingConnector` work under DCP4 plus MTP as plan B?
11. Does EFA on `g7e` make P2P KV transfer between replicas worth it? (Untested anywhere.)

## Sources

- `docs/04-kv-cache-routing-and-disaggregation.md` §1 to §3, §4.3, §6, §8; `docs/02-model-hardware-and-checkpoints.md`; `docs/03-serving-engine-and-benchmarks.md` §3, §7; `docs/05-capacity-cost-and-providers.md`; `docs/06-aws-implementation-plan.md` (phase 4)
- `ARQUITETURA.md` §2, §7.2 to §7.4, §9.3, §10.1, §12.2, §15, §16, §17, §25.1, §29.6 to §29.9
- Results archive: `f3/resultados/vast-20261111/vllm/vast-vllm-lmcache/` and `.../vast-vllm-lmcache-controle/`
- Harness: `bench/server-vllm-lmcache-direct.sh`, `bench/vast/vast.sh`, `bench/run_benchmark.sh`, `bench/summarize.py`
- Upstream docs and PRs read 2026-11-12: listed with URLs in each reference file
