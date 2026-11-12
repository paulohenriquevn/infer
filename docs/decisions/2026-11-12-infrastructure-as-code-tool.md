# Infrastructure as code tool: Terraform

Date: 2026-11-12. Status: decided.

## Context

`06-aws-implementation-plan.md` left the IaC tool open and said to pick it before the first line of infrastructure code. Phase 1 needs one `g7e.24xlarge`, a security group, a disk for weights and tags.

## Options

| Option | For | Against |
|---|---|---|
| Terraform | The Nebius environments of this project are already Terraform (`f3/rtx/`, `f3/b300/`, `f3/terraform/`, Observed). One language for every provider we priced (Nebius and AWS have providers; Vast.ai has none in either tool). The same team's other AWS repositories use Terraform (Reported by the project owner) | State has to be stored and locked (an S3 backend) |
| AWS CDK | Higher-level constructs, CloudFormation handles state | AWS only, so Nebius would stay in a second tool; no CDK code exists in the project |

## Decision

Terraform for all infrastructure, with remote state in S3 and locking. Plain EC2 for phases 1 to 3, as `06-aws-implementation-plan.md` recommends.

## Why

The project already has working Terraform, and keeping a second provider open (Nebius lists the same GPU at US$ 1.80 per GPU-hour against US$ 4.14 for AWS on-demand, both read in November 2026) argues for a tool that covers both. Inferred from the facts above.

## What would make us revisit it

Moving the whole serving stack to a managed AWS service that is configured mainly through CDK constructs, or a team decision to standardize on CDK.
