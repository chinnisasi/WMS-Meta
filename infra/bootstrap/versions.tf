# Story 6-2b — the state bucket every other stack keeps its state in.
#
# The first apply runs on LOCAL state: create `local_override.tf` (git-ignored)
# holding `terraform { backend "local" {} }`, apply, then delete it and migrate
# the state into the bucket it just made (infra/README.md, "Bootstrap").
terraform {
  required_version = ">= 1.10, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Partial configuration: bucket, region and key come from
  # `-backend-config=` at init (infra/README.md). Native S3 locking, no DynamoDB.
  backend "s3" {}
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      project      = "wms"
      env          = "shared"
      "managed-by" = "terraform"
    }
  }
}
