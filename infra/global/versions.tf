# Story 6-2b — what both environments share in the one account (A11): the ECR
# repositories, the GitHub OIDC provider and the SES identity for <domain>.
# Apply after bootstrap, before either environment (infra/README.md).
terraform {
  required_version = ">= 1.10, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Partial: -backend-config="bucket=wms-tfstate-<account>-ap-south-1"
  #          -backend-config="key=global/terraform.tfstate"
  #          -backend-config="region=ap-south-1" -backend-config="use_lockfile=true"
  backend "s3" {}
}

provider "aws" {
  region              = var.region
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = {
      project      = "wms"
      env          = "shared"
      "managed-by" = "terraform"
    }
  }
}
