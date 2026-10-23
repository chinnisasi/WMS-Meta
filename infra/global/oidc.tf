# GitHub Actions' OIDC issuer: the deploy roles (one per environment, in the
# environment module — A11) trust it, so no long-lived AWS key exists anywhere.
# AWS no longer checks the thumbprint for this issuer, so none is pinned.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}
