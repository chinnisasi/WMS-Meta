# Placeholders (REPLACE_ME): there is no real account yet. The operator
# replaces them and commits the result — the repo is public, so tfvars hold
# nothing account-sensitive beyond the account ID and role names (A9).
account_id = "REPLACE_ME"
operator_principal_arns = [
  "REPLACE_ME", # e.g. arn:aws:iam::<account>:role/*AWSReservedSSO_AdministratorAccess_* (the path follows the Identity Center home region)
]
