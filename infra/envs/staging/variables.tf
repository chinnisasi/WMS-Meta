# Identical in both roots; the values are in terraform.tfvars.

variable "account_id" {
  description = "The one AWS account (A11)."
  type        = string
}

variable "domain" {
  description = "The registrable domain (global's var.domain)."
  type        = string
}

variable "route53_zone_id" {
  description = "The Route 53 zone for var.domain."
  type        = string
}

variable "vpc_cidr" {
  description = "The environment's VPC /16."
  type        = string
}

variable "nat_gateway_per_az" {
  description = "One NAT per AZ (production) or one shared (staging)."
  type        = bool
}

variable "interface_endpoints" {
  description = "ECR / Secrets Manager / Logs interface endpoints (production)."
  type        = bool
}

variable "alb_deletion_protection" {
  description = "ALB deletion protection (production)."
  type        = bool
}

variable "alb_access_logs" {
  description = "ALB access logs to S3 (production)."
  type        = bool
}

variable "api_cpu" {
  description = "API vCPU units."
  type        = number
}

variable "api_memory" {
  description = "API memory, MiB."
  type        = number
}

variable "api_desired_count" {
  description = "API tasks (>= 2 in production)."
  type        = number
}

variable "api_autoscaling" {
  description = "API CPU autoscaling. Pass -var api_autoscaling=false on an environment's FIRST apply (infra/README.md)."
  type        = bool
}

variable "api_max_count" {
  description = "API autoscaling ceiling."
  type        = number
}

variable "web_desired_count" {
  description = "Web tasks."
  type        = number
}

variable "log_retention_days" {
  description = "CloudWatch log retention."
  type        = number
}

variable "ledger_anchor_retention_days" {
  description = "Ledger anchor Object Lock retention (1 staging, 2557 production)."
  type        = number
}

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
}

variable "db_multi_az" {
  description = "Multi-AZ RDS."
  type        = bool
}

variable "db_backup_retention_days" {
  description = "RDS backup retention."
  type        = number
}

variable "db_deletion_protection" {
  description = "RDS deletion protection."
  type        = bool
}

variable "db_final_snapshot" {
  description = "Named final snapshot on destroy."
  type        = bool
}

variable "valkey_node_type" {
  description = "Valkey node type."
  type        = string
}

variable "valkey_num_nodes" {
  description = "Valkey nodes (2 = Multi-AZ failover)."
  type        = number
}

variable "valkey_snapshot_retention_days" {
  description = "Valkey snapshot retention."
  type        = number
}

variable "secret_recovery_window_days" {
  description = "Secrets Manager recovery window (0 staging, 7 production)."
  type        = number
}

variable "push_gateway" {
  description = "PUSH_GATEWAY on the worker: unconfigured | expo."
  type        = string
}

variable "eway_gateway" {
  description = "EWAY_GATEWAY: unconfigured | sandbox."
  type        = string
}
