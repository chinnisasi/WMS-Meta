output "ecr_repository_urls" {
  description = "Image repositories, by name."
  value       = { for name, repo in aws_ecr_repository.app : name => repo.repository_url }
}

output "github_oidc_provider_arn" {
  description = "The GitHub Actions OIDC provider the deploy roles trust."
  value       = aws_iam_openid_connect_provider.github.arn
}

output "ses_identity_arn" {
  description = "The shared SES domain identity (the worker role may send as it)."
  value       = aws_sesv2_email_identity.domain.arn
}
