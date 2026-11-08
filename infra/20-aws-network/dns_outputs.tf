# Split-horizon DNS: <service>.<domain> resolves only inside these VPCs (the public DuckDNS record points to
# 127.0.0.1). The gateway resolves names with the dbx-connect VPC resolver, so this zone must be associated
# with that VPC. Records are added by infra/30-aws-services.
resource "aws_route53_zone" "internal" {
  name          = local.domain
  comment       = "pngdemo internal services (private, split horizon)"
  force_destroy = true

  vpc {
    vpc_id = aws_vpc.connect.id
  }
  vpc {
    vpc_id = aws_vpc.services.id
  }
}

output "domain" {
  value = local.domain
}

output "private_zone_id" {
  value = aws_route53_zone.internal.zone_id
}

output "cidr" {
  value = merge(local.cidr, { png_subnet = local.png_subnet_cidr })
}

output "connect" {
  description = "Inputs for the private network gateway (infra/40-databricks-network)."
  value = {
    vpc_id                = aws_vpc.connect.id
    png_subnet_id         = aws_subnet.png.id
    png_subnet_az_id      = aws_subnet.png.availability_zone_id
    png_security_group_id = aws_security_group.png.id
  }
}

output "services" {
  value = {
    vpc_id         = aws_vpc.services.id
    app_subnet_ids = [for s in aws_subnet.app : s.id]
    route_table_id = aws_route_table.app.id
  }
}

output "transit_gateway_id" {
  value = aws_ec2_transit_gateway.this.id
}

output "nat_public_ip" {
  description = "Source IP of all internet egress from the customer network (and the gateway in ALL_TRAFFIC mode)."
  value       = aws_eip.nat.public_ip
}

output "inspection" {
  value = {
    enabled     = var.enable_inspection
    mode        = var.firewall_mode
    endpoint_id = local.firewall_endpoint_id
    rules       = local.firewall_rules
  }
}

output "log_groups" {
  value = {
    png_flow       = aws_cloudwatch_log_group.png_flow.name
    firewall_alert = aws_cloudwatch_log_group.firewall["alert"].name
    firewall_flow  = aws_cloudwatch_log_group.firewall["flow"].name
  }
}
