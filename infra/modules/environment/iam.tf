# Least privilege per role (Boundaries, A9):
#   - three EXECUTION roles (ECS pulls the image, writes logs, resolves the
#     task's secrets): app (api + worker) reads only the app secrets, migrate
#     alone reads the owner URL and the role passwords, web reads none;
#   - one TASK role per family: only the worker's carries permissions (the
#     anchor bucket, SES); the others are empty but named, so the pipeline can
#     assert a copied revision kept this environment's roles (A2).

data "aws_iam_policy_document" "ecs_tasks_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:ecs:${var.region}:${var.account_id}:*"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
  }
}

# ── execution roles ─────────────────────────────────────────────────────────

locals {
  execution_secret_arns = {
    app     = distinct(values(local.worker_secret_refs)) # worker's set ⊇ the API's
    migrate = values(local.migrate_secret_refs)
    web     = []
  }

  execution_log_groups = {
    app     = ["api", "worker"]
    migrate = ["migrate"]
    web     = ["web"]
  }

  execution_repos = {
    app     = [data.aws_ecr_repository.be.arn]
    migrate = [data.aws_ecr_repository.be.arn]
    web     = [data.aws_ecr_repository.fe.arn]
  }
}

data "aws_iam_policy_document" "execution" {
  for_each = local.execution_log_groups

  # Not scopable to a resource (an account-wide token).
  statement {
    sid       = "EcrToken"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "EcrPull"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = local.execution_repos[each.key]
  }

  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [for role in each.value : "${aws_cloudwatch_log_group.service[role].arn}:*"]
  }

  dynamic "statement" {
    for_each = length(local.execution_secret_arns[each.key]) > 0 ? [1] : []

    content {
      sid       = "Secrets"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = local.execution_secret_arns[each.key]
    }
  }
}

resource "aws_iam_role" "execution_app" {
  name               = "${local.name}-execution-app"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_trust.json
}

resource "aws_iam_role_policy" "execution_app" {
  name   = "execution"
  role   = aws_iam_role.execution_app.id
  policy = data.aws_iam_policy_document.execution["app"].json
}

resource "aws_iam_role" "execution_migrate" {
  name               = "${local.name}-execution-migrate"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_trust.json
}

resource "aws_iam_role_policy" "execution_migrate" {
  name   = "execution"
  role   = aws_iam_role.execution_migrate.id
  policy = data.aws_iam_policy_document.execution["migrate"].json
}

resource "aws_iam_role" "execution_web" {
  name               = "${local.name}-execution-web"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_trust.json
}

resource "aws_iam_role_policy" "execution_web" {
  name   = "execution"
  role   = aws_iam_role.execution_web.id
  policy = data.aws_iam_policy_document.execution["web"].json
}

# ── task roles ──────────────────────────────────────────────────────────────

resource "aws_iam_role" "task" {
  for_each = local.families

  name               = "${local.name}-task-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_trust.json
}

data "aws_iam_policy_document" "worker_task" {
  # The ledger anchor WORM copies (A15): exactly the code's actions
  # (src/modules/inventory/ledger-anchor-worm.ts) — put under COMPLIANCE
  # retention, read back by version, and list (without ListBucket S3 answers a
  # missing object 403, which reads as transient instead of a WORM break).
  statement {
    sid = "LedgerAnchorObjects"
    actions = [
      "s3:PutObject",
      "s3:PutObjectRetention",
      "s3:GetObject",
      "s3:GetObjectVersion",
    ]
    resources = ["${aws_s3_bucket.ledger_anchors.arn}/ledger-anchors/*"]
  }

  statement {
    sid       = "LedgerAnchorList"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.ledger_anchors.arn]
  }

  # Story 5-1a's mailer (EMAIL_PROVIDER stays off until it ships).
  statement {
    sid       = "SesSend"
    actions   = ["ses:SendEmail"]
    resources = [local.ses_identity_arn]
  }

  # Not scopable to a resource (the account-level suppression list).
  statement {
    sid       = "SesSuppression"
    actions   = ["ses:GetSuppressedDestination"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "worker_task" {
  name   = "worker"
  role   = aws_iam_role.task["worker"].id
  policy = data.aws_iam_policy_document.worker_task.json
}
