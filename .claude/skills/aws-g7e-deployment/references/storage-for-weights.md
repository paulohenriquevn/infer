# Storage for weights and caches

How to get the 177.7 GB QAD checkpoint, the 12.9 GB image and the kernel cache onto a G7e quickly, with the AWS throughput limits as documented, our load times measured elsewhere, and what phase 1 measures. No storage option has been tested on AWS.

Labels: Reported (URL and read date), Observed (path or journal section), Inferred (reasoning shown), Unknown.

## What has to be on the instance

| Item | Size | Source |
|---|---|---|
| Checkpoint `local-inference-lab/GLM-5.3-Flash-NVFP4-MXFP8-CSF-QAD` at `dec48abd33efa73c3bb7c95b74eee10cad34f9be` | 177.7 GB (docs/02); the loader reported `165G/165G` (Observed, `f3/resultados/vast-20261111/vllm/vast-vllm-dcp1/servidor.log`, Portuguese file name), which is the same size in GiB (177.7 / 1.0737 = 165.5, Inferred) | 49 files on the Hugging Face Hub (Observed, `f3/resultados/vast-20261111/vllm/host-vllm/download.log`) |
| Image `ghcr.io/local-inference-lab/vllm:karmic-kraken-20261016` | 12.9 GB compressed, 30.6 GB uncompressed | §12.1, §17.2 |
| Kernel cache (`/cache`, B12X JIT and compile artefacts) | Unknown size | §12.2, §13.4 |
| Results | small (JSON and logs) | `bench/README.md` |

## Our measured load times (other providers)

Observed unless marked. These are the numbers any AWS choice is compared with.

| Step | Time | Where | Source |
|---|---|---|---|
| Checkpoint download from the Hub, `hf download --revision`, unauthenticated | 5 min 31 s for 49 files (about 537 MB/s, Inferred: 177.7 GB / 331 s) | Vast 157204 | `f3/resultados/vast-20261111/vllm/host-vllm/download.log` |
| Weights, `--load-format instanttensor`, right after the download | `165G/165G [00:21<00:00, 8.19GB/s]`, "Loading weights took 24.68 seconds"; "Model loading took 42.2 GiB memory and 49.097309 seconds" | Vast 157204 | `f3/resultados/vast-20261111/vllm/vast-vllm-dcp1/servidor.log` |
| Server start to ready, same run | 260 s | Vast 157204 | `vast-vllm-dcp1/tempo-pronto.txt` (old Portuguese name of `ready-time.txt`) |
| Server start, cold and warm kernel cache | 511 s and 201 s | Vast 157204 | §29.1 |
| Weights, `instanttensor`, 1,767 GiB network disk | 134.5 s at 1.4 GB/s | Nebius | §12.1 |
| Weights, default vLLM loader, 1.9 GB/s disk | 829.7 s (about 270 MB/s) | Nebius | §12.1 |
| Weights, default loader, small network disk | 888 s (about 205 MB/s) | Nebius | §9.3 |
| Image pull, 12.9 GB | 7.5 min on both a 104 MiB/s and a 1.9 GB/s disk (about 29 MB/s): registry, decompression or layer concurrency is the limit, not the disk | Nebius | §12.1, §17.2 |
| B12X JIT on first start | about 9 min of a 15 min first start | Nebius | §12.2 |
| Cold start of a new VM, end to end | 21 to 23 min (VM 2, pull 7.5, start 1.7, weights 2.2, post-load 1.1, JIT and graphs 8.4) | Nebius | §17.2 |

Two readings of the 157204 load:

1. 8.19 GB/s is far above any single disk we rented. The host had 1,511 GiB RAM with 1,354 GiB in buffers and cache when recorded, and the download had just written the files (Observed, `host-vllm/host.txt`). So the load most likely read the page cache, not the disk (Inferred). On a `g7e.24xlarge` (1,024 GiB RAM) a download immediately followed by a server start should behave the same way (Inferred). A start after a reboot, or from a volume the instance did not just write, reads the disk.
2. Both causes of slow loads were real on Nebius: a slow disk and the default loader (§12.1). Always use `--load-format instanttensor` (the fork's server scripts already do: `'load_format': 'instanttensor'` in the 157204 log).

## Storage options

### Instance store NVMe

Reported, `https://docs.aws.amazon.com/ec2/latest/instancetypes/ac.html`, read 2026-11-12: `g7e.24xlarge` has 2 x 3,800 GB NVMe SSD (1,100,000 random-read IOPS at 4 KiB across both); `g7e.48xlarge` has 4 x 3,800 GB. No sequential MB/s figure is published (Unknown).

Persistence (Reported, `https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instance-store-lifetime.html`, read 2026-11-12): data survives a reboot; it "does not persist if the instance is stopped, hibernated, or terminated", and then "every block of the instance store volume is cryptographically erased". Instance store volumes "are attached only at instance launch". No extra charge.

The DLAMI mounts NVMe instance store at `/opt/dlami/nvme` (Reported, DLAMI release notes, `nvme_location`). Whether it stripes both devices into one volume on a `g7e.24xlarge` is Unknown; check with `lsblk` and `df -h /opt/dlami/nvme`. If it does not, build a RAID 0 with `mdadm` in user data.

Fit: weights (177.7 GB) plus the image (30.6 GB) plus KV spill fit many times over in 7,600 GB (Inferred). Every new instance has to refill it from S3 or the Hub.

### EBS

Reported, `https://docs.aws.amazon.com/ebs/latest/userguide/ebs-volume-types.html` and `https://docs.aws.amazon.com/ebs/latest/userguide/general-purpose.html`, read 2026-11-12:

| Volume | Max throughput per volume | Max IOPS | Included baseline | Notes |
|---|---|---|---|---|
| gp3 | 2,000 MiB/s | 80,000 | 3,000 IOPS, 125 MiB/s | Extra throughput at 0.25 MiB/s per provisioned IOPS; 2,000 MiB/s needs at least 8,000 IOPS and 16 GiB |
| io2 Block Express | 4,000 MiB/s | 256,000 | none | Sub-millisecond latency; priced per provisioned IOPS (price not read) |
| st1 | 500 MiB/s | 500 (1 MiB I/O) | | HDD, not bootable |

Instance cap (Reported, instance types spec): `g7e.24xlarge` 6,250 MB/s at 128 KiB I/O, 200,000 IOPS; `g7e.48xlarge` 12,500 MB/s. AWS: "An instance's EBS performance is bounded by the instance's performance limits, or the aggregated performance of its attached volumes, whichever is smaller."

Consequences (Inferred):

- One gp3 at 2,000 MiB/s (about 2.1 GB/s) reads 177.7 GB in about 85 s, already better than the 1.4 GB/s that gave 134.5 s on Nebius. Two or three gp3 in RAID 0 approach the 6,250 MB/s instance cap.
- The Terraform AWS provider's launch template page still documents a gp3 `throughput` maximum of 1,000 MiB/s (Reported, `https://raw.githubusercontent.com/hashicorp/terraform-provider-aws/main/website/docs/r/launch_template.html.markdown`, read 2026-11-12) while EBS documents 2,000 MiB/s. Whether the provider rejects values above 1,000 is Unknown; test with `terraform plan` before relying on it.

Volumes created from a snapshot are slow until initialized (Reported, `https://docs.aws.amazon.com/ebs/latest/userguide/initalize-volume.html`, read 2026-11-12): "the data blocks must be downloaded from Amazon S3 to the new volume", with increased latency until done. Options there: a Provisioned Rate for Volume Initialization of 100 to 300 MiB/s (charged per GiB of snapshot data; 5,000 MiB/s regional quota across concurrent requests), Fast Snapshot Restore (fully initialized at creation, priced separately, price not read), or reading every block with `fio`. At 300 MiB/s, 177.7 GB takes about 565 s (Inferred: 177.7e9 / (300 x 1,048,576)), slower than a download from S3. A snapshot only helps when it is fast-restore enabled or when the same volume is reattached, not recreated (Inferred).

A persistent gp3 volume that is detached and reattached keeps its data and needs no initialization (Inferred from "Empty volumes deliver their maximum performance immediately"; reattaching is not creation). Its cost while idle is storage only. This is the simplest way to keep the kernel cache across phase 1 runs.

### S3 plus a local copy

Reported, `https://docs.aws.amazon.com/AmazonS3/latest/userguide/optimizing-performance.html`, read 2026-11-12: at least 5,500 GET/HEAD requests per second per prefix; data-lake applications reach "up to 100 Gb/s on a single instance"; parallel byte-range reads raise throughput.

Tools:

- `s5cmd` (Reported, `https://github.com/peak/s5cmd`, read 2026-11-12): "For downloads, s5cmd can saturate a 40Gbps link (~4.3 GB/s)" (a quote from a third-party article; no instance type given). Defaults: `--numworkers` 256, `cp --concurrency` 5 parts per file. Syntax: `s5cmd cp 's3://bucket/prefix/*' local/`. The repository page showed no release version (pin one at install time).
- Mountpoint for Amazon S3 (Reported, `https://github.com/awslabs/mountpoint-s3/blob/main/doc/CONFIGURATION.md`, read 2026-11-12): by default targets "the available network bandwidth" on EC2, override with `--maximum-throughput-gbps`; `--read-only`; local cache with `--cache <dir>`; default part size 8 MiB; no benchmark numbers published. Whether InstantTensor's read pattern performs well through a FUSE mount is Unknown; copying to NVMe first avoids the question.

Estimate (Inferred, not measured): at 4.3 GB/s the checkpoint arrives in about 41 s; at 1 GB/s in about 178 s. Either beats the 331 s Hub download, and S3 in the same region has no Hub rate limits. The first upload to S3 costs a full download once plus S3 storage (S3 price not read; Unknown).

Hub direct remains the simplest path for phase 1 because it needs no bucket. Use an `HF_TOKEN` from the environment if downloads are throttled; the 157204 log warned "You are sending unauthenticated requests to the HF Hub" (Observed, `download.log`). Never write the token to user data or Terraform (see `security-and-cost-guardrails.md`).

When downloading with `hf download --revision <sha>`, create `refs/main` pointing at the revision by hand, or offline vLLM will not find the model (§25.3).

### Shared file system (FSx for Lustre)

Reported, `https://docs.aws.amazon.com/fsx/latest/LustreGuide/ssd-storage.html`, `https://docs.aws.amazon.com/fsx/latest/LustreGuide/performance.html` and `https://docs.aws.amazon.com/fsx/latest/LustreGuide/using-fsx-lustre.html`, read 2026-11-12:

| Deployment | Disk throughput per TiB (baseline) | Network throughput per TiB (baseline / burst) | RAM cache per TiB |
|---|---|---|---|
| SCRATCH_2 | 200 MB/s read | 200 / 1,300 | 6.7 GiB |
| PERSISTENT-125 | 125 | 320 / 1,300 | 3.4 GiB |
| PERSISTENT-250 | 250 | 640 / 1,300 | 6.8 GiB |
| PERSISTENT-500 | 500 | 1,300 | 13.7 GiB |
| PERSISTENT-1000 | 1,000 | 2,600 | 27.3 GiB |

Per client (same pages): 100 Gbps without EFA (and "traffic between an individual client instance and an individual FSx for Lustre object storage server is limited to 5 Gbps"), 700 Gbps with EFA, 1,200 Gbps with EFA and GPUDirect Storage. The smallest size in AWS's tables is 1.2 TiB; the minimum and increments for Persistent 2 were not read (Unknown). FSx price not read (Unknown). The DLAMI ships the Lustre client modules (Reported, release notes).

Fit (Inferred): a 1.2 TiB PERSISTENT-1000 file system gives about 1.2 GB/s disk baseline, less than one gp3 at full throughput; its value is sharing one copy across many instances and a possible shared KV tier (docs/06 open question 5), not phase 1. Revisit in phase 5 when several replicas start at once.

## Recommendation for phase 1

1. Root volume gp3 for the OS and Docker (`data-root` on the root volume or on NVMe; measure pull time either way, since pull time did not depend on the disk on Nebius).
2. Weights on instance store at `/opt/dlami/nvme`, downloaded from the Hub at the pinned revision (first run), and timed. If an S3 mirror exists by then, time `s5cmd` from it too.
3. Kernel cache on a small persistent gp3 volume created empty (no snapshot), tagged, reattached for later runs of phases 1 and 2, deleted at the end of phase 2. Measure start time with an empty and a filled cache. The gain of a warm cache was 511 s to 201 s on 157204 (§29.1).
4. Record the image pull time separately.

Why not EBS for weights in phase 1: it adds a volume to create, initialize and delete, and the instance store is free and local. Why not FSx: one instance does not need shared storage (Inferred).

## What phase 1 measures

| Measurement | Command (run on the instance) | Compare with |
|---|---|---|
| Instance store sequential read, one device and the striped volume | `sudo fio --name=seqread --filename=<file on /opt/dlami/nvme> --rw=read --bs=1M --iodepth=32 --ioengine=libaio --direct=1 --size=50G --numjobs=4 --group_reporting` | 1.4 GB/s (Nebius disk that gave 134.5 s) |
| Hub download time at the pinned revision | `time hf download ... --revision dec48abd...` | 5 min 31 s (157204) |
| S3 download time, if a mirror exists | `time s5cmd cp 's3://<bucket>/<prefix>/*' /opt/dlami/nvme/...` | Hub time |
| Weight load from page cache | "Loading weights took" line in `server.log` right after download | 24.68 s (157204) |
| Weight load from disk | same line after `sync; echo 3 \| sudo tee /proc/sys/vm/drop_caches` and a server restart | 134.5 s (Nebius, 1.4 GB/s) |
| Image pull | `time docker pull ghcr.io/local-inference-lab/vllm:karmic-kraken-20261016` | 7.5 min (Nebius) |
| Server start to ready, cold and warm kernel cache | `ready-time.txt` | 511 s and 201 s (157204) |
