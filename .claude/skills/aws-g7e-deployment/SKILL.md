---
name: aws-g7e-deployment
description: Use when planning, writing infrastructure code for, launching, qualifying or tearing down GLM-5.3-Flash replicas on AWS G7e instances (`g7e.24xlarge`, `g7e.48xlarge`), when requesting G7e quota or reading its price, or when deciding IaC tool, EKS versus plain EC2, region, weight storage or purchase model. Also use before running any phase of `docs/06-aws-implementation-plan.md`.
---

# AWS G7e deployment

How to bring the measured replica (4x RTX PRO 6000 Server Edition, local-inference-lab vLLM fork, TP4 + MTP3) up on AWS G7e, in phases, without paying for anything that has not earned it. Nothing has run on AWS yet. Price, quota, driver behaviour and GPU peer-to-peer on G7e are either stale or Unknown.

Evidence labels: Observed (we measured or read it, source given), Reported (a named source says it), Inferred (derived, reasoning shown), Hypothesis, Unknown. "§N" points to `/home/paulo/Projetos/infer/ARQUITETURA.md`; "docs/0N" to `docs/` in this repository. The harness and raw results live in `/home/paulo/Projetos/infer/f3/` and are cited as `f3/...`. Prices carry the date they were read.

## When to use

- Writing Terraform, CDK or launch scripts for G7e, or choosing between them.
- Requesting AWS quota, reading a G7e price, or choosing a region or purchase model.
- Launching a G7e instance, checking that it is healthy, or tearing it down.
- Running or checking any phase of `docs/06-aws-implementation-plan.md`.
- Putting the llm-d router in front of replicas before there is a Kubernetes cluster.

## What AWS offers

Observed in the AWS documentation on 2026-11-12 (`https://docs.aws.amazon.com/ec2/latest/instancetypes/ac.html`, `https://aws.amazon.com/ec2/instance-types/g7e/`), EFA interface counts from `NOTAS.md` (2026-11-04):

| Instance | GPUs | GPU memory | Host memory | vCPU | Network | EFA interfaces | Replicas |
|---|---|---|---|---|---|---|---|
| `g7e.24xlarge` | 4x RTX PRO 6000 Server Edition | 384 GiB | 1,024 GiB | 96 | 800 Gbps | 2 | 1 |
| `g7e.48xlarge` | 8x RTX PRO 6000 Server Edition | 768 GiB | 2,048 GiB | 192 | 1,600 Gbps | 4 | 2 |

- CPUs are Intel Xeon Emerald Rapids. The GPU is the same Server Edition we measured on Vast host 157204 and Nebius.
- Sizes with 1 or 2 GPUs are not a replica: the decided profile is TP4 on 4 GPUs, and the QAD checkpoint is 177.7 GB against 96 GB per GPU (docs/06).
- Host RAM (Inferred, docs/06 and 10k report §4): 1,024 GiB per replica covers the §6 request of 300 GiB or more for the RAM KV tier and the revised design's 700 to 800 GB of LMCache L1 per engine. Our experiments used 200 GiB. Whether the RAM tier is worth it is still open (§29.8).
- EFA gives RDMA between instances, which Nebius RTX VMs lacked. It would reopen P2P KV transfer and P/D disaggregation, but neither is in the first design and none of it was tested (docs/06). AWS's "up to 2.3x the inference performance of G6e" is a marketing claim that says nothing about our model (Reported).

Price and quota as last read (Observed on 2026-11-04 in the Price List API and Service Quotas, `NOTAS.md`; not rechecked):

| Item | Value |
|---|---|
| `g7e.24xlarge` on-demand, `us-east-1`, Linux | US$ 16.57/h (US$ 4.14 per GPU-hour) |
| `g7e.48xlarge` on-demand, `us-east-1`, Linux | US$ 33.14/h |
| Zones offering G7e in `us-east-1` | `us-east-1b`, `us-east-1c`, `us-east-1d` |
| G and VT on-demand vCPU quota | 0 in `us-east-1`, `us-east-2`, `us-west-2`, `eu-west-1`, `eu-central-1`, `sa-east-1`; the AWS default is also 0 |
| Requests pending on 2026-11-04 | 96 on-demand vCPUs (one `g7e.24xlarge`) and 48 Spot vCPUs |
| Whether G7e counts against the G and VT quota | Inferred yes, by analogy with other G families; not confirmed |
| Savings Plans rate for G7e | Unknown (Savings Plan offered; 10k report Table 5) |
| Capacity Blocks | did not list G7e (10k report Table 5, about 2026-11-05) |

At that price one replica costs about 3 times Vast host 157204 (16.57 / 5.61) and 2.3 times Nebius list (16.57 / 7.20); with 24 sessions per replica (DCP1, one run) that is 24 / 16.57 = 1.45 sessions per US$/h against 4.28 on host 157204 (Inferred, docs/06). A month of one `g7e.24xlarge` on-demand is 16.57 x 730 = about US$ 12,096 (Inferred). This is why the plan starts with one instance that must reproduce known numbers before anything is built around it.

## Decisions and why

Decided:

| Decision | Why | Evidence |
|---|---|---|
| One replica = one `g7e.24xlarge`; one `g7e.48xlarge` = two replicas | The replica is 4 GPUs with TP4; the 48xlarge layout matches the two-replicas-per-node design the LMCache work assumed | docs/06; §16, §17.2 |
| Engine: fork image `ghcr.io/local-inference-lab/vllm:karmic-kraken-20261016`, checkpoint `local-inference-lab/GLM-5.3-Flash-NVFP4-MXFP8-CSF-QAD` at revision `dec48abd33efa73c3bb7c95b74eee10cad34f9be` | SGLang served half the sessions (FP8) or failed quality (NVFP4) on the same host | Observed, §29.7 (accepted 2026-11-12) |
| Phases run in order; a phase starts only after the previous one passed | Each phase's acceptance criteria are what make the next phase's money worth spending | docs/06 |
| Stop at phase 1 if C32 decode is below 1,400 tok/s | A host with the same GPUs and software was 5 times slower; buying more of a slow host multiplies the loss | Observed, §29.10 |
| P/D disaggregation is not in the first design, even with EFA | Untested on the real model | docs/README, docs/06 |

Open, with the current recommendation:

| Decision | Options | Recommendation and reason | Label |
|---|---|---|---|
| IaC tool | Terraform, AWS CDK | Decided on 2026-11-12: Terraform with S3 state and locking. Why: the Nebius environments are already Terraform, and one tool covers both providers we may use. Record: `docs/decisions/2026-11-12-infrastructure-as-code-tool.md` |
| Orchestration, phases 1 to 3 | plain EC2 with a startup script, EKS | Plain EC2. One to two instances need no scheduler, and the llm-d EPP runs without Kubernetes (next row). Move to EKS in phase 5, when autoscaling and rollouts are needed | docs/06; Reported (LMCache PR 5307) |
| Router before Kubernetes | standalone llm-d EPP + Envoy + file discovery | Use it for phase 3. The LMCache PR 5307 validation ran the unmodified llm-d EPP (`b16fa8db`), Envoy `v1.33.2`, vLLM HTTP servers and file-based replica discovery, with no Kubernetes, and routed 6 of 6 correctly. The exact EPP configuration for this mode is not in our sources (Unknown); read the PR before writing it | Reported, §25.1 |
| Region | any region with G7e capacity and quota | Open. Quota was 0 in all six regions checked, and G7e zones were read only for `us-east-1`. Choose by where the users are once quota answers come back; there is no KV between regions in the design (§17.1) | Observed quota; region choice Unknown |
| Weight storage | EBS, instance store, S3 plus local copy, FSx for Lustre | Open; measure in phase 1. Load time is dominated by the loader and the disk read speed (next section). Whether G7e has local instance store, and the EBS throughput needed to reach about 1.4 GB/s, are not in our sources (Unknown) | Observed timings; AWS options Unknown |
| Purchase model | on-demand, Savings Plans, Capacity Blocks, Spot | On-demand for phases 1 to 4: short runs, destroyed after. No commitment until discounted prices are read, because at list price AWS is the most expensive provider we measured. No Spot for serving: a preempted replica pays a cold start (about 23 min on Nebius, §9.3) and loses its KV. Ask AWS for On-Demand Capacity Reservations, the G7e Savings Plan rate and future reservations (10k report §9) | Inferred from Observed prices |

## How to

### Phase 1: one replica reproduces the measured numbers

Goal: show the AWS host behaves like Vast host 157204 and not like host 48294.

1. Confirm with Paulo the region, the instance count (one), the hourly price read that day, and who tears it down. Do not launch before that (see Invariants).
2. Check the G and VT on-demand quota in the chosen region covers 96 vCPUs. If not, the request is the blocker; record its date and lead time.
3. Launch one `g7e.24xlarge` with the fork image and the pinned checkpoint revision above. Tag it (see Invariants).
4. Qualify the host (next section). If C32 decode is below 1,400 tok/s, stop and find the cause before buying anything else.
5. Run the harness in `f3/sglang/`. On the host: `MOTOR=vllm IMAGE=ghcr.io/local-inference-lab/vllm:karmic-kraken-20261016 SERVIDOR=servidor-vllm-dcp1.sh EXECUCAO=docker bash comparativo.sh`; inside the container use `SERVIDOR=servidor-vllm-dcp1-direto.sh EXECUCAO=direto` (`MOTOR`, `IMAGE` and `SERVIDOR` are required; the script exits without them). Record start-to-first-request time and weight-load time; `comparativo.sh` writes `tempo-pronto.txt`.
6. Summarize with `python3 f3/sglang/resumir.py --preco 16.57 <result dir>` (use the price read that day).
7. Destroy the instance and confirm zero instances and volumes remain.

Acceptance criteria (values from host 157204 in parentheses, Observed):

1. `nvidia-smi topo -p2p r` reports OK between all 4 GPUs, and the server log contains `Using B12X PCIe all-reduce`.
2. Decode at C32 is at least 1,400 tok/s (1,580 with DCP1, 1,279 with DCP4; the threshold applies to DCP1).
3. `resumir.py --needle-ref 3/500` marks the run `ok`: needle-checksum with 500 runs at C8 is not worse than 3/500 at p < 0.05 (0/500 and 3/120 on the two DCP1 runs).
4. gsm8k scores at least 94/96 (95/96 and 96/96 on the two DCP1 runs, Observed in `gsm8k.json`).
5. Time from instance start to first served request and weight-load time are in the result directory. No pass value; this is the baseline phase 5 must improve.

### Phase 2: choose DCP1 or DCP4

On the phase 1 instance, run agent levels 16 and 24 twice with DCP1 and twice with DCP4 (`AGENTES="16:900 24:900"`; the second run of each profile with `SO_AGENTES=1` and its own `OUT` directory, because `comparativo.sh` overwrites `OUT`). `resumir.py` shows the second run's gate as "not run here"; the verdict comes from the first.

1. Four result directories exist, each with `agentes-16.json` and `agentes-24.json`.
2. `resumir.py` prints the agent level inside the SLO for each (measured elsewhere: DCP1 24 in one run; DCP4 16 in run 1, failed 16 in run 2, and level 8 ran only once).
3. The chosen profile is the one whose lower run has more sessions inside the SLO. Write the choice and both numbers to `docs/03-serving-engine-and-benchmarks.md`.

Why two runs: DCP4 passed 16 agents once and failed the repeat (§29.6).

### Phase 3: two replicas behind the router

Two `g7e.24xlarge` (or one `g7e.48xlarge` with two replicas), standalone llm-d EPP and Envoy in front, prefix-affinity routing as in the guide values.

1. Repeat the §7.1 routing test on the real model: serial run of 21 prefix groups with 3 repetitions each; report the share of repetitions that return to the replica that served the first request, with affinity and with load-only routing (mini model: 100% against 52.4%).
2. With affinity, report the share of prompt tokens served from cache in the repetitions next to its theoretical ceiling (mini: 97.1% of a 97.1% ceiling).
3. A burst of 51 requests with the same prefix completes without errors; report the per-replica split (mini: 27 and 24).

A `g7e.48xlarge` needs 192 vCPUs of quota (Inferred from its vCPU count).

### Phase 4: KV tier

The corrected LMCache test (`roteiro.sh` arms `vllm/lmcache-dcp1` and `vllm/lmcache-dcp1-controle`): DCP1, KV pool cut to about 3.5M tokens, 48 agents thinking 60 to 100 s between turns, LMCache L1 in host RAM against HBM only.

1. Both arms produce `agentes-48.json` (the bench does not save an interrupted level).
2. Per arm: prefix-cache hit rate, LMCache hit rate, TTFT p95 of cached turns, and restores that waited for GPU capacity (log lines `waiting for GPU capacity`).
3. The server log shows how many agents ran at once. Above about 24, the test repeated the overload of §29.8 and its TTFT result is not used.

Keep LMCache if its TTFT p95 is lower than HBM-only with no more turn errors. The fork's LMCache has `BlockStored` but no `BlockRemoved` (Observed in the image, §25.1), so the router will not see CPU-tier evictions until the fork picks up upstream PR 5307 and its fixes.

### Phase 5: production cell

To be specified after phases 1 to 4 pass (docs/06): EKS or not, autoscaling on queue and KV signals instead of GPU utilization, cold start target from the phase 1 baseline, gateway authentication and per-user limits, observability matching the SLO, and a fleet size recomputed with the `capacity-and-cost` skill.

### What to verify first on any new instance

Run these before any measurement; they are the host qualification rule (docs/05, CLAUDE.md rule 4). `f3/sglang/vast/preparar.sh` and `comparativo.sh` already record most of them.

| Check | How | Pass | Why |
|---|---|---|---|
| Driver | `nvidia-smi` (record the version) | Recorded. The image expects 615.65.02 or newer (§25.1). Which driver the G7e AMI ships is Unknown | 157204 ran 615.71.09 and was fast; Nebius ran 580.173 and worked (1,425 tok/s at C32); slow host 48294 ran 580.95.05. The driver alone did not explain the slow host (Inferred, §29.10) |
| Topology | `nvidia-smi topo -m`; PCIe gen and width via `nvidia-smi --query-gpu=...` as in `comparativo.sh` | Recorded; links at Gen5 x16 on the good host | 48294 matched 157204 here and was still slow, so topology is necessary evidence, not sufficient |
| GPU peer-to-peer | `nvidia-smi topo -p2p r` | OK between all 4 GPUs | B12X PCIe all-reduce needs P2P. Without the driver P2P override, the custom all-reduce lost to NCCL from 4 KiB; with it, it was 5.7 times faster at 32 KiB (Observed, §25.2). P2P on G7e is Unknown |
| All-reduce microbenchmark | `llm_decode_bench.py --p2pmark-only --p2pmark-max-gpus 4 --p2pmark-mode allreduce` (in `preparar.sh`) | Recorded | Small all-reduce took 9.1 to 9.5 µs on 157204 against 32.1 to 57.4 µs on Nebius R1, where the override was not in effect (§28.2) |
| All-reduce log line | server log contains `Using B12X PCIe all-reduce` | Present | The fork does not check driver state or compare against NCCL at startup, so the log line is the only confirmation the path was chosen (§23.4) |
| C32 decode | harness, about 5 min after the server is up | At least 1,400 tok/s aggregate, with the DCP1 profile | Good hosts gave 1,423 to 1,580 with DCP1 (DCP4 gave 1,279 to 1,288 on the same good host); 48294 gave 296 (§12.2, §29.6, §29.10) |
| Quality gate | `resumir.py --needle-ref 3/500`; gsm8k | `ok`; gsm8k at least 94/96 | Quality should not depend on the host with the same software (Inferred), but a run only counts after the gate |

If P2P is not OK, do not apply the Nebius driver fix blindly. On Nebius the driver already ships `RegistryDwords="PeerMappingOverride=1;"`; a second `options nvidia NVreg_RegistryDwords=` file can override it, so a new override must include the original value and live in a `zz-*.conf` file, and `nv-hostengine` and `nvidia-persistenced` must be stopped before reloading the driver (§25.3). Whether any of this applies on the AWS AMI is Unknown.

### Weight loading and cold start

What we measured (Observed):

| Step | Time | Source |
|---|---|---|
| Cold start of a new VM, end to end | 21 to 23 min (VM 2, pull 7.5, start 1.7, weights 2.2, post-load 1.1, JIT and graphs 8.4) | §17.2, 10k report §4 |
| Image pull, 12.9 GB compressed (30.6 GB uncompressed) | 7.5 min, the same on 104 MiB/s and 1.9 GB/s disks, about 29 MB/s: registry, decompression or layer concurrency is the bottleneck | §12.1, §17.2 |
| Weights, `--load-format instanttensor`, fork, 1,767 GiB network disk | 134.5 s at 1.4 GB/s | §12.1 |
| Weights, default vLLM loader, 1.9 GB/s disk | 829.7 s (about 270 MB/s) | §12.1 |
| Weights, default loader, small network disk | 888 s (about 205 MB/s) | §9.3 |
| B12X JIT compile on first start | about 9 min of a 15-min first start | §12.2 |
| Server start on Vast 157204, cold and warm kernel cache | 511 s and 201 s | §29.1 |

How to apply it on AWS:

1. Use `--load-format instanttensor` and a weights volume that reads at least as fast as the 1.4 GB/s it achieved. Both causes mattered: a slow disk and the default loader (§12.1).
2. Persist the kernel cache (`/cache`) on a volume that survives the instance, so later starts skip the 9-min JIT. The gain on a second start was never measured (§13.4).
3. Measure the image pull separately from the registry you will use; the pull time did not depend on the disk.
4. If you prepare images on a machine with Docker, set `{"features":{"containerd-snapshotter":false}}` in `daemon.json`, or the image lands in containerd outside `data-root` and is lost (§25.3).
5. If you download the checkpoint with `hf download --revision <sha>`, create `refs/main` by hand; offline vLLM will not find the model otherwise (§25.3).
6. Targets (Inferred, §17.2): 8 to 12 min for a new instance with seeded caches; 5 min only for a replica on an instance that already exists. Phase 1 sets the AWS baseline.

## Invariants

- Confirm with Paulo before any action that costs money: launching, starting or scaling instances, reservations, Savings Plans, `terraform apply`. State the hourly price with its date and the teardown plan. Why: G7e on-demand is US$ 16.57 to 33.14 per hour, and a forgotten GPU VM on Nebius ran 6 h 8 min with no result (about US$ 88, §25.3). The project hook `guard-paid-actions.sh` asks before such commands; do not work around it.
- Never hardcode credentials in code, Terraform, user data, logs or result files. Use short-lived credentials from the environment. Why: on Nebius we passed a 12-hour token through an environment variable and never wrote it to a file or state (`NOTAS.md`); a provider key that appeared in a conversation had to be revoked.
- Do not write AWS account IDs, support case IDs or profile names into versioned files. Why: the repository is open source.
- Tag every resource with the project, the phase and the owner, and sweep by tag at teardown. Why: on Nebius a resource sweep failed silently and reported "0 resources" (zsh did not split `nebius $cmd` into words, §25.3); tags plus a sweep whose errors are visible make leftovers findable (Inferred).
- Destroy test instances when the run ends, then confirm zero instances, volumes and filesystems remain, and say so in the report. Why: the docs' process lesson is to verify teardown in every project (docs/05). A teardown command that exits 0 is not proof: `vastai destroy` printed "Aborted." with exit code 0 (§28.2).
- Tear down when the start log is empty instead of waiting. Why: that is how the 6 h 8 min incident happened; a wait loop with `pgrep -f name` inside an `ssh` command containing `name` matched itself (§25.3).
- Qualify every instance before its numbers count or before it is reserved. Why: §29.10.
- Pin the image tag and checkpoint revision; any change to image, checkpoint, flags, environment, kernels or driver reruns the quality gate and the agent levels. Why: a kernel change once produced 5.9% wrong answers that passed several releases (§10.4).
- Never edit raw results; write a new run. Why: the numbers above are only trustworthy because their files are immutable (CLAUDE.md rule 5).
- Every number from AWS is recorded with instance type, region, zone, driver and date. Why: price, quota and driver on G7e are all Unknown or stale today.

## Pitfalls we hit (on other providers, expected to bite here too)

- Same listing, 5 times slower host, cause Unknown (§29.10).
- The custom all-reduce silently runs slower without P2P; the server starts without any warning (§23.4, §25.2).
- Weight loading of 888 s was blamed on the disk; the default loader was also limiting (§12.1).
- Image pull of 7.5 min was blamed on the boot disk; moving Docker to a 1.9 GB/s disk did not change it (§17.2).
- A `set -e` start script aborted on a repeated `mount`; the B300 sat idle about 15 min (§12.6).
- `a && b || c` runs `c` when `b` succeeds; a script reported failure on success (§25.3).
- Spot B300 on Nebius was preempted twice in 75 min, each costing about 23 min of replica downtime (§9.3).
- Budgets on Nebius only email and update every few hours; the spend estimate overshot the assumed balance (§12.6, §25.5). Check AWS billing in the console, not in a local estimate (Inferred from the same lesson).

## Open questions

1. Current G7e price, discounted price (Savings Plans, reservations), capacity per zone, and the status and lead time of the quota request (last read 2026-11-04).
2. Which driver the G7e AMI ships, and whether the fork image runs at full speed on it.
3. Whether GPU peer-to-peer works inside `g7e.24xlarge`.
4. Whether G7e passes C32 decode of at least 1,400 tok/s.
5. Whether G7e has local NVMe instance store, and which AWS storage gives the read bandwidth for weights and an LMCache L2 (Nebius shared filesystem measured 2 GiB/s per stream, probably page cache, §12.1).
6. Whether EFA changes the case for P2P KV sharing or P/D. Untested anywhere.
7. Region (Paulo). The IaC tool is decided: Terraform.
8. The standalone EPP configuration for file discovery (read LMCache PR 5307 first).

## Sources

- `docs/06-aws-implementation-plan.md` (phases, criteria, decisions), `docs/05-capacity-cost-and-providers.md` (AWS section, host qualification, lessons), `docs/README.md`, `docs/01-product-demand-and-slo.md`.
- `/home/paulo/Projetos/infer/NOTAS.md`: AWS G7e prices, zones, EFA interface counts and quotas read on 2026-11-04; Nebius token handling.
- `/home/paulo/Projetos/infer/ARQUITETURA.md` §6, §9.3, §12.1, §12.2, §17.2, §18.3, §23.4, §25.1 to §25.3, §28.2, §29.1, §29.6, §29.10.
- `/home/paulo/Projetos/infer/reports/Arquitetura para 10 mil usuários.md` §3 Table 5, §4, §9.
- Code: `/home/paulo/Projetos/infer/f3/sglang/comparativo.sh`, `resumir.py`, `vast/preparar.sh`, `vast/roteiro.sh`; log line evidence in `f3/resultados/vast-20261111/vllm/vast-vllm-r1/servidor.log`.
