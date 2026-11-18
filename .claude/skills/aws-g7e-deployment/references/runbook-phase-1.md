# Phase 1 runbook: one `g7e.24xlarge` reproduces the measured numbers

Ordered steps from an empty account to the phase 1 acceptance criteria, then teardown. Nothing here has run yet; durations and costs are Inferred from runs on other providers and the price recorded on 2026-11-04. Steps marked PAID need Paulo's confirmation (project rule 6); the `guard-paid-actions` hook asks before `terraform apply` and `aws ... run-instances`.

Goal (docs/06): show that the AWS host behaves like Vast host 157204 (C32 decode 1,580 tok/s with DCP1) and not like host 48294 (296 tok/s).

## 0. Before anything is created

| # | Step | Done when |
|---|---|---|
| 0.1 | Sign in with short-lived credentials (IAM Identity Center session) in the shell that will run Terraform. No access keys in files | `aws sts get-caller-identity` answers |
| 0.2 | Choose the region with Paulo. Today only `us-east-1` has known zones (`1b`, `1c`, `1d`, Observed 2026-11-04) | Region written in the phase notes |
| 0.3 | Check the G and VT On-Demand quota (`L-DB2E81BA`) in that region is at least 96: `aws service-quotas get-service-quota --service-code ec2 --quota-code L-DB2E81BA --region <r>` | Value at least 96. If not, the request is the blocker: record its date and status (`quotas-and-purchase.md`) |
| 0.4 | List zones offering the type: `aws ec2 describe-instance-type-offerings --location-type availability-zone --filters Name=instance-type,Values=g7e.24xlarge --region <r>` | One zone chosen |
| 0.5 | Read the current On-Demand price for `g7e.24xlarge` in that region (Price List API or Pricing Calculator) and write it with the date | Price and date in the notes |
| 0.6 | Resolve the DLAMI AMI ID: `aws ssm get-parameter --name /aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-ubuntu-24.04/latest/ami-id --region <r> --query Parameter.Value --output text`; read its release notes for the driver | AMI ID and driver version in `terraform.tfvars` and the notes |
| 0.7 | Confirm with Paulo: region, one instance, the hourly price of 0.5, expected duration and cost (section "Cost"), who tears down, watchdog limit | Written yes from Paulo |

## 1. One-time account setup

| # | Step | Done when |
|---|---|---|
| 1.1 | State bucket: versioning on, encryption on, public access blocked, name kept out of git (`terraform-layout.md`). Small cost (S3 storage of a few KB) | Bucket exists |
| 1.2 | `backend.hcl` with `bucket`, `key`, `region`, `use_lockfile = true`, `encrypt = true`, outside git | `terraform init -backend-config=backend.hcl` succeeds |
| 1.3 | Budget for the project (`security-and-cost-guardrails.md`): monthly cost budget, alerts at actual 50% and 80% and forecast 100% | Budget visible in the Billing console |
| 1.4 | Optional: an S3 prefix for results and, later, a weights mirror. Bucket policy allows only the instance role | Prefix exists |

## 2. Plan and apply

| # | Step | Done when |
|---|---|---|
| 2.1 | Fill `terraform.tfvars` from `../examples/terraform-phase-1/terraform.tfvars.example`: region, zone, AMI ID, owner, run id, `max_runtime_minutes` (240 proposed), results bucket | File complete |
| 2.2 | `terraform plan -out phase1.plan`; read it: one instance `g7e.24xlarge`, one gp3 cache volume, security group with no inbound rules, role and profile, every resource tagged | Plan reviewed |
| 2.3 | PAID. `terraform apply phase1.plan`. Write the launch time (UTC) in the notes | `terraform output instance_id` returns an ID |
| 2.4 | If the apply fails with `InsufficientInstanceCapacity`, change the zone in `terraform.tfvars` and plan again. Do not loop automatically | Instance running, or a written note that no zone had capacity |

## 3. Connect and check the bootstrap

| # | Step | Done when |
|---|---|---|
| 3.1 | `aws ssm start-session --target <instance-id>` (needs the Session Manager plugin locally) | Shell on the instance |
| 3.2 | `tail -f /var/log/infer-bootstrap.log`; the step markers are in `/var/lib/infer/steps/` | Last marker is `weights-ready` |
| 3.3 | If the log is empty or stuck for more than 15 min with no new line, terminate (section 7) instead of waiting. Why: §25.3, 6 h 8 min lost on Nebius | Decision written |
| 3.4 | Record the timings the script printed: image pull, weights download | Times in the notes |

## 4. Qualify the host

Run each check and record the output in the result directory (`host.txt` and notes). Pass values from the host qualification rule (`CLAUDE.md` rule 4) and 157204 (Observed).

| # | Check | Command | Pass | 157204 value |
|---|---|---|---|---|
| 4.1 | Driver | `nvidia-smi --query-gpu=index,name,driver_version --format=csv` | 4 GPUs, version recorded | 615.71.09 |
| 4.2 | Topology | `nvidia-smi topo -m` | recorded | GPU0 on NUMA 0, GPUs 1 to 3 on NUMA 1, GPU2 and GPU3 PIX |
| 4.3 | P2P | `nvidia-smi topo -p2p r` | `OK` in all 12 off-diagonal cells | all `OK`, `RegistryDwords: ""` |
| 4.4 | All-reduce microbenchmark | `$PY llm-inference-bench/llm_decode_bench.py --p2pmark-only --p2pmark-max-gpus 4 --p2pmark-mode allreduce` | "peer access: all enabled (12/12)"; custom faster than NCCL at 256 B to 8 KiB | custom 9.1 to 22.8 µs, NCCL 15.5 to 35.5 µs at 256 B to 8 KiB |
| 4.5 | Instance store read | `fio` command in `storage-for-weights.md` | recorded | not measured there |

If 4.3 fails, do not apply the Nebius driver override blindly (`g7e-instance.md`, "GPUDirect P2P and the module parameters"). Stop and decide with the team.

## 5. Run the harness

Use the DCP1 profile. The run also counts as phase 2's first DCP1 run if phase 1 passes, because phase 2 runs on the phase 1 instance with the same image, checkpoint and flags (Inferred from docs/06).

From `bench/` on the host (the DLAMI has Docker and the container toolkit, so `LAUNCH_MODE=docker`):

```bash
export PY=$HOME/bench-venv/bin/python
OUT=results/aws-$(date +%Y%m%d)-g7e24-dcp1 \
ENGINE=vllm IMAGE=ghcr.io/local-inference-lab/vllm:karmic-kraken-20261016 \
SERVER_SCRIPT=server-vllm-dcp1.sh LAUNCH_MODE=docker \
AGENT_LEVELS="16:900 24:900" bash run_benchmark.sh
```

`ENGINE`, `IMAGE` and `SERVER_SCRIPT` are required; the script exits without them (`bench/README.md`). `NEEDLE_RUNS` defaults to 500 at C8 and `STOP_ON_GATE_FAIL` to 1.

In Docker mode, `server-vllm-dcp1.sh` mounts `HF_CACHE` at `/root/.cache/huggingface` and `RUNTIME_CACHE` at `/cache`, starts with `HF_HUB_OFFLINE=1`, and defaults both to named Docker volumes (`model-cache`, `glm53-flash-runtime`) (Observed in the script). Export them so the server finds the weights on NVMe and the kernel cache on the persistent volume:

```bash
export HF_CACHE=/opt/dlami/nvme/hf      # the bootstrap downloaded with HF_HOME=/opt/dlami/nvme/hf
export RUNTIME_CACHE=/cache             # persistent gp3 volume
```

After about 5 min of the server being ready, the decode cells run; if C32 decode in `decode.json` is below 1,400 tok/s, stop the run (Ctrl-C), keep the directory, and go to section 7: the cause must be found before buying anything else (§29.10).

Then summarize with the price read in step 0.5:

```bash
python3 summarize.py --price <price-read-in-0.5> --needle-ref 3/500 results/aws-<date>-g7e24-dcp1
```

Copy the result directory to the results prefix (`aws s3 cp --recursive`) and to your machine. Raw results are never edited afterwards (rule 5).

## 6. Acceptance criteria

Values from host 157204 in parentheses (Observed). A filled example is `../examples/phase-1-result-checklist.md`.

1. `nvidia-smi topo -p2p r` reports OK between all 4 GPUs, and `server.log` contains `Using B12X PCIe all-reduce` (both present on 157204).
2. Decode at C32 is at least 1,400 tok/s with DCP1 (1,580; DCP4 gave 1,279 on the same host).
3. `summarize.py --needle-ref 3/500` marks the needle `ok` (3/120 near misses at C8 on 157204, which `summarize.py` prints as "97.5% ok"; the DCP1 rerun on host 48294 had 0/500).
4. gsm8k at least 94/96 (95/96 on 157204; 96/96 on 48294).
5. `ready-time.txt` and the weight-load line of `server.log` are in the result directory, plus the image pull and download times from the bootstrap log. No pass value; this is the baseline phase 5 must improve (157204: ready in 260 s, weights 24.68 s from page cache).

Phase 1 passes when 1 to 4 pass and 5 is recorded. Write the verdict and the numbers in the phase notes with instance type, region, zone, AMI ID, driver and date.

## 7. Teardown

Do this the same day, pass or fail, unless phase 2 starts on the same instance immediately (then the watchdog limit is raised with Paulo's agreement, not silently).

| # | Step | Done when |
|---|---|---|
| 7.1 | Results copied off the instance (S3 and local) | `aws s3 ls` shows the files |
| 7.2 | `terraform destroy` with the same `backend.hcl` and `terraform.tfvars`. Keep the kernel cache volume only if phase 2 follows within days, by removing it from state first or by a variable (`keep_cache_volume`); otherwise destroy it | Destroy reports the expected count |
| 7.3 | Sweep by tag, reading errors: `aws ec2 describe-instances --filters Name=tag:project,Values=infer Name=instance-state-name,Values=pending,running,stopping,stopped --region <r>`; same for `describe-volumes`, `describe-snapshots --owner-ids self`, `describe-addresses`, `describe-network-interfaces` | Every list empty, or only the kept cache volume |
| 7.4 | Cross-check with the Resource Groups Tagging API: `aws resourcegroupstaggingapi get-resources --tag-filters Key=project,Values=infer --region <r>` | Only expected leftovers (state bucket, kept volume, budget) |
| 7.5 | Check the shell exit status of every teardown command and read its output. Why: `vastai destroy` printed "Aborted." with exit code 0 (§28.2), and a zsh sweep reported "0 resources" because of word splitting (§25.3) | Statuses and outputs read |
| 7.6 | Next day: Cost Explorer or Billing shows the run's cost; compare with the estimate. Budgets data lags (updated "up to three times a day", Reported) | Actual cost in the notes |
| 7.7 | Report: verdict, numbers, cost, and "0 instances, 0 unexpected volumes" with the commands used | Report written |

## Cost

Inferred from the On-Demand price recorded on 2026-11-04 (US$ 16.57/h, `us-east-1`; recheck in step 0.5) and the step durations below. Worked calculation: `../examples/cost-phase-1.md`.

| Step | Expected duration | Basis |
|---|---|---|
| Apply to SSM shell | about 5 min | Unknown on AWS; Nebius VM creation was 2 min (§17.2) |
| Image pull | about 7.5 min | Nebius, 12.9 GB (§17.2) |
| Weights from the Hub | about 5.5 min | 157204, 5 min 31 s |
| Bench setup and checks | about 10 min | Inferred |
| Server start | 4.3 to 8.5 min | 157204: 260 s here, 511 s cold kernel cache (§29.1) |
| Gate, speed, agents 16 and 24 | about 37 min | 157204: decode started 4 min after ready, agents-24 started at 00:46:18 and ran 900 s (Observed, JSON timestamps of `vast-vllm-dcp1`); 500 needle runs instead of 120 add a few minutes |
| Summarize, copy, teardown | about 10 min | Inferred |
| Total | about 80 to 85 min | sum |

| Scenario | Hours | On-Demand cost at US$ 16.57/h |
|---|---|---|
| Hourly rate | 1 | US$ 16.57 |
| Smooth run | 1.5 | US$ 24.86 |
| One retry or a driver change and rerun | 3 | US$ 49.71 |
| Watchdog cap (240 min) | 4 | US$ 66.28 |

EBS adds little: 300 GiB root plus 200 GiB cache gp3 at the example rate on the EBS pricing page (US$ 0.08 per GB-month, region not named, Reported `https://aws.amazon.com/ebs/pricing/`, read 2026-11-12) is about 500 x 0.08 / 730 = US$ 0.05/h (Inferred). Data transfer in from the internet and the Hub download: price not read (Unknown).
