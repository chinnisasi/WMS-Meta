variable "region" {
  description = "The one AWS region (D6)."
  type        = string
  default     = "ap-south-1"

  validation {
    condition     = var.region == "ap-south-1"
    error_message = "WMS runs in ap-south-1 only (D6)."
  }
}

variable "account_id" {
  description = "The one AWS account for both environments (A11)."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be the 12-digit AWS account ID (replace the REPLACE_ME placeholder)."
  }
}

variable "domain" {
  description = "The registrable domain both environments live under (the cookie rule: app.<domain> and api.<domain>, never *.elb.amazonaws.com). Also the SES sending identity."
  type        = string

  validation {
    condition     = can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", var.domain))
    error_message = "domain must be a lower-case DNS name such as example.in (replace the REPLACE_ME placeholder)."
  }
}

variable "route53_zone_id" {
  description = "The Route 53 public hosted zone for var.domain (created outside Terraform, with the registrar delegated to it)."
  type        = string

  validation {
    condition     = can(regex("^Z[A-Z0-9]+$", var.route53_zone_id))
    error_message = "route53_zone_id must be a Route 53 zone ID such as Z0123456789ABC (replace the REPLACE_ME placeholder)."
  }
}

variable "dmarc_record" {
  description = "The _dmarc TXT value. p=none (monitor only) until mail flows cleanly (A11). Set to null when the zone already has a DMARC record managed elsewhere."
  type        = string
  default     = "v=DMARC1; p=none;"
  nullable    = true
}
