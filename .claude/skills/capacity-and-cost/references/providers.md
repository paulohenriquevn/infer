# Providers: Nebius, Vast.ai, AWS (and the others we priced)

Read this before you quote a price, a discount, a quota or a host rule. Every price has the date it was read; prices older than a few days are stale. Prices read on 2026-11-12 come from the public pages and APIs named in each row (no account was used). Older values come from `NOTAS.md` (project research notes, not published) and the 10k report (project research note "Arquitetura para 10 mil usuários", not published); the facts used are copied here.

Unit used everywhere: **replica-hour** = one 4-GPU replica for one hour. An 8-GPU machine holds two replicas.

## 1. Summary per replica-hour

| Provider and offer | US$ per replica-hour | Read | Label |
|---|---|---|---|
| Vast.ai host 157204 (where all capacity was measured) | 5.61 | 2026-11-11 | Observed (offer at rental) |
| Vast.ai cheapest 4x Server Edition offer with reliability above 0.95 | 5.33 | 2026-11-12 | Reported (Vast API) |
| AWS `g7e.24xlarge`, EC2 Instance Savings Plan 3 years, all upfront | 6.23 | 2026-11-12 | Reported (AWS price list) |
| AWS `g7e.24xlarge`, EC2 Instance Savings Plan 3 years, no upfront | 7.16 | 2026-11-12 | Reported |
| Nebius RTX PRO 6000 list (8-GPU VM US$ 14.40 / 2) | 7.20 | 2026-11-12 | Reported (nebius.com/prices) |
| AWS `g7e.24xlarge`, EC2 Instance Savings Plan 1 year, no upfront | 10.44 | 2026-11-12 | Reported |
| AWS `g7e.24xlarge`, Compute Savings Plan 1 year, no upfront | 13.05 | 2026-11-12 | Reported |
| AWS `g7e.24xlarge` on-demand, `us-east-1` | 16.57 | 2026-11-12 | Reported |

## 2. AWS

### Prices (read 2026-11-12)

On-demand Linux, from the public price data behind the EC2 pricing page (`https://b0.p.awsstatic.com/pricing/2.0/meteredUnitMaps/ec2/USD/current/ec2-ondemand-without-sec-sel/<Region>/Linux/index.json`, publication date 2026-11-10T17:38:52Z):

| Region | `g7e.24xlarge` (4 GPUs) | `g7e.48xlarge` (8 GPUs) |
|---|---|---|
| US East (N. Virginia), US East (Ohio), US West (Oregon) | 16.57216 | 33.14432 |
| Europe (Spain) | 17.46268 | 34.92536 |
| Asia Pacific (Seoul) | 20.3746 | 40.74921 |
| Europe (Stockholm) | 23.90667 | 47.81334 |
| Asia Pacific (Tokyo) | 24.03454 | 48.06908 |
| Asia Pacific (Mumbai) | 27.06754 | 54.13507 |
| EU (Frankfurt) | 28.18177 | 56.36354 |
| Europe (London) | 28.80344 | 57.60687 |
| EU (Ireland), US West (N. California), South America (São Paulo) | no G7e | no G7e |

Smaller sizes in `us-east-1`: `g7e.2xlarge` 3.36312, `4xlarge` 3.99816, `8xlarge` 5.26824, `12xlarge` 8.28608 (one or two GPUs, too small for the model).

Compared with `NOTAS.md` of 2026-11-04: `us-east-1` prices unchanged (24xlarge 16.57, 48xlarge 33.14, 12xlarge 8.29, 2xlarge 3.36).

Savings Plans, `us-east-1`, Linux, shared tenancy, from the Savings Plans bulk price list (`https://pricing.us-east-1.amazonaws.com/savingsPlan/v1.0/aws/AWSComputeSavingsPlan/20261110215713/us-east-1/index.json`, publication 2026-11-10T21:57:13Z). US$ per hour:

| Plan | Term | Payment | `g7e.24xlarge` | `g7e.48xlarge` | Discount vs on-demand |
|---|---|---|---|---|---|
| Compute SP | 1 year | No upfront | 13.05058 | 26.10115 | 21% |
| Compute SP | 1 year | Partial | 12.42912 | 24.85824 | 25% |
| Compute SP | 1 year | All upfront | 12.18054 | 24.36108 | 26% |
| Compute SP | 3 years | No upfront | 9.66488 | 19.32977 | 42% |
| Compute SP | 3 years | Partial | 8.94897 | 17.89793 | 46% |
| Compute SP | 3 years | All upfront | 8.76999 | 17.53997 | 47% |
| EC2 Instance SP (G7e family) | 1 year | No upfront | 10.44046 | 20.88092 | 37% |
| EC2 Instance SP | 1 year | Partial | 9.9433 | 19.88659 | 40% |
| EC2 Instance SP | 1 year | All upfront | 9.74443 | 19.48886 | 41% |
| EC2 Instance SP | 3 years | No upfront | 7.15917 | 14.31835 | 57% |
| EC2 Instance SP | 3 years | Partial | 6.62886 | 13.25773 | 60% |
| EC2 Instance SP | 3 years | All upfront | 6.23113 | 12.46226 | 62% |

Discounts are Inferred (1 minus SP rate over on-demand). The AWS Savings Plans page states "up to 66%" for Compute and "up to 72%" for EC2 Instance plans (https://aws.amazon.com/savingsplans/compute-pricing/, read 2026-11-12); G7e sits below those caps. Partial and all-upfront rates are the effective hourly rate including the upfront part (Inferred from how the price list expresses them; not checked against a bill).

The rates in the price list carry effective dates of 2026-11-10 (Compute SP) and 2026-01-20 (EC2 Instance SP). The docs, the 10k report and the `aws-g7e-deployment` skill record the G7e Savings Plan rate as Unknown; it is published.

A Savings Plan is a commitment of US$ per hour for the whole term, used or not. It fits the base load only (Inferred).

Capacity Blocks for ML do not offer G7e: the pricing page and the user guide list p6-b300, p6-b200, p5, p5e, p5en, p4d, p4de, trn1 and trn2 (https://aws.amazon.com/ec2/capacityblocks/pricing/ and https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-capacity-blocks.html, read 2026-11-12). Blocks are bookable up to 8 weeks ahead, up to 64 instances per block and 256 in total.

### The instance (https://aws.amazon.com/ec2/instance-types/g7e/, read 2026-11-12)

| | `g7e.24xlarge` | `g7e.48xlarge` |
|---|---|---|
| GPUs | 4 RTX PRO 6000 Blackwell Server Edition | 8 |
| GPU memory | 384 GB | 768 GB (Inferred, 2 x 384) |
| vCPU | 96 | 192 |
| Memory | 1,024 GiB | 2,048 GiB (10k report Table 5) |
| Local NVMe | 2 x 3.8 TB | |
| Network | 800 Gbps (24xlarge row of the page) | EFA |

The page states "G7e also supports NVIDIA GPUDirect P2P via PCIe" and GPUDirect RDMA with EFAv4 in EC2 UltraClusters. Whether P2P works between all 4 GPUs of a `g7e.24xlarge` with our image, and which driver AWS ships, is Unknown until phase 1 of `docs/06`.

### Quota and account (from `NOTAS.md`, 2026-11-04)

- Running On-Demand G and VT instances quota: 0 vCPU in every region checked. A request for 96 vCPU (one `g7e.24xlarge`) was pending. Current status Unknown.
- G7e on-demand was seen in `us-east-1` zones b, c and d.

## 3. Nebius

### Prices

| Item | Value | Read | Source |
|---|---|---|---|
| RTX PRO 6000, on-demand | US$ 1.80 per GPU-hour (8-GPU VM US$ 14.40/h) | 2026-11-12 | https://nebius.com/prices |
| RTX PRO 6000, preemptible | "from US$ 0.79" per GPU-hour | 2026-11-12 | same page |
| Commitment discount | "contact sales"; no figure published | 2026-11-12 | same page |
| H100 / H200 / B200 / B300 | US$ 4.50 / 5.40 / 8.50 / 9.50 per GPU-hour | 2026-11-12 | same page |

The page shows no effective date. These are the values `NOTAS.md` recorded from the console on 2026-11-04 (US$ 1.80, preemptible from US$ 0.79): unchanged. An aggregator listed US$ 2.35 for the same VM earlier (§18.2); which applies to a contract is Unknown.

Spot history (Observed, §8.3, §13.4): RTX spot US$ 0.79 (`uk-south2`), 1.09 (`us-central1`), 1.38 (`eu-south1`) per GPU-hour on 2026-11-05 14:06 UTC; once equal to list (1.789) in `us-central1`; B300 spot in `eu-west2` above list. No preemptible capacity for the 8-GPU RTX VM in `uk-south2` (0 of 2). Preemption gives 60 s notice and no recovery.

### Shapes, network, quota

- Presets: `1gpu-24vcpu-218gb` and `8gpu-192vcpu-1744gb` only. One GPU cannot hold the model, so the 8-GPU VM (two replicas) is the smallest usable unit (Observed, §8.3).
- No InfiniBand for RTX; 400 Gbps Ethernet; plan TCP between VMs (§8.3, §17.2).
- Our quota (`NOTAS.md`, 2026-11-04): 8 RTX GPUs in each of `eu-south1`, `uk-south2`, `us-central1`; in `uk-south2` 2 instances and 4 disks per project.
- The "full" quota tier: 32 GPUs per region in 3 regions = 12 VMs (Reported in Nebius docs, 10k report §3). The corrected base needs 34 VMs with DCP1 at b = 2 (`fleet-recalculation.md`).
- Budgets alert by email only and update every few hours; the hard cap is a quota reduction (§25.5).
- No resources running: everything was destroyed on 2026-11-06 by Paulo's decision (`NOTAS.md`).

## 4. Vast.ai

### Offers on 2026-11-12

Public search API (`https://console.vast.ai/api/v0/bundles/`, query: 4x RTX PRO 6000, rentable, on-demand), read 2026-11-12 12:18 UTC. Reported by the API; prices include the platform fee as `dph_total`:

| Offer | Machine | Card | US$/h | Per GPU | Reliability | Location | Driver | `credit_discount_max` |
|---|---|---|---|---|---|---|---|---|
| 60315373 | 157372 | Workstation | 3.20 | 0.80 | 0.692 | California | 580.178.04 | 0.0 |
| 59894976 | 147870 | Server | 5.33 | 1.33 | 0.974 | Florida | 580.178.04 | 0.4 |
| 54166495 | 152669 | Server | 5.34 | 1.33 | 0.993 | Japan | 595.91.07 | 0 |
| 54166464 | 152668 | Server | 5.34 | 1.33 | 0.994 | Japan | 595.91.07 | 0 |
| 56228579 | 149175 | Server | 6.40 | 1.60 | 0.996 | Utah | 580.178.04 | 0 |
| 59856583 | 55573 | Server | 6.67 | 1.67 | 0.983 | Taiwan | 595.80 | |
| 48926600 | 146170 | Server | 7.47 | 1.87 | 0.995 | CA | 580.173.02 | |
| 60330536 | 142266 | Workstation | 8.01 | 2.00 | 0.989 | Norway | 620.70.06 | 0.4 |
| 60147210 | 157270 | Server | 10.67 | 2.67 | 0.916 | Czechia | 620.70.06 | 0.05 |
| 56159876 | 109672 | Workstation | 14.67 | 3.67 | 0.995 | Texas | 615.71.09 | 0.03 |

Host 157204 was not listed. Hosts 48294 and 157204 (the two we used) are described in the `inference-benchmarking` skill.

What changed since the record of the same day in the docs: `credit_discount_max` reaches 0.4 on two hosts, where docs/05 recorded 0% to 15%. Whether 0.4 means 40% off with prepaid credit is Inferred from the field name; not confirmed by Vast.

### Reserved and interruptible

- https://vast.ai/pricing (read 2026-11-12): prices load dynamically; "Interruptible" is "50%+ cheaper"; "Reserved" is "up to 50% off" for 1, 3 or 6 months.
- Vast support (Reported, 2026-11-12, §29.10): an on-demand instance converts to reserved with a prepaid period; the credit is locked to that instance and host; refundable if the host is deverified.
- Rule: never reserve a host before it passes qualification (C32 decode at least 1,400 tok/s with DCP1). Host 48294 failed with the same listing as 157204.

### Role

Measurements and on-demand bursts only, never the reserved base (instances are containers without access to the driver or kernel modules, same-listing hosts differed up to 5.3 times in decode, credit locks to one host).

## 5. Other providers (10k report Table 5, read about 2026-11-05, not rechecked)

| Provider | 8x RTX PRO 6000 machine | US$ per machine-hour, list | Reserve or commit | Note |
|---|---|---|---|---|
| CoreWeave | `rtxp6000-8x` | 20.0 | contract, price not published | Spain and 5 US zones |
| GCP | `g4-standard-384` | 36.0 | 1-year CUD 24.84; 3-year 15.84; Flex-start 18.00 | only 8x RTX VM in Brazil (`southamerica-east1`) |
| OCI | `BM.GPU.RTXPRO.8` (bare metal) | 36.0 | not published | regions and quota Unknown |
| Exoscale | `gpurtx6000pro.huge` | EUR 15.97 | quote | manual account validation |
| Hetzner | GEX430, 4 GPUs Max-Q (300 W) | EUR 5.77 per 4-GPU server | EUR 3,599 per month | Max-Q yields less per GPU, not measured |
| Azure | NCv6 | not usable | | at most 2 GPUs per VM |

## 6. What is still Unknown

- AWS: G7e quota status, driver version, P2P on `g7e.24xlarge`, real C32 decode.
- Nebius: commitment discount for RTX, quota lead time, whether US$ 1.80 or US$ 2.35 applies to a contract.
- Vast: reserved price per host, the meaning of `credit_discount_max`.
