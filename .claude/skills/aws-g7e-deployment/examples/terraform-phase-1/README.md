# Terraform skeleton for phase 1

Illustrative only. Not applied, not planned, not tested against any account or provider version. It shows the shape proposed in `../../references/terraform-layout.md`; the real code goes in `infra/aws/` through a pull request, and the first `terraform plan` decides whether it is right.

Files:

- `versions.tf`: Terraform and AWS provider pins (versions read 2026-11-12, see the layout reference).
- `backend.tf`: S3 backend with `use_lockfile`; everything account-specific comes from a git-ignored `backend.hcl`.
- `variables.tf`: inputs, with no account IDs or bucket names as defaults.
- `main.tf`: default VPC lookup, security group without inbound rules, instance role and profile, launch template, one instance, kernel cache volume, budget.
- `outputs.tf`: instance ID and the SSM command.
- `terraform.tfvars.example`: placeholders to copy into a git-ignored `terraform.tfvars`.

Known gaps (Unknown until a plan runs): whether provider v6.73.0 accepts gp3 throughput above 1,000 MiB/s; whether the chosen region still has a default VPC; whether the NVMe instance store needs explicit mappings on G7e.

Running `terraform apply` on this creates a `g7e.24xlarge` at about US$ 16.57/h (2026-11-04 price). It needs Paulo's confirmation (project rule 6).
