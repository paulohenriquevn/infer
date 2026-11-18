# Illustrative, not applied, not tested.
# Partial configuration: bucket, key and region come from a git-ignored backend.hcl:
#   terraform init -backend-config=backend.hcl
# backend.hcl example (values are placeholders):
#   bucket       = "<state-bucket-name>"
#   key          = "infer/phase-1/terraform.tfstate"
#   region       = "us-east-1"
#   use_lockfile = true
#   encrypt      = true
terraform {
  backend "s3" {}
}
