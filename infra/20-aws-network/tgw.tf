# Transit Gateway: the hub. No default route table: every attachment is explicitly associated, so routing is
# readable and the inspection toggle is a pure route change.
#
# enable_inspection = true:  spokes → inspection → (spoke | egress);  egress → inspection → spokes
# enable_inspection = false: spokes → (spoke | egress) directly;      egress → spokes directly

resource "aws_ec2_transit_gateway" "this" {
  description                     = "pngdemo hub"
  default_route_table_association = "disable"
  default_route_table_propagation = "disable"
  dns_support                     = "enable"
  auto_accept_shared_attachments  = "disable"
  tags                            = { Name = "pngdemo-hub" }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "connect" {
  transit_gateway_id                              = aws_ec2_transit_gateway.this.id
  vpc_id                                          = aws_vpc.connect.id
  subnet_ids                                      = [aws_subnet.connect_tgw.id]
  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false
  tags                                            = { Name = "pngdemo-dbx-connect" }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "services" {
  transit_gateway_id                              = aws_ec2_transit_gateway.this.id
  vpc_id                                          = aws_vpc.services.id
  subnet_ids                                      = [for s in aws_subnet.services_tgw : s.id]
  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false
  tags                                            = { Name = "pngdemo-internal-services" }
}

# Appliance mode: both directions of a flow use the same firewall endpoint (stateful inspection).
resource "aws_ec2_transit_gateway_vpc_attachment" "inspection" {
  transit_gateway_id                              = aws_ec2_transit_gateway.this.id
  vpc_id                                          = aws_vpc.inspection.id
  subnet_ids                                      = [aws_subnet.inspection_tgw.id]
  appliance_mode_support                          = "enable"
  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false
  tags                                            = { Name = "pngdemo-inspection" }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "egress" {
  transit_gateway_id                              = aws_ec2_transit_gateway.this.id
  vpc_id                                          = aws_vpc.egress.id
  subnet_ids                                      = [aws_subnet.egress_tgw.id]
  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false
  tags                                            = { Name = "pngdemo-egress" }
}

locals {
  attachments = {
    connect  = aws_ec2_transit_gateway_vpc_attachment.connect.id
    services = aws_ec2_transit_gateway_vpc_attachment.services.id
  }
}

# ---------- Route table for the spokes (dbx-connect, internal-services) ----------

resource "aws_ec2_transit_gateway_route_table" "spokes" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  tags               = { Name = "pngdemo-spokes" }
}

resource "aws_ec2_transit_gateway_route_table_association" "spokes" {
  for_each                       = local.attachments
  transit_gateway_attachment_id  = each.value
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spokes.id
}

resource "aws_ec2_transit_gateway_route" "spokes_default" {
  destination_cidr_block         = "0.0.0.0/0"
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spokes.id
  transit_gateway_attachment_id = (var.enable_inspection
    ? aws_ec2_transit_gateway_vpc_attachment.inspection.id
  : aws_ec2_transit_gateway_vpc_attachment.egress.id)
}

# Without inspection, spoke-to-spoke traffic goes direct.
resource "aws_ec2_transit_gateway_route" "spokes_direct" {
  for_each                       = var.enable_inspection ? {} : { connect = local.cidr.connect, services = local.cidr.services }
  destination_cidr_block         = each.value
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spokes.id
  transit_gateway_attachment_id  = local.attachments[each.key]
}

# ---------- Route table for the inspection VPC (traffic leaving the firewall) ----------

resource "aws_ec2_transit_gateway_route_table" "inspection" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  tags               = { Name = "pngdemo-inspection" }
}

resource "aws_ec2_transit_gateway_route_table_association" "inspection" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.inspection.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.inspection.id
}

resource "aws_ec2_transit_gateway_route" "inspection_to_spokes" {
  for_each                       = { connect = local.cidr.connect, services = local.cidr.services }
  destination_cidr_block         = each.value
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.inspection.id
  transit_gateway_attachment_id  = local.attachments[each.key]
}

resource "aws_ec2_transit_gateway_route" "inspection_default" {
  destination_cidr_block         = "0.0.0.0/0"
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.inspection.id
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.egress.id
}

# ---------- Route table for the egress VPC (return traffic from the internet) ----------

resource "aws_ec2_transit_gateway_route_table" "egress" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  tags               = { Name = "pngdemo-egress" }
}

resource "aws_ec2_transit_gateway_route_table_association" "egress" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.egress.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.egress.id
}

resource "aws_ec2_transit_gateway_route" "egress_to_spokes" {
  for_each                       = { connect = local.cidr.connect, services = local.cidr.services }
  destination_cidr_block         = each.value
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.egress.id
  transit_gateway_attachment_id = (var.enable_inspection
    ? aws_ec2_transit_gateway_vpc_attachment.inspection.id
  : local.attachments[each.key])
}
