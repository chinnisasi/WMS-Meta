# Production (decisions 3–8, A14, A15). Placeholders (REPLACE_ME) until the
# operator fills in the account, domain and zone and commits — the repo is
# public, and those are the only account values here (A9). Never a secret.
account_id      = "REPLACE_ME"
domain          = "REPLACE_ME" # serves app.<domain> / api.<domain>
route53_zone_id = "REPLACE_ME"

vpc_cidr                = "10.30.0.0/16"
nat_gateway_per_az      = true
interface_endpoints     = true
alb_deletion_protection = true
alb_access_logs         = true

api_cpu           = 1024
api_memory        = 2048
api_desired_count = 2    # AZ redundancy and a rolling deploy with no gap (A14)
api_autoscaling   = true # FIRST apply only: -var api_autoscaling=false (infra/README.md)
api_max_count     = 6
web_desired_count = 2

log_retention_days           = 90
ledger_anchor_retention_days = 2557

# t4g instances run in unlimited-credit mode; the CPU-credit alarm is 6.3's (A14).
db_instance_class        = "db.t4g.medium"
db_multi_az              = true
db_backup_retention_days = 14
db_deletion_protection   = true
db_final_snapshot        = true

valkey_node_type               = "cache.t4g.small"
valkey_num_nodes               = 2 # Multi-AZ automatic failover
valkey_snapshot_retention_days = 7

secret_recovery_window_days = 7

push_gateway = "unconfigured" # "expo" once EXPO_ACCESS_TOKEN is set
eway_gateway = "unconfigured"
