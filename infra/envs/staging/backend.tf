# Partial S3 backend (decision 1): pass at init —
#   -backend-config="bucket=wms-tfstate-<account>-ap-south-1"
#   -backend-config="key=staging/terraform.tfstate"
#   -backend-config="region=ap-south-1" -backend-config="use_lockfile=true"
# (infra/README.md). Native S3 locking, no DynamoDB.
terraform {
  backend "s3" {}
}
