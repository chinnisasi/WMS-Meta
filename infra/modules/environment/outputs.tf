output "deploy_role_arn" {
  description = "Set as the repository variable AWS_DEPLOY_ROLE_ARN_<ENV> — AFTER the GitHub environment's protection rules exist (DEPLOY.md §AWS)."
  value       = aws_iam_role.deploy.arn
}

output "app_url" {
  description = "The web."
  value       = local.web_origin
}

output "api_base_url" {
  description = "The API base the browser calls (WMS_API_BASE_URL)."
  value       = local.api_base_url
}

output "cluster_name" {
  description = "The ECS cluster."
  value       = aws_ecs_cluster.this.name
}

output "db_endpoint" {
  description = "The RDS endpoint (host:port)."
  value       = aws_db_instance.this.endpoint
}

output "out_of_band_secret_names" {
  description = "Secrets Terraform creates with NO value: set each before the first deploy (DEPLOY.md §AWS)."
  value       = sort([for secret in aws_secretsmanager_secret.out_of_band : secret.name])
}

output "ledger_anchor_bucket" {
  description = "The Object Lock bucket for the ledger anchors."
  value       = aws_s3_bucket.ledger_anchors.id
}
