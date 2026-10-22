# A15: the ledger anchor WORM bucket — S3 Object Lock COMPLIANCE, in BOTH
# environments, so the S3 path runs in staging before production. Staging
# keeps objects 1 day (COMPLIANCE objects cannot be deleted before then),
# production 2557 days. SSE-S3.

resource "aws_s3_bucket" "ledger_anchors" {
  bucket              = "${local.name}-ledger-anchors-${var.account_id}"
  object_lock_enabled = true
  # Staging only: a destroyed staging can take its (expired) anchors with it.
  # Production's anchors are evidence and are never force-deleted.
  force_destroy = var.environment == "staging"
}

# Staging only: once an anchor's 1-day COMPLIANCE lock has passed, expire it
# (current and noncurrent versions), so staging's bucket does not grow forever.
resource "aws_s3_bucket_lifecycle_configuration" "ledger_anchors" {
  count = var.environment == "staging" ? 1 : 0

  bucket = aws_s3_bucket.ledger_anchors.id

  rule {
    id     = "expire-after-retention"
    status = "Enabled"

    filter {}

    expiration {
      days = var.ledger_anchor_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = var.ledger_anchor_retention_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.ledger_anchors]
}

resource "aws_s3_bucket_ownership_controls" "ledger_anchors" {
  bucket = aws_s3_bucket.ledger_anchors.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "ledger_anchors" {
  bucket                  = aws_s3_bucket.ledger_anchors.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "ledger_anchors" {
  bucket = aws_s3_bucket.ledger_anchors.id

  versioning_configuration {
    status = "Enabled" # implied by Object Lock; stated so it is never suspended
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "ledger_anchors" {
  bucket = aws_s3_bucket.ledger_anchors.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# A backstop: the code sets each object's own COMPLIANCE retain-until
# (anchoredAt + LEDGER_ANCHOR_RETENTION_DAYS); this default covers a put that
# did not.
resource "aws_s3_bucket_object_lock_configuration" "ledger_anchors" {
  bucket = aws_s3_bucket.ledger_anchors.id

  rule {
    default_retention {
      mode = "COMPLIANCE"
      days = var.ledger_anchor_retention_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.ledger_anchors]
}

data "aws_iam_policy_document" "ledger_anchors" {
  statement {
    sid     = "DenyNonTls"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.ledger_anchors.arn,
      "${aws_s3_bucket.ledger_anchors.arn}/*",
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

resource "aws_s3_bucket_policy" "ledger_anchors" {
  bucket = aws_s3_bucket.ledger_anchors.id
  policy = data.aws_iam_policy_document.ledger_anchors.json

  depends_on = [aws_s3_bucket_public_access_block.ledger_anchors]
}
