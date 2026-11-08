# ---------- dbx-connect: the Databricks landing zone (no internet gateway, no direct route out) ----------

resource "aws_vpc" "connect" {
  cidr_block           = local.cidr.connect
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "pngdemo-dbx-connect" }
}

# Exactly one subnet in one AZ for the private network gateway. Dedicated to the gateway.
resource "aws_subnet" "png" {
  vpc_id               = aws_vpc.connect.id
  cidr_block           = local.png_subnet_cidr
  availability_zone_id = local.az1
  tags                 = { Name = "pngdemo-dbx-connect-png-${local.az1}" }
}

resource "aws_subnet" "connect_tgw" {
  vpc_id               = aws_vpc.connect.id
  cidr_block           = "10.70.0.16/28"
  availability_zone_id = local.az1
  tags                 = { Name = "pngdemo-dbx-connect-tgw-${local.az1}" }
}

# Gateway ENIs: no inbound; outbound only to the internal services network (443, 5432),
# plus HTTPS to the internet when the gateway runs in ALL_TRAFFIC mode.
resource "aws_security_group" "png" {
  name        = "pngdemo-png-sg"
  description = "Private network gateway ENIs: no inbound; egress to internal services only"
  vpc_id      = aws_vpc.connect.id
  tags        = { Name = "pngdemo-png-sg" }
}

resource "aws_vpc_security_group_egress_rule" "png_services" {
  for_each          = toset(["443", "5432"])
  security_group_id = aws_security_group.png.id
  description       = "Internal services (${each.key})"
  ip_protocol       = "tcp"
  from_port         = tonumber(each.key)
  to_port           = tonumber(each.key)
  cidr_ipv4         = local.cidr.services
}

resource "aws_vpc_security_group_egress_rule" "png_internet" {
  count             = var.png_allow_internet ? 1 : 0
  security_group_id = aws_security_group.png.id
  description       = "HTTPS to the internet (ALL_TRAFFIC mode; filtered by the firewall)"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_route_table" "png" {
  vpc_id = aws_vpc.connect.id
  tags   = { Name = "pngdemo-dbx-connect-png" }
}

resource "aws_route" "png_default" {
  route_table_id         = aws_route_table.png.id
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = aws_ec2_transit_gateway.this.id
  depends_on             = [aws_ec2_transit_gateway_vpc_attachment.connect]
}

resource "aws_route_table_association" "png" {
  subnet_id      = aws_subnet.png.id
  route_table_id = aws_route_table.png.id
}

# Flow logs on the gateway subnet: every connection the gateway ENIs make (allowed and rejected).
resource "aws_cloudwatch_log_group" "png_flow" {
  name              = "/pngdemo/vpc-flow/png-subnet"
  retention_in_days = 7
}

resource "aws_iam_role" "flow_logs" {
  name = "pngdemo-vpc-flow-logs"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id } }
    }]
  })
}

# Least privilege: write to this one log group only.
resource "aws_iam_role_policy" "flow_logs" {
  name = "write-png-flow-log-group"
  role = aws_iam_role.flow_logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
      Resource = "${aws_cloudwatch_log_group.png_flow.arn}:*"
    }]
  })
}

resource "aws_flow_log" "png" {
  subnet_id                = aws_subnet.png.id
  traffic_type             = "ALL"
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.png_flow.arn
  iam_role_arn             = aws_iam_role.flow_logs.arn
  max_aggregation_interval = 60
  tags                     = { Name = "pngdemo-png-subnet" }
}

data "aws_caller_identity" "current" {}

# ---------- internal-services: the "corporate network" ----------

resource "aws_vpc" "services" {
  cidr_block           = local.cidr.services
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "pngdemo-internal-services" }
}

# Two AZs: required by the internal ALB and the RDS subnet group.
resource "aws_subnet" "app" {
  for_each             = { a = { az = local.az1, cidr = "10.80.0.0/24" }, b = { az = local.az2, cidr = "10.80.1.0/24" } }
  vpc_id               = aws_vpc.services.id
  cidr_block           = each.value.cidr
  availability_zone_id = each.value.az
  tags                 = { Name = "pngdemo-services-app-${each.value.az}" }
}

resource "aws_subnet" "services_tgw" {
  for_each             = { a = { az = local.az1, cidr = "10.80.15.0/28" }, b = { az = local.az2, cidr = "10.80.15.16/28" } }
  vpc_id               = aws_vpc.services.id
  cidr_block           = each.value.cidr
  availability_zone_id = each.value.az
  tags                 = { Name = "pngdemo-services-tgw-${each.value.az}" }
}

# Central egress: everything that isn't local goes to the Transit Gateway (and so through inspection).
resource "aws_route_table" "app" {
  vpc_id = aws_vpc.services.id
  tags   = { Name = "pngdemo-services-app" }
}

resource "aws_route" "app_default" {
  route_table_id         = aws_route_table.app.id
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = aws_ec2_transit_gateway.this.id
  depends_on             = [aws_ec2_transit_gateway_vpc_attachment.services]
}

resource "aws_route_table_association" "app" {
  for_each       = aws_subnet.app
  subnet_id      = each.value.id
  route_table_id = aws_route_table.app.id
}

# ---------- inspection: AWS Network Firewall between the TGW and everything else ----------

resource "aws_vpc" "inspection" {
  cidr_block = local.cidr.inspection
  tags       = { Name = "pngdemo-inspection" }
}

resource "aws_subnet" "inspection_tgw" {
  vpc_id               = aws_vpc.inspection.id
  cidr_block           = "10.71.0.0/28"
  availability_zone_id = local.az1
  tags                 = { Name = "pngdemo-inspection-tgw-${local.az1}" }
}

resource "aws_subnet" "firewall" {
  vpc_id               = aws_vpc.inspection.id
  cidr_block           = "10.71.0.16/28"
  availability_zone_id = local.az1
  tags                 = { Name = "pngdemo-inspection-firewall-${local.az1}" }
}

# TGW → firewall endpoint
resource "aws_route_table" "inspection_tgw" {
  vpc_id = aws_vpc.inspection.id
  tags   = { Name = "pngdemo-inspection-tgw" }
}

resource "aws_route" "inspection_tgw_to_fw" {
  count                  = var.enable_inspection ? 1 : 0
  route_table_id         = aws_route_table.inspection_tgw.id
  destination_cidr_block = "0.0.0.0/0"
  vpc_endpoint_id        = local.firewall_endpoint_id
}

resource "aws_route_table_association" "inspection_tgw" {
  subnet_id      = aws_subnet.inspection_tgw.id
  route_table_id = aws_route_table.inspection_tgw.id
}

# firewall endpoint → TGW
resource "aws_route_table" "firewall" {
  vpc_id = aws_vpc.inspection.id
  tags   = { Name = "pngdemo-inspection-firewall" }
}

resource "aws_route" "firewall_to_tgw" {
  route_table_id         = aws_route_table.firewall.id
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = aws_ec2_transit_gateway.this.id
  depends_on             = [aws_ec2_transit_gateway_vpc_attachment.inspection]
}

resource "aws_route_table_association" "firewall" {
  subnet_id      = aws_subnet.firewall.id
  route_table_id = aws_route_table.firewall.id
}

# ---------- egress: the only internet exit (NAT + IGW) ----------

resource "aws_vpc" "egress" {
  cidr_block = local.cidr.egress
  tags       = { Name = "pngdemo-egress" }
}

resource "aws_subnet" "egress_public" {
  vpc_id               = aws_vpc.egress.id
  cidr_block           = "10.90.0.0/27"
  availability_zone_id = local.az1
  tags                 = { Name = "pngdemo-egress-public-${local.az1}" }
}

resource "aws_subnet" "egress_tgw" {
  vpc_id               = aws_vpc.egress.id
  cidr_block           = "10.90.0.32/28"
  availability_zone_id = local.az1
  tags                 = { Name = "pngdemo-egress-tgw-${local.az1}" }
}

resource "aws_internet_gateway" "egress" {
  vpc_id = aws_vpc.egress.id
  tags   = { Name = "pngdemo-egress" }
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "pngdemo-egress-nat" }
}

resource "aws_nat_gateway" "egress" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.egress_public.id
  tags          = { Name = "pngdemo-egress" }
  depends_on    = [aws_internet_gateway.egress]
}

resource "aws_route_table" "egress_public" {
  vpc_id = aws_vpc.egress.id
  tags   = { Name = "pngdemo-egress-public" }
}

resource "aws_route" "egress_public_igw" {
  route_table_id         = aws_route_table.egress_public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.egress.id
}

# Return traffic to the spokes goes back via the TGW.
resource "aws_route" "egress_public_spokes" {
  route_table_id         = aws_route_table.egress_public.id
  destination_cidr_block = "10.0.0.0/8"
  transit_gateway_id     = aws_ec2_transit_gateway.this.id
  depends_on             = [aws_ec2_transit_gateway_vpc_attachment.egress]
}

resource "aws_route_table_association" "egress_public" {
  subnet_id      = aws_subnet.egress_public.id
  route_table_id = aws_route_table.egress_public.id
}

resource "aws_route_table" "egress_tgw" {
  vpc_id = aws_vpc.egress.id
  tags   = { Name = "pngdemo-egress-tgw" }
}

resource "aws_route" "egress_tgw_nat" {
  route_table_id         = aws_route_table.egress_tgw.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.egress.id
}

resource "aws_route_table_association" "egress_tgw" {
  subnet_id      = aws_subnet.egress_tgw.id
  route_table_id = aws_route_table.egress_tgw.id
}
