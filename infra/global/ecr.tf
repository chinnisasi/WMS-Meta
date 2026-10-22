# One repository per image. Tags are the source commit's full SHA and are
# immutable: one image per SHA, promoted staging → production, never rebuilt
# (decision 2, A3).
resource "aws_ecr_repository" "app" {
  for_each = toset(["wms-be", "wms-fe"])

  name                 = each.key
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

# A12: only UNTAGGED images expire (layers left by a failed or superseded
# push). Tagged images are kept — they are what production runs and what a
# rollback re-deploys.
resource "aws_ecr_lifecycle_policy" "app" {
  for_each = aws_ecr_repository.app

  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire untagged images after 7 days"
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = 7
      }
      action = { type = "expire" }
    }]
  })
}
