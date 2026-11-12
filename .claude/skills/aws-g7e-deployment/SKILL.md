---
name: aws-g7e-deployment
description: Use when planning, writing infrastructure code for, launching, qualifying or tearing down GLM-5.3-Flash replicas on AWS G7e instances (`g7e.24xlarge`, `g7e.48xlarge`), when requesting G7e quota or reading its price, or when deciding EKS versus plain EC2, region, weight storage, EFA or purchase model. Also use before running any phase of `docs/06-aws-implementation-plan.md`.
---

# AWS G7e deployment

How to bring the measured replica (4x RTX PRO 6000 Server Edition, local-inference-lab vLLM fork, TP4 + MTP3) up on AWS G7e, in phases, without paying for anything that has not earned it. Nothing has run on AWS yet. Price and quota are stale (read 2026-11-04); GPU peer-to-peer and speed on G7e are Unknown.

Evidence labels: Observed (we measured or read it, source given), Reported (a named source says it, with URL and read date), Inferred (derived, reasoning shown), Hypothesis, Unknown. "§N" points to `ARQUITETURA.md`, the Portuguese working journal kept outside this repository; "docs/0N" to `docs/` in this repository. The harness is in `bench/`; raw results are cited as `f3/resultados/...`, a path inside the published results archive. Older result directories use Portuguese file names (`tempo-pronto.txt`, `servidor.log`, `agentes-N.json`, `motor.txt`); new runs write `ready-time.txt`, `server.log`, `agents-N.json`, `engine.txt` (`bench/README.md`). Prices carry the date they were read.

## When to use

- Writing Terraform or launch scripts for G7e.
- Requesting AWS quota, reading a G7e price, or choosing a region or purchase model.
- Launching a G7e instance, checking that it is healthy, or tearing it down.
- Running or checking any phase of `docs/06-aws-implementation-plan.md`.
- Deciding whether EFA, FSx for Lustre or a reservation is worth it.
- Putting the llm-d router in front of replicas before there is a Kubernetes cluster.

## Files in this skill

| File | Read it when |
|---|---|
| [references/g7e-instance.md](references/g7e-instance.md) | You need the size table, network and EBS limits, regions, the DLAMI and its driver (595.112.07 against the image's 615.65.02), or the list of Unknowns phase 1 measures |
| [references/networking-and-efa.md](references/networking-and-efa.md) | Someone proposes EFA, P/D or KV transfer between instances, or you set up the phase 3 network |
| [references/storage-for-weights.md](references/storage-for-weights.md) | Choosing where the 177.7 GB checkpoint, the image and the kernel cache live, or reading our load times |
| [references/quotas-and-purchase.md](references/quotas-and-purchase.md) | Requesting quota, reading a price, or comparing On-Demand, reservations, Savings Plans, Capacity Blocks and Spot |
| [references/terraform-layout.md](references/terraform-layout.md) | Writing the Terraform (proposal: modules, backend, launch template settings, tags, startup steps) |
| [references/runbook-phase-1.md](references/runbook-phase-1.md) | Running phase 1, step by step, from quota check to teardown, with time and cost |
| [references/security-and-cost-guardrails.md](references/security-and-cost-guardrails.md) | Handling credentials, tags, budgets, watchdogs and teardown checks |
| [examples/terraform-phase-1/](examples/terraform-phase-1/) | You want a starting point for `infra/aws/` (illustrative, not applied, not tested) |
| [examples/user-data-phase-1.sh.tftpl](examples/user-data-phase-1.sh.tftpl) | Writing the instance bootstrap (draft, not run) |
| [examples/phase-1-result-checklist.md](examples/phase-1-result-checklist.md) | Recording a phase 1 run next to the Vast 157204 reference values |
| [examples/cost-phase-1.md](examples/cost-phase-1.md) | Estimating or checking what a phase 1 run costs |

## What AWS offers

Reported, `https://docs.aws.amazon.com/ec2/latest/instancetypes/ac.html` and `https://aws.amazon.com/ec2/instance-types/g7e/`, read 2026-11-12; EFA interface counts also Observed in the API on 2026-11-04 (`NOTAS.md`). Full table in `references/g7e-instance.md`.

| Instance | GPUs | GPU memory | Host memory | vCPU | Network | EFA interfaces | Instance store | Replicas |
|---|---|---|---|---|---|---|---|---|
| `g7e.24xlarge` | 4x RTX PRO 6000 Server Edition | 384 GiB | 1,024 GiB | 96 | 800 Gbps | 2 | 2 x 3,800 GB NVMe | 1 |
| `g7e.48xlarge` | 8x RTX PRO 6000 Server Edition | 768 GiB | 2,048 GiB | 192 | 1,600 Gbps | 4 | 4 x 3,800 GB NVMe | 2 |

- CPUs are Intel Xeon Emerald Rapids. The GPU is the same Server Edition we measured on Vast host 157204 and Nebius.
- Sizes with 1 or 2 GPUs are not a replica: the decided profile is TP4 on 4 GPUs, and the QAD checkpoint is 177.7 GB against 96 GB per GPU (docs/06).
- Host RAM (Inferred, docs/06 and 10k report §4): 1,024 GiB per replica covers the §6 request of 300 GiB or more for the RAM KV tier and the revised design's 700 to 800 GB of LMCache L1 per engine. Our experiments used 200 GiB. Whether the RAM tier is worth it is still open (§29.8).
- No NVLink; GPUs talk over PCIe. Whether GPUDirect P2P works between the 4 GPUs of a `g7e.24xlarge` is Unknown and is the first thing phase 1 checks.
- EFA gives RDMA between instances, which Nebius RTX VMs lacked. It would reopen P2P KV transfer and P/D disaggregation, but neither is in the first design and none of it was tested (`references/networking-and-efa.md`). AWS's "up to 2.3x the inference performance of G6e" is a marketing claim that says nothing about our model (Reported).
- The DLAMI Base OSS Nvidia Driver GPU AMI lists G7e and ships driver 595.112.07, Docker and the NVIDIA container toolkit (Reported, DLAMI 20261027 release notes, read 2026-11-12). The fork image targets driver 615.65.02 (§23). Whether the image runs at full speed on 595 is Unknown.

Price and quota as last read (Observed on 2026-11-04 in the Price List API and Service Quotas, `NOTAS.md`; not rechecked). Details and purchase models in `references/quotas-and-purchase.md`.

| Item | Value |
|---|---|
| `g7e.24xlarge` On-Demand, `us-east-1`, Linux | US$ 16.57/h (US$ 4.14 per GPU-hour) |
| `g7e.48xlarge` On-Demand, `us-east-1`, Linux | US$ 33.14/h |
| Zones offering G7e in `us-east-1` | `us-east-1b`, `us-east-1c`, `us-east-1d` |
| G and VT On-Demand vCPU quota (`L-DB2E81BA`) | 0 in `us-east-1`, `us-east-2`, `us-west-2`, `eu-west-1`, `eu-central-1`, `sa-east-1`; the AWS default is also 0 (Reported) |
| Requests pending on 2026-11-04 | 96 On-Demand vCPUs (one `g7e.24xlarge`) and 48 Spot vCPUs |
| Whether G7e counts against the G and VT quota | Inferred yes: the quota covers G instances and AWS lists no separate G7e quota (Reported, On-Demand quotas table, read 2026-11-12) |
| Savings Plans rate for G7e | Unknown (Savings Plans offered for G7e, Reported) |
| Capacity Blocks | do not offer G7e (Reported, supported list read 2026-11-12) |

At that price one replica costs about 3 times Vast host 157204 (16.57 / 5.61) and 2.3 times Nebius list (16.57 / 7.20); with 24 sessions per replica (DCP1, one run) that is 24 / 16.57 = 1.45 sessions per US$/h against 4.28 on host 157204 (Inferred, docs/06). A month of one `g7e.24xlarge` On-Demand is 16.57 x 730 = about US$ 12,096 (Inferred). This is why the plan starts with one instance that must reproduce known numbers before anything is built around it.

## Decisions and why

Decided:

| Decision | Why | Evidence |
|---|---|---|
| One replica = one `g7e.24xlarge`; one `g7e.48xlarge` = two replicas | The replica is 4 GPUs with TP4; the 48xlarge layout matches the two-replicas-per-node design the LMCache work assumed | docs/06; §16, §17.2 |
| Engine: fork image `ghcr.io/local-inference-lab/vllm:karmic-kraken-20261016`, checkpoint `local-inference-lab/GLM-5.3-Flash-NVFP4-MXFP8-CSF-QAD` at revision `dec48abd33efa73c3bb7c95b74eee10cad34f9be` | SGLang served half the sessions (FP8) or failed quality (NVFP4) on the same host | Observed, §29.7 (accepted 2026-11-12) |
| IaC: Terraform with S3 state and locking | The Nebius environments are already Terraform; one tool covers both providers we may use | `docs/decisions/2026-11-12-infrastructure-as-code-tool.md` |
| Plain EC2 with a startup script for phases 1 to 3; EKS question deferred to phase 5 | One or two instances need no scheduler, and the llm-d EPP runs without Kubernetes | docs/06, same decision record; Reported (LMCache PR 5307, §25.1) |
| Phases run in order; a phase starts only after the previous one passed | Each phase's acceptance criteria are what make the next phase's money worth spending | docs/06 |
| Stop at phase 1 if C32 decode is below 1,400 tok/s | A host with the same GPUs and software was 5 times slower; buying more of a slow host multiplies the loss | Observed, §29.10 |
| P/D disaggregation is not in the first design, even with EFA | Untested on the real model; on the mini model it cut throughput by about 46% | docs/README, docs/04 §9.2, docs/06 |

Open, with the current recommendation:

| Decision | Options | Recommendation and reason | Label |
|---|---|---|---|
| Router before Kubernetes | standalone llm-d EPP + Envoy + file discovery | Use it for phase 3. The LMCache PR 5307 validation ran the unmodified llm-d EPP (`b16fa8db`), Envoy `v1.33.2`, vLLM HTTP servers and file-based replica discovery, with no Kubernetes, and routed 6 of 6 correctly. The exact EPP configuration for this mode is not in our sources (Unknown); read the PR before writing it | Reported, §25.1 |
| Region | any region with G7e capacity and quota | Open (Paulo). Quota was 0 in all six regions checked, and G7e zones were read only for `us-east-1`. Choose by where the users are once quota answers come back; there is no KV between regions in the design (§17.1) | Observed quota; region choice Unknown |
| Weight storage | instance store, EBS, S3 plus local copy, FSx for Lustre | Phase 1: weights on the instance store from the Hub, kernel cache on a small persistent gp3 volume, and measure both (`references/storage-for-weights.md`). FSx only if many replicas start at once (phase 5) | Reported limits; AWS timings Unknown |
| Purchase model | On-Demand, Capacity Reservations, Savings Plans, Spot | On-Demand for phases 1 to 4: short runs, destroyed after. No commitment until discounted prices are read, because at list price AWS is the most expensive provider we measured. No Spot for serving: two minutes of notice against a start of minutes, and the instance store is lost (`references/quotas-and-purchase.md`). Ask AWS for On-Demand Capacity Reservations, the G7e Savings Plan rate and future reservations (10k report §9) | Inferred from Observed prices |
| EFA | none, EFA with ENA, EFA-only | None in phases 1 to 3; one instance or HTTP between replicas needs no RDMA (`references/networking-and-efa.md`) | Inferred |

## How to

### Phase 1: one replica reproduces the measured numbers

Goal: show the AWS host behaves like Vast host 157204 and not like host 48294. The ordered runbook with commands, timings and teardown is `references/runbook-phase-1.md`; this is its outline.

1. Confirm with Paulo the region, the instance count (one), the hourly price read that day, the expected cost (about US$ 25 for a smooth 1.5 h run at US$ 16.57/h, Inferred, `examples/cost-phase-1.md`), and who tears it down. Do not launch before that (see Invariants).
2. Check the G and VT On-Demand quota in the chosen region covers 96 vCPUs. If not, the request is the blocker; record its date and lead time.
3. `terraform plan`, read it, then `terraform apply` one `g7e.24xlarge` from the pinned DLAMI with the bootstrap script (watchdog, host record, image pull, weights at the pinned revision). Every resource tagged.
4. Qualify the host (next section). If C32 decode is below 1,400 tok/s, stop and find the cause before buying anything else.
5. Run the harness in `bench/`. On the host: `ENGINE=vllm IMAGE=ghcr.io/local-inference-lab/vllm:karmic-kraken-20261016 SERVER_SCRIPT=server-vllm-dcp1.sh LAUNCH_MODE=docker AGENT_LEVELS="16:900 24:900" bash run_benchmark.sh`, with `HF_CACHE` and `RUNTIME_CACHE` pointing at the NVMe weights and the persistent `/cache`; inside the container use `SERVER_SCRIPT=server-vllm-dcp1-direct.sh LAUNCH_MODE=direct` (`ENGINE`, `IMAGE` and `SERVER_SCRIPT` are required; the script exits without them). `run_benchmark.sh` writes `ready-time.txt`; the bootstrap log has the image pull and download times.
6. Summarize with `python3 bench/summarize.py --price <price read that day> --needle-ref 3/500 <result dir>`.
7. Destroy, sweep by tag, and confirm zero instances and unexpected volumes remain.

Acceptance criteria (values from host 157204 in parentheses, Observed; filled table in `examples/phase-1-result-checklist.md`):

1. `nvidia-smi topo -p2p r` reports OK between all 4 GPUs, and the server log contains `Using B12X PCIe all-reduce`.
2. Decode at C32 is at least 1,400 tok/s (1,580 with DCP1, 1,279 with DCP4; the threshold applies to DCP1).
3. `summarize.py --needle-ref 3/500` marks the run `ok`: needle-checksum with 500 runs at C8 is not worse than 3/500 at p < 0.05 (0/500 and 3/120 on the two DCP1 runs).
4. gsm8k scores at least 94/96 (95/96 and 96/96 on the two DCP1 runs, Observed in `gsm8k.json`).
5. `ready-time.txt`, the weight-load line of the server log, the image pull time and the download time are in the result directory. No pass value; this is the baseline phase 5 must improve (157204: ready in 260 s).

### Phase 2: choose DCP1 or DCP4

On the phase 1 instance, run agent levels 16 and 24 twice with DCP1 and twice with DCP4 (`AGENT_LEVELS="16:900 24:900"`; the second run of each profile with `AGENTS_ONLY=1` and its own `OUT` directory, because `run_benchmark.sh` overwrites `OUT`). `summarize.py` shows the second run's gate as "not run here"; the verdict comes from the first.

1. Four result directories exist, each with `agents-16.json` and `agents-24.json`.
2. `summarize.py` prints the agent level inside the SLO for each (measured elsewhere: DCP1 24 in one run; DCP4 16 in run 1, failed 16 in run 2, and level 8 ran only once).
3. The chosen profile is the one whose lower run has more sessions inside the SLO. Write the choice and both numbers to `docs/03-serving-engine-and-benchmarks.md`.

Why two runs: DCP4 passed 16 agents once and failed the repeat (§29.6).

### Phase 3: two replicas behind the router

Two `g7e.24xlarge` (or one `g7e.48xlarge` with two replicas) in one zone, standalone llm-d EPP and Envoy in front, prefix-affinity routing as in the guide values. Network: `references/networking-and-efa.md`, "Plain networking in phases 1 to 3".

1. Repeat the §7.1 routing test on the real model: serial run of 21 prefix groups with 3 repetitions each; report the share of repetitions that return to the replica that served the first request, with affinity and with load-only routing (mini model: 100% against 52.4%).
2. With affinity, report the share of prompt tokens served from cache in the repetitions next to its theoretical ceiling (mini: 97.1% of a 97.1% ceiling).
3. A burst of 51 requests with the same prefix completes without errors; report the per-replica split (mini: 27 and 24).

Phase 3 needs 192 vCPUs of quota for either layout (Inferred from the vCPU counts).

### Phase 4: KV tier

The corrected LMCache test (`vast.sh` arms `vllm/lmcache-dcp1` and `vllm/lmcache-dcp1-control`): DCP1, KV pool cut to about 3.5M tokens, 48 agents thinking 60 to 100 s between turns, LMCache L1 in host RAM against HBM only.

1. Both arms produce `agents-48.json` (the bench does not save an interrupted level).
2. Per arm: prefix-cache hit rate, LMCache hit rate, TTFT p95 of cached turns, and restores that waited for GPU capacity (log lines `waiting for GPU capacity`).
3. The server log shows how many agents ran at once. Above about 24, the test repeated the overload of §29.8 and its TTFT result is not used.

Keep LMCache if its TTFT p95 is lower than HBM-only with no more turn errors. The fork's LMCache has `BlockStored` but no `BlockRemoved` (Observed in the image, §25.1), so the router will not see CPU-tier evictions until the fork picks up upstream PR 5307 and its fixes.

### Phase 5: production cell

To be specified after phases 1 to 4 pass (docs/06): EKS or not, autoscaling on queue and KV signals instead of GPU utilization, cold start target from the phase 1 baseline, gateway authentication and per-user limits, observability matching the SLO, and a fleet size recomputed with the `capacity-and-cost` skill.

### What to verify first on any new instance

Run these before any measurement; they are the host qualification rule (docs/05, CLAUDE.md rule 4). `bench/vast/prepare_host.sh`, `run_benchmark.sh` and the bootstrap draft already record most of them.

| Check | How | Pass | Why |
|---|---|---|---|
| Driver | `nvidia-smi` (record the version) | Recorded. The image expects 615.65.02 or newer (§25.1); the DLAMI ships 595.112.07 (Reported). What to do if they disagree: `references/g7e-instance.md`, "The driver gap" | 157204 ran 615.71.09 and was fast; Nebius ran 580.173 and worked (1,425 tok/s at C32); slow host 48294 ran 580.95.05. The driver alone did not explain the slow host (Inferred, §29.10) |
| Topology | `nvidia-smi topo -m`; PCIe gen and width via `nvidia-smi --query-gpu=...` as in `run_benchmark.sh` | Recorded; links at Gen5 x16 on the good host | 48294 matched 157204 here and was still slow, so topology is necessary evidence, not sufficient |
| GPU peer-to-peer | `nvidia-smi topo -p2p r` | OK between all 4 GPUs | B12X PCIe all-reduce needs P2P. Without the driver P2P override, the custom all-reduce lost to NCCL from 4 KiB; with it, it was 5.7 times faster at 32 KiB (Observed, §25.2). P2P on G7e is Unknown |
| All-reduce microbenchmark | `llm_decode_bench.py --p2pmark-only --p2pmark-max-gpus 4 --p2pmark-mode allreduce` (in `prepare_host.sh`) | Recorded | Small all-reduce took 9.1 to 9.5 µs on 157204 against 32.1 to 57.4 µs on Nebius R1, where the override was not in effect (§28.2) |
| All-reduce log line | server log contains `Using B12X PCIe all-reduce` | Present | The fork does not check driver state or compare against NCCL at startup, so the log line is the only confirmation the path was chosen (§23.4) |
| C32 decode | harness, about 5 min after the server is up | At least 1,400 tok/s aggregate, with the DCP1 profile | Good hosts gave 1,423 to 1,580 with DCP1 (DCP4 gave 1,279 to 1,288 on the same good host); 48294 gave 296 (§12.2, §29.6, §29.10) |
| Quality gate | `summarize.py --needle-ref 3/500`; gsm8k | `ok`; gsm8k at least 94/96 | Quality should not depend on the host with the same software (Inferred), but a run only counts after the gate |

If P2P is not OK, do not apply the Nebius driver fix blindly. On Nebius the driver already ships `RegistryDwords="PeerMappingOverride=1;"`; a second `options nvidia NVreg_RegistryDwords=` file can override it, so a new override must include the original value and live in a `zz-*.conf` file, and `nv-hostengine` and `nvidia-persistenced` must be stopped before reloading the driver (§25.3). Whether any of this applies on the AWS AMI is Unknown. 157204 had `RegistryDwords: ""` and P2P worked anyway (Observed, `host-vllm/host.txt`).

### Weight loading and cold start

Summary; the measured table, AWS limits and phase 1 measurements are in `references/storage-for-weights.md`.

1. Use `--load-format instanttensor` (the fork's server scripts do) and a weights location that reads at least as fast as the 1.4 GB/s that gave 134.5 s on Nebius. Both causes mattered: a slow disk and the default loader (§12.1). On 157204 the weights loaded at 8.19 GB/s in 24.68 s, most likely from page cache right after the download (Inferred).
2. Persist the kernel cache (`/cache`) on a volume that survives the instance. On 157204 a warm cache cut server start from 511 s to 201 s (§29.1).
3. Measure the image pull separately from the registry you will use; on Nebius the pull time did not depend on the disk (§17.2).
4. If you prepare images on a machine with Docker, set `{"features":{"containerd-snapshotter":false}}` in `daemon.json`, or the image lands in containerd outside `data-root` and is lost (§25.3).
5. If you download the checkpoint with `hf download --revision <sha>`, create `refs/main` by hand; offline vLLM will not find the model otherwise (§25.3).
6. Targets (Inferred, §17.2): 8 to 12 min for a new instance with seeded caches; 5 min only for a replica on an instance that already exists. Phase 1 sets the AWS baseline.

## Invariants

- Confirm with Paulo before any action that costs money: launching, starting or scaling instances, reservations, Savings Plans, `terraform apply`. State the hourly price with its date and the teardown plan. Why: G7e On-Demand is US$ 16.57 to 33.14 per hour, and a forgotten GPU VM on Nebius ran 6 h 8 min with no result (about US$ 88, §25.3). The project hook `guard-paid-actions.sh` asks before such commands; do not work around it.
- Every instance carries a watchdog (`shutdown -h +N` with `instance_initiated_shutdown_behavior = "terminate"`). Why: AWS Budgets updates "up to three times a day" (Reported), so the budget cannot stop today's runaway instance (`references/security-and-cost-guardrails.md`).
- Never hardcode credentials in code, Terraform, user data, logs or result files. Use short-lived credentials from the environment and an instance profile on the instance. Why: on Nebius we passed a 12-hour token through an environment variable and never wrote it to a file or state (`NOTAS.md`); a provider key that appeared in a conversation had to be revoked.
- Do not write AWS account IDs, support case IDs, quota request IDs or profile names into versioned files. Why: the repository is open source.
- Tag every resource with the project, the phase and the owner, and sweep by tag at teardown. Why: on Nebius a resource sweep failed silently and reported "0 resources" (zsh did not split `nebius $cmd` into words, §25.3); tags plus a sweep whose errors are visible make leftovers findable (Inferred).
- Destroy test instances when the run ends, then confirm zero instances, volumes and filesystems remain, and say so in the report. Why: the docs' process lesson is to verify teardown in every project (docs/05). A teardown command that exits 0 is not proof: `vastai destroy` printed "Aborted." with exit code 0 (§28.2).
- Tear down when the start log is empty instead of waiting. Why: that is how the 6 h 8 min incident happened; a wait loop with `pgrep -f name` inside an `ssh` command containing `name` matched itself (§25.3).
- Qualify every instance before its numbers count or before it is reserved. Why: §29.10.
- Pin the image tag, checkpoint revision and AMI ID; any change to image, checkpoint, flags, environment, kernels or driver reruns the quality gate and the agent levels. Why: a kernel change once produced 5.9% wrong answers that passed several releases (§10.4).
- Never edit raw results; write a new run. Why: the numbers above are only trustworthy because their files are immutable (CLAUDE.md rule 5).
- Every number from AWS is recorded with instance type, region, zone, AMI ID, driver and date. Why: price, quota and P2P on G7e are stale or Unknown today.

## Pitfalls we hit (on other providers, expected to bite here too)

- Same listing, 5 times slower host, cause Unknown (§29.10).
- The custom all-reduce silently runs slower without P2P; the server starts without any warning (§23.4, §25.2).
- Weight loading of 888 s was blamed on the disk; the default loader was also limiting (§12.1).
- Image pull of 7.5 min was blamed on the boot disk; moving Docker to a 1.9 GB/s disk did not change it (§17.2).
- A `set -e` start script aborted on a repeated `mount`; the B300 sat idle about 15 min (§12.6).
- `a && b || c` is not an if/else: `c` also runs when `b` fails, and our script reported failure on success (§25.3). Use `if`.
- Spot B300 on Nebius was preempted twice in 75 min, each costing about 23 min of replica downtime (§9.3).
- Budgets on Nebius only email and update every few hours; the spend estimate overshot the assumed balance (§12.6, §25.5). AWS Budgets lags the same way (Reported); check billing in the console the next day.

## Open questions

1. Current G7e price, discounted price (Savings Plans, reservations), capacity per zone, and the status and lead time of the quota request (last read 2026-11-04).
2. Whether the fork image runs at full speed on the DLAMI driver 595.112.07, or needs a 615 branch driver (`references/g7e-instance.md`).
3. Whether GPU peer-to-peer works inside `g7e.24xlarge`.
4. Whether G7e passes C32 decode of at least 1,400 tok/s.
5. Sequential read speed of the G7e instance store, whether the DLAMI stripes both devices, and which AWS storage suits an LMCache L2 (`references/storage-for-weights.md`).
6. Whether EFA changes the case for P2P KV sharing or P/D. Untested anywhere.
7. Region (Paulo).
8. The standalone EPP configuration for file discovery (read LMCache PR 5307 first).

## Sources

- `docs/06-aws-implementation-plan.md` (phases, criteria, decisions), `docs/decisions/2026-11-12-infrastructure-as-code-tool.md`, `docs/05-capacity-cost-and-providers.md` (AWS section, host qualification, lessons), `docs/04` §5 and §9.2 (P/D), `docs/README.md`, `docs/01-product-demand-and-slo.md`.
- AWS and HashiCorp pages, each listed with its URL in the reference files, read 2026-11-12.
- `NOTAS.md` (project research notes, not published): AWS G7e prices, zones, EFA interface counts and quotas read on 2026-11-04; Nebius token handling.
- `ARQUITETURA.md` §6, §9.3, §10.4, §12.1, §12.2, §12.6, §17.2, §23, §25.1 to §25.3, §28.2, §29.1, §29.6, §29.10.
- `reports/Arquitetura para 10 mil usuários.md` (project research notes, not published) §3 Table 5, §4, §9.
- Code: `bench/run_benchmark.sh`, `bench/summarize.py`, `bench/server-vllm-dcp1.sh`, `bench/setup_bench.sh`, `bench/vast/prepare_host.sh`, `bench/vast/vast.sh`.
- Results: `f3/resultados/vast-20261111/vllm/vast-vllm-dcp1/` and `f3/resultados/vast-20261111/vllm/host-vllm/` (157204, old Portuguese file names), `f3/resultados/vast-20261111/validacao-vllm/host-vllm/p2pmark-4gpu.txt`.
