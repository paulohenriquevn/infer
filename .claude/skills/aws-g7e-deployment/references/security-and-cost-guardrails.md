# Security and cost guardrails

Rules for credentials, tags, budgets and teardown on AWS, with the incident or source behind each. They apply to every phase.

Labels: Reported (URL and read date), Observed (our incident or measurement, source given), Inferred (reasoning shown), Unknown.

## Credentials

| Rule | How | Why |
|---|---|---|
| No access keys anywhere in the repository, Terraform files, `terraform.tfvars`, user data, logs or result files | People use short-lived IAM Identity Center sessions in their shell; Terraform reads them from the environment | Terraform's S3 backend page: hardcoded values end up "in both the `.terraform` subdirectory and in plan files" (Reported, `https://developer.hashicorp.com/terraform/language/backend/s3`, read 2026-11-12). On this project a provider key that appeared in a conversation had to be revoked (Observed, `NOTAS.md`, project research notes, not published) |
| The instance gets AWS access only through its instance profile | IAM role with least privilege: `AmazonSSMManagedInstanceCore`, read on the weights prefix, write on the results prefix | AWS: roles let applications "securely make API requests from your instances, without requiring you to manage the security credentials"; "You can only attach one IAM role to an instance" (Reported, `https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/iam-roles-for-amazon-ec2.html`, read 2026-11-12) |
| IMDSv2 only | `metadata_options { http_tokens = "required" }`; the provider default is `"optional"` | Instance profile credentials are served by IMDS; requiring session tokens is the hardened mode (Reported, provider launch template doc, read 2026-11-12) |
| Third-party tokens (Hugging Face, GitHub) stay out of user data | Pass `HF_TOKEN` only in the interactive session that runs the download, or store it in Secrets Manager and resolve it at runtime (load the `aws-secrets-manager` guidance first; never print it) | User data is readable by anyone with `ec2:DescribeInstanceAttribute` and is kept with the instance (Inferred). On Nebius a 12-hour token was passed only through an environment variable and never written to a file or state (Observed, `NOTAS.md`) |
| No inbound ports | Security group without inbound rules; access with SSM Session Manager | Nothing in phases 1 and 2 needs inbound traffic: the harness calls `localhost:8000` (Observed in `bench/run_benchmark.sh`, `PORT` default 8000) |
| No account IDs, profile names, quota request IDs or support case IDs in versioned files | Pass them through `backend.hcl`, `terraform.tfvars` and the environment, all git-ignored | The repository is open source |
| Root user never used | Identity Center role only | AWS account hygiene; also the user's standing rule |

The AWS MCP server or the AWS CLI may be used to read account state; every mutating call is confirmed first (project rule 6).

## Tags

Every resource carries `project`, `phase`, `owner`, `run-id`, `expires-at`, `managed-by` (definitions in `terraform-layout.md`). Set them in the provider's `default_tags` and in the launch template's `tag_specifications` for instances and volumes.

Why: on Nebius a resource sweep failed silently and reported "0 resources" because zsh did not split `nebius $cmd` into words (Observed, §25.3). A tag gives one filter that finds everything the project created; a sweep that prints its errors makes leftovers visible (Inferred).

Activate `project` and `phase` as cost allocation tags so the budget and Cost Explorer can filter on them. Tags only appear in billing data after activation and for usage after that point (Inferred from how cost allocation tags work; the activation page was not read, Unknown delay).

## Budgets and alarms

Reported, `https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-managing-costs.html`, read 2026-11-12:

- "AWS Budgets information is updated up to three times a day." Updates typically come 8 to 12 hours after the previous one (paraphrased).
- "There can be a delay between when you incur a charge and when you receive a notification ... You might incur additional costs or usage that exceed your budget notification threshold before AWS Budgets can notify you."
- Alerts can be on actual or forecasted cost, by email or SNS.
- Budget actions can, for example, "automatically apply a custom IAM policy that denies you the ability to provision additional resources".

What follows (Inferred):

- A budget cannot stop a run that is going wrong today. A `g7e.24xlarge` costs US$ 16.57/h (2026-11-04); 12 hours of lag is about US$ 200 before the first alert. The same lesson came from Nebius, whose budgets "only email and update every few hours" (Observed, §12.6, §25.5).
- The guard that bounds a single run is on the instance: the watchdog `shutdown -h +<minutes>` with `instance_initiated_shutdown_behavior = "terminate"` (`terraform-layout.md`). Set it to the planned duration plus margin (240 min proposed for phase 1).
- A second guard: a CloudWatch alarm on the instance's `CPUUtilization` below a low threshold for a long period, with the EC2 terminate action, catches an idle forgotten instance. GPU utilization is not a default EC2 metric (it needs the CloudWatch agent or DCGM exporter), so this alarm sees only CPU (Inferred; alarm thresholds Unknown until phase 1 shows idle CPU levels).
- Budgets still matter for the month: one monthly cost budget for the project, alerts at 50% and 80% actual and 100% forecast, sent to the owner and Paulo.

## Teardown checks

Pass or fail, the run ends with teardown and a written check. Steps are in `runbook-phase-1.md` section 7. The rules behind them:

| Rule | Why |
|---|---|
| Destroy test instances when the run ends, then confirm zero instances, volumes, snapshots, Elastic IPs and network interfaces with the project tag | docs/05 process lesson; the report states it explicitly |
| A teardown command exiting 0 is not proof; read its output and list what remains | `vastai destroy` printed "Aborted." with exit code 0 (Observed, §28.2) |
| Tear down when the startup log is empty instead of waiting | A wait loop with `pgrep -f name` inside an `ssh` command containing `name` matched itself; the VM ran 6 h 8 min with no result, about US$ 88 (Observed, §25.3) |
| Use `terraform destroy`, then the tag sweep | Resources created by hand or by a failed apply are not in state (Inferred) |
| Stopped is not gone | A stopped instance still bills its EBS volumes; the instance store is erased on stop (Reported, instance store lifetime page) |
| Check billing the next day, in the console | Local estimates overshot reality on Nebius (§12.6, §25.5); Budgets lags 8 to 12 hours (Reported) |
| Write the actual cost next to the estimate | Calibrates the next estimate (Inferred) |

## Scripts on the instance

Two shell pitfalls already cost time on other providers (Observed):

- A `set -e` start script aborted on a repeated `mount`; the B300 sat idle about 15 min (§12.6). Make mounts idempotent (`mountpoint -q /cache || mount ...`).
- `a && b || c` runs `c` when `b` fails, and also reported failure on success in our script (§25.3). Use `if ...; then ...; else ...; fi`.
