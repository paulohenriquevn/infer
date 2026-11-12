# Illustrative, not applied, not tested.

variable "region" {
  description = "AWS region with G7e capacity and quota (us-east-1 was the only region with known zones on 2026-11-04)."
  type        = string
}

variable "availability_zone" {
  description = "Zone that offers g7e.24xlarge (check with describe-instance-type-offerings)."
  type        = string
}

variable "ami_id" {
  description = "Resolved DLAMI Base OSS Nvidia Driver GPU AMI (Ubuntu 24.04), pinned for the whole phase."
  type        = string
}

variable "instance_type" {
  description = "One replica is one g7e.24xlarge (4 GPUs)."
  type        = string
  default     = "g7e.24xlarge"
}

variable "root_volume_gib" {
  description = "Root gp3 size: OS, Docker data root (30.6 GB uncompressed image), logs."
  type        = number
  default     = 300
}

variable "cache_volume_gib" {
  description = "Persistent gp3 volume mounted at /cache for the kernel (JIT) cache."
  type        = number
  default     = 200
}

variable "max_runtime_minutes" {
  description = "Watchdog: the instance shuts down (and terminates) after this many minutes."
  type        = number
  default     = 240
}

variable "results_bucket" {
  description = "Bucket that receives result directories. Name kept out of git (terraform.tfvars)."
  type        = string
}

variable "results_prefix" {
  description = "Prefix inside results_bucket the instance may write to."
  type        = string
  default     = "infer/results/"
}

variable "owner" {
  description = "Handle of the person who tears this down. Not an email."
  type        = string
}

variable "run_id" {
  description = "Ties the instance to a result directory, e.g. 2026-11-20-a."
  type        = string
}

variable "expires_at" {
  description = "ISO 8601 timestamp after which the sweep may delete anything left."
  type        = string
}

variable "budget_limit_usd" {
  description = "Monthly cost budget for the project."
  type        = string
  default     = "200"
}

variable "budget_emails" {
  description = "Addresses that receive budget alerts. Kept in terraform.tfvars, not in git."
  type        = list(string)
}
