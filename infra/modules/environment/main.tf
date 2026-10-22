locals {
  name          = "wms-${var.environment}"
  is_production = var.environment == "production"

  # The cookie rule: both hosts under one registrable domain.
  host_prefix = local.is_production ? "" : "staging."
  app_host    = "app.${local.host_prefix}${var.domain}"
  api_host    = "api.${local.host_prefix}${var.domain}"

  web_origin       = "https://${local.app_host}"
  api_base_url     = "https://${local.api_host}/api/v1"
  api_ready_url    = "https://${local.api_host}/api/v1/health/ready"
  ses_identity     = coalesce(var.ses_identity_domain, var.domain)
  ses_identity_arn = "arn:aws:ses:${var.region}:${var.account_id}:identity/${local.ses_identity}"

  ecs_cluster_arn = "arn:aws:ecs:${var.region}:${var.account_id}:cluster/${local.name}"
}

# global's repositories and OIDC provider. Read, never created here: a plan
# before global is applied fails at these lookups (stack order, A11).
data "aws_ecr_repository" "be" {
  name = "wms-be"
}

data "aws_ecr_repository" "fe" {
  name = "wms-fe"
}

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}
