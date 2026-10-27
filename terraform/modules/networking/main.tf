# VPC with PUBLIC SUBNETS ONLY.

data "aws_region" "current" {}

data "aws_availability_zones" "available" {
  # checkov:skip=CKV_AWS_394:Pinned two ways — the opt-in-status filter below excludes Local and Wavelength Zones, and var.availability_zones takes an explicit list. Either way the result is sliced to exactly two.
  state = "available"

  # Local Zones and Wavelength Zones are returned by this data source and are NOT
  # interchangeable with a standard AZ — Fargate and RDS are not available
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  # Two AZs: an ALB requires two subnets, and RDS needs a subnet group
  # spanning two even for a single-AZ instance.
  azs = length(var.availability_zones) > 0 ? var.availability_zones : slice(data.aws_availability_zones.available.names, 0, 2)
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true # required for RDS endpoint resolution

  tags = merge(var.tags, { Name = "${var.name_prefix}-vpc" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name_prefix}-igw" })
}

# Every VPC is created with a default security group that allows all traffic between
# anything attached to it.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id

  # No ingress and no egress blocks = no rules.

  tags = merge(var.tags, { Name = "${var.name_prefix}-default-DO-NOT-USE" })
}

resource "aws_subnet" "public" {
  for_each = { for idx, az in local.azs : az => idx }

  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, each.value)

  # Tasks need a public IP to reach ECR and Secrets Manager without a NAT.
  map_public_ip_on_launch = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-public-${each.key}" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-public-rt" })
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# --- Security groups ------------------------------------------------------- Three
# groups, chained.

resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-alb"
  description = "ALB: accepts public HTTP on the service listener ports"
  vpc_id      = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name_prefix}-alb" })
}

resource "aws_vpc_security_group_ingress_rule" "alb_listener" {
  for_each = toset([for p in var.alb_listener_ports : tostring(p)])

  security_group_id = aws_security_group.alb.id
  description       = "Public HTTP on listener port ${each.key}"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = tonumber(each.key)
  to_port           = tonumber(each.key)
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_all" {
  security_group_id = aws_security_group.alb.id
  description       = "ALB to targets"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "tasks" {
  name        = "${var.name_prefix}-tasks"
  description = "ECS tasks: accept traffic ONLY from the ALB"
  vpc_id      = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name_prefix}-tasks" })
}

resource "aws_vpc_security_group_ingress_rule" "tasks_from_alb" {
  security_group_id            = aws_security_group.tasks.id
  description                  = "nginx port, from the ALB security group only"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = var.task_ingress_port
  to_port                      = var.task_ingress_port
  ip_protocol                  = "tcp"
}

# Deliberately absent: a NAT gateway (~$32/mo). See var.enable_nat_gateway.

resource "aws_vpc_security_group_egress_rule" "tasks_all" {
  security_group_id = aws_security_group.tasks.id
  description       = "Outbound: ECR, Secrets Manager, CloudWatch, RDS, Anthropic API"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "rds" {
  name        = "${var.name_prefix}-rds"
  description = "RDS: accept 5432 from the task SG and the operator only"
  vpc_id      = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name_prefix}-rds" })
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_tasks" {
  security_group_id            = aws_security_group.rds.id
  description                  = "Postgres from the ECS tasks"
  referenced_security_group_id = aws_security_group.tasks.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_operator" {
  security_group_id = aws_security_group.rds.id
  description       = "Postgres from the operator, for the one-time database bootstrap"
  cidr_ipv4         = var.operator_cidr
  from_port         = 5432
  to_port           = 5432
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "rds_all" {
  security_group_id = aws_security_group.rds.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# Private subnets, NAT gateways, VPC endpoints and flow logs.

locals {
  private_enabled = var.enable_private_subnets
  # One NAT per AZ, or one shared. Nothing is created unless private subnets
  # are on — a NAT gateway attached to nothing is $32/month of scenery.
  use_nat_gateway  = var.enable_nat_gateway && var.nat_mode == "gateway"
  use_nat_instance = var.enable_nat_gateway && var.nat_mode == "instance"

  nat_azs = (local.private_enabled && local.use_nat_gateway
    ? (var.single_nat_gateway ? slice(local.azs, 0, 1) : local.azs)
  : [])
}

resource "aws_subnet" "private" {
  for_each = local.private_enabled ? { for idx, az in local.azs : az => idx } : {}

  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  # Offset by 10 so the private CIDRs never collide with the public ones, and
  # stay readable: 10.0.0.x/10.0.1.x public, 10.0.10.x/10.0.11.x private.
  cidr_block = cidrsubnet(var.vpc_cidr, 8, each.value + 10)

  # The whole point. No public IP, no route to the internet gateway.
  map_public_ip_on_launch = false

  tags = merge(var.tags, { Name = "${var.name_prefix}-private-${each.key}", Tier = "private" })
}

resource "aws_eip" "nat" {
  for_each = toset(local.nat_azs)

  domain = "vpc"
  tags   = merge(var.tags, { Name = "${var.name_prefix}-nat-${each.key}" })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  for_each = toset(local.nat_azs)

  allocation_id = aws_eip.nat[each.key].id
  # The NAT lives in the PUBLIC subnet and serves the private one.
  subnet_id = aws_subnet.public[each.key].id

  tags = merge(var.tags, { Name = "${var.name_prefix}-nat-${each.key}" })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "private" {
  for_each = local.private_enabled ? { for idx, az in local.azs : az => idx } : {}

  vpc_id = aws_vpc.this.id

  # A route table with no 0.0.0.0/0 route at all is the correct state when endpoints
  # No 0.0.0.0/0 route is correct when endpoints are used instead of NAT:
  # traffic to AWS services goes through the endpoint, and nowhere else.
  dynamic "route" {
    for_each = length(local.nat_azs) > 0 ? [1] : []
    content {
      cidr_block     = "0.0.0.0/0"
      nat_gateway_id = aws_nat_gateway.this[var.single_nat_gateway ? local.nat_azs[0] : each.key].id
    }
  }

  dynamic "route" {
    for_each = local.use_nat_instance && local.private_enabled ? [1] : []
    content {
      cidr_block           = "0.0.0.0/0"
      network_interface_id = aws_instance.nat[0].primary_network_interface_id
    }
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-private-rt-${each.key}" })
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}

# --- VPC endpoints --------------------------------------------------------- The
# no-NAT way to run private subnets.

resource "aws_security_group" "endpoints" {
  count = local.private_enabled && var.enable_vpc_endpoints ? 1 : 0

  name        = "${var.name_prefix}-vpce"
  description = "VPC interface endpoints: accept HTTPS from the tasks only"
  vpc_id      = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name_prefix}-vpce" })
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_from_tasks" {
  count = local.private_enabled && var.enable_vpc_endpoints ? 1 : 0

  security_group_id            = aws_security_group.endpoints[0].id
  description                  = "HTTPS from the ECS tasks"
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.tasks.id
}

resource "aws_vpc_endpoint" "gateway" {
  # S3, as a GATEWAY endpoint. Free, and required for ECR image pulls because
  # layers live in S3.
  count = local.private_enabled && var.enable_vpc_endpoints ? 1 : 0

  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [for rt in aws_route_table.private : rt.id]

  tags = merge(var.tags, { Name = "${var.name_prefix}-vpce-s3" })
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.private_enabled && var.enable_vpc_endpoints ? toset([
    "ecr.api",        # authenticate to the registry
    "ecr.dkr",        # pull the layers
    "logs",           # awslogs driver
    "secretsmanager", # DATABASE_URL at task start
    "ssmmessages",    # ECS Exec
  ]) : toset([])

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [for s in aws_subnet.private : s.id]
  security_group_ids  = [aws_security_group.endpoints[0].id]
  private_dns_enabled = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-vpce-${each.key}" })
}

# --- Flow logs -------------------------------------------------------------

resource "aws_cloudwatch_log_group" "flow" {
  count = var.enable_flow_logs ? 1 : 0

  name              = "/vpc/${var.name_prefix}/flow"
  retention_in_days = var.flow_log_retention_days
  tags              = var.tags
}

data "aws_iam_policy_document" "flow_assume" {
  count = var.enable_flow_logs ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "flow" {
  count = var.enable_flow_logs ? 1 : 0

  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
    ]
    resources = ["${aws_cloudwatch_log_group.flow[0].arn}:*"]
  }
}

resource "aws_iam_role" "flow" {
  count = var.enable_flow_logs ? 1 : 0

  name               = "${var.name_prefix}-vpc-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_assume[0].json
  tags               = var.tags
}

resource "aws_iam_role_policy" "flow" {
  count = var.enable_flow_logs ? 1 : 0

  name   = "${var.name_prefix}-vpc-flow-logs"
  role   = aws_iam_role.flow[0].id
  policy = data.aws_iam_policy_document.flow[0].json
}

resource "aws_flow_log" "this" {
  count = var.enable_flow_logs ? 1 : 0

  vpc_id          = aws_vpc.this.id
  traffic_type    = "ALL"
  log_destination = aws_cloudwatch_log_group.flow[0].arn
  iam_role_arn    = aws_iam_role.flow[0].arn

  tags = merge(var.tags, { Name = "${var.name_prefix}-flow" })
}

# NAT instance: the ~$3/month alternative to a ~$32/month managed gateway.
#
# What it gives up, stated rather than buried: it is one instance, so it is a
# single point of failure for every outbound connection from the private
# subnets, and it is a host somebody has to patch. A managed gateway is neither.

data "aws_ami" "nat" {
  count = local.use_nat_instance && local.private_enabled ? 1 : 0

  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-arm64"]
  }
}

resource "aws_security_group" "nat_instance" {
  count = local.use_nat_instance && local.private_enabled ? 1 : 0

  name        = "${var.name_prefix}-nat"
  description = "NAT instance: forwards outbound traffic from the private subnets"
  vpc_id      = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name_prefix}-nat" })
}

resource "aws_vpc_security_group_ingress_rule" "nat_from_vpc" {
  count = local.use_nat_instance && local.private_enabled ? 1 : 0

  security_group_id = aws_security_group.nat_instance[0].id
  description       = "All protocols from inside the VPC only"
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_egress_rule" "nat_out" {
  count = local.use_nat_instance && local.private_enabled ? 1 : 0

  security_group_id = aws_security_group.nat_instance[0].id
  description       = "Outbound to anywhere — this is what the instance exists to do"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_instance" "nat" {
  count = local.use_nat_instance && local.private_enabled ? 1 : 0

  ami           = data.aws_ami.nat[0].id
  instance_type = var.nat_instance_type
  subnet_id     = aws_subnet.public[local.azs[0]].id

  vpc_security_group_ids      = [aws_security_group.nat_instance[0].id]
  associate_public_ip_address = true

  # Without this the VPC drops every packet the instance forwards, because
  # the source address is not its own. This one attribute is what makes an
  # ordinary EC2 instance a NAT.
  source_dest_check = false

  # IMDSv2 only. The instance has no role attached, but a NAT sits in a public
  # subnet forwarding traffic, and v1's un-authenticated metadata endpoint is
  # the classic SSRF pivot.
  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    encrypted   = true
    volume_size = 8
    volume_type = "gp3"
  }

  user_data_replace_on_change = true
  user_data                   = <<-EOT
    #!/bin/bash
    set -euo pipefail
    # Masquerade everything arriving from the VPC out of the primary interface.
    IFACE="$(ip -o -4 route show to default | awk '{print $5}')"
    sysctl -w net.ipv4.ip_forward=1
    printf 'net.ipv4.ip_forward = 1\n' > /etc/sysctl.d/99-nat.conf
    dnf install -y iptables-services
    iptables -t nat -A POSTROUTING -o "$IFACE" -s ${var.vpc_cidr} -j MASQUERADE
    iptables -F FORWARD
    service iptables save
    systemctl enable --now iptables
  EOT

  tags = merge(var.tags, { Name = "${var.name_prefix}-nat" })
}
