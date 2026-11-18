# Tiers and sizing

The four places a session's KV can be (HBM, LMCache L1 in host RAM, LMCache L2 on shared storage, recompute), how big a session is, how to size each tier for one `g7e.24xlarge`, and when restoring beats recomputing. Read this before choosing `LMCACHE_L1_GB`, `/dev/shm`, a container memory limit or an instance size, and before claiming that a RAM tier raises concurrency.

All AWS numbers are Inferred: nothing has run on AWS. The calculation is reproduced step by step in `../examples/sizing-calculation.md`.

## The tiers

| Tier | Holds | Capacity on one replica | Cost to use | Status |
|---|---|---|---|---|
| HBM | KV of running requests and the local prefix cache | 6,789,052 tokens with DCP1, about 23.1 million with DCP4 (Observed, §29.6, Vast host 157204, `--gpu-memory-utilization 0.96`) | none | sets concurrency |
| L1, host RAM (`/dev/shm`) | idle sessions on the same engine | `LMCACHE_L1_GB`; our only run used 200 GB | a restore into HBM | one real-model run (§29.8), collapsed on overload |
| L2, shared storage | persistence, node replacement, warming a new replica | Unknown on AWS | a read plus a restore | never enabled in our runs (`LMCACHE_L2_ENABLED=0`) |
| Recompute | anything not cached | unlimited | prefill time | always available; the failover path |

The rule that follows from §29.8: a restored session must fit back into HBM before it runs. In the LMCache arm, 90 restore lines waited for GPU capacity and every one of the 62 restores that started had waited at least 31 s (Observed, `../examples/lmcache-log-lines.md`). L1 and L2 never add concurrent sessions; they only make an idle session cheaper to resume.

## How big a session is

| Quantity | Value | Label and source |
|---|---|---|
| KV per token | 8,721 bytes: 39.05 GiB for 4,807,959 tokens on 1 B300 | Observed, §9.3; rtx6kpro reports 8.3 KB (Reported, §10.1) |
| KDA recurrent state per sequence | about 0.15 GB, constant with context | Inferred from config geometry, §2 |
| Session of 100K tokens | 1.02 GB | Inferred: 100,000 x 8,721 B + 0.15 GB |
| Session of 262,144 tokens | 2.44 GB | Inferred, same formula; docs/README.md gives "about 2.3 GB" for 256K |
| Same at 20 KB per token | 2.15 GB and 5.39 GB | Hypothesis: the KV report's pessimistic case where every chunk carries a KDA snapshot |

What the 8.7 KB contains (versus 6.0 to 6.3 KB from the architecture) is an open question (§14). How many recurrent checkpoints LMCache keeps per session is Unknown. The fork's `request_boundaries` policy saves one at the end of each response (Observed log line, `../examples/lmcache-log-lines.md`), and a restore line asked for 20 to 32 blocks for 46K to 98K-token prompts. So budget at least one 0.15 GB state per stored turn.

Without DCP, MLA KV is replicated on every TP rank (Reported, llm-d GLM-5.2 blog, §2), and the HBM pool above already accounts for it. Whether LMCache stores one copy or one per rank under DCP1 is Unknown. Upstream #4679 has each DCP rank store its own shard. The open #6564 is about "TP-replicated groups" in committed residency (Reported, `https://github.com/LMCache/LMCache/pull/4679`, `/pull/6564`, read 2026-11-12). Check by comparing L1 usage after storing one known prompt with the prompt's size.

## HBM: active sessions

`g7e.24xlarge` has the same 4 RTX PRO 6000 Server Edition GPUs (384 GiB of GPU memory) as the Vast host (Reported, `docs/06-aws-implementation-plan.md` instance table). If the fork reserves the same memory there, the pool is the one measured on Vast (Inferred):

| Profile | Pool | Active sessions of 100K | of 256K |
|---|---|---|---|
| DCP1 | 6,789,052 tokens | 68 | 25.9 |
| DCP4 | about 23.1 million | 231 | 88.1 |

The SLO cap is lower than HBM in both profiles: 24 agents passed with DCP1 and 8 with DCP4, one run each (Observed, §29.6). So the HBM pool is not today's limit at agent sizes. It becomes the limit when idle sessions keep their KV in HBM, which is why the corrected LMCache test cuts the pool to 28 GiB per GPU (`../examples/experiment-configs.md`).

## L1: host RAM

### Constraints that must all hold

1. `/dev/shm` at least as large as the L1. The LMCache server checks it at start (`Checking if shm capacity is larger than L1 request`, Observed). A tmpfs without a size option defaults to "half of your physical RAM without swap" (Reported, `https://www.kernel.org/doc/html/latest/filesystems/tmpfs.html`, read 2026-11-12); a container usually gets its own smaller `/dev/shm`, so check with `df -h /dev/shm` inside the container. On the mini, a 16 GiB `/dev/shm` failed a 32 GiB offload at start with `32758 MiB required, 16384 MiB free` (Observed on the mini, §7.2).
2. The container or pod memory limit covers L1, because pages in `/dev/shm` count against the memory cgroup (Inferred; for Kubernetes a `medium: Memory` `emptyDir` is how `router/pd/pd.yaml` provides `/dev/shm`).
3. Node RAM covers L1 plus the OS, the vLLM processes (API server, engine core, 4 workers) and the LMCache server. Their resident size on this image is Unknown; measure with `ps -o rss` on a running server before fixing the reserve.
4. Pinned allocation. The worker log shows `SHM pinned=True` (Observed). LMCache MP mode defaults to `--l1-use-lazy` with `--l1-init-size-gb 20` (Reported, `https://docs.lmcache.ai/mp/configuration.html`, read 2026-11-12, no version shown). The Kimi K3 recipe warns against the lazy L1 (Reported, §17.5). Our server printed `Total free size: 204800.000000 MB` at start; whether those pages were already touched is Unknown.

### Sizing for one `g7e.24xlarge` (Inferred)

Host RAM is 1,024 GiB (Reported, AWS instance table in `docs/05-capacity-cost-and-providers.md`). The reserve for the OS and processes is a choice until it is measured; two cases:

| Reserve for OS and processes | L1 | Idle sessions of 100K | of 256K | of 256K at 20 KB per token |
|---|---|---|---|---|
| 124 GiB | 900 GiB (966 GB) | 945 | 397 | 179 |
| 224 GiB | 800 GiB (859 GB) | 840 | 353 | 159 |

§6 asks for 300 GiB or more of RAM tier per replica (as cited in `docs/05-capacity-cost-and-providers.md`); both cases clear it. The KV report sized 700 to 800 GB per engine when two engines shared a 1.7 TiB VM (Inferred there, doc 04 §2.5). One `g7e.24xlarge` is one engine and one LMCache server; `g7e.48xlarge` (2,048 GiB, 8 GPUs) is two engines and two servers, each with its own L1 (decision 4 of the skill).

How many idle sessions you need is a workload question: at the SLO cap of 24 active sessions with DCP1, 800 GiB holds about 35 times that many 100K sessions (Inferred). The p99 gap between main-agent turns in the llm-d trace is 11.4 min (Reported, `https://llm-d.ai/blog/serving-glm-5-2-agentic-workloads-on-llm-d`, read 2026-11-12), so most idle sessions are short-lived. Size L1 for the sessions you want to resume within the L1 TTL and accept recompute for the rest.

### Chunk size

Only whole chunks are stored, and the tail of each turn is recomputed (§17.2). In the §29.8 run the server printed `TokenHasher initialized: chunk_size=4096` under DCP4 with 1,024-token split pages (Observed). LMCache MP docs say `--chunk-size` (default 256) is a minimum that "the vLLM MP connector may raise" (Reported, `https://docs.lmcache.ai/mp/configuration.html`, read 2026-11-12). The project research notes (not published) record that the final chunk is the LCM of the group spans and the attention span under DCP is block x DCP. Upstream #5042 negotiated 1,152 for Flash without DCP, and the author needed 640 on an 8-GPU setup (Reported, `https://github.com/LMCache/LMCache/pull/5042`). The chunk under DCP1 on our image is Unknown; read the `TokenHasher initialized` line.

## L2: shared storage

Keep it off the hot path (decision 7 of the skill). Facts we have:

- Write rate needed in the KV report's Base scenario: about 54 MB/s per VM, below the 218 MiB/s we measured writing a 1 TiB Nebius filesystem (Inferred, doc 04 §2.5; Observed write, §17.2).
- Our read of 2 GiB/s on that filesystem was taken right after writing 40 GiB and was probably page cache (§17.2). Real read bandwidth is Unknown.
- The AWS service for L2 and its consistency model are Unknown (`docs/06-aws-implementation-plan.md` open question 5).

## Restore against recompute

Recompute cost (Observed rates on R1, §12.2; times Inferred):

| Prompt | Cold, 10.3k tok/s | Under decode, 4.1k tok/s |
|---|---|---|
| 100K | 9.7 s | 24.4 s |
| 262,144 | 25.5 s | 63.9 s |

Restore cost: a fixed cost per hit plus bytes over bandwidth. The GLM-5.3 LMCache paper (arXiv 2610.21500) reports about 0.33 s fixed cost per hit and synchronous-load p99 of 83 s (Reported, §17.4). The rtx6kpro wiki reports 1M tokens restored from RAM in 0.855 s against 99.3 s cold (Reported, §15). At our bytes per token that is about 10.2 GB/s effective, if their 1M tokens carry the same bytes (Inferred). With 0.33 s fixed and 5 to 10 GB/s, a 100K restore takes 0.43 to 0.53 s and a 256K restore 0.57 to 0.82 s (Inferred).

Break-even:

- Bandwidth: restoring is faster than prefilling when the link moves more than bytes per token times prefill rate: 8,721 B x 10,300 tok/s = 0.090 GB/s (0.72 Gbps) cold, 0.036 GB/s under decode (Inferred, §17.4). PCIe host-to-GPU and EFA are both far above this (Inferred), so bandwidth is not the risk.
- Length: with a 0.33 s fixed cost, a restore loses to recompute below 3,399 tokens cold or 1,353 under decode (Inferred, doc 04 §1.2).
- Queue: the real cost in §29.8 was waiting for HBM, 31 to 212 s per restore (Observed). A restore is only cheap when HBM has room, which the corrected test is designed to check.

Failover between cells recomputes everything: 64 sessions of 256K are 16.8 million tokens, about 27 min of cold prefill on one replica (Inferred, §17.4). Admission control has to spread that.

## What to measure on the first AWS host

1. `GPU KV cache size` for DCP1 and DCP4 at `--gpu-memory-utilization 0.96`, to confirm the HBM rows above.
2. Resident memory of the vLLM and LMCache processes (`ps -o pid,rss,cmd`), to replace the reserve guess.
3. `df -h /dev/shm` inside the container and the memory limit.
4. The `TokenHasher initialized: chunk_size=` line for DCP1.
5. L1 usage after one stored prompt of known length, to settle bytes per token in L1 and one copy against one per rank.
