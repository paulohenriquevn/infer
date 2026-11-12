# G7e instance facts

Everything the public AWS documentation said about G7e on 2026-11-12, what our own reads of 2026-11-04 added, and what is still Unknown with the phase 1 step that measures it. Nothing in this file has been run on AWS.

Labels: Reported (AWS or NVIDIA page, URL and read date given), Observed (our own read or measurement, source given), Inferred (reasoning shown), Unknown.

## Sources read

| Short name | URL | Read |
|---|---|---|
| Instance types spec | `https://docs.aws.amazon.com/ec2/latest/instancetypes/ac.html` | 2026-11-12 |
| G7e product page | `https://aws.amazon.com/ec2/instance-types/g7e/` | 2026-11-12 |
| GA announcement | `https://aws.amazon.com/about-aws/whats-new/2026/01/amazon-g7e-instances-generally-available/` | 2026-11-12 |
| Regions announcement | `https://aws.amazon.com/about-aws/whats-new/2026/07/amazon-g7e-additional-regions/` | 2026-11-12 |
| NVIDIA drivers on EC2 | `https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/install-nvidia-driver.html` | 2026-11-12 |
| Public driver install | `https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/public-nvidia-driver.html` | 2026-11-12 |
| DLAMI Base GPU (Ubuntu 24.04) | `https://docs.aws.amazon.com/dlami/latest/devguide/aws-deep-learning-x86-base-gpu-ami-ubuntu-24-04.html` | 2026-11-12 |
| DLAMI 20261027 release (Ubuntu 24.04) | `https://docs.aws.amazon.com/dlami/latest/devguide/aws-deep-learning-ami-gpubaseoss-ul2404-2026-10-28.html` | 2026-11-12 |
| DLAMI 20261106 release (Ubuntu 26.04) | `https://docs.aws.amazon.com/dlami/latest/devguide/aws-deep-learning-ami-gpubaseoss-ul2604-2026-11-09.html` | 2026-11-12 |
| DLAMI driver change FAQ | `https://docs.aws.amazon.com/dlami/latest/devguide/important-changes.html` | 2026-11-12 |
| EFA user guide | `https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa.html` | 2026-11-12 |

## Sizes

Reported, instance types spec and G7e product page, read 2026-11-12. All sizes use Intel Xeon Emerald Rapids (5th generation Xeon Scalable), 2 threads per core, the Nitro v6 hypervisor, and the GPU NVIDIA RTX PRO Server 6000 (96 GiB each).

| Size | GPUs | GPU memory | Host memory (GiB) | vCPU | Cores | Instance store | EBS bandwidth (Mbps) | EBS throughput (MB/s, 128 KiB I/O) | EBS IOPS (16 KiB) | EBS volume limit |
|---|---|---|---|---|---|---|---|---|---|---|
| `g7e.2xlarge` | 1 | 96 GiB | 64 | 8 | 4 | 1 x 1,900 GB NVMe | 2,000 / 5,000 (burst) | 250 / 625 | 8,000 / 20,000 | 32 |
| `g7e.4xlarge` | 1 | 96 GiB | 128 | 16 | 8 | 1 x 1,900 GB NVMe | 8,000 | 1,000 | 32,000 | 32 |
| `g7e.8xlarge` | 1 | 96 GiB | 256 | 32 | 16 | 1 x 1,900 GB NVMe | 16,000 | 2,000 | 64,000 | 32 |
| `g7e.12xlarge` | 2 | 192 GiB | 512 | 48 | 24 | 1 x 3,800 GB NVMe | 25,000 | 3,125 | 100,000 | 32 |
| `g7e.24xlarge` | 4 | 384 GiB | 1,024 | 96 | 48 | 2 x 3,800 GB NVMe | 50,000 | 6,250 | 200,000 | 64 |
| `g7e.48xlarge` | 8 | 768 GiB | 2,048 | 192 | 96 | 4 x 3,800 GB NVMe | 100,000 | 12,500 | 400,000 | 128 |

The `g7e.2xlarge` EBS figures are baseline / maximum; the spec page says such instances "can support maximum performance for 30 minutes at least once every 24 hours". The larger sizes sustain the listed figure.

Instance store random-read / write IOPS at 4 KiB (Reported, same page): `g7e.24xlarge` 1,100,000 / 550,000; `g7e.48xlarge` 2,200,000 / 1,100,000. AWS publishes no sequential-read MB/s figure for these disks (Unknown; phase 1 measures it with `fio`, see `storage-for-weights.md`).

Family summary row (Reported): Nitro v6, x86_64, no metal size, Dedicated Hosts supported, Spot supported, hibernation not supported, Windows and Linux.

Security specs (Reported): EBS encryption, instance store encryption and encryption in transit are supported on every G7e size; NitroTPM and Nitro Enclaves supported; AMD SEV-SNP not.

### Which sizes we use

- `g7e.24xlarge` is one replica: 4 GPUs for TP4 (decided, docs/06).
- `g7e.48xlarge` is two replicas sharing 2,048 GiB of host RAM (docs/06, §16, §17.2).
- 1 and 2 GPU sizes cannot hold the 177.7 GB QAD checkpoint with KV room: 96 or 192 GiB of GPU memory (Inferred from docs/02 and the table).
- A `g7e.24xlarge` has 96 vCPU and 1,024 GiB RAM. Vast host 157204 had 128 vCPU and 1,511 GiB (Observed, `f3/resultados/vast-20261111/vllm/host-vllm/host.txt`, `nproc` and `free -g`). Whether 96 vCPU is enough for the server plus the harness on the same host is Unknown; the bench client ran on the same 157204 host. Watch CPU in phase 1 (`mpstat` or `top` during the agent levels).

## Network

Reported, instance types spec, read 2026-11-12 (columns: bandwidth, EFA, ENA, ENA Express, ENA queues per interface, network cards, max interfaces, IPs per interface, IPv6):

| Size | Bandwidth | EFA | ENA Express | Network cards | Max interfaces | IPv4 per interface |
|---|---|---|---|---|---|---|
| `g7e.2xlarge` | 50 Gbit | no | no | 1 | 4 | 64 |
| `g7e.4xlarge` | 50 Gbit | no | no | 1 | 8 | 64 |
| `g7e.8xlarge` | 100 Gbit | yes | no | 1 | 8 | 64 |
| `g7e.12xlarge` | 400 Gbit | yes | yes | 1 | 10 | 64 |
| `g7e.24xlarge` | 800 Gbit | yes | yes | 2 | 20 | 64 |
| `g7e.48xlarge` | 1,600 Gbit | yes | yes | 4 | 40 | 64 |

ENA queues per interface (default): 8 on the 2xlarge, 16 on the 4xlarge, 32 on the larger sizes; configurable queue allocation is not supported on G7e (footnote 2 of the spec table).

EFA interface counts: one EFA per network card (EFA user guide: "Instance types that support multiple network cards can be configured with one EFA per network card"). So `g7e.24xlarge` takes 2 EFAs and `g7e.48xlarge` takes 4 (Inferred from the network-card column, and it matches what we read in the API on 2026-11-04, Observed in `NOTAS.md`).

EFA generation and RDMA (Reported, EFA user guide, Nitro v6 / EFA v4 table): `g7e.12xlarge`, `g7e.24xlarge`, `g7e.48xlarge` support RDMA read, RDMA write, Accelerator Data Transfer (GPUDirect RDMA) and Accelerator Command Initiation (GPUDirect Async). `g7e.8xlarge` supports RDMA read and write without ADT or ACI. Details and what it would mean for us are in `networking-and-efa.md`.

## GPU interconnect inside the instance

- NVLink: not mentioned on the G7e product page (Reported, read 2026-11-12). The RTX PRO 6000 Server Edition we measured has no NVLink in any host we used (`nvidia-smi topo -m` shows SYS, NODE and PIX links, no NV#; Observed, `f3/resultados/vast-20261111/vllm/host-vllm/host.txt`).
- GPUDirect P2P: the product page says G7e supports "NVIDIA GPUDirect P2P via PCIe", and the GA announcement says "G7e instances support NVIDIA GPUDirect Peer to Peer (P2P) that boosts performance for multi-GPU workloads" (Reported, read 2026-11-12).
- PCIe topology (which GPUs share a switch, which cross the CPU socket): not published (Unknown). On 157204 GPU0 sat on NUMA node 0 and GPUs 1 to 3 on node 1, with GPU2 and GPU3 behind one PCIe bridge (PIX) (Observed, same `host.txt`). Record `nvidia-smi topo -m` in phase 1.
- Fabric Manager: AWS says "G-series instances do not use NVSwitch and do not require Fabric Manager" (Reported, `https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa-start-nccl.html`, read 2026-11-12).

Why it matters: the fork's B12X PCIe one-shot all-reduce needs peer access between the 4 GPUs. Without it the custom all-reduce lost to NCCL from 4 KiB on Nebius; with it, 157204 measured 9.1 to 9.5 µs at 256 B to 2 KiB against 15.5 to 34.7 µs for NCCL (Observed, `f3/resultados/vast-20261111/validacao-vllm/host-vllm/p2pmark-4gpu.txt`; §25.2, §28.2). AWS advertising P2P is Reported, not measured by us. Phase 1 step "qualify" checks it.

## Regions and zones

Reported, regions announcement (July 2026), read 2026-11-12: US West (Oregon), US East (N. Virginia, Ohio), Europe (Spain, London, Frankfurt, Stockholm), Asia Pacific (Tokyo, Seoul, Mumbai). Purchase options listed: On-Demand, Spot, Savings Plans. The GA announcement (2026-01-20) listed only N. Virginia and Ohio.

Zones: in `us-east-1` G7e was offered in `us-east-1b`, `us-east-1c` and `us-east-1d` (Observed on 2026-11-04 with `describe-instance-type-offerings`, `NOTAS.md`). Zone IDs map to zone names differently per account, so this list is valid for our account only. Other regions: Unknown; read them with `aws ec2 describe-instance-type-offerings --location-type availability-zone --filters Name=instance-type,Values=g7e.24xlarge --region <r>` before choosing the subnet.

Region list on the AWS "capabilities by region" page was not read (Unknown); the announcement list may lag.

## AMIs and drivers

### What AWS recommends

- Driver types: G7e supports the Tesla (datacenter), GRID and gaming drivers (Reported, NVIDIA drivers on EC2). We need the Tesla driver: CUDA compute, no display.
- Minimum public driver for G7e: "575.0 or later", product type Tesla, series "RTX series", product "RTX PRO 6000 Blackwell" (Reported, public driver install page).
- AWS's install steps install the open kernel module variant (`nvidia-open` on Ubuntu 24.04, `nvidia-driver:open-dkms` on Amazon Linux 2023) and enable `nvidia-persistenced` (Reported, same page).
- DLAMIs use the NVIDIA open source (OpenRM) driver since 2023-11-15 because the upstream kernel isolates proprietary modules from other kernel drivers, which "disables GPUDirect RDMA" (Reported, DLAMI driver change FAQ).

### The DLAMI base GPU image

Name format: `Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 24.04) ${YYYY-MM-DD}`. Latest AMI ID through the public SSM parameter `/aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-ubuntu-24.04/latest/ami-id` (Ubuntu 26.04: `.../base-oss-nvidia-driver-gpu-ubuntu-26.04/latest/ami-id`). Reported, DLAMI Base GPU pages, read 2026-11-12.

Package versions of the two newest releases (Reported, release pages above):

| Field | Ubuntu 24.04, release 20261027 | Ubuntu 26.04, release 20261106 |
|---|---|---|
| Supported instances | G4dn, G5, G6, Gr6, G6e, G7, G7e, P4d, P4de, P5, P5e, P5en, P6-B200, P6-B300 | same |
| Kernel | 7.0.0-1014-aws | 7.0.0-1017-aws |
| NVIDIA driver | 595.112.07 | 595.112.07 |
| Default CUDA | 13.2 (stack 12.8, 12.9, 13.0, 13.2) | 13.3 |
| NVIDIA container toolkit | 1.20.1 | 1.20.1 |
| EFA installer | 1.51.0 | 1.51.0 |
| aws-ofi-nccl | 1.22.0 | 1.22.0 |
| GDRCopy | 2.6 | 2.5.2 |
| DCGM | 4.7.1 | 4.7.1 |
| Instance store mount | `/opt/dlami/nvme` | `/opt/dlami/nvme` |
| Root volume type | gp3 | gp3 |
| containerd | v2.4.2 | v2.4.2 |

Earlier Ubuntu 24.04 releases with G7e in the supported list: 20260307 (driver 580.126.09), 20260918 and 20261002 (driver 595.91.07). Reported, DLAMI release pages read 2026-11-12. Docker CE is installed (`docker-ce-cli 29.9.2` updated in 20261027; Reported).

Known issue on the Ubuntu 24.04 page: "Users running multinode workloads on G7e may see errors on G7e.8xlarge instances. For those users, please consider using G7e.12xlarge instead." (Reported, read 2026-11-12). It does not concern the 24xlarge.

### The driver gap

The fork image was built for `CUDA_DRIVER_VERSION=615.65.02` with CUDA 13.4.1 (Observed in the image, §23 and §25.1). The newest DLAMI ships 595.112.07. Evidence on lower drivers:

| Host | Driver | C32 decode, DCP1 | Source |
|---|---|---|---|
| Vast 157204 | 615.71.09 | 1,580 tok/s | Observed, `f3/resultados/vast-20261111/vllm/vast-vllm-dcp1/decode.json` |
| Nebius R1 | 580.173 | 1,425 tok/s | Observed, §12.2 |
| Vast 48294 | 580.95.05 | 296 tok/s | Observed, §29.10 (cause Unknown) |

Inferred: the image runs on a 580 driver (Nebius), so it will probably start on 595.112.07, but the DLAMI driver is older than the one the image targets, and the slow host also ran an older driver. The driver is the first variable to rule out if phase 1 is slow, not a proven cause.

Two options, decided in phase 1 by measurement:

1. Run on the DLAMI driver as shipped, record it, run qualification. Cheapest; if C32 decode is at least 1,400 tok/s, keep it.
2. If qualification fails, install a 615 branch driver with the open kernel module from the NVIDIA CUDA repository (the AWS public-driver procedure), reboot, and repeat qualification on the same instance. The exact Ubuntu package name for the 615 branch was not read (Unknown; list it with `apt-cache policy 'nvidia-open*'` after adding the CUDA keyring). Removing the DLAMI's driver first is needed, since AWS warns that driver packages from preinstalled AMIs must be uninstalled to avoid version conflicts (Reported, `https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/preinstalled-nvidia-driver.html`).

Building our own AMI with the chosen driver, Docker, the image layers and the kernel cache is a phase 5 question (cold start).

### GPUDirect P2P and the module parameters

On Nebius, P2P needed `NVreg_RegistryDwords` with `PeerMappingOverride=1`, already set by the provider's image (§25.3). On 157204, P2P was OK with `RegistryDwords: ""` (Observed, `host.txt`: `== P2P leitura:` matrix all `OK`; the file uses the Portuguese label). The bench prints a suggested override line (`ForceP2P=0x11;RMForceP2PType=1;...`) whenever none is configured, even on a host where peer access is already "all enabled (12/12)" (Observed, `p2pmark-4gpu.txt`). Do not treat that suggestion as a diagnosis.

On AWS, whether P2P is OK out of the box with the DLAMI driver is Unknown. If it is not, the Nebius procedure (keep existing values, `zz-*.conf`, stop `nv-hostengine` and `nvidia-persistenced`, reload) is the starting point, but whether AWS allows these overrides on a virtualized Nitro instance is Unknown.

## What remains Unknown and how phase 1 measures it

| Unknown | Measured by (phase 1 runbook step) | Record in |
|---|---|---|
| Driver shipped and whether the image runs at full speed on it | `nvidia-smi`; qualification C32 decode | `host.txt`, `decode.json` |
| PCIe topology and NUMA placement of the 4 GPUs | `nvidia-smi topo -m` | `host.txt` |
| GPUDirect P2P between all 4 GPUs | `nvidia-smi topo -p2p r`; p2pmark | `host.txt`, `p2pmark-4gpu.txt` |
| B12X all-reduce chosen | `grep 'Using B12X PCIe all-reduce' server.log` | `server.log` |
| Instance store sequential read speed (one disk, two in RAID 0) | `fio` read test | phase 1 notes |
| Time to first served request | `ready-time.txt` | result directory |
| Whether 96 vCPU limit the harness or server | CPU use during agent levels | phase 1 notes |
| Which zones in the chosen region offer G7e | `describe-instance-type-offerings` | phase 1 notes |
| Whether the PCIe link reports Gen5 x16 under load | `nvidia-smi --query-gpu=pcie.link.gen.current,...` during decode; at idle 157204 reported gen 1 (power saving, Observed `vast-vllm-dcp1/host.txt`) | phase 1 notes |
