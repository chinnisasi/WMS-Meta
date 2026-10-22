# Staging (decisions 3–8, A14, A15). Placeholders (REPLACE_ME) until the
# operator fills in the account, domain and zone and commits — the repo is
# public, and those are the only account values here (A9). Never a secret.
account_id      = "REPLACE_ME"
domain          = "REPLACE_ME" # serves app.staging.<domain> / api.staging.<domain>
route53_zone_id = "REPLACE_ME"

vpc_cidr                = "10.20.0.0/16"
nat_gateway_per_az      = false # one shared NAT
interface_endpoints     = false
alb_deletion_protection = false
alb_access_logs         = false

api_cpu           = 512
api_memory        = 1024
api_desired_count = 1
api_autoscaling   = false # no autoscaling in staging (A14)
api_max_count     = 1
web_desired_count = 1

log_retention_days           = 30
ledger_anchor_retention_days = 1 # A15: the S3 path runs; each copy is locked 1 day, then the bucket lifecycle expires it

db_instance_class        = "db.t4g.small"
db_multi_az              = false
db_backup_retention_days = 7
db_deletion_protection   = false
db_final_snapshot        = false

valkey_node_type               = "cache.t4g.micro"
valkey_num_nodes               = 1
valkey_snapshot_retention_days = 1

secret_recovery_window_days = 0 # a destroyed staging can be re-created at once

push_gateway = "unconfigured"
eway_gateway = "unconfigured"
