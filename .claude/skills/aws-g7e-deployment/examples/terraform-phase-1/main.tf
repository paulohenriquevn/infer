# Illustrative, not applied, not tested.

provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }
}

locals {
  tags = {
    project    = "infer"
    phase      = "phase-1"
    owner      = var.owner
    run-id     = var.run_id
    expires-at = var.expires_at
    managed-by = "terraform"
  }
}

# Network: default VPC for one instance (phase 1 and 2).
data "aws_vpc" "default" {
  default = true
}

data "aws_subnet" "selected" {
  vpc_id            = data.aws_vpc.default.id
  availability_zone = var.availability_zone
  default_for_az    = true
}

# No inbound rules: access through SSM Session Manager, the bench calls localhost.
resource "aws_security_group" "replica" {
  name_prefix = "infer-replica-"
  description = "infer replica, no inbound"
  vpc_id      = data.aws_vpc.default.id

  egress {
    description = "Outbound for ghcr.io, Hugging Face Hub, S3 and SSM"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Instance role: SSM plus write to the results prefix. No access keys on the instance.
data "aws_iam_policy_document" "assume_ec2" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "replica" {
  name_prefix        = "infer-replica-"
  assume_role_policy = data.aws_iam_policy_document.assume_ec2.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.replica.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "results" {
  statement {
    actions   = ["s3:PutObject"]
    resources = ["arn:aws:s3:::${var.results_bucket}/${var.results_prefix}*"]
  }
  statement {
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.results_bucket}"]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${var.results_prefix}*"]
    }
  }
}

resource "aws_iam_role_policy" "results" {
  name   = "results-write"
  role   = aws_iam_role.replica.id
  policy = data.aws_iam_policy_document.results.json
}

resource "aws_iam_instance_profile" "replica" {
  name_prefix = "infer-replica-"
  role        = aws_iam_role.replica.name
}

resource "aws_launch_template" "replica" {
  name_prefix   = "infer-replica-"
  image_id      = var.ami_id
  instance_type = var.instance_type

  # A shutdown from inside (the watchdog) terminates instead of stopping.
  instance_initiated_shutdown_behavior = "terminate"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  iam_instance_profile {
    name = aws_iam_instance_profile.replica.name
  }

  network_interfaces {
    device_index                = 0
    subnet_id                   = data.aws_subnet.selected.id
    security_groups             = [aws_security_group.replica.id]
    associate_public_ip_address = true
    delete_on_termination       = true
  }

  block_device_mappings {
    # Root device name of the DLAMI; check with describe-images before plan.
    device_name = "/dev/sda1"
    ebs {
      volume_type           = "gp3"
      volume_size           = var.root_volume_gib
      encrypted             = true
      delete_on_termination = true
    }
  }

  user_data = base64encode(templatefile("${path.module}/../user-data-phase-1.sh.tftpl", {
    max_runtime_minutes = var.max_runtime_minutes
    cache_volume_id     = aws_ebs_volume.kernel_cache.id
    results_uri         = "s3://${var.results_bucket}/${var.results_prefix}${var.run_id}/"
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = local.tags
  }

  tag_specifications {
    resource_type = "volume"
    tags          = local.tags
  }
}

# The zone comes from the launch template's subnet.
resource "aws_instance" "replica" {
  launch_template {
    id      = aws_launch_template.replica.id
    version = aws_launch_template.replica.latest_version
  }
}

# Kernel cache: created empty (no snapshot), so it needs no initialization.
resource "aws_ebs_volume" "kernel_cache" {
  availability_zone = var.availability_zone
  type              = "gp3"
  size              = var.cache_volume_gib
  encrypted         = true
}

resource "aws_volume_attachment" "kernel_cache" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.kernel_cache.id
  instance_id = aws_instance.replica.id
}

# Monthly budget. Data lags 8 to 12 hours; the watchdog is the per-run guard.
resource "aws_budgets_budget" "project" {
  name         = "infer-monthly"
  budget_type  = "COST"
  limit_amount = var.budget_limit_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:project$infer"]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = var.budget_emails
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = var.budget_emails
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = var.budget_emails
  }
}
