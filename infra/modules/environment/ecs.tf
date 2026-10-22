# Decision 5 + A5 + A7 + A13: one Fargate cluster; api, worker and web
# services; a migrate task definition with no service.
#
# Terraform owns the SHAPE (env, secrets, sizes, roles). The pipeline copies
# each base revision named in the SSM deploy parameter, swaps only the image
# and rolls (A2). Services ignore task_definition and desired_count, so an
# apply never reverts a deploy; task definitions skip_destroy, so a shape
# change never deregisters the revision that is running.

resource "aws_ecs_cluster" "this" {
  name = local.name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}

resource "aws_cloudwatch_log_group" "service" {
  for_each = toset(["api", "worker", "web", "migrate"])

  name              = "/wms/${var.environment}/${each.key}"
  retention_in_days = var.log_retention_days
}

# ── the per-role environment (A5; DEPLOY.md §AWS carries the same table) ────

locals {
  be_image = "${data.aws_ecr_repository.be.repository_url}:${var.image_tag}"
  fe_image = "${data.aws_ecr_repository.fe.repository_url}:${var.image_tag}"

  # API and worker share these.
  backend_env = {
    NODE_ENV                     = "production"
    PORT                         = "3000"
    AWS_REGION                   = var.region
    LEDGER_ANCHOR_WORM           = "s3"
    LEDGER_ANCHOR_S3_BUCKET      = aws_s3_bucket.ledger_anchors.id
    LEDGER_ANCHOR_RETENTION_DAYS = tostring(var.ledger_anchor_retention_days)
    EWAY_GATEWAY                 = var.eway_gateway
    CHANNEL_HTTP_TIMEOUT_MS      = tostring(var.channel_http_timeout_ms)
  }

  # The API: no *_POLL_MS at all — it runs no background job.
  api_env = merge(local.backend_env, {
    TRUSTED_PROXY_HOPS = "1" # behind the ALB (DEPLOY.md §2)
    CORS_ORIGIN        = local.web_origin
  })

  # The ONE worker: every job on.
  worker_env = merge(local.backend_env, var.worker_job_settings, {
    PUSH_GATEWAY         = var.push_gateway
    PUSH_HTTP_TIMEOUT_MS = tostring(var.push_http_timeout_ms)
  })

  migrate_env = merge(var.migrate_settings, {
    NODE_ENV = "production"
  })

  # WMS_API_INTERNAL_BASE_URL is left unset: the web server's own requests
  # take the public ALB through the NAT (accepted, A5).
  web_env = {
    PORT             = "3001"
    HOSTNAME         = "0.0.0.0"
    WMS_API_BASE_URL = local.api_base_url
  }

  app_secret_refs = {
    DATABASE_URL           = aws_secretsmanager_secret.generated["database-url"].arn
    DATABASE_AUTH_URL      = aws_secretsmanager_secret.generated["database-auth-url"].arn
    VALKEY_URL             = aws_secretsmanager_secret.generated["valkey-url"].arn
    JWT_SECRET             = aws_secretsmanager_secret.out_of_band["jwt-secret"].arn
    MFA_ENCRYPTION_KEY     = aws_secretsmanager_secret.out_of_band["mfa-encryption-key"].arn
    DEVICE_ENCRYPTION_KEY  = aws_secretsmanager_secret.out_of_band["device-encryption-key"].arn
    CARRIER_ENCRYPTION_KEY = aws_secretsmanager_secret.out_of_band["carrier-encryption-key"].arn
    CHANNEL_ENCRYPTION_KEY = aws_secretsmanager_secret.out_of_band["channel-encryption-key"].arn
  }

  worker_secret_refs = merge(
    local.app_secret_refs,
    var.push_gateway == "expo" ? { EXPO_ACCESS_TOKEN = aws_secretsmanager_secret.out_of_band["expo-access-token"].arn } : {},
  )

  # The migrate task alone gets the OWNER url (as its DATABASE_URL) and the
  # two role passwords (A9).
  migrate_secret_refs = {
    DATABASE_URL      = aws_secretsmanager_secret.generated["migrate-database-url"].arn
    WMS_APP_PASSWORD  = aws_secretsmanager_secret.generated["db-app-password"].arn
    WMS_AUTH_PASSWORD = aws_secretsmanager_secret.generated["db-auth-password"].arn
  }

  # Fargate ignores the Dockerfile HEALTHCHECK, so each container states its
  # own (A7). Alpine has no curl: Bun's / Node's fetch probes.
  be_health = {
    command     = ["CMD", "bun", "-e", "fetch('http://127.0.0.1:3000/api/v1/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]
    interval    = 15
    timeout     = 5
    retries     = 3
    startPeriod = 30
  }

  web_health = {
    command     = ["CMD", "node", "-e", "fetch('http://127.0.0.1:3001/runtime-config.js').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]
    interval    = 15
    timeout     = 5
    retries     = 3
    startPeriod = 30
  }

  families = {
    api     = "${local.name}-api"
    worker  = "${local.name}-worker"
    web     = "${local.name}-web"
    migrate = "${local.name}-migrate"
  }
}

locals {
  # Shared container shape. Every secret is a valueFrom reference — never a
  # literal in the task definition.
  container = {
    for role, spec in {
      api     = { image = local.be_image, env = local.api_env, secrets = local.app_secret_refs, port = 3000, health = local.be_health }
      worker  = { image = local.be_image, env = local.worker_env, secrets = local.worker_secret_refs, port = 3000, health = local.be_health }
      web     = { image = local.fe_image, env = local.web_env, secrets = {}, port = 3001, health = local.web_health }
      migrate = { image = local.be_image, env = local.migrate_env, secrets = local.migrate_secret_refs, port = null, health = null }
    } :
    role => merge(
      {
        name        = role
        image       = spec.image
        essential   = true
        stopTimeout = 30
        environment = [for key in sort(keys(spec.env)) : { name = key, value = spec.env[key] }]
        secrets     = [for key in sort(keys(spec.secrets)) : { name = key, valueFrom = spec.secrets[key] }]
        logConfiguration = {
          logDriver = "awslogs"
          options = {
            awslogs-group         = aws_cloudwatch_log_group.service[role].name
            awslogs-region        = var.region
            awslogs-stream-prefix = role
          }
        }
      },
      spec.port == null ? {} : { portMappings = [{ containerPort = spec.port, protocol = "tcp" }] },
      spec.health == null ? {} : { healthCheck = spec.health },
      role == "migrate" ? { command = ["sh", "-c", "bun run db:migrate:deploy && bun run db:provision-roles"] } : {},
    )
  }

  task_size = {
    api     = { cpu = var.api_cpu, memory = var.api_memory }
    worker  = { cpu = var.worker_cpu, memory = var.worker_memory }
    web     = { cpu = var.web_cpu, memory = var.web_memory }
    migrate = { cpu = var.migrate_cpu, memory = var.migrate_memory }
  }

  execution_role_arn = {
    api     = aws_iam_role.execution_app.arn
    worker  = aws_iam_role.execution_app.arn
    web     = aws_iam_role.execution_web.arn
    migrate = aws_iam_role.execution_migrate.arn
  }
}

resource "aws_ecs_task_definition" "this" {
  for_each = local.families

  family                   = each.value
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(local.task_size[each.key].cpu)
  memory                   = tostring(local.task_size[each.key].memory)
  execution_role_arn       = local.execution_role_arn[each.key]
  task_role_arn            = aws_iam_role.task[each.key].arn
  container_definitions    = jsonencode([local.container[each.key]])
  skip_destroy             = true # A13: a shape change never deregisters a running revision

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64" # the CI-verified linux/amd64 images
  }
}

# ── services (desired 0 at creation; the first pipeline roll sets the
#    target count from the SSM parameter — A13) ─────────────────────────────

resource "aws_ecs_service" "api" {
  name                               = "api"
  cluster                            = aws_ecs_cluster.this.id
  task_definition                    = aws_ecs_task_definition.this["api"].arn
  desired_count                      = 0
  launch_type                        = "FARGATE"
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  health_check_grace_period_seconds  = 60
  propagate_tags                     = "SERVICE"
  enable_ecs_managed_tags            = true

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = aws_subnet.app[*].id
    security_groups  = [aws_security_group.app.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = "api"
    container_port   = 3000
  }

  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }

  depends_on = [aws_lb_listener_rule.api]
}

# Exactly one worker, stop-then-start: seven jobs are not proven safe to run
# twice (DEPLOY.md §1). Not attached to the ALB.
resource "aws_ecs_service" "worker" {
  name                               = "worker"
  cluster                            = aws_ecs_cluster.this.id
  task_definition                    = aws_ecs_task_definition.this["worker"].arn
  desired_count                      = 0
  launch_type                        = "FARGATE"
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100
  propagate_tags                     = "SERVICE"
  enable_ecs_managed_tags            = true

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = aws_subnet.app[*].id
    security_groups  = [aws_security_group.app.id]
    assign_public_ip = false
  }

  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }
}

resource "aws_ecs_service" "web" {
  name                               = "web"
  cluster                            = aws_ecs_cluster.this.id
  task_definition                    = aws_ecs_task_definition.this["web"].arn
  desired_count                      = 0
  launch_type                        = "FARGATE"
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  health_check_grace_period_seconds  = 30
  propagate_tags                     = "SERVICE"
  enable_ecs_managed_tags            = true

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = aws_subnet.app[*].id
    security_groups  = [aws_security_group.app.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.web.arn
    container_name   = "web"
    container_port   = 3001
  }

  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }

  depends_on = [aws_lb_listener_rule.web]
}

# ── API autoscaling (production; A14: 2 → 6 on CPU 60 %) ────────────────────

resource "aws_appautoscaling_target" "api" {
  count = var.api_autoscaling ? 1 : 0

  service_namespace  = "ecs"
  scalable_dimension = "ecs:service:DesiredCount"
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.api.name}"
  min_capacity       = var.api_desired_count
  max_capacity       = var.api_max_count
}

resource "aws_appautoscaling_policy" "api_cpu" {
  count = var.api_autoscaling ? 1 : 0

  name               = "${local.name}-api-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.api[0].service_namespace
  scalable_dimension = aws_appautoscaling_target.api[0].scalable_dimension
  resource_id        = aws_appautoscaling_target.api[0].resource_id

  target_tracking_scaling_policy_configuration {
    target_value       = 60
    scale_in_cooldown  = 300
    scale_out_cooldown = 60

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}
