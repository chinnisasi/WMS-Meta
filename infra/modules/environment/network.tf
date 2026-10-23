# Decision 3: a VPC across two AZs — public (ALB, NAT), private-app (ECS) and
# private-data (RDS, Valkey) subnets; security groups chain ALB → app → data.

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = local.name }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = { Name = local.name }
}

resource "aws_subnet" "public" {
  count = 2

  vpc_id            = aws_vpc.this.id
  availability_zone = var.availability_zones[count.index]
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index)

  tags = { Name = "${local.name}-public-${var.availability_zones[count.index]}", tier = "public" }
}

resource "aws_subnet" "app" {
  count = 2

  vpc_id            = aws_vpc.this.id
  availability_zone = var.availability_zones[count.index]
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 10 + count.index)

  tags = { Name = "${local.name}-app-${var.availability_zones[count.index]}", tier = "app" }
}

resource "aws_subnet" "data" {
  count = 2

  vpc_id            = aws_vpc.this.id
  availability_zone = var.availability_zones[count.index]
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 20 + count.index)

  tags = { Name = "${local.name}-data-${var.availability_zones[count.index]}", tier = "data" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${local.name}-public" }
}

resource "aws_route_table_association" "public" {
  count = 2

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# NAT: one shared in staging, one per AZ in production (decision 3).
locals {
  nat_count = var.nat_gateway_per_az ? 2 : 1
}

resource "aws_eip" "nat" {
  count = local.nat_count

  domain = "vpc"

  tags = { Name = "${local.name}-nat-${count.index}" }
}

resource "aws_nat_gateway" "this" {
  count = local.nat_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = { Name = "${local.name}-${var.availability_zones[count.index]}" }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "app" {
  count = 2

  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this[var.nat_gateway_per_az ? count.index : 0].id
  }

  tags = { Name = "${local.name}-app-${var.availability_zones[count.index]}" }
}

resource "aws_route_table_association" "app" {
  count = 2

  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = aws_route_table.app[count.index].id
}

# The data tier has no route out at all.
resource "aws_route_table" "data" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "${local.name}-data" }
}

resource "aws_route_table_association" "data" {
  count = 2

  subnet_id      = aws_subnet.data[count.index].id
  route_table_id = aws_route_table.data.id
}

# ── endpoints (A14) ─────────────────────────────────────────────────────────

# S3 gateway (free): ECR layer downloads and the anchor bucket stay off the NAT.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.app[*].id

  tags = { Name = "${local.name}-s3" }
}

resource "aws_vpc_endpoint" "interface" {
  for_each = var.interface_endpoints ? toset(["ecr.api", "ecr.dkr", "secretsmanager", "logs"]) : toset([])

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.app[*].id
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = { Name = "${local.name}-${each.key}" }
}

# ── security groups ─────────────────────────────────────────────────────────

resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "WMS ${var.environment} load balancer: HTTPS (and the HTTP redirect) from anywhere"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${local.name}-alb" }
}

resource "aws_security_group" "app" {
  name        = "${local.name}-app"
  description = "WMS ${var.environment} ECS tasks: only the load balancer reaches them"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${local.name}-app" }
}

resource "aws_security_group" "data" {
  name        = "${local.name}-data"
  description = "WMS ${var.environment} RDS and Valkey: only the app tasks reach them"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${local.name}-data" }
}

resource "aws_security_group" "endpoints" {
  name        = "${local.name}-endpoints"
  description = "WMS ${var.environment} interface endpoints: HTTPS from the app tasks"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${local.name}-endpoints" }
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP (redirected to HTTPS)"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  for_each = { api = 3000, web = 3001 }

  security_group_id            = aws_security_group.alb.id
  description                  = "To the ${each.key} tasks"
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
  referenced_security_group_id = aws_security_group.app.id
}

resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  for_each = { api = 3000, web = 3001 }

  security_group_id            = aws_security_group.app.id
  description                  = "The ${each.key} port, from the load balancer"
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
  referenced_security_group_id = aws_security_group.alb.id
}

# Outbound: the data tier, the endpoints, and the internet through the NAT
# (Expo push, the channel APIs, e-way, SES).
resource "aws_vpc_security_group_egress_rule" "app_out" {
  security_group_id = aws_security_group.app.id
  description       = "All outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "data_from_app" {
  for_each = { postgres = 5432, valkey = 6379 }

  security_group_id            = aws_security_group.data.id
  description                  = "${each.key}, from the app tasks only"
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
  referenced_security_group_id = aws_security_group.app.id
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_from_app" {
  security_group_id            = aws_security_group.endpoints.id
  description                  = "HTTPS from the app tasks"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.app.id
}
