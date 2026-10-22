# Story 6-2b — the committed staging terraform.tfvars, planned through the
# module against MOCK providers (no AWS): the tfvars load automatically; only
# the three REPLACE_ME account values are supplied here. Run:
# `terraform init -backend=false && terraform test` in infra/envs/staging.

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

run "staging_decisions" {
  command = plan

  assert {
    condition     = var.api_desired_count == 1 && !var.api_autoscaling && var.web_desired_count == 1
    error_message = "Staging runs 1 API task without autoscaling and 1 web task (decision 5, A14)."
  }

  assert {
    condition     = var.api_cpu == 512 && var.api_memory == 1024
    error_message = "Staging's API is 0.5 vCPU / 1 GB (decision 5)."
  }

  assert {
    condition     = !var.db_multi_az && !var.db_deletion_protection && !var.db_final_snapshot && var.db_backup_retention_days == 7 && var.db_instance_class == "db.t4g.small"
    error_message = "Staging RDS: single-AZ, no deletion protection or final snapshot, 7-day backups, db.t4g.small (decision 6, A14)."
  }

  assert {
    condition     = var.valkey_num_nodes == 1 && var.valkey_node_type == "cache.t4g.micro" && var.valkey_snapshot_retention_days == 1
    error_message = "Staging Valkey: 1 cache.t4g.micro node, 1-day snapshots (decision 6, A14)."
  }

  assert {
    condition     = var.secret_recovery_window_days == 0 && var.log_retention_days == 30 && var.ledger_anchor_retention_days == 1
    error_message = "Staging: immediate secret deletion, 30-day logs, 1-day anchors (A14, A15)."
  }

  assert {
    condition     = !var.nat_gateway_per_az && !var.interface_endpoints && !var.alb_deletion_protection && !var.alb_access_logs
    error_message = "Staging: one NAT, no interface endpoints, no ALB deletion protection or access logs (decision 3, A14)."
  }

  assert {
    condition     = output.app_url == "https://app.staging.example.in" && output.api_base_url == "https://api.staging.example.in/api/v1"
    error_message = "Staging serves app.staging.<domain> / api.staging.<domain>."
  }
}
