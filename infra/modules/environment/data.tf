# Decision 6 + A14: RDS Postgres 18 and ElastiCache Valkey 8 in the data
# subnets, reachable only from the app security group.
#
# Maintenance: Sunday 21:30–22:30 UTC (03:00 IST); RDS backups 20:00–21:00 UTC.

locals {
  db_name       = "wms"
  db_owner      = "wms" # the RDS master user: owns the schema, runs the migrator (A6)
  db_port       = 5432
  valkey_port   = 6379
  maint_window  = "sun:21:30-sun:22:30"
  backup_window = "20:00-21:00"
}

resource "aws_db_subnet_group" "this" {
  name       = local.name
  subnet_ids = aws_subnet.data[*].id
}

# Prefixed, so a family change (a major upgrade) can create the new group
# before destroying the old one (create_before_destroy).
resource "aws_db_parameter_group" "this" {
  name_prefix = "${local.name}-"
  family      = var.db_parameter_group_family

  # Already RDS's default for Postgres 15+; kept explicit (A14) so a changed
  # default can never let a plaintext connection in. The URLs carry
  # sslmode=require; verify-full needs the RDS CA in the image (6-2c).
  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "this" {
  identifier     = local.name
  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  db_name  = local.db_name
  username = local.db_owner
  password = random_password.db_master.result
  port     = local.db_port

  storage_type          = "gp3"
  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage
  storage_encrypted     = true # the AWS-managed key (A14)

  multi_az               = var.db_multi_az
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.data.id]
  publicly_accessible    = false
  parameter_group_name   = aws_db_parameter_group.this.name
  ca_cert_identifier     = "rds-ca-rsa2048-g1"

  backup_retention_period    = var.db_backup_retention_days
  backup_window              = local.backup_window
  maintenance_window         = local.maint_window
  auto_minor_version_upgrade = true
  copy_tags_to_snapshot      = true

  performance_insights_enabled          = true
  performance_insights_retention_period = 7

  deletion_protection       = var.db_deletion_protection
  skip_final_snapshot       = !var.db_final_snapshot
  final_snapshot_identifier = var.db_final_snapshot ? "${local.name}-final" : null

  apply_immediately = false
}

resource "aws_elasticache_subnet_group" "this" {
  name       = local.name
  subnet_ids = aws_subnet.data[*].id
}

# Reservations are the only thing in Valkey and they fail closed without
# their counters: never evict (A14).
# ElastiCache parameter groups take no name_prefix: the family is in the name
# instead, so a family change still creates the new group before the old one
# goes (create_before_destroy).
resource "aws_elasticache_parameter_group" "this" {
  name   = "${local.name}-${var.valkey_parameter_group_family}"
  family = var.valkey_parameter_group_family

  parameter {
    name  = "maxmemory-policy"
    value = "noeviction"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_elasticache_replication_group" "this" {
  replication_group_id = local.name
  description          = "WMS ${var.environment} reservation counters"

  engine               = "valkey"
  engine_version       = var.valkey_engine_version
  node_type            = var.valkey_node_type
  num_cache_clusters   = var.valkey_num_nodes
  port                 = local.valkey_port
  parameter_group_name = aws_elasticache_parameter_group.this.name

  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [aws_security_group.data.id]

  automatic_failover_enabled = var.valkey_num_nodes > 1
  multi_az_enabled           = var.valkey_num_nodes > 1

  transit_encryption_enabled = true
  at_rest_encryption_enabled = true
  auth_token                 = random_password.valkey_auth.result

  snapshot_retention_limit   = var.valkey_snapshot_retention_days
  snapshot_window            = local.backup_window
  maintenance_window         = local.maint_window
  auto_minor_version_upgrade = true
  apply_immediately          = false
}
