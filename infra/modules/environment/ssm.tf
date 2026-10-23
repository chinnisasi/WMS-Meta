# The deploy parameter (decision 9, A2, A13): everything the pipeline needs to
# run the migrate task and roll the services, and nothing secret. The
# pipeline copies each `task_definition` (Terraform's base revision — never
# "latest"), asserts its roles equal the ones named here, swaps only the image.

resource "aws_ssm_parameter" "deploy" {
  name        = "/wms/${var.environment}/deploy"
  description = "WMS ${var.environment} deploy pipeline inputs (story 6-2b; .github/workflows/deploy.yml)"
  type        = "String"
  tier        = "Intelligent-Tiering"

  value = jsonencode({
    environment     = var.environment
    region          = var.region
    cluster         = aws_ecs_cluster.this.name
    subnets         = aws_subnet.app[*].id
    security_groups = [aws_security_group.app.id]
    api_ready_url   = local.api_ready_url
    repositories = {
      "wms-be" = data.aws_ecr_repository.be.repository_url
      "wms-fe" = data.aws_ecr_repository.fe.repository_url
    }
    migrate = {
      task_definition    = aws_ecs_task_definition.this["migrate"].arn
      container          = "migrate"
      repository         = "wms-be"
      execution_role_arn = local.execution_role_arn["migrate"]
      task_role_arn      = aws_iam_role.task["migrate"].arn
      log_group          = aws_cloudwatch_log_group.service["migrate"].name
      log_stream_prefix  = "migrate"
    }
    # Rolled in this order: api → (readiness gate) → worker → web.
    services = {
      api = {
        service            = aws_ecs_service.api.name
        task_definition    = aws_ecs_task_definition.this["api"].arn
        container          = "api"
        repository         = "wms-be"
        target_count       = var.api_desired_count
        execution_role_arn = local.execution_role_arn["api"]
        task_role_arn      = aws_iam_role.task["api"].arn
      }
      worker = {
        service            = aws_ecs_service.worker.name
        task_definition    = aws_ecs_task_definition.this["worker"].arn
        container          = "worker"
        repository         = "wms-be"
        target_count       = 1 # exactly one (DEPLOY.md §1)
        execution_role_arn = local.execution_role_arn["worker"]
        task_role_arn      = aws_iam_role.task["worker"].arn
      }
      web = {
        service            = aws_ecs_service.web.name
        task_definition    = aws_ecs_task_definition.this["web"].arn
        container          = "web"
        repository         = "wms-fe"
        target_count       = var.web_desired_count
        execution_role_arn = local.execution_role_arn["web"]
        task_role_arn      = aws_iam_role.task["web"].arn
      }
    }
  })
}

# A3: what staging last deployed successfully — the only SHAs production may
# promote. Created here, written by the staging pipeline; Terraform never
# reverts it.
resource "aws_ssm_parameter" "staging_deployed" {
  count = var.environment == "staging" ? 1 : 0

  name        = local.staging_deployed_name
  description = "The {be, fe} SHAs staging last deployed (written by .github/workflows/deploy.yml; production promotes only these)"
  type        = "String"
  value       = jsonencode({ be = "", fe = "" })

  lifecycle {
    ignore_changes = [value]
  }
}
