# Story 6-2b — everything one environment (staging or production) needs.
# Every value that differs between the two is a variable set in
# infra/envs/<env>/terraform.tfvars (Boundaries).

# ── identity ────────────────────────────────────────────────────────────────

variable "environment" {
  description = "staging or production."
  type        = string

  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "environment must be staging or production."
  }
}

variable "region" {
  description = "The one AWS region (D6)."
  type        = string
  default     = "ap-south-1"

  validation {
    condition     = var.region == "ap-south-1"
    error_message = "WMS runs in ap-south-1 only (D6)."
  }
}

variable "account_id" {
  description = "The one AWS account for both environments (A11)."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be the 12-digit AWS account ID (replace the REPLACE_ME placeholder)."
  }
}

variable "domain" {
  description = "The registrable domain (global's var.domain). Production serves app.<domain> / api.<domain>; staging app.staging.<domain> / api.staging.<domain> — one site, so the SameSite=Strict refresh cookie works (the cookie rule)."
  type        = string

  validation {
    condition     = can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", var.domain))
    error_message = "domain must be a lower-case DNS name such as example.in (replace the REPLACE_ME placeholder)."
  }
}

variable "route53_zone_id" {
  description = "The Route 53 public hosted zone for var.domain: the ACM validation and the app/api records go in it."
  type        = string

  validation {
    condition     = can(regex("^Z[A-Z0-9]+$", var.route53_zone_id))
    error_message = "route53_zone_id must be a Route 53 zone ID (replace the REPLACE_ME placeholder)."
  }
}

variable "github_repository" {
  description = "owner/repo whose deploy workflow may assume this environment's deploy role (only from the GitHub environment of the same name)."
  type        = string
  default     = "chinnisasi/WMS-Meta"
}

# ── network ─────────────────────────────────────────────────────────────────

variable "vpc_cidr" {
  description = "The environment's VPC range (a /16; subnets are /24s carved from it)."
  type        = string

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && endswith(var.vpc_cidr, "/16")
    error_message = "vpc_cidr must be a /16, e.g. 10.20.0.0/16."
  }
}

variable "availability_zones" {
  description = "Exactly two AZs (decision 3)."
  type        = list(string)
  default     = ["ap-south-1a", "ap-south-1b"]

  validation {
    condition     = length(var.availability_zones) == 2
    error_message = "availability_zones must name exactly two AZs."
  }
}

variable "nat_gateway_per_az" {
  description = "One NAT gateway per AZ (production) or one shared (staging). The tasks need outbound for Expo push, channel APIs and e-way."
  type        = bool
}

variable "interface_endpoints" {
  description = "Interface endpoints for ECR (api, dkr), Secrets Manager and Logs, so image pulls and secrets stay off the NAT (A14: production). The S3 gateway endpoint is always on."
  type        = bool
  default     = false
}

# ── edge ────────────────────────────────────────────────────────────────────

variable "alb_deletion_protection" {
  description = "ALB deletion protection (A14: production)."
  type        = bool
  default     = false
}

variable "alb_access_logs" {
  description = "ALB access logs to an S3 bucket of their own (A14: production)."
  type        = bool
  default     = false
}

variable "alb_access_log_retention_days" {
  description = "Days the ALB access logs are kept."
  type        = number
  default     = 90
}

# ── compute ─────────────────────────────────────────────────────────────────

variable "image_tag" {
  description = "The image tag Terraform's BASE task definitions name. The pipeline copies each base revision and swaps only the image (A2), so this is never what runs; `bootstrap` names no image and is never pulled (services start at desired 0, A13)."
  type        = string
  default     = "bootstrap"
}

variable "api_cpu" {
  description = "API task vCPU units (1024 = 1 vCPU)."
  type        = number
}

variable "api_memory" {
  description = "API task memory, MiB."
  type        = number
}

variable "api_desired_count" {
  description = "API tasks the first deploy starts (and autoscaling's floor). Production needs >= 2: AZ redundancy and a rolling deploy with no gap (A14)."
  type        = number

  validation {
    condition     = var.api_desired_count >= 1 && (var.environment != "production" || var.api_desired_count >= 2)
    error_message = "api_desired_count must be >= 1, and >= 2 in production."
  }
}

variable "api_autoscaling" {
  description = "Target-tracking autoscaling on CPU 60% between api_desired_count and api_max_count (production). Its floor scales a service out the moment it registers, so the FIRST apply of a new environment passes -var api_autoscaling=false (infra/README.md, A13)."
  type        = bool
  default     = false
}

variable "api_max_count" {
  description = "Autoscaling ceiling for the API."
  type        = number
  default     = 6

  validation {
    condition     = var.api_max_count >= 1 && var.api_max_count >= var.api_desired_count
    error_message = "api_max_count must be >= 1 and >= api_desired_count (autoscaling's floor)."
  }
}

variable "worker_cpu" {
  description = "Worker task vCPU units. There is exactly one worker task (DEPLOY.md)."
  type        = number
  default     = 512
}

variable "worker_memory" {
  description = "Worker task memory, MiB."
  type        = number
  default     = 1024
}

variable "web_cpu" {
  description = "Web task vCPU units."
  type        = number
  default     = 512
}

variable "web_memory" {
  description = "Web task memory, MiB."
  type        = number
  default     = 1024
}

variable "web_desired_count" {
  description = "Web tasks the first deploy starts."
  type        = number

  validation {
    condition     = var.web_desired_count >= 1
    error_message = "web_desired_count must be >= 1."
  }
}

variable "migrate_cpu" {
  description = "Migrate task vCPU units."
  type        = number
  default     = 512
}

variable "migrate_memory" {
  description = "Migrate task memory, MiB."
  type        = number
  default     = 1024
}

variable "log_retention_days" {
  description = "CloudWatch retention for every service's log group (30 staging, 90 production)."
  type        = number
}

# ── application settings (not secrets) ──────────────────────────────────────

variable "push_gateway" {
  description = "PUSH_GATEWAY on the worker: `unconfigured` (the code's non-sending default) or `expo` (wires the out-of-band EXPO_ACCESS_TOKEN secret, which must then hold a value or the task cannot start)."
  type        = string
  default     = "unconfigured"

  validation {
    condition     = contains(["unconfigured", "expo"], var.push_gateway)
    error_message = "push_gateway must be unconfigured or expo."
  }
}

variable "eway_gateway" {
  description = "EWAY_GATEWAY on the API and worker: `unconfigured` (the default — bills export as NIC bulk JSON) or `sandbox`."
  type        = string
  default     = "unconfigured"

  validation {
    condition     = contains(["unconfigured", "sandbox"], var.eway_gateway)
    error_message = "eway_gateway must be unconfigured or sandbox."
  }
}

variable "channel_http_timeout_ms" {
  description = "CHANNEL_HTTP_TIMEOUT_MS on the API and worker (the code's default)."
  type        = number
  default     = 10000
}

variable "push_http_timeout_ms" {
  description = "PUSH_HTTP_TIMEOUT_MS on the worker (the code's default)."
  type        = number
  default     = 10000
}

variable "worker_job_settings" {
  description = "The worker's job switches and per-tick bounds (DEPLOY.md §2 and deploy/compose.yml). Every *_POLL_MS goes on the worker and NEVER on the API. Values are strings (ECS environment values)."
  type        = map(string)
  default = {
    OUTBOX_RELAY_POLL_MS                 = "2000"
    OUTBOX_RECONCILE_POLL_MS             = "2000"
    RECONCILE_FULL_PASS_EVERY            = "20"
    RESERVATION_REAPER_POLL_MS           = "2000"
    COUNT_SCHEDULER_POLL_MS              = "3600000"
    REPLENISHMENT_SCHEDULER_POLL_MS      = "60000"
    CHANNELS_SYNC_POLL_MS                = "60000"
    STORAGE_SNAPSHOT_POLL_MS             = "300000"
    PUSH_SENDER_POLL_MS                  = "5000"
    WAVE_CUTOFF_SWEEP_POLL_MS            = "60000"
    AUDIT_EXPORT_POLL_MS                 = "10000"
    LEDGER_INTEGRITY_POLL_MS             = "3600000"
    MAX_LEDGER_INTEGRITY_SCOPES_PER_TICK = "50"
    LEDGER_ANCHOR_MAX_RANGE              = "10000"
    LEDGER_ANCHOR_CHUNKS_PER_TICK        = "10"
    SESSION_PURGE_POLL_MS                = "86400000"
    LICENCE_EXPIRY_POLL_MS               = "3600000"
    EMAIL_SEND_POLL_MS                   = "5000"
  }

  validation {
    condition = alltrue([
      for key in [
        "OUTBOX_RELAY_POLL_MS", "OUTBOX_RECONCILE_POLL_MS", "RESERVATION_REAPER_POLL_MS", "COUNT_SCHEDULER_POLL_MS",
        "REPLENISHMENT_SCHEDULER_POLL_MS", "CHANNELS_SYNC_POLL_MS", "STORAGE_SNAPSHOT_POLL_MS", "PUSH_SENDER_POLL_MS",
        "WAVE_CUTOFF_SWEEP_POLL_MS", "AUDIT_EXPORT_POLL_MS", "LEDGER_INTEGRITY_POLL_MS", "SESSION_PURGE_POLL_MS",
        "LICENCE_EXPIRY_POLL_MS", "EMAIL_SEND_POLL_MS",
      ] : can(regex("^[1-9][0-9]*$", lookup(var.worker_job_settings, key, "")))
    ])
    error_message = "worker_job_settings must set every one of the fourteen *_POLL_MS (DEPLOY.md §2) to a positive integer: unset means the job is OFF."
  }
}

variable "migrate_settings" {
  description = "The migrator's thresholds and timeouts (DEPLOY.md §2, the code's defaults)."
  type        = map(string)
  default = {
    MIGRATE_LARGE_TABLE_ROWS     = "100000"
    MIGRATE_LARGE_TABLE_BYTES    = "67108864"
    MIGRATE_LOCK_TIMEOUT_MS      = "5000"
    MIGRATE_STATEMENT_TIMEOUT_MS = "600000"
    MIGRATE_ADVISORY_WAIT_MS     = "600000"
  }
}

variable "ledger_anchor_retention_days" {
  description = "LEDGER_ANCHOR_RETENTION_DAYS and the anchor bucket's default Object Lock retention (COMPLIANCE): 2557 in production, 1 in staging so its objects expire (A15)."
  type        = number

  validation {
    condition     = var.ledger_anchor_retention_days >= 1 && var.ledger_anchor_retention_days <= 36500 && floor(var.ledger_anchor_retention_days) == var.ledger_anchor_retention_days
    error_message = "ledger_anchor_retention_days must be a whole number of days between 1 and 36500 (the code's bound)."
  }
}

variable "ses_identity_domain" {
  description = "The SES domain identity global created (normally var.domain). The worker role may send as it (5-1a)."
  type        = string
  default     = null
}

# ── data ────────────────────────────────────────────────────────────────────

variable "db_engine_version" {
  description = "RDS Postgres engine version. Major 18 matches compose; the minor is chosen by RDS and upgraded automatically (A14). Verify at the first plan: `aws rds describe-db-engine-versions --engine postgres --query 'DBEngineVersions[?starts_with(EngineVersion, `18`)].EngineVersion'`."
  type        = string
  default     = "18"
}

variable "db_parameter_group_family" {
  description = "The parameter group family matching db_engine_version's major."
  type        = string
  default     = "postgres18"
}

variable "db_instance_class" {
  description = "RDS instance class (db.t4g.small staging, db.t4g.medium production)."
  type        = string
}

variable "db_multi_az" {
  description = "Multi-AZ RDS (production)."
  type        = bool
}

variable "db_allocated_storage" {
  description = "Initial gp3 storage, GB."
  type        = number
  default     = 50
}

variable "db_max_allocated_storage" {
  description = "Storage autoscaling ceiling, GB."
  type        = number
  default     = 500
}

variable "db_backup_retention_days" {
  description = "Automated backup retention (7 staging, 14 production)."
  type        = number
}

variable "db_deletion_protection" {
  description = "RDS deletion protection (production)."
  type        = bool
}

variable "db_final_snapshot" {
  description = "Take a named final snapshot on destroy (production); staging skips it (A14)."
  type        = bool
}

variable "valkey_engine_version" {
  description = "ElastiCache Valkey engine version, major 8. Verify at the first plan: `aws elasticache describe-cache-engine-versions --engine valkey`."
  type        = string
  default     = "8.1"
}

variable "valkey_parameter_group_family" {
  description = "The parameter group family matching valkey_engine_version's major."
  type        = string
  default     = "valkey8"
}

variable "valkey_node_type" {
  description = "Valkey node type (cache.t4g.micro staging, cache.t4g.small production)."
  type        = string
}

variable "valkey_num_nodes" {
  description = "Valkey nodes: 1 (staging) or 2 with Multi-AZ automatic failover (production)."
  type        = number

  validation {
    condition     = var.valkey_num_nodes >= 1 && var.valkey_num_nodes <= 6
    error_message = "valkey_num_nodes must be between 1 and 6."
  }
}

variable "valkey_snapshot_retention_days" {
  description = "Valkey snapshot retention (1 staging, 7 production)."
  type        = number
}

variable "secret_recovery_window_days" {
  description = "Secrets Manager recovery window on delete: 0 (immediate) in staging so a re-create is not blocked, 7 in production (A14)."
  type        = number

  validation {
    condition     = var.secret_recovery_window_days == 0 || (var.secret_recovery_window_days >= 7 && var.secret_recovery_window_days <= 30)
    error_message = "secret_recovery_window_days must be 0 or between 7 and 30."
  }
}
