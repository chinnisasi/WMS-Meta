# The GitHub Actions deploy role for this environment (A2, A3, A9, A11).
#
# Trust: only the deploy workflow running in the GitHub environment of the
# same name — aud AND sub are both checked. Terraform state is out of reach
# (A10: the state bucket denies everyone but the operator).

locals {
  deploy_ssm_parameter_arn  = "arn:aws:ssm:${var.region}:${var.account_id}:parameter/wms/${var.environment}/deploy"
  staging_deployed_name     = "/wms/staging/deployed"
  staging_deployed_arn      = "arn:aws:ssm:${var.region}:${var.account_id}:parameter${local.staging_deployed_name}"
  service_arn_prefix        = "arn:aws:ecs:${var.region}:${var.account_id}:service/${local.name}"
  task_arn_prefix           = "arn:aws:ecs:${var.region}:${var.account_id}:task/${local.name}"
  migrate_task_def_arn_glob = "arn:aws:ecs:${var.region}:${var.account_id}:task-definition/${local.families.migrate}:*"
  can_push_images           = var.environment == "staging" # A3: only staging builds
}

data "aws_iam_policy_document" "deploy_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository}:environment:${var.environment}"]
    }
  }
}

resource "aws_iam_role" "deploy" {
  name                 = "${local.name}-deploy"
  description          = "GitHub Actions deploy (.github/workflows/deploy.yml) for ${var.environment}"
  assume_role_policy   = data.aws_iam_policy_document.deploy_trust.json
  max_session_duration = 10800 # 3 h: above the deploy job's 170-minute timeout (DEPLOY.md §8.5)
}

data "aws_iam_policy_document" "deploy" {
  # ── ECR ──
  # Not scopable to a resource (an account-wide token).
  statement {
    sid       = "EcrToken"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "EcrReadDescribe"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:DescribeImages",
    ]
    resources = [data.aws_ecr_repository.be.arn, data.aws_ecr_repository.fe.arn]
  }

  # A3: push belongs to the staging role alone; production promotes.
  dynamic "statement" {
    for_each = local.can_push_images ? [1] : []

    content {
      sid = "EcrPush"
      actions = [
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:PutImage",
      ]
      resources = [data.aws_ecr_repository.be.arn, data.aws_ecr_repository.fe.arn]
    }
  }

  # ── ECS ──
  # Not scopable to a resource: RegisterTaskDefinition and
  # DescribeTaskDefinition accept only "*". A2 contains the risk instead: the
  # pipeline copies the base revision Terraform wrote into SSM and asserts
  # its roles, and PassRole (below) admits only this environment's roles.
  statement {
    sid       = "EcsTaskDefinitions"
    actions   = ["ecs:RegisterTaskDefinition", "ecs:DescribeTaskDefinition"]
    resources = ["*"]
  }

  # The copied revision keeps its tags (Terraform's default_tags); tagging is
  # allowed only as part of registering one.
  statement {
    sid       = "EcsTagOnRegister"
    actions   = ["ecs:TagResource"]
    resources = ["arn:aws:ecs:${var.region}:${var.account_id}:task-definition/${local.name}-*"]

    condition {
      test     = "StringEquals"
      variable = "ecs:CreateAction"
      values   = ["RegisterTaskDefinition"]
    }
  }

  statement {
    sid       = "EcsServices"
    actions   = ["ecs:UpdateService", "ecs:DescribeServices"]
    resources = ["${local.service_arn_prefix}/*"]

    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [local.ecs_cluster_arn]
    }
  }

  statement {
    sid       = "EcsRunMigrate"
    actions   = ["ecs:RunTask"]
    resources = [local.migrate_task_def_arn_glob]

    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [local.ecs_cluster_arn]
    }
  }

  statement {
    sid       = "EcsDescribeStopTasks"
    actions   = ["ecs:DescribeTasks", "ecs:StopTask"] # StopTask: a migrate task past its deadline
    resources = ["${local.task_arn_prefix}/*"]

    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [local.ecs_cluster_arn]
    }
  }

  statement {
    sid     = "PassOwnRolesToEcs"
    actions = ["iam:PassRole"]
    resources = concat(
      [aws_iam_role.execution_app.arn, aws_iam_role.execution_migrate.arn, aws_iam_role.execution_web.arn],
      [for role in aws_iam_role.task : role.arn],
    )

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }

  # ── SSM: the deploy parameter, and the promotion record (A3) ──
  statement {
    sid       = "ReadDeployParameter"
    actions   = ["ssm:GetParameter"]
    resources = [local.deploy_ssm_parameter_arn, local.staging_deployed_arn]
  }

  dynamic "statement" {
    for_each = local.can_push_images ? [1] : []

    content {
      sid       = "RecordStagingDeployed"
      actions   = ["ssm:PutParameter"]
      resources = [local.staging_deployed_arn]
    }
  }

  # ── Logs: the migrate log group only (A9) ──
  statement {
    sid       = "ReadMigrateLogs"
    actions   = ["logs:GetLogEvents", "logs:FilterLogEvents"]
    resources = [aws_cloudwatch_log_group.service["migrate"].arn, "${aws_cloudwatch_log_group.service["migrate"].arn}:*"]
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = "deploy"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy.json
}
