variable "region" {
  description = "The one AWS region (decision 1, D6: Mumbai)."
  type        = string
  default     = "ap-south-1"

  validation {
    condition     = var.region == "ap-south-1"
    error_message = "WMS runs in ap-south-1 only (D6)."
  }
}

variable "account_id" {
  description = "The AWS account both environments live in (A11: one account). Not a secret, but kept in tfvars only."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be the 12-digit AWS account ID (replace the REPLACE_ME placeholder)."
  }
}

variable "operator_principal_arns" {
  description = <<-EOT
    IAM principal ARN patterns (ArnLike) that may read and write Terraform state:
    the operator's admin SSO role, e.g.
    arn:aws:iam::<account>:role/*AWSReservedSSO_AdministratorAccess_*
    (the role's path follows the IAM Identity Center home region — some carry
    it as a segment, aws-reserved/sso.amazonaws.com/<region>/ — so the pattern
    wildcards the path; check with `aws iam list-roles --path-prefix /aws-reserved/`).
    Every other principal — the deploy roles included — is denied (A10). Each
    pattern must be in var.account_id: a typo here locks everyone out of the
    state (break-glass: infra/README.md).
  EOT
  type        = list(string)

  validation {
    condition     = length(var.operator_principal_arns) > 0 && alltrue([for arn in var.operator_principal_arns : startswith(arn, "arn:aws:iam::${var.account_id}:")])
    error_message = "operator_principal_arns needs at least one IAM ARN pattern, each in account_id's account (replace the REPLACE_ME placeholder)."
  }
}
