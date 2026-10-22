# Decision 4 + A7 + A14: one ALB per environment, host-routed —
# app.<domain> → web (3001), api.<domain> → API (3000). HTTP redirects to
# HTTPS; the certificate is DNS-validated in the caller's zone.

resource "aws_acm_certificate" "this" {
  domain_name               = local.app_host
  subject_alternative_names = [local.api_host]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# Keyed by the two (static) host names, so the plan never depends on the
# certificate's computed validation options for its instance keys.
locals {
  cert_validation = { for option in aws_acm_certificate.this.domain_validation_options : option.domain_name => option }
}

resource "aws_route53_record" "cert_validation" {
  for_each = toset([local.app_host, local.api_host])

  zone_id         = var.route53_zone_id
  name            = local.cert_validation[each.key].resource_record_name
  type            = local.cert_validation[each.key].resource_record_type
  ttl             = 300
  records         = [local.cert_validation[each.key].resource_record_value]
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

resource "aws_lb" "this" {
  name                       = local.name
  load_balancer_type         = "application"
  internal                   = false
  subnets                    = aws_subnet.public[*].id
  security_groups            = [aws_security_group.alb.id]
  idle_timeout               = 60 # 6-2c raises the API's keepAliveTimeout above it (a go-live gate)
  drop_invalid_header_fields = true
  enable_deletion_protection = var.alb_deletion_protection

  dynamic "access_logs" {
    for_each = var.alb_access_logs ? [1] : []

    content {
      bucket  = aws_s3_bucket.alb_logs[0].id
      prefix  = "alb"
      enabled = true
    }
  }

  depends_on = [aws_s3_bucket_policy.alb_logs]
}

# API target health is LIVENESS (A7): readiness covers shared dependencies,
# so on /ready every task would fail together in a database or Valkey outage
# and ECS would recycle them all. Readiness is the pipeline's deploy gate
# instead. All-unhealthy routing stays fail-open (the ALB default).
resource "aws_lb_target_group" "api" {
  name                 = "${local.name}-api"
  port                 = 3000
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = aws_vpc.this.id
  deregistration_delay = 25 # inside the 25 s force exit and the 30 s stop timeout (DEPLOY.md §1)

  health_check {
    path                = "/api/v1/health"
    matcher             = "200"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_target_group" "web" {
  name                 = "${local.name}-web"
  port                 = 3001
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = aws_vpc.this.id
  deregistration_delay = 25

  health_check {
    path                = "/runtime-config.js"
    matcher             = "200"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.this.certificate_arn

  # A host that is neither app nor api (the bare *.elb.amazonaws.com name
  # included) gets a 404, never the app.
  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "Not found"
      status_code  = "404"
    }
  }
}

resource "aws_lb_listener_rule" "api" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }

  condition {
    host_header {
      values = [local.api_host]
    }
  }
}

resource "aws_lb_listener_rule" "web" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 20

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }

  condition {
    host_header {
      values = [local.app_host]
    }
  }
}

resource "aws_route53_record" "host" {
  for_each = { app = local.app_host, api = local.api_host }

  zone_id = var.route53_zone_id
  name    = each.value
  type    = "A"

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = false
  }
}

# ── access logs (A14: production) ───────────────────────────────────────────

data "aws_elb_service_account" "this" {}

resource "aws_s3_bucket" "alb_logs" {
  count = var.alb_access_logs ? 1 : 0

  bucket = "${local.name}-alb-logs-${var.account_id}"
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  count = var.alb_access_logs ? 1 : 0

  bucket                  = aws_s3_bucket.alb_logs[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "alb_logs" {
  count = var.alb_access_logs ? 1 : 0

  bucket = aws_s3_bucket.alb_logs[0].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# ALB access logs support SSE-S3 only.
resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  count = var.alb_access_logs ? 1 : 0

  bucket = aws_s3_bucket.alb_logs[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  count = var.alb_access_logs ? 1 : 0

  bucket = aws_s3_bucket.alb_logs[0].id

  rule {
    id     = "expire"
    status = "Enabled"

    filter {}

    expiration {
      days = var.alb_access_log_retention_days
    }
  }
}

data "aws_iam_policy_document" "alb_logs" {
  count = var.alb_access_logs ? 1 : 0

  # ap-south-1 predates the log-delivery service principal: the regional ELB
  # account writes the logs.
  statement {
    sid       = "ElbLogDelivery"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.alb_logs[0].arn}/alb/AWSLogs/${var.account_id}/*"]

    principals {
      type        = "AWS"
      identifiers = [data.aws_elb_service_account.this.arn]
    }
  }

  statement {
    sid     = "DenyNonTls"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.alb_logs[0].arn,
      "${aws_s3_bucket.alb_logs[0].arn}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "alb_logs" {
  count = var.alb_access_logs ? 1 : 0

  bucket = aws_s3_bucket.alb_logs[0].id
  policy = data.aws_iam_policy_document.alb_logs[0].json

  depends_on = [aws_s3_bucket_public_access_block.alb_logs]
}
