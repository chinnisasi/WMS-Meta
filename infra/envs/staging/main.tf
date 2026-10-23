# Story 6-2b — the staging environment: a thin root over modules/environment.
# Sizes and flags live in terraform.tfvars.
terraform {
  required_version = ">= 1.10, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region              = "ap-south-1"
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = {
      project      = "wms"
      env          = "staging"
      "managed-by" = "terraform"
    }
  }
}

module "environment" {
  source = "../../modules/environment"

  environment     = "staging"
  account_id      = var.account_id
  domain          = var.domain
  route53_zone_id = var.route53_zone_id

  vpc_cidr                       = var.vpc_cidr
  nat_gateway_per_az             = var.nat_gateway_per_az
  interface_endpoints            = var.interface_endpoints
  alb_deletion_protection        = var.alb_deletion_protection
  alb_access_logs                = var.alb_access_logs
  api_cpu                        = var.api_cpu
  api_memory                     = var.api_memory
  api_desired_count              = var.api_desired_count
  api_autoscaling                = var.api_autoscaling
  api_max_count                  = var.api_max_count
  web_desired_count              = var.web_desired_count
  log_retention_days             = var.log_retention_days
  ledger_anchor_retention_days   = var.ledger_anchor_retention_days
  db_instance_class              = var.db_instance_class
  db_multi_az                    = var.db_multi_az
  db_backup_retention_days       = var.db_backup_retention_days
  db_deletion_protection         = var.db_deletion_protection
  db_final_snapshot              = var.db_final_snapshot
  valkey_node_type               = var.valkey_node_type
  valkey_num_nodes               = var.valkey_num_nodes
  valkey_snapshot_retention_days = var.valkey_snapshot_retention_days
  secret_recovery_window_days    = var.secret_recovery_window_days
  push_gateway                   = var.push_gateway
  eway_gateway                   = var.eway_gateway
}

output "deploy_role_arn" {
  description = "Set as the repository variable AWS_DEPLOY_ROLE_ARN_STAGING — after the GitHub environment's protection rules exist."
  value       = module.environment.deploy_role_arn
}

output "app_url" {
  description = "The web."
  value       = module.environment.app_url
}

output "api_base_url" {
  description = "The API base."
  value       = module.environment.api_base_url
}

output "out_of_band_secret_names" {
  description = "Set each before the first deploy (DEPLOY.md §AWS)."
  value       = module.environment.out_of_band_secret_names
}
