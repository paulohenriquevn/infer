# AWS implementation plan

## Summary

The measured replica (4x RTX PRO 6000 Blackwell Server Edition, vLLM fork, TP4 + MTP3) maps to one `g7e.24xlarge`. Nothing has run on AWS yet. Regional capacity, GPU peer-to-peer inside the instance, and whether the fork image runs at full speed on the AWS driver are Unknown.

Price and quota as last read (Observed on 2026-11-04 in the AWS Price List API and Service Quotas, not re-checked; `NOTAS.md`):

- On-demand list price in `us-east-1`: `g7e.24xlarge` US$ 16.57/h, `g7e.48xlarge` US$ 33.14/h, or US$ 4.14 per GPU-hour. G7e was offered in `us-east-1b`, `1c` and `1d`.
- Quota for G and VT on-demand vCPUs was 0 in every region checked; a request for 96 vCPUs (one `g7e.24xlarge`, Inferred: if G7e counts against that quota) was pending.

At list price a replica costs 3 times the Vast host 157204 (US$ 5.61/h) and 2.3 times the Nebius list price (US$ 1.80 per GPU-hour). With the measured 24 sessions per replica (DCP1, one run), that is about 1.45 sessions per US$/h on AWS on-demand, against 4.28 on host 157204 (Inferred, same sessions, different price). Discounts (Savings Plans, reserved capacity) were not read. The plan therefore starts with one instance that must reproduce the numbers measured elsewhere before anything is built around it.

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
| Orchestration for the first phases | Plain EC2 with a startup script; EKS | Plain EC2 for phases 1 to 3. The llm-d EPP runs outside Kubernetes (standalone EPP + Envoy + file discovery, Reported in LMCache PR 5307 validation). Move to EKS when autoscaling and rollouts are needed (phase 5) |
| Region | Any region with G7e capacity | Open: depends on capacity and quota answers, and on where the users are |
| Weight storage | EBS gp3/io2, instance store, S3 + local copy, FSx for Lustre | Open. Startup is dominated by weight loading (888 s from a slow network disk vs 134 s with a fast disk and `--load-format instanttensor`, §12.1). Measure in phase 1 |
| Purchase model | On-demand, Savings Plans, Capacity Blocks, Spot | Open until discounted prices are read: on-demand list price makes AWS the most expensive provider measured. Spot preemption cost a replica about 23 min of cold start on Nebius (§9.3) |

## Phase 1: one replica reproduces the measured numbers

Goal: show that the AWS host behaves like the good Vast host (157204) and not like the bad one (48294).

Work:

- Request G7e quota in the chosen region; launch one `g7e.24xlarge` with the fork image `ghcr.io/local-inference-lab/vllm:karmic-kraken-20261016` and checkpoint `local-inference-lab/GLM-5.3-Flash-NVFP4-MXFP8-CSF-QAD` at revision `dec48abd33efa73c3bb7c95b74eee10cad34f9be`.
- Run the harness in `f3/sglang/` (`comparativo.sh` with `EXECUCAO=direto` inside the container, or `EXECUCAO=docker` on the host).

Acceptance criteria (values from host 157204 in parentheses, Observed):

1. `nvidia-smi topo -p2p r` reports OK between all 4 GPUs, and the server log contains `Using B12X PCIe all-reduce`.
2. Decode at C32 is at least 1,400 tok/s (1,580 with DCP1, 1,279 with DCP4; the threshold applies to DCP1).
3. `resumir.py --needle-ref 3/500` marks the run `ok`: needle-checksum with 500 runs at C8 is not worse than 3/500 at p < 0.05 (0/500 and 3/120 on the two DCP1 runs).
4. gsm8k scores at least 94/96 (95/96 and 96/96 on the two DCP1 runs, raw `gsm8k.json`).
5. The time from instance start to the first served request and the time to load weights are recorded in the result directory (`tempo-pronto.txt`, server log). No pass value: this is the baseline that phase 5 must improve.

If criterion 2 fails, stop: the cause has to be found before buying more instances (§29.10 shows a host 5 times slower with the same software).

## Phase 2: choose DCP1 or DCP4

Work: on the phase 1 instance, run the agent levels 16 and 24 twice with DCP1 and twice with DCP4 (`AGENTES="16:900 24:900"`; the second run of each profile with `SO_AGENTES=1` and its own output directory, `OUT` for `comparativo.sh` or `RODADA=2` for `roteiro.sh`, because a run overwrites its directory). `resumir.py` shows the second run's gate as not run there; the verdict comes from the first run.

Acceptance criteria:

1. Four result directories exist, each with `agentes-16.json` and `agentes-24.json`.
2. `resumir.py` prints, for each, the agent level inside the SLO (measured elsewhere: DCP1 24 in one run; DCP4 16 then fail at 16).
3. The chosen profile is the one whose lower of the two runs has more sessions inside the SLO. The choice and both numbers are written to `03-serving-engine-and-benchmarks.md`.

## Phase 3: two replicas behind the router

Work: two `g7e.24xlarge` (or one `g7e.48xlarge` running two replicas) with the llm-d EPP in standalone mode and Envoy in front, prefix-affinity routing as in the guide values.

Acceptance criteria:

1. The routing test of §7.1 repeated on the real model: in a serial run of 21 prefix groups with 3 repetitions each, the share of repetitions that return to the replica that served the first request is reported for affinity routing and for load-only routing (mini model: 100% vs 52.4%).
2. With affinity, the share of prompt tokens served from cache in the repetitions is reported next to its theoretical ceiling (mini: 97.1% of a 97.1% ceiling).
3. A burst of 51 requests with the same prefix completes without errors, and the per-replica request split is reported (mini: 27 and 24).

## Phase 4: KV tier

Work: the corrected LMCache test (`roteiro.sh` arms `vllm/lmcache-dcp1` and `vllm/lmcache-dcp1-controle`): DCP1, KV pool cut to about 3.5M tokens, 48 agents thinking 60 to 100 s between turns, LMCache L1 in host RAM against HBM only.

Acceptance criteria:

1. Both arms produce `agentes-48.json` (the bench does not save an interrupted level, so the run must finish).
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
2. Which GPU driver the G7e AMI ships, and whether the fork image runs at full speed on it. The image expects driver 615.65.02 or newer (§25). Host 157204 ran 615.71.09; Nebius ran 580.173 and worked (§12.1); the slow host 48294 ran 580.95.05 (§29.10). Record the driver in phase 1.
3. Whether GPU peer-to-peer is enabled inside `g7e.24xlarge` (required for the B12X PCIe all-reduce).
4. Whether EFA changes the case for P2P KV sharing between replicas or for P/D. Untested anywhere.
5. Shared storage for weights and for an LMCache L2 tier: which AWS service gives the read bandwidth needed (Nebius shared filesystem measured 2 GiB/s per stream, §12.1).
