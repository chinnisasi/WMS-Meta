# Story 6-2b — the module's load-bearing shape, applied against MOCK providers
# (no AWS call, no credentials, nothing created): `terraform init -backend=false && terraform
# test` in infra/modules/environment (infra-ci runs it).

mock_provider "aws" {
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

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{}"
    }
  }

  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:ap-south-1:123456789012:log-group:mock"
    }
  }

  mock_resource "aws_s3_bucket" {
    defaults = {
      arn = "arn:aws:s3:::mock"
    }
  }

  mock_resource "aws_lb" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:ap-south-1:123456789012:loadbalancer/app/mock/0123456789abcdef"
    }
  }

  mock_resource "aws_lb_target_group" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:ap-south-1:123456789012:targetgroup/mock/0123456789abcdef"
    }
  }

  mock_resource "aws_lb_listener" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:ap-south-1:123456789012:listener/app/mock/0123456789abcdef/0123456789abcdef"
    }
  }

  mock_resource "aws_ecs_cluster" {
    defaults = {
      arn = "arn:aws:ecs:ap-south-1:123456789012:cluster/mock"
    }
  }

  mock_resource "aws_ecs_task_definition" {
    defaults = {
      arn = "arn:aws:ecs:ap-south-1:123456789012:task-definition/mock:1"
    }
  }

  mock_resource "aws_secretsmanager_secret" {
    defaults = {
      arn = "arn:aws:secretsmanager:ap-south-1:123456789012:secret:mock"
    }
  }

  mock_resource "aws_kms_key" {
    defaults = {
      arn = "arn:aws:kms:ap-south-1:123456789012:key/mock"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/mock"
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

# The certificate's validation options for both environments' hosts (the
# mocks cannot derive them from the domain names).
override_resource {
  target = aws_acm_certificate.this
  values = {
    arn = "arn:aws:acm:ap-south-1:123456789012:certificate/mock"
    domain_validation_options = [
      { domain_name = "app.example.in", resource_record_name = "_a.app.example.in.", resource_record_type = "CNAME", resource_record_value = "_a.acm-validations.aws." },
      { domain_name = "api.example.in", resource_record_name = "_b.api.example.in.", resource_record_type = "CNAME", resource_record_value = "_b.acm-validations.aws." },
      { domain_name = "app.staging.example.in", resource_record_name = "_c.app.staging.example.in.", resource_record_type = "CNAME", resource_record_value = "_c.acm-validations.aws." },
      { domain_name = "api.staging.example.in", resource_record_name = "_d.api.staging.example.in.", resource_record_type = "CNAME", resource_record_value = "_d.acm-validations.aws." },
    ]
  }
}

# The mocks give every secret one ARN; the migrate-only secrets get their own,
# so the A9 split (the app execution role never reads them) is observable.
override_resource {
  target = aws_secretsmanager_secret.generated["migrate-database-url"]
  values = { arn = "arn:aws:secretsmanager:ap-south-1:123456789012:secret:wms/production/migrate-database-url" }
}

override_resource {
  target = aws_secretsmanager_secret.generated["db-app-password"]
  values = { arn = "arn:aws:secretsmanager:ap-south-1:123456789012:secret:wms/production/db-app-password" }
}

override_resource {
  target = aws_secretsmanager_secret.generated["db-auth-password"]
  values = { arn = "arn:aws:secretsmanager:ap-south-1:123456789012:secret:wms/production/db-auth-password" }
}

variables {
  environment                    = "production"
  account_id                     = "123456789012"
  domain                         = "example.in"
  route53_zone_id                = "Z0123456789ABC"
  vpc_cidr                       = "10.30.0.0/16"
  nat_gateway_per_az             = true
  interface_endpoints            = true
  alb_deletion_protection        = true
  alb_access_logs                = true
  api_cpu                        = 1024
  api_memory                     = 2048
  api_desired_count              = 2
  api_autoscaling                = true
  api_max_count                  = 6
  web_desired_count              = 2
  log_retention_days             = 90
  ledger_anchor_retention_days   = 2557
  db_instance_class              = "db.t4g.medium"
  db_multi_az                    = true
  db_backup_retention_days       = 14
  db_deletion_protection         = true
  db_final_snapshot              = true
  valkey_node_type               = "cache.t4g.small"
  valkey_num_nodes               = 2
  valkey_snapshot_retention_days = 7
  secret_recovery_window_days    = 7
}

run "production_task_definitions" {
  command = apply # against the mocks: computed values become known

  # No *_POLL_MS on the API; every one of compose's thirteen on the worker.
  assert {
    condition     = length([for e in jsondecode(aws_ecs_task_definition.this["api"].container_definitions)[0].environment : e if endswith(e.name, "_POLL_MS")]) == 0
    error_message = "The API task must set no *_POLL_MS."
  }

  assert {
    condition = length(setsubtract(
      ["OUTBOX_RELAY_POLL_MS", "OUTBOX_RECONCILE_POLL_MS", "RESERVATION_REAPER_POLL_MS", "COUNT_SCHEDULER_POLL_MS",
        "REPLENISHMENT_SCHEDULER_POLL_MS", "CHANNELS_SYNC_POLL_MS", "STORAGE_SNAPSHOT_POLL_MS", "PUSH_SENDER_POLL_MS",
        "WAVE_CUTOFF_SWEEP_POLL_MS", "AUDIT_EXPORT_POLL_MS", "LEDGER_INTEGRITY_POLL_MS", "SESSION_PURGE_POLL_MS",
      "LICENCE_EXPIRY_POLL_MS"],
      [for e in jsondecode(aws_ecs_task_definition.this["worker"].container_definitions)[0].environment : e.name],
    )) == 0
    error_message = "The worker must set every *_POLL_MS from deploy/compose.yml."
  }

  # Migrate alone gets the owner URL and the role passwords.
  assert {
    condition = alltrue([
      for role in ["api", "worker", "web"] : length(setintersection(
        ["WMS_APP_PASSWORD", "WMS_AUTH_PASSWORD"],
        [for s in jsondecode(aws_ecs_task_definition.this[role].container_definitions)[0].secrets : s.name],
      )) == 0
    ])
    error_message = "Only the migrate task may carry the role passwords."
  }

  assert {
    condition     = toset([for s in jsondecode(aws_ecs_task_definition.this["migrate"].container_definitions)[0].secrets : s.name]) == toset(["DATABASE_URL", "WMS_APP_PASSWORD", "WMS_AUTH_PASSWORD"])
    error_message = "The migrate task's secrets are the owner DATABASE_URL and the two role passwords."
  }

  # Every secret is a valueFrom reference; no secret name appears as a literal.
  assert {
    condition = alltrue(flatten([
      for role in ["api", "worker", "web", "migrate"] : [
        for e in jsondecode(aws_ecs_task_definition.this[role].container_definitions)[0].environment :
        !contains(["DATABASE_URL", "DATABASE_AUTH_URL", "VALKEY_URL", "JWT_SECRET", "MFA_ENCRYPTION_KEY", "DEVICE_ENCRYPTION_KEY",
        "CARRIER_ENCRYPTION_KEY", "CHANNEL_ENCRYPTION_KEY", "WMS_APP_PASSWORD", "WMS_AUTH_PASSWORD", "EXPO_ACCESS_TOKEN", "EMAIL_SEAL_KEY"], e.name)
      ]
    ]))
    error_message = "A secret must never be a literal environment value."
  }

  # The API-only edge settings stay off the worker.
  assert {
    condition     = length([for e in jsondecode(aws_ecs_task_definition.this["worker"].container_definitions)[0].environment : e if contains(["CORS_ORIGIN", "TRUSTED_PROXY_HOPS"], e.name)]) == 0
    error_message = "CORS_ORIGIN and TRUSTED_PROXY_HOPS belong to the API only."
  }

  assert {
    condition     = contains([for e in jsondecode(aws_ecs_task_definition.this["api"].container_definitions)[0].environment : "${e.name}=${e.value}"], "CORS_ORIGIN=https://app.example.in")
    error_message = "Production's CORS_ORIGIN is https://app.<domain>."
  }

  assert {
    condition     = contains([for e in jsondecode(aws_ecs_task_definition.this["web"].container_definitions)[0].environment : "${e.name}=${e.value}"], "WMS_API_BASE_URL=https://api.example.in/api/v1")
    error_message = "Production's WMS_API_BASE_URL is https://api.<domain>/api/v1."
  }

  # The worker: exactly one, stop-then-start, no load balancer.
  assert {
    condition     = aws_ecs_service.worker.deployment_minimum_healthy_percent == 0 && aws_ecs_service.worker.deployment_maximum_percent == 100 && length(aws_ecs_service.worker.load_balancer) == 0
    error_message = "The worker deploys stop-then-start (0 % / 100 %) and is not behind the ALB."
  }

  assert {
    condition     = jsondecode(aws_ssm_parameter.deploy.value).services.worker.target_count == 1
    error_message = "The worker's target count is exactly 1."
  }

  # The deploy role trusts only this repository's production environment.
  assert {
    condition     = toset(one([for c in data.aws_iam_policy_document.deploy_trust.statement[0].condition : c.values if c.variable == "token.actions.githubusercontent.com:sub"])) == toset(["repo:chinnisasi/WMS-Meta:environment:production"])
    error_message = "The production deploy role is assumable only from environment:production."
  }

  # Production never pushes images (A3).
  assert {
    condition     = length([for s in data.aws_iam_policy_document.deploy.statement : s if s.sid == "EcrPush"]) == 0
    error_message = "The production deploy role must not push to ECR."
  }

  # A9: the app execution role reads none of the migrate-only secrets; the web's reads no secret.
  assert {
    condition = length(setintersection(
      flatten([for st in data.aws_iam_policy_document.execution["app"].statement : st.resources if st.sid == "Secrets"]),
      [
        "arn:aws:secretsmanager:ap-south-1:123456789012:secret:wms/production/migrate-database-url",
        "arn:aws:secretsmanager:ap-south-1:123456789012:secret:wms/production/db-app-password",
        "arn:aws:secretsmanager:ap-south-1:123456789012:secret:wms/production/db-auth-password",
      ],
    )) == 0 && length([for st in data.aws_iam_policy_document.execution["app"].statement : st if st.sid == "Secrets"]) == 1
    error_message = "The api/worker execution role must not read the owner URL or the role passwords (A9)."
  }

  assert {
    condition     = toset(flatten([for st in data.aws_iam_policy_document.execution["migrate"].statement : st.resources if st.sid == "Secrets"])) == toset(["arn:aws:secretsmanager:ap-south-1:123456789012:secret:wms/production/migrate-database-url", "arn:aws:secretsmanager:ap-south-1:123456789012:secret:wms/production/db-app-password", "arn:aws:secretsmanager:ap-south-1:123456789012:secret:wms/production/db-auth-password"])
    error_message = "The migrate execution role reads exactly the owner URL and the two role passwords."
  }

  assert {
    condition     = length([for st in data.aws_iam_policy_document.execution["web"].statement : st if st.sid == "Secrets"]) == 0
    error_message = "The web execution role reads no secret."
  }

  # The deploy parameter carries every key .github/scripts/ecs-deploy.sh and deploy.yml read.
  assert {
    condition = alltrue(concat(
      [for key in ["cluster", "subnets", "security_groups", "api_ready_url", "repositories", "migrate", "services"] : contains(keys(jsondecode(aws_ssm_parameter.deploy.value)), key)],
      [for repo in ["wms-be", "wms-fe"] : can(jsondecode(aws_ssm_parameter.deploy.value).repositories[repo]) && jsondecode(aws_ssm_parameter.deploy.value).repositories[repo] != ""],
      [for key in ["task_definition", "container", "execution_role_arn", "task_role_arn", "log_group", "log_stream_prefix"] : try(jsondecode(aws_ssm_parameter.deploy.value).migrate[key], "") != ""],
      flatten([for svc in ["api", "worker", "web"] : [
        for key in ["service", "container", "target_count", "task_definition", "execution_role_arn", "task_role_arn"] :
        try(tostring(jsondecode(aws_ssm_parameter.deploy.value).services[svc][key]), "") != ""
      ]]),
      [length(jsondecode(aws_ssm_parameter.deploy.value).subnets) == 2, length(jsondecode(aws_ssm_parameter.deploy.value).security_groups) == 1],
    ))
    error_message = "The deploy parameter lacks a key the pipeline reads."
  }

  # The pipeline reads the migrate log at <log_stream_prefix>/<container>/<task id>.
  assert {
    condition = (
      jsondecode(aws_ssm_parameter.deploy.value).migrate.log_stream_prefix == jsondecode(aws_ecs_task_definition.this["migrate"].container_definitions)[0].logConfiguration.options["awslogs-stream-prefix"]
      && jsondecode(aws_ssm_parameter.deploy.value).migrate.container == jsondecode(aws_ecs_task_definition.this["migrate"].container_definitions)[0].name
      && jsondecode(aws_ssm_parameter.deploy.value).migrate.log_group == jsondecode(aws_ecs_task_definition.this["migrate"].container_definitions)[0].logConfiguration.options["awslogs-group"]
    )
    error_message = "The deploy parameter's migrate log location must match the migrate container's awslogs settings."
  }

  assert {
    condition = alltrue([
      for svc in ["api", "worker", "web"] :
      jsondecode(aws_ssm_parameter.deploy.value).services[svc].container == jsondecode(aws_ecs_task_definition.this[svc].container_definitions)[0].name
    ])
    error_message = "Each service's container name in the deploy parameter matches its task definition."
  }

  assert {
    condition     = aws_lb_target_group.api.health_check[0].path == "/api/v1/health"
    error_message = "The API target group checks liveness, never /ready (A7)."
  }
}

run "staging_shape" {
  command = apply

  variables {
    environment                    = "staging"
    vpc_cidr                       = "10.20.0.0/16"
    nat_gateway_per_az             = false
    interface_endpoints            = false
    alb_deletion_protection        = false
    alb_access_logs                = false
    api_cpu                        = 512
    api_memory                     = 1024
    api_desired_count              = 1
    api_autoscaling                = false
    api_max_count                  = 1
    web_desired_count              = 1
    log_retention_days             = 30
    ledger_anchor_retention_days   = 1
    db_instance_class              = "db.t4g.small"
    db_multi_az                    = false
    db_backup_retention_days       = 7
    db_deletion_protection         = false
    db_final_snapshot              = false
    valkey_node_type               = "cache.t4g.micro"
    valkey_num_nodes               = 1
    valkey_snapshot_retention_days = 1
    secret_recovery_window_days    = 0
  }


  assert {
    condition     = contains([for e in jsondecode(aws_ecs_task_definition.this["api"].container_definitions)[0].environment : "${e.name}=${e.value}"], "CORS_ORIGIN=https://app.staging.example.in")
    error_message = "Staging serves app.staging.<domain>."
  }

  assert {
    condition     = toset(one([for c in data.aws_iam_policy_document.deploy_trust.statement[0].condition : c.values if c.variable == "token.actions.githubusercontent.com:sub"])) == toset(["repo:chinnisasi/WMS-Meta:environment:staging"])
    error_message = "The staging deploy role is assumable only from environment:staging."
  }

  assert {
    condition     = length([for s in data.aws_iam_policy_document.deploy.statement : s if s.sid == "EcrPush"]) == 1
    error_message = "Only the staging deploy role pushes images."
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 1 && length(aws_ssm_parameter.staging_deployed) == 1
    error_message = "Staging has one NAT and owns the promotion record."
  }
}

run "production_needs_two_api_tasks" {
  command = plan

  variables {
    api_desired_count = 1
  }

  expect_failures = [var.api_desired_count]
}
