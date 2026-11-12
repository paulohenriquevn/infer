# Terraform layout for phases 1 to 3 (proposal)

Status: proposal. Nothing here has been applied or planned against an account. The tool and the backend are decided (Terraform, S3 state with locking, `docs/decisions/2026-11-12-infrastructure-as-code-tool.md`); the module split, resource choices and startup steps below are a recommendation that the first `terraform plan` will test. The illustrative skeleton is in `../examples/terraform-phase-1/`.

Labels: Reported (URL and read date), Observed, Inferred, Unknown.

## Versions read

- Terraform v1.17.2, published 2026-11-11 (Reported, GitHub releases API for `hashicorp/terraform`, read 2026-11-12).
- AWS provider v6.73.0, published 2026-11-11 (Reported, GitHub releases API for `hashicorp/terraform-provider-aws`, read 2026-11-12).

Pin both in `versions.tf` and upgrade on purpose. Provider docs quoted below come from the provider repository's `main` branch (`website/docs/r/*.html.markdown`), read 2026-11-12; they may run ahead of v6.73.0.

## State backend

Reported, `https://developer.hashicorp.com/terraform/language/backend/s3`, read 2026-11-12:

- "State locking is an opt-in feature of the S3 backend." Set `use_lockfile = true` (S3 native lock file).
- "DynamoDB-based locking is deprecated and will be removed in a future minor version." Do not add `dynamodb_table`.
- Permissions: `s3:ListBucket` on the bucket; `s3:GetObject` and `s3:PutObject` on the state object; with `use_lockfile`, `s3:GetObject`, `s3:PutObject` and `s3:DeleteObject` on the lock file.
- "It is highly recommended that you enable Bucket Versioning."
- `encrypt = true` for server-side encryption; `kms_key_id` for a customer key.
- Credentials: "We recommend using environment variables to supply credentials", and values hardcoded in the configuration end up "in both the `.terraform` subdirectory and in plan files". Use a partial backend configuration for anything account-specific.

Proposal:

- One state bucket per AWS account, created once by hand or by a tiny bootstrap configuration with local state, with versioning, encryption and public access block on. Its name is not written in this repository: pass it with `terraform init -backend-config=backend.hcl`, and keep `backend.hcl` out of git.
- State key per environment and phase, for example `infer/phase-1/terraform.tfstate`.

## Module layout

```text
infra/aws/
  versions.tf            terraform and provider pins
  backend.tf             backend "s3" {} with use_lockfile, rest from backend.hcl (not in git)
  providers.tf           provider "aws" with default_tags
  variables.tf
  network.tf             default VPC lookup (phase 1 and 2) or modules/network (phase 3)
  security.tf            security group(s)
  iam.tf                 instance role, instance profile, policies
  replica.tf             one module "replica" per replica
  outputs.tf
  modules/
    replica/             launch template + aws_instance + kernel-cache volume attachment
    network/             VPC, one subnet per AZ that offers G7e, S3 gateway endpoint (phase 3)
  user-data/
    replica.sh.tftpl     startup script template
```

Why this split (Inferred): the replica module is the unit that phases 1 to 3 repeat (one replica, then two); network and IAM change rarely; a separate bootstrap keeps the state bucket out of the state it stores.

Where the code lives: the `infra/` directory does not exist yet. Creating it is part of phase 1 work and needs a pull request through `workspace`, like any code.

## Resources per phase

| Resource | Phase 1 and 2 | Phase 3 | Why |
|---|---|---|---|
| VPC and subnet | default VPC, subnet in a zone that offers G7e (data sources) | dedicated VPC module, two replicas in one AZ | Fewer resources to create and destroy for one instance; phase 3 needs private addressing between router and replicas. Whether the account still has a default VPC in the chosen region is Unknown |
| Internet access | public IP on the instance, outbound only | public IP or NAT; S3 gateway endpoint | Needs ghcr.io, the Hugging Face Hub and the SSM endpoints. A NAT gateway costs per hour (price not read) |
| Security group | no inbound rules; all outbound | plus port 8000 from the router's group; self-referencing all-traffic only if EFA is added | Bench runs on `localhost`; access through SSM Session Manager |
| IAM role and instance profile | `AmazonSSMManagedInstanceCore` plus read on the weights prefix and write on the results prefix | same | No keys on the instance (`security-and-cost-guardrails.md`) |
| Launch template | yes | yes | IMDSv2, user data, block devices, tags in one versioned object |
| `aws_instance` from the template | one | two (or one `g7e.48xlarge`) | Plain EC2, no Auto Scaling group: one or two hand-launched instances, no scheduler (docs/06) |
| Kernel cache volume | gp3, created empty, attached at `/dev/sdf` | one per replica | Keeps `/cache` between runs (`storage-for-weights.md`) |
| Placement group | none | none | No EFA; a cluster group could make a launch fail for capacity (Inferred) |
| Budget and alarm | yes (`aws_budgets_budget`) | yes | `security-and-cost-guardrails.md` |

Phase 5 (EKS or not, Auto Scaling, custom AMI) is out of this layout.

## Launch template settings

Reported, provider doc `launch_template.html.markdown`, read 2026-11-12, unless marked.

| Setting | Value | Why |
|---|---|---|
| `image_id` | from `data "aws_ssm_parameter"` on `/aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-ubuntu-24.04/latest/ami-id`, then pinned: write the resolved AMI ID into `terraform.tfvars` for the phase | The DLAMI lists G7e and ships driver, Docker and the NVIDIA container toolkit (Reported, `g7e-instance.md`). Pinning keeps the driver fixed across runs (rule 2 of `CLAUDE.md`) |
| `instance_type` | `g7e.24xlarge` | One replica |
| `metadata_options.http_tokens` | `"required"` | IMDSv2 only; the provider default is `"optional"` |
| `metadata_options.http_put_response_hop_limit` | 2 | Lets a container reach IMDS if the harness ever runs in Docker on the host (Inferred; default is 1) |
| `instance_initiated_shutdown_behavior` | `"terminate"` | A `shutdown` from inside (the watchdog in user data) then terminates instead of stopping. The provider default is `"stop"`; a stopped instance still bills its EBS volumes |
| `block_device_mappings` root | gp3, 300 GiB, `delete_on_termination = true`, encrypted | OS, Docker data root (30.6 GB image), logs |
| `block_device_mappings` instance store | not listed at first | The DLAMI reports instance store mounted at `/opt/dlami/nvme` (Reported, release notes). Whether G7e needs an explicit `virtual_name = "ephemeral0"` mapping to expose both NVMe devices was not read (Unknown); check `lsblk` on the first instance and add mappings only if devices are missing |
| `iam_instance_profile.name` | the profile from `iam.tf` | |
| `network_interfaces` | one, `device_index = 0`, `associate_public_ip_address = true`, `security_groups`, `delete_on_termination = true` | Phase 1; EFA interfaces only if a later decision adds them (`networking-and-efa.md`) |
| `user_data` | `base64encode(templatefile("user-data/replica.sh.tftpl", {...}))` | "The base64-encoded user data" |
| `tag_specifications` | `instance` and `volume` with the project tags | The provider says it can tag "instances, volumes, elastic GPUs and spot instance requests" |

Provider default tags: set `default_tags` in the provider block. The launch template doc warns that default tags are "currently not propagated to ASG created resources"; there is no ASG here, but keep `tag_specifications` anyway so volumes carry tags (Inferred).

Instance purchase: no `instance_market_options` (On-Demand). See `quotas-and-purchase.md`.

## Tags

Every resource gets (proposal):

| Key | Example | Use |
|---|---|---|
| `project` | `infer` | Budget filter and teardown sweep |
| `phase` | `phase-1` | Which phase created it |
| `owner` | a person's handle, not an email | Who tears it down |
| `run-id` | `2026-11-20-a` | Ties the instance to a result directory |
| `expires-at` | ISO timestamp | Read by the watchdog and the sweep |
| `managed-by` | `terraform` | Separates code-made from hand-made resources |

Activate `project` and `phase` as cost allocation tags in the Billing console so budgets can filter on them (activation is an account change; confirm first).

## Startup script steps

The user data runs once at first boot as root. Draft: `../examples/user-data-phase-1.sh.tftpl`. Steps and the reason for each:

1. `set -euo pipefail`, log everything to `/var/log/infer-bootstrap.log`, and write a step marker file after each step. Why: on Nebius, a start script with an empty log let a VM sit for 6 h 8 min (§25.3); markers show where it stopped.
2. Watchdog: `shutdown -h +<max_minutes>` scheduled first. With `instance_initiated_shutdown_behavior = "terminate"` the instance terminates itself if nobody does it (Inferred from the provider doc and AWS shutdown behaviour). Why: the forgotten-VM incident above.
3. Driver check: `nvidia-smi` must list 4 GPUs named `NVIDIA RTX PRO 6000 Blackwell Server Edition`; record the driver version. Do not stop on a driver below 615.65.02; record it and let qualification decide (`g7e-instance.md`).
4. Host record: `nvidia-smi`, `nvidia-smi topo -m`, `nvidia-smi topo -p2p r`, `grep RegistryDwords /proc/driver/nvidia/params`, `nproc`, `free -g`, `lsblk`, `df -h`. Same content as `bench/vast/prepare_host.sh` step 1.
5. Storage: confirm the instance store mount (`/opt/dlami/nvme`); if two devices are not striped, build RAID 0. Format and mount the kernel cache volume if it is empty, mount it at `/cache`.
6. Docker and NVIDIA container toolkit: present in the DLAMI (Reported). Check `docker info` and `docker run --rm --gpus all <image> nvidia-smi`. If preparing images on another machine, `{"features":{"containerd-snapshotter":false}}` in `daemon.json` keeps the image under `data-root` (§25.3).
7. Pull the image by its pinned tag and time it.
8. Fetch weights at the pinned revision into the Hugging Face cache layout on NVMe (`hf download local-inference-lab/GLM-5.3-Flash-NVFP4-MXFP8-CSF-QAD --revision dec48abd33efa73c3bb7c95b74eee10cad34f9be`), create `refs/main` (§25.3), time it. `HF_TOKEN` comes from the environment of the session that runs it, never from user data.
9. Clone this repository at a pinned commit, run `bench/setup_bench.sh` (pins `llm-inference-bench` at `52216d70865a015b34689626d04a80b89c9dc45f`), build the bench venv.
10. Run the all-reduce microbenchmark (`llm_decode_bench.py --p2pmark-only --p2pmark-max-gpus 4 --p2pmark-mode allreduce`).
11. Start the server and run the bench: `ENGINE=vllm IMAGE=... SERVER_SCRIPT=server-vllm-dcp1.sh LAUNCH_MODE=docker bash run_benchmark.sh` from `bench/`.
12. Copy the result directory to the results prefix in S3 and write a `done` marker. Do not terminate from the script when the run fails: a person reads the logs first, and the watchdog still bounds the cost.

Recommendation (Inferred): keep steps 1 to 8 in user data, and run steps 9 to 12 by hand over SSM for phase 1, because phase 1 is the first contact and each step's output has to be read. Automate steps 9 to 12 once phase 1 has passed.

## What the first `terraform plan` must confirm

| Question | How |
|---|---|
| Provider accepts gp3 `throughput` above 1,000 MiB/s (its doc says 1,000; EBS says 2,000) | `terraform plan` with 2,000 |
| Default VPC exists in the chosen region | `data "aws_vpc" "default"` |
| Subnet zone offers `g7e.24xlarge` | `aws ec2 describe-instance-type-offerings` before choosing `availability_zone` |
| DLAMI SSM parameter resolves in the region | `data "aws_ssm_parameter"` in plan output |
| The plan creates only tagged resources | read the plan; every resource shows `project`, `phase`, `owner` |

`terraform plan` is free and is not covered by the paid-actions hook; `terraform apply` is, and needs Paulo's confirmation with the hourly price and teardown plan (project rule 6).
