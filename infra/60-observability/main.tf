# Evidence for the network team: "Databricks serverless traffic enters our network through the private network
# gateway, and only there, and every call carries a named user."
#
#   - Saved CloudWatch Logs Insights queries (folder "pngdemo"), one click each in the demo
#   - Dashboard "pngdemo-private-network-gateway": gateway subnet → services, calls by user, firewall verdicts,
#     load balancer traffic per service
#
# Everything filters on the gateway SUBNET, not on fixed IPs: Databricks manages the gateway's network interfaces
# and their addresses can change over time. No address translation happens between the gateway and the services, so
# the gateway subnet is the source address in every log along the path.
# Cost: dashboards are free up to 3 per account; queries are billed per GB scanned (cents for this demo).
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile
  default_tags {
    tags = { project = "pngdemo", stack = "60-observability", Owner = var.owner }
  }
}

variable "region" {
  type    = string
  default = "eu-central-1"
}

variable "aws_profile" {
  type    = string
  default = "pngdemo-sandbox"
}

variable "owner" {
  type = string
}

data "terraform_remote_state" "net" {
  backend = "local"
  config  = { path = "${path.module}/../20-aws-network/terraform.tfstate" }
}

data "terraform_remote_state" "svc" {
  backend = "local"
  config  = { path = "${path.module}/../30-aws-services/terraform.tfstate" }
}

locals {
  net      = data.terraform_remote_state.net.outputs
  png_cidr = local.net.cidr.png_subnet
  logs = {
    flow     = local.net.log_groups.png_flow
    alert    = local.net.log_groups.firewall_alert
    services = data.terraform_remote_state.svc.outputs.log_group
  }
  registry      = yamldecode(file("${path.module}/../../services.yaml"))
  service_names = sort(keys(local.registry.services))

  queries = {
    gateway_to_services = {
      name   = "pngdemo/1 Gateway subnet -> internal services (VPC flow logs)"
      groups = [local.logs.flow]
      query  = <<-EOT
        fields @timestamp, interfaceId, srcAddr, dstAddr, dstPort, action
        | filter isIpv4InSubnet(srcAddr, "${local.png_cidr}") and dstPort in [443, 5432]
        | stats count(*) as connections, sum(bytes) as bytes, latest(@timestamp) as last_seen by interfaceId, srcAddr, dstAddr, dstPort, action
        | sort last_seen desc
      EOT
    }
    calls_by_user = {
      name   = "pngdemo/2 Calls by user and source (service logs)"
      groups = [local.logs.services]
      query  = <<-EOT
        fields @timestamp, @message, @logStream
        | filter @message like /mcp.auth call/
        | parse @message "call user=* client=* scp=* roles=* src=*" as user, client, scope, roles, src
        | parse @logStream "*/app/*" as service, task
        | fields isIpv4InSubnet(src, "${local.png_cidr}") as via_gateway
        | display @timestamp, service, user, roles, scope, src, via_gateway
        | sort @timestamp desc
        | limit 100
      EOT
    }
    firewall_verdicts = {
      name   = "pngdemo/3 Firewall verdicts for the gateway subnet (Network Firewall)"
      groups = [local.logs.alert]
      query  = <<-EOT
        fields @timestamp, event.src_ip, event.dest_ip, event.dest_port, event.tls.sni, event.alert.action, event.alert.signature
        | filter isIpv4InSubnet(event.src_ip, "${local.png_cidr}")
        | stats count(*) as events, latest(@timestamp) as last_seen by event.alert.action, event.tls.sni, event.dest_ip, event.alert.signature
        | sort last_seen desc
      EOT
    }
    rejected = {
      name   = "pngdemo/4 Rejected connections from the gateway subnet (VPC flow logs)"
      groups = [local.logs.flow]
      query  = <<-EOT
        fields @timestamp, interfaceId, srcAddr, dstAddr, dstPort, action
        | filter isIpv4InSubnet(srcAddr, "${local.png_cidr}") and action = "REJECT"
        | stats count(*) as attempts, latest(@timestamp) as last_seen by srcAddr, dstAddr, dstPort
        | sort last_seen desc
      EOT
    }
  }
}

# ---------- Saved queries (CloudWatch → Logs Insights → Saved queries → pngdemo) ----------

resource "aws_cloudwatch_query_definition" "this" {
  for_each        = local.queries
  name            = each.value.name
  log_group_names = each.value.groups
  query_string    = each.value.query
}

# ---------- Dashboard ----------

data "aws_lb" "internal" {
  name = "pngdemo-internal"
}

data "aws_lb_target_group" "svc" {
  for_each = toset(local.service_names)
  name     = "pngdemo-${each.key}"
}

locals {
  console = "https://${var.region}.console.aws.amazon.com"
  log_widget = { for k, q in local.queries : k => {
    type = "log"
    properties = {
      title  = trimprefix(q.name, "pngdemo/")
      region = var.region
      view   = "table"
      query  = "${join(" | ", [for g in q.groups : "SOURCE '${g}'"])} | ${q.query}"
    }
  } }
}

resource "aws_cloudwatch_dashboard" "png" {
  dashboard_name = "pngdemo-private-network-gateway"
  dashboard_body = jsonencode({
    start = "-PT1H"
    widgets = [
      {
        type = "text", x = 0, y = 0, width = 24, height = 3
        properties = {
          markdown = join("\n", [
            "## Databricks serverless → private network gateway → internal services",
            "The gateway's network interfaces live in **subnet ${local.png_cidr}** (your account, your security group). Every connection from Databricks serverless to the internal services starts there, and the source address is kept end to end (no NAT).",
            "[Gateway network interfaces](${local.console}/ec2/home?region=${var.region}#NIC:subnetId=${local.net.connect.png_subnet_id}) · [Saved queries](${local.console}/cloudwatch/home?region=${var.region}#logsV2:logs-insights) · Flow and firewall logs arrive with a delay of 1–10 minutes; the service log is near real time.",
          ])
        }
      },
      merge(local.log_widget.calls_by_user, { x = 0, y = 3, width = 24, height = 7 }),
      merge(local.log_widget.gateway_to_services, { x = 0, y = 10, width = 14, height = 7 }),
      {
        type = "metric", x = 14, y = 10, width = 10, height = 7
        properties = {
          title   = "Requests per internal service (internal load balancer)"
          region  = var.region
          view    = "timeSeries"
          stacked = true
          stat    = "Sum"
          period  = 60
          metrics = [for n in local.service_names : [
            "AWS/ApplicationELB", "RequestCountPerTarget", "TargetGroup", data.aws_lb_target_group.svc[n].arn_suffix,
            { label = n }
          ]]
        }
      },
      merge(local.log_widget.firewall_verdicts, { x = 0, y = 17, width = 14, height = 6 }),
      merge(local.log_widget.rejected, { x = 14, y = 17, width = 10, height = 6 }),
    ]
  })
}

output "dashboard_url" {
  value = "${local.console}/cloudwatch/home?region=${var.region}#dashboards/dashboard/${aws_cloudwatch_dashboard.png.dashboard_name}"
}

output "saved_queries" {
  value = [for q in local.queries : q.name]
}
