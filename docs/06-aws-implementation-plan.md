# AWS implementation plan

## Summary

The measured replica (4x RTX PRO 6000 Blackwell Server Edition, vLLM fork, TP4 + MTP3) maps to one `g7e.24xlarge`. Nothing has run on AWS yet. Regional capacity, GPU peer-to-peer inside the instance, and whether the fork image runs at full speed on the AWS driver are Unknown.

Price and quota as last read (Observed on 2026-11-04 in the AWS Price List API and Service Quotas, not re-checked; `NOTAS.md`):

- On-demand list price in `us-east-1`: `g7e.24xlarge` US$ 16.57/h, `g7e.48xlarge` US$ 33.14/h, or US$ 4.14 per GPU-hour. G7e was offered in `us-east-1b`, `1c` and `1d`.
- Quota for G and VT on-demand vCPUs was 0 in every region checked; a request for 96 vCPUs (one `g7e.24xlarge`, Inferred: if G7e counts against that quota) was pending.

At list price a replica costs 3 times the Vast host 157204 (US$ 5.61/h) and 2.3 times the Nebius list price (US$ 1.80 per GPU-hour). With the measured 24 sessions per replica (DCP1, one run), that is about 1.45 sessions per US$/h on AWS on-demand, against 4.28 on host 157204 (Inferred, same sessions, different price). Discounted price (Observed on 2026-11-12 in the AWS Price List files, `us-east-1`, no upfront): EC2 Instance Savings Plan US$ 10.44/h for 1 year and US$ 7.16/h for 3 years, which gives about 3.35 sessions per US$/h at 24 sessions with the 3-year plan (Inferred). The plan therefore starts with one instance that must reproduce the numbers measured elsewhere before anything is built around it.

Each phase below ends in acceptance criteria that someone can check and fail. A phase starts only when the previous one passed.

## What AWS offers for this workload

Observed in the AWS documentation on 2026-11-12 (`https://docs.aws.amazon.com/ec2/latest/instancetypes/ac.html`, `https://aws.amazon.com/ec2/instance-types/g7e/`):

| Instance | GPUs | GPU memory | Memory | vCPU | Network | EFA |
|---|---|---|---|---|---|---|
| `g7e.24xlarge` | 4x RTX PRO 6000 Server Edition | 384 GiB | 1,024 GiB | 96 | 800 Gbps | yes |
| `g7e.48xlarge` | 8x RTX PRO 6000 Server Edition | 768 GiB | 2,048 GiB | 192 | 1,600 Gbps | yes |

CPUs are Intel Xeon Emerald Rapids. Smaller sizes have 1 or 2 GPUs and cannot hold the model (the QAD checkpoint is 177.7 GB; see `02-model-hardware-and-checkpoints.md`).

Inferred consequences:

- `g7e.24xlarge` is one replica. `g7e.48xlarge` is two replicas sharing host RAM, which is the layout the LMCache design assumed (one L1 per node, section 16 of ARQUITETURA.md).
- 1,024 GiB of host RAM per replica leaves room for the LMCache L1 tier (the experiments used 200 GiB).
- EFA gives RDMA between instances. On Nebius, RTX VMs had no RDMA, which is why P2P KV transfer and P/D were ruled out. On AWS they become possible again, but none of it was tested.

## Decisions to take before writing infrastructure code

| Decision | Options | Recommendation |
|---|---|---|
| IaC tool | Terraform, AWS CDK | Decided on 2026-11-12: Terraform, state in S3 with locking (`decisions/2026-11-12-infrastructure-as-code-tool.md`) |
| Orchestration for the first phases | Plain EC2 with a startup script; EKS | Plain EC2 for phases 1 to 3. The llm-d EPP runs outside Kubernetes (standalone EPP + Envoy + file discovery, Reported: llm-d `v1.0.0` guide `guides/no-kubernetes-deployment`; LMCache PR 5307 used this setup in its validation). Move to EKS when autoscaling and rollouts are needed (phase 5) |
| Region | Any region with G7e capacity | Open: depends on capacity and quota answers, and on where the users are |
| Weight storage | EBS gp3/io2, instance store, S3 + local copy, FSx for Lustre | Open. Startup is dominated by weight loading (888 s from a slow network disk vs 134 s with a fast disk and `--load-format instanttensor`, §12.1). Measure in phase 1 |
| Purchase model | On-demand, Savings Plans, Capacity Blocks, Spot | Open until discounted prices are read: on-demand list price makes AWS the most expensive provider measured. Spot preemption cost a replica about 23 min of cold start on Nebius (§9.3) |

## Phase 1: one replica reproduces the measured numbers

Goal: show that the AWS host behaves like the good Vast host (157204) and not like the bad one (48294).

Work:

- Request G7e quota in the chosen region; launch one `g7e.24xlarge` with the fork image `ghcr.io/local-inference-lab/vllm:karmic-kraken-20261016` and the QAD weights. Download them from `nvidia/GLM-5.3-Flash-FP4-Local` at revision `f83de1b0169cc3376a25563da66e3fc077e53591` once legal review accepts the NVIDIA Open Model Agreement (read 2026-11-17; terms summarized in `02-model-hardware-and-checkpoints.md` §3.4); until then use `local-inference-lab/GLM-5.3-Flash-NVFP4-MXFP8-CSF-QAD` at revision `dec48abd33efa73c3bb7c95b74eee10cad34f9be`. Both hold the same 36 shards (Observed, sha256 on the Hugging Face API, 2026-11-17; see `02-model-hardware-and-checkpoints.md` §3.4 for the licence difference).
- Run the harness in `bench/` (`run_benchmark.sh` with `LAUNCH_MODE=direct` inside the container, or `LAUNCH_MODE=docker` on the host).

Acceptance criteria (values from host 157204 in parentheses, Observed):

1. `nvidia-smi topo -p2p r` reports OK between all 4 GPUs, and the server log contains `Using B12X PCIe all-reduce`.
2. Decode at C32 is at least 1,400 tok/s (1,580 with DCP1, 1,279 with DCP4; the threshold applies to DCP1).
3. `summarize.py --needle-ref 3/500` marks the run `ok`: needle-checksum with 500 runs at C8 is not worse than 3/500 at p < 0.05 (0/500 and 3/120 on the two DCP1 runs).
4. gsm8k scores at least 94/96 (95/96 and 96/96 on the two DCP1 runs, raw `gsm8k.json`).
5. The time from instance start to the first served request and the time to load weights are recorded in the result directory (`ready-time.txt`, server log). No pass value: this is the baseline that phase 5 must improve.
6. The sha256 of each downloaded `.safetensors` shard equals the LFS sha256 that the Hugging Face API lists for `dec48abd33` at the same path. A mismatch means the gate result above does not apply to these files.

If criterion 2 fails, stop: the cause has to be found before buying more instances (§29.10 shows a host 5 times slower with the same software).

## Phase 2: choose DCP1 or DCP4, and confirm checkpoint quality

Work: on the phase 1 instance, run the agent levels 16 and 24 twice with DCP1 and twice with DCP4 (`AGENT_LEVELS="16:900 24:900"`; the second run of each profile with `AGENTS_ONLY=1` and its own output directory, `OUT` for `run_benchmark.sh` or `RUN_SUFFIX=2` for `vast.sh`, because a run overwrites its directory). `summarize.py` shows the second run's gate as not run there; the verdict comes from the first run.

Acceptance criteria:

1. Four result directories exist, each with `agents-16.json` and `agents-24.json`.
2. `summarize.py` prints, for each, the agent level inside the SLO (measured elsewhere: DCP1 24 in one run; DCP4 16 then fail at 16).
3. The chosen profile is the one whose lower of the two runs has more sessions inside the SLO. The choice and both numbers are written to `03-serving-engine-and-benchmarks.md`.

### Checkpoint quality against the FP8 original

Why: our weights pass the needle gate, but nobody has compared them with the original model on coding-agent tasks, long context or Portuguese. QAD also adapts routers, shared experts and dense MLPs on 500M synthetic tokens (Reported, `nvidia/GLM-5.3-Flash-FP4-Local` card), so the result is a slightly different model, and the needle gate has little power: 6 errors in 500 still pass (p = 0.25, Inferred). The NVIDIA card's two benchmarks cannot settle it: GPQA Diamond has 198 questions and the same table is printed for two different weight sets (`02-model-hardware-and-checkpoints.md` §3.1).

Work, on the phase 1 instance type, with the profile chosen above:

- Reference: `zai-org/GLM-5.3-Flash` (FP8, 328.3 GB, revision `46a050bec13002ad29ee795c16e61cf4fa3c4a9c`) on 4 GPUs, served by the fork if it loads FP8, otherwise by SGLang, which matched the fork on the needle (§29.5).
- Candidates: the current weights (`f83de1b016` = `dec48abd33`) and the QAD2 weights (`nvidia/GLM-5.3-Flash-FP4-Local@76348ddb2be2e35e39ecfc00e75dc07703f4f3d5` = LIL `qad2-kda-w8a16-csf@96f27f8c4e443be5bc486f8a978e3b9e0d3f7125`). QAD2 first passes the needle gate; if it fails, it leaves the comparison.
- Fix before the first run, and commit to the repository: the prompt set, the task list, the seeds and the number of tasks. Choose the number of tasks so that the one-sided 95% bound of the paired difference can fall within 2 percentage points; if that number is not affordable, the comparison can only report, not accept.
- Measures, each on the reference and on every candidate:
  1. KL divergence of next-token distributions against the FP8 reference on a fixed set of coding-agent prompts (top-k logprobs from the server). The fastest signal of numerical drift; the first run sets the baseline, no threshold yet.
  2. Resolve rate on a fixed subset of SWE-bench Verified or Terminal-Bench 2.1, paired task by task, at temperature 0 and at the production sampling.
  3. Retrieval at 128K and 256K tokens.
  4. Tool-call validity and turn errors at the harness agent levels.
  5. A Portuguese sample from the same suites.
  6. Vision, only if the product accepts images.

Acceptance criteria:

1. Result directories exist for the reference and each candidate, with the committed prompt and task lists and the engine, image and revision of each run.
2. For each candidate, the report gives the resolve rate of both arms, the paired difference with its one-sided 95% bound (McNemar or exact paired test), the retrieval scores, the tool-call error rate and the mean KL divergence.
3. A candidate passes if the lower 95% bound of (candidate resolve rate minus FP8 resolve rate) is above minus 2 percentage points, its retrieval at 128K and 256K is no more than 2 points below FP8, it has no more turn errors than FP8, and it passed the needle gate.
4. Decision rule: keep the current weights if they pass. Switch to QAD2 only if QAD2 also passes and its resolve rate is not lower than the current weights' in the paired comparison. If the current weights fail, stop: the checkpoint choice is reopened before phase 3. The result and the decision are written to `02-model-hardware-and-checkpoints.md` §3.

The 2-point margin was set on 2026-11-17 as a product decision.

## Phase 3: two replicas behind the router

Work: two `g7e.24xlarge` (or one `g7e.48xlarge` running two replicas) with the llm-d EPP in standalone mode and Envoy in front, prefix-affinity routing as in the guide values.

Acceptance criteria:

1. The routing test of §7.1 repeated on the real model: in a serial run of 21 prefix groups with 3 repetitions each, the share of repetitions that return to the replica that served the first request is reported for affinity routing and for load-only routing (mini model: 100% vs 52.4%).
2. With affinity, the share of prompt tokens served from cache in the repetitions is reported next to its theoretical ceiling (mini: 97.1% of a 97.1% ceiling).
3. A burst of 51 requests with the same prefix completes without errors, and the per-replica request split is reported (mini: 27 and 24).

## Phase 4: KV tier

Work: the corrected LMCache test (`vast.sh` arms `vllm/lmcache-dcp1` and `vllm/lmcache-dcp1-control`): DCP1, KV pool cut to about 3.5M tokens, 48 agents thinking 60 to 100 s between turns, LMCache L1 in host RAM against HBM only.

Acceptance criteria:

1. Both arms produce `agents-48.json` (the bench does not save an interrupted level, so the run must finish).
2. For each arm the report gives prefix-cache hit rate, external (LMCache) hit rate, TTFT p95 of cached turns, and the number of restores that waited for GPU capacity (server log lines `waiting for GPU capacity`).
3. The server log shows how many agents were running at once. If more than about 24 ran together, the test repeated the overload of §29.8 and its TTFT result is not used.

Decision rule: keep the LMCache tier if the LMCache arm has a lower TTFT p95 than the HBM-only arm with no more turn errors. Note that the fork's LMCache does not emit removal events, so the router's index will not see CPU-tier evictions until the fork picks up upstream PR 5307 and its follow-up fixes (see `04-kv-cache-routing-and-disaggregation.md`).

## Phase 5: production cell

Scope, to be specified when phases 1 to 4 have passed:

- Orchestration (EKS or not), autoscaling on queue and KV signals rather than GPU utilization (§8.4 `workload-autoscaling`).
- Cold start: weight cache and `instanttensor`, target set from the phase 1 baseline.
- Authentication, per-user quotas and rate limits at the gateway (product decision of unlimited tokens with a fixed cost per user, see `01-product-demand-and-slo.md`).
- Observability: vLLM metrics (KV usage, prefix hits, offload), EPP metrics, per-turn TTFT and per-stream speed matching the SLO definitions.
- Fleet size: recomputed from phase 2 and 4 results (the fleet table in `05-capacity-cost-and-providers.md` assumed 40 streams per replica, measured is 16 to 24 agent sessions).

## Open questions

1. Current G7e price, discounted price (Savings Plans or reserved capacity), capacity and the status of the quota request (last read on 2026-11-04).
2. Whether the fork image runs at full speed on G7e. The AWS Deep Learning Base OSS AMI (Ubuntu 24.04, release 2026-10-27) ships NVIDIA driver 595.112.07 (Reported, DLAMI release notes, read 2026-11-12), older than the 615.65.02 the image expects (§25), so phase 1 must install a newer driver or prove 595 works. The image digest to pin is `sha256:c14295c214f6...0e38` (project version manifest, not published). Host 157204 ran 615.71.09; Nebius ran 580.173 and worked (§12.1); the slow host 48294 ran 580.95.05 (§29.10). Record the driver in phase 1.
3. Whether GPU peer-to-peer is enabled inside `g7e.24xlarge` (required for the B12X PCIe all-reduce).
4. Whether EFA changes the case for P2P KV sharing between replicas or for P/D. Untested anywhere.
5. Weights: `g7e.24xlarge` has 2 x 3,800 GB local NVMe instance store (Reported, AWS price list and G7e page, read 2026-11-12), enough to cache the 177.7 GB checkpoint per instance; its read speed is Unknown until phase 1. Shared storage for weights and for an LMCache L2 tier: which AWS service gives the read bandwidth needed (Nebius shared filesystem measured 2 GiB/s per stream, §12.1).
