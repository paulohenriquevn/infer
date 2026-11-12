# Capacity, cost and providers

Scope: what one serving replica of GLM-5.3-Flash costs and holds, which GPU providers we evaluated, and what we know about capacity, expansion and cold start. The target is about 10,000 developers running coding agents, served by replicas of 4x NVIDIA RTX PRO 6000 on the vLLM fork from local-inference-lab. The team now plans to build on AWS.

Evidence labels used throughout: **Observed** (we measured or read it in the original), **Reported** (a named source says it, we did not reproduce it), **Inferred** (derived, with the reasoning given), **Hypothesis** (to be tested), **Unknown**. Section references such as (ARQUITETURA.md §8.3) point to the design log in the repository root. Prices carry the date they were read; GPU prices move, so treat any price older than a few days as stale.

## Summary

- One replica is 4 RTX PRO 6000 GPUs running TP4 with the vLLM fork. With DCP4 it holds 23.2 million KV tokens (88.7 sessions of 262,144 tokens in HBM); with DCP1 it holds 6.79 million (Observed, §12.2, §29.6).
- The efficiency metric is sessions served within the SLO per US$/h. Measured: 2.85 (DCP4, 16 agents) and 4.28 (DCP1, 24 agents, one run) on a Vast.ai host at US$5.61/h (Observed, §29.1, §29.6). The older figure of 12.3 sessions per US$/h counts HBM capacity without an SLO (§12.4).
- Nebius lists the RTX PRO 6000 at US$1.80 per GPU-hour (2026-11-05), sells it only as 1-GPU or 8-GPU VMs, has no InfiniBand for it, and had no preemptible capacity for the 8-GPU VM when we checked (Observed, §8.3).
- Vast.ai is fine for measurements and on-demand bursts but not for the reserved base: same-listing hosts differed 1.4x to 5.3x in decode, and instances are containers (Observed and Inferred, §29.10, §28.1).
- AWS G7e uses the same GPU (Server Edition) and `g7e.24xlarge` matches our 4-GPU replica. None of our software has run there. The on-demand list price read on 2026-11-04 was US$ 16.57/h for `g7e.24xlarge` in `us-east-1` (US$ 4.14 per GPU-hour, the highest of the providers we priced), and our G and VT quota was 0 with a request pending (Observed, `NOTAS.md`, not re-checked). P2P behaviour and current price and quota are Unknown.

## What a replica costs and holds

### The replica

The unit is one engine on 4 RTX PRO 6000 Server Edition GPUs: checkpoint `local-inference-lab/GLM-5.3-Flash-NVFP4-MXFP8-CSF-QAD`, TP4, MTP3, and either DCP4 or DCP1 (ARQUITETURA.md §12.2, §29.7). The official checkpoints do not fit in fewer than 4 RTX GPUs: the FP8 checkpoint is 328.3 GB and the NVIDIA NVFP4 checkpoint is 204.4 GB, against 96 GB per GPU (Observed via Hugging Face API, §8.3). Only a community checkpoint of 178.0 GB fits on 2 GPUs, with about 7 GB per GPU left for everything else (Inferred, §8.3).

The engine decision is the fork's vLLM; whether to run DCP1 or DCP4, with or without LMCache, is still open (§29.7).

### Measured capacity and speed

R1 on Nebius (8-GPU VM, replica on GPUs 0 to 3, one run per cell, Observed, §12.2 and §12.4):

| Measure | Value |
|---|---|
| KV budget | 23,249,576 tokens (88.7 sessions of 262,144 tokens) |
| Decode, 1 / 8 / 32 streams (tok/s, aggregate) | 119.8 / 585 to 631 / 1,423 to 1,441 |
| Cold prefill, 128K | 10,289 tok/s, TTFT 12.5 s |
| Cold prefill, 256K | TTFT 25.2 s |
| Prefill while decode is active | about 4,100 tok/s |
| Weight load with `--load-format instanttensor` | 134 s |
| Full first start, with JIT compile | 15 min |
| `needle-checksum` gate | 120/120 |

Decode does not change with context from 0 to 128K (Observed, §12.2). For comparison, one B300 on upstream vLLM held 10.4 sessions of 262,144 tokens with MTP, decoded 1.9x faster on one stream, prefilled 2.5x faster, and failed 12 of 120 checksum probes (Observed, §12.4). The B300 is a reference only; the platform decision is RTX (§26.4).

Vast.ai host 157204 (Nevada, 4x RTX PRO 6000 Server Edition, US$5.61/h, driver 615.71.09, Observed, §29.1 and §29.6):

| vLLM fork | DCP4, run 1 | DCP4, run 2 | DCP1 (one run) |
|---|---|---|---|
| KV tokens | 23.1 M | 23.1 M | 6.79 M |
| Decode C1 / C8 / C16 / C32 (tok/s) | 146 / 599 / 910 / 1,279 | 139 / 586 / 923 / 1,288 | 154 / 696 / 1,073 / 1,580 |
| 16 agents: TTFT p95, tok/s p50 | 4.77 s, 57.2 (pass) | 5.20 s, 57.8 (fail) | 4.71 s, 70.8 (pass) |
| 24 agents: TTFT p95, tok/s p50 | not measured | 5.97 s, 47.1 (fail) | 4.93 s, 55.3 (pass) |

The SLO behind "pass" is TPOT p50 of 30 tok/s per stream and TTFT p95 of 5 s on a cached turn (Hypothesis adopted for the MVP, §20, §26.4). Run 2 of DCP4 at 16 agents missed the TTFT target (§29.6). §29.6 calls 8 agents its guaranteed capacity, but level 8 passed in run 1 and was not repeated (run 2 tested only 16 and 24), so no DCP4 capacity is confirmed by two runs yet. DCP1 still needs its second speed run (§29.9).

On this host, small all-reduce took 9.1 to 9.5 µs against 32.1 to 57.4 µs on Nebius R1, where the driver P2P override was not in effect, and C1 decode was 22% higher than R1 (Observed; the causal link is Inferred, §28.2, §29.2).

### Cost per replica and sessions per US$/h

| Where | Price per replica (date read) | Sessions per US$/h | Basis |
|---|---|---|---|
| Nebius, list | US$7.20/h, half of the US$14.40 8-GPU VM (2026-11-05) | 12.3 | HBM capacity, no SLO (§12.4) |
| Nebius, spot | US$3.16/h at US$0.79 per GPU-hour (2026-11-05) | none | The 8-GPU VM had no preemptible capacity (§8.3, §12.4) |
| Vast.ai host 157204 | US$5.61/h (2026-11-11) | 2.85 (DCP4, 16 agents); 4.28 (DCP1, 24 agents) | Agents within SLO, Observed (§29.1, §29.6) |
| Nebius, list, at the Vast SLO counts | US$7.20/h | 2.2 (16 agents); 3.3 (24 agents) | Inferred: Vast agent counts divided by the Nebius price; assumes Nebius hosts perform like host 157204, untested |

Two definitions are in play. "12.3" divides the number of 256K sessions that fit in HBM by the price; it ignores speed. The decision of 2026-11-11 makes sessions within the SLO per US$/h the main metric (§26.4), so the 2.85 and 4.28 figures are the ones to optimise against.

Unit cost at Nebius list price, full utilisation, no SLO: US$0.194 per million cold-prefill tokens and US$1.40 per million output tokens at 32 streams (Inferred, §12.4).

Other measured Nebius costs (official calculator, list, §25.4): CPU VM `cpu-d3` 16 vCPU 64 GB US$0.528/h; NRD disk of 1,767 GiB US$0.128/h (US$94 per month). Preparing disk, image and checkpoint on a CPU VM costs about US$1 and 25 min (Inferred from one run).

### Fleet size at 10,000 users

All values Inferred at Nebius list price (§18.1), with 2 replicas per 8-GPU VM, 40 streams per replica and one N+1 VM per 5 loaded VMs:

| Scale and scenario | Peak streams | Replicas | Loaded / total VMs | Fleet, US$k per month | Z.ai API, US$k per month |
|---|---|---|---|---|---|
| 1,000 low | 17 | 1 | 1 / 2 | 21 | 1.4 |
| 1,000 base | 85 | 3 | 2 / 3 | 31.5 | 5.1 |
| 1,000 high | 146 | 4 | 3 / 4 | 42 | 8.7 |
| 10,000 low | 166 | 5 | 3 / 4 | 42 | 14.2 |
| 10,000 base | 845 | 22 | 12 / 15 | 158 | 51 |
| 10,000 high | 1,460 | 37 | 20 / 24 | 252 | 87 |

Later sections push these numbers up:

- The table assumes 40 streams per replica. The measured SLO capacity is 16 agents (DCP4) to 24 agents (DCP1) per replica (Observed, §29.6). Inferred: the replica counts above are a lower bound.
- With the measured GLM latency, the fraction of time a session spends in the loop rises from 0.26 to about 0.41, and the 22 replicas of the 10,000 base case become about 35 to 44, before Poisson margin and N+1 (Inferred, §24.2, §24.3).
- At these prices the API is cheaper: a fleet sized for one timezone's peak costs about 3x the API at 10,000 users (Inferred, §18.2). Self-hosting wins only with GPUs 33% to 43% cheaper, very good caching, users across timezones, or non-cost reasons such as data residency (Inferred, §18.2).

## Providers evaluated

### Nebius

Presets (Observed in documentation, §8.3). RTX PRO 6000 exists only as `1gpu-24vcpu-218gb` and `8gpu-192vcpu-1744gb`. A single GPU cannot hold the model, so the smallest usable unit is the 8-GPU VM at US$14.40/h, which hosts 2 TP4 replicas (§11.2). RTX regions: `uk-south2`, `eu-south1`, `us-central1`; B300 is in other regions, so no region has both (Observed, §13.2).

Network (Observed in documentation, §8.3, §17.2). Only 8-GPU B300, B200, H200 and H100 presets join InfiniBand GPU clusters. RTX VMs get 400 Gbps Ethernet (BlueField-3), and the managed RDMA driver only applies to GPU-cluster node groups. Plan for TCP between RTX VMs. Wide-EP and TP8 have no measurement without RDMA, and the fork's wiki marks EP over PCIe as "DO NOT USE" (Reported, §18.3).

Quotas. On 2026-11-04 the quota was 8 RTX PRO 6000 GPUs in each of the three RTX regions, which is one 8-GPU VM per region (Observed, §8.3). Preemptible quota is 2 VMs per platform and region (Observed, §8.3). The project was limited to 2 instances and 4 disks (Observed, §6). §18.3 sets a ceiling of 12 VMs (3 regions x 4, quota tier "full"), covering about 85% of the 10,000-user base peak (Inferred). The shared filesystem quota is 5 TiB per region (Reported in Nebius docs, §17.2). The lead time for a quota increase is Unknown (V10 in §21.2).

Prices (Observed, documentation and public spot API, 2026-11-05 14:06 UTC, §8.3):

| GPU | List per GPU-hour | Spot at the time, by region |
|---|---|---|
| RTX PRO 6000 | US$1.80 | US$0.79 (`uk-south2`); 1.09 (`us-central1`); 1.38 (`eu-south1`) |
| B300 | US$9.50 | 7.50 (`us-north1`); 8.70 (`uk-south1`); 12.20 (`eu-west2`) |

Spot is not always cheaper: B300 spot in `eu-west2` was above list (Observed, §8.3). Later, the 8-GPU RTX spot price in `us-central1` was US$1.789 per GPU-hour, the same as list (Observed, §13.4).

Capacity snapshot (`nebius capacity resource-advice list`, read-only, our quota, 2026-11-05, §8.3). The tool says it is accurate at read time and guarantees nothing.

| Region and preset | On-demand | Preemptible |
|---|---|---|
| `uk-south2`, RTX 1 GPU | 8 of 8, high | 2 of 2, high |
| `uk-south2`, RTX 8 GPUs | 1 of 1, high | 0 of 2, low |
| B300 1 GPU | 0 of 8, low | 2 of 2, high |

`LIMIT_REACHED` on reserved capacity reflects that we hold no reservation; it says nothing about physical capacity (Observed, §8.3). Nebius offers capacity block groups; reservations do not apply to preemptible VMs (Reported, §17.2).

Spot and preemption (Reported in Nebius docs, §8.3, §17.2). Compute sends `SIGTERM` 60 s before stopping the VM, then `SIGKILL`. Only `recovery_policy = FAIL` and `on_preemption = STOP` are supported, so the VM is stopped and not recovered. Persistent volumes survive; dynamic IP and local disk do not. There is no spot price cap. For us a preemption drops that replica's KV in HBM and RAM (Inferred). The "on-demand base plus spot burst" plan was refuted and removed (§17.2, §18.3). The B300 spot VM was preempted twice in 75 min (Observed, §11.1).

Disks (Observed with `fio`, direct reads, 16 MiB blocks, §12.1). Network disk bandwidth grows with provisioned size (Reported in docs: 15 MiB/s per 32 GiB on `NETWORK_SSD`; 110 MiB/s per 93 GiB up to 2 GiB/s on NRD and IO M3).

| Disk | Read |
|---|---|
| 200 GiB `NETWORK_SSD` boot | 104 MiB/s |
| NRD, 1,767 GiB | 1,923 MiB/s |
| `NETWORK_SSD_IO_M3`, 1,860 GiB | 2,075 to 2,115 MiB/s |
| Shared filesystem | 2,062 MiB/s single stream; write only 218 MiB/s |

The shared filesystem showed 7,056 MiB/s with 4 streams, likely host cache. Its real read bandwidth is Unknown (§12.1, §17.2). NRD is the chosen weights disk (cheaper, fine for recreatable data). Local SSD exists only on the 8-GPU B300 (Observed, §12.1). Price: local disk US$0.065 and shared SSD filesystem US$0.08 per GiB per 730 h (Observed, §8.3).

Credits and spend control (Reported, official sources, 2026-11-06, §25.5). Coupons need a card on file; Nebius charges US$25 and credits the balance. Budgets send email alerts per period, project or product, update every few hours and **do not block usage**. The hard cap is a quota reduction. The CLI only estimates prices; billed usage shows only in the console. Whether the AI Builder Program credits apply to GPU VMs is Unknown.

Software compatibility (Observed, §12.1, §25.1). The fork image `ghcr.io/local-inference-lab/vllm:karmic-kraken-20261016` (CUDA 13.4.1, torch 2.14) runs on the Nebius driver 580.173, although the image expects 615.65.02. Nebius hosts are Server Edition, while the fork's published numbers come from Max-Q and Workstation cards (Reported, §11.2).

### Vast.ai

How it works (Observed, §28.1). A Vast instance is the container of the chosen image: no Docker inside and no access to the host driver. Our script runs one instance per engine and pins the second engine to the same 4 GPUs by `machine_id`. Offers disappear within minutes; the first offer we picked was rented by someone else while the account was being set up (§28.3).

Hosts we used (Observed):

| Host | Location, type | Price | Result |
|---|---|---|---|
| 157204 | Nevada, 4x RTX PRO 6000 Server Edition | US$5.61/h (2026-11-11) | All §29 numbers; P2P enabled without driver override; 10.5 Gbit/s Hugging Face download (§28.2) |
| 48294 | Texas, datacenter, 4x RTX PRO 6000 S, reliability 0.965 | US$7.03/h (2026-11-12) | Same image, checkpoint, profile and harness as §29.6. Decode 108 / 298 / 350 / 296 tok/s at C1 / C8 / C16 / C32 against 154 / 696 / 1,072 / 1,578 on 157204; server start 1,084 s against 260 s (§29.10) |

On host 48294 decode was 1.4x lower at C1 and 3x to 5.3x lower at C16 and C32. The PCIe topology, all-reduce path and Gen5 x16 links matched host 157204, and the GPUs drew about 116 W during the agent run, meaning they sat idle. The cause is Unknown; one hypothesis is something outside the GPUs, such as another tenant sharing the 8-GPU host, CPU or memory (§29.10). Quality did not change: needle 500/500 at 8 concurrent, gsm8k 99% (Observed, §29.10).

Selection rule in force (§28.3, §29.9): Server Edition, at least 800 GB disk, at least 400 GB RAM, reliability of at least 0.95, up to US$7/h; numbers from a different machine are recorded with the machine ID.

Reserved pricing (Reported by Vast.ai support, 2026-11-12):

- An on-demand instance can be converted to reserved with a prepaid period, at a discount of "up to 50%".
- The prepaid credit is locked to that instance and cannot move to another host.
- If the machine fails its SLA and is deverified, the remaining balance can be withdrawn without penalty.
- Periods such as 1, 3 or 6 months show on the instance's discount badge.
- Still unanswered: same-datacenter placement, private networking and shared storage.

What the API showed (Observed via Vast API, 2026-11-12):

- The per-host maximum discount field `credit_discount_max` was 0% to 15% on 4x and 8x RTX PRO 6000 hosts, and 5% on host 48294.
- Personal hosts: US$1.44 to 1.52 per GPU-hour, reliability about 0.95, no discount.
- Datacenter hosts: US$2.33 to 2.93 per GPU-hour; the best discount was 15%, on an 8x Workstation host in Czechia.

Inferred from the two lists above: the 50% is a platform cap that no RTX PRO 6000 host we saw offers, and a datacenter host at its best discount still costs more per GPU-hour than the Nebius list price of US$1.80 (2026-11-05).

Fit (Inferred). Instances are Docker containers, not VMs, so running our own Kubernetes on them is impractical. Prepaid credit is tied to one host, and the same listing can deliver 1.4x to 5.3x different decode. Vast fits measurements and on-demand burst. It does not fit the reserved base.

### AWS

What the documentation says (Observed in https://docs.aws.amazon.com/ec2/latest/instancetypes/ac.html and https://aws.amazon.com/ec2/instance-types/g7e/, read 2026-11-12):

| Instance | GPUs | Memory | vCPU | Network |
|---|---|---|---|---|
| `g7e.24xlarge` | 4 | 1,024 GiB | 96 | 800 Gbps |
| `g7e.48xlarge` | 8 | 2,048 GiB | 192 | 1,600 Gbps |
| smaller sizes | 1 or 2 | | | |

- G7e uses NVIDIA RTX PRO 6000 Blackwell Server Edition, 96 GB per GPU, with Intel Xeon Emerald Rapids CPUs.
- The docs table shows EFA support on `g7e.8xlarge` and larger.
- AWS states G7e delivers up to 2.3x the inference performance of G6e (Reported, AWS marketing claim; it says nothing about our model).

What the repository recorded earlier (Observed on 2026-11-04 in `NOTAS.md`, not rechecked on 2026-11-12): on-demand list prices in `us-east-1` from the Price List API were US$16.57/h for `g7e.24xlarge` and US$33.14/h for `g7e.48xlarge`, about US$4.14 per GPU-hour; G7e existed in `us-east-1b`, `1c` and `1d`; our G/VT vCPU quota was 0 with a 96 vCPU on-demand request pending. §18.3 uses the same US$33.14 per 8-GPU VM, against US$14.4 at Nebius.

What we do not know (Unknown as of 2026-11-12): current G7e prices and any commit discount, regional availability beyond that one read, our current quota, whether GPU P2P works inside a G7e instance (the driver override mattered on Nebius, §25.2), and whether the fork image and its expected driver run there.

Inferred:

- `g7e.24xlarge` maps 1:1 to our 4-GPU replica, and its 1,024 GiB of host RAM leaves room for the RAM KV tier (§6 asks for 300 GiB or more per replica).
- If the 2026-11-04 price still holds, one replica costs about 2.3x the Nebius list price (US$16.57 against US$7.20 per hour). At the Vast SLO counts that is about 0.97 (DCP4, 16 agents) to 1.45 (DCP1, 24 agents) sessions per US$/h, assuming G7e performs like host 157204. Nothing was tested.
- EFA would reopen options ruled out on Nebius for lack of RDMA: P2P KV transfer between replicas and prefill/decode disaggregation. Nothing was tested; V13 (same benchmark on AWS, GCP and CoreWeave) is still open (§21.2).

## Host qualification rule (any provider)

From §29.10: the same "4x RTX PRO 6000" listing can deliver several times less throughput. Before any measurement, reservation or adding a host to the fleet:

1. Start the server with the production image, checkpoint and flags.
2. Run a C32 decode test with the harness, about 5 minutes after the server is up.
3. Discard the host if aggregate C32 decode with the DCP1 profile is below 1,400 tok/s (DCP4 gives about 1,280 on a good host).

The threshold sits below the 1,423 to 1,580 tok/s measured on good hosts (Observed, §12.2, §29.6) and far above the 296 tok/s of host 48294. It applies to Nebius VMs and AWS instances too, since nothing guarantees uniform hosts there either (Inferred).

## Availability, expansion and cold start

Start-up time (Observed, §12.2, §17.2, §29.1):

- Cold start of a new VM: 21 to 23 min. A realistic target for a new VM with seeded caches is 8 to 12 min; 5 min only holds for a replica on a VM that already exists (Inferred, §17.2).
- Image pull of 12.9 GB compressed took 7.5 min, the same on the 104 MiB/s and 1.9 GB/s disks, so the bottleneck is the registry, decompression or layer concurrency (Observed, §17.2).
- Weight load: 134 s with `instanttensor`; 830 s with the default vLLM loader on a 1.9 GB/s disk (Observed, §12.1).
- JIT compile of the B12X kernels: about 9 min of the first 15-min start. Persisting `/cache` should cut later starts; not measured (§12.2, §13.4).
- On Vast host 157204: 511 s with a cold kernel cache, 201 s with a warm one (Observed, §29.1).

Effects at scale (Inferred, §18.3): rolling one 3+1 cell takes 84 min cold and 32 min with warm caches; reactive autoscaling cannot cover start-up, so a scheduled replica floor 15 to 20 min before the peak is required. The growth unit is a cell of 3 working VMs plus 1 N+1 VM (6 replicas). A cell needs at least 2 VMs (Inferred, §17.3). Cell failover recomputes: 64 sessions of 256K cost about 27 min of prefill on one replica, so the destination cell needs admission control (Inferred, §17.4).

Validation matrix (§21.2; thresholds are Hypothesis until measured):

| # | What it validates | Pass criterion |
|---|---|---|
| V1 | Losing one replica does not take down the cell | 5xx under 1% over 5 min |
| V2 | Losing the LMCache server only costs recompute | 0 errors |
| V5 | Losing one of 2 VMs degrades, does not collapse | 429 with `retry-after`; accepted requests within SLO |
| V8 | New VM with seeded caches | First token in 12 min or less (cold: 21 to 23 min, Observed) |
| V9 | New replica joins without losing affinity | Old sessions' prefix hit stays within noise |
| V10 | Quota lead time is known | Answer and date recorded |
| V11 | Gateway holds 1,000 long streams | 0 connections dropped |
| V13 | Same performance on another provider | Variance measured on AWS, GCP, CoreWeave; outside the MVP |

V3, V4, V6, V7 and V12 cover the router, rollout, sub-agent bursts, structured output and cache salt (§21.2). The validation does not prove capacity at 10,000 users, L2 read behaviour, or RDMA on RTX (§21.4).

## What to ask a provider

From §6, with the reason for each item. Use it for AWS as well as any neocloud.

| Item | What to ask | Why |
|---|---|---|
| GPU unit and count | GPUs per region, including 8-GPU sizes | Replica size and scale test |
| Price | Preemptible and reserved price per GPU-hour, and eviction policy | Cost per million tokens and risk of losing sessions |
| Host RAM per GPU | 300 GiB or more per replica, pinned memory allowed | RAM KV tier |
| Local disk | Local NVMe per node and a read-write shared filesystem | Deep KV tier |
| Network | RDMA or InfiniBand only if P/D or wide-EP will be used; 400 Gbps Ethernet may do with small KV | Transfer cost |
| Quotas | Instances, disks, public IPs, GPUs per region (Nebius today: 2 instances, 4 disks) | Growing past 2 nodes |
| Capacity reservations | Reservation for the base and approval lead time | Avoid `InsufficientInstanceCapacity` |
| Observability | vLLM (offload, KV) and EPP (index) metrics via Prometheus | Calibrate router and capacity |
| Images | Local registry or image cache for the vLLM image (pull took 8.5 min per node) | Scale-up time |
| Drain time | Confirm how long node scale-down takes (about 11 min observed) | Cost of each test session |

Questions §17.6 adds for Nebius: RoCE/RDMA and a device plugin on `gpu-rtx6000`; reservations and preemptible capacity for the 8-GPU RTX VM; filesystem quota above 5 TiB; private network between regions and egress price.

## Lessons

Operation lessons that cost time or money (Observed, §25.3, §12.6):

| Lesson | What it cost |
|---|---|
| A wait loop with `pgrep -f name` inside an `ssh` command that contains `name` matches itself | The 8-GPU VM ran 6 h 8 min with no result, about US$88 (Inferred) |
| Not tearing down the VM when the start log is empty | Same incident |
| The Nebius GPU disk image already ships Docker; `apt-get install docker.io` in `cloud-init` conflicts | About 10 min of GPU time without Docker |
| Recent Docker stores images in containerd, outside `data-root` | Image lost with the CPU VM; another 7.5-min pull on GPU time. Fix: `features.containerd-snapshotter=false` in `daemon.json` |
| `hf download --revision <sha>` does not create `refs/main` | Offline vLLM cannot find the model; create `refs/main` by hand |
| The driver ships `RegistryDwords="PeerMappingOverride=1;"`; a second `options nvidia NVreg_RegistryDwords=` file can override it | The new override must include the original value and live in `zz-*.conf` |
| `nv-hostengine` (DCGM) and `nvidia-persistenced` hold the GPU | Driver reload fails until both are stopped; unload modules in order |
| In zsh, `nebius $cmd` does not split words | A resource sweep failed silently and reported "0 resources" |
| `a && b \|\| c` runs `c` when `b` succeeds | A script reported failure on success |
| A `set -e` start script aborted on a repeated `mount` | B300 idle about 15 min, about US$2.25 (§12.6) |

From the Vast script validation (Observed, §28.2): the CLI does not filter offers by `id=`; `status_msg` is null while the image downloads; `vastai destroy` asks for confirmation and prints "Aborted." with exit code 0, so the script uses `-y` and forgets an instance only after the CLI confirms destruction.

Process lessons (Inferred from the above): set a provider-side budget before any GPU session and check billing in the console, since the cumulative spend estimate reached about US$44 against a balance assumed to be US$25 (§12.6); verify that teardown left 0 instances, disks and filesystems in every project.

## Open questions

- AWS: current G7e on-demand and commit prices, regions and zones with capacity, our G/VT quota and the lead time for raising it, whether GPU P2P works inside `g7e.24xlarge`, whether the fork image runs on the AWS driver, and whether EFA gives usable RDMA for KV transfer. None was tested.
- Does G7e pass the host qualification rule (C32 decode of at least 1,400 tok/s with DCP1)?
- Vast.ai: same-datacenter placement, private networking and shared storage (asked, unanswered on 2026-11-12). The cause of host 48294's low throughput.
- Nebius: quota increase lead time (V10), reservation pricing and any commit discount (Unknown, §18.2), preemptible capacity for the 8-GPU RTX VM, real shared-filesystem read bandwidth.
- Second DCP1 speed run on a qualified host, and the LMCache test with 24 active agents (§29.9). These decide sessions per replica, which drives every fleet number above.
- Fleet tables need recomputing with measured SLO capacity (16 to 24 agents per replica) and the engine-dependent loop fraction of §24; the §18.1 table assumes 40 streams per replica.
- The SLO itself is a Hypothesis adopted for the MVP (§20).
