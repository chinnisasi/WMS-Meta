# Story 6-2b — the committed production terraform.tfvars, planned through the
# module against MOCK providers (no AWS): the tfvars load automatically; only
# the three REPLACE_ME account values are supplied here. Run:
# `terraform init -backend=false && terraform test` in infra/envs/production.

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{}"
    }
  }

  mock_data "aws_ecr_repository" {
    defaults = {
      arn            = "arn:aws:ecr:ap-south-1:123456789012:repository/mock"
      repository_url = "123456789012.dkr.ecr.ap-south-1.amazonaws.com/mock"
    }
  }

  mock_data "aws_iam_openid_connect_provider" {
    defaults = {
      arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    }
  }
}

mock_provider "random" {
  mock_resource "random_password" {
    defaults = {
      result = "mockmockmockmockmockmockmockmockmockmock"
    }
  }
}

variables {
  account_id      = "123456789012"
  domain          = "example.in"
  route53_zone_id = "Z0123456789ABC"
}

run "production_decisions" {
  command = plan

  assert {
    condition     = var.api_desired_count >= 2 && var.api_autoscaling && var.api_max_count == 6 && var.web_desired_count == 2
    error_message = "Production runs >= 2 API tasks, autoscaling to 6, and 2 web tasks (decision 5, A14)."
  }

  assert {
    condition     = var.api_cpu == 1024 && var.api_memory == 2048
    error_message = "Production's API is 1 vCPU / 2 GB (decision 5)."
  }

  assert {
    condition     = var.db_multi_az && var.db_deletion_protection && var.db_final_snapshot && var.db_backup_retention_days == 14 && var.db_instance_class == "db.t4g.medium"
    error_message = "Production RDS: Multi-AZ, deletion protection, a final snapshot, 14-day backups, db.t4g.medium (decision 6)."
  }

  assert {
    condition     = var.valkey_num_nodes == 2 && var.valkey_node_type == "cache.t4g.small" && var.valkey_snapshot_retention_days == 7
    error_message = "Production Valkey: 2 cache.t4g.small nodes, 7-day snapshots (decision 6, A14)."
  }

  assert {
    condition     = var.secret_recovery_window_days == 7 && var.log_retention_days == 90 && var.ledger_anchor_retention_days == 2557
    error_message = "Production: 7-day secret recovery, 90-day logs, 2557-day anchors (A14, decision 8)."
  }

  assert {
    condition     = var.nat_gateway_per_az && var.interface_endpoints && var.alb_deletion_protection && var.alb_access_logs
    error_message = "Production: a NAT per AZ, interface endpoints, ALB deletion protection and access logs (decision 3, A14)."
  }

  assert {
    condition     = output.app_url == "https://app.example.in" && output.api_base_url == "https://api.example.in/api/v1"
    error_message = "Production serves app.<domain> / api.<domain>."
  }
}
