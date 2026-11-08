# Reusable smoke test with real traffic through the whole path, including AWS Network Firewall when it is on.
# Temporary t4g.nano instances, no public IP, no instance role, no SSH. Each runs its checks at boot and prints SMOKE
# lines to the serial console (aws ec2 get-console-output). Apply, read the consoles, destroy.
#
#   client-png  in the gateway subnet with the gateway's security group: sees exactly what serverless sees through
#               the private network gateway (same source range, same security group, same DNS).
#   client-svc  in the internal services network: central egress through the firewall (when enabled).
#
# TLS is verified (no -k): proves the public certificate, private DNS and ALB host rules together.
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
  region  = "eu-central-1"
  profile = "pngdemo-sandbox"
  default_tags {
    tags = { project = "pngdemo", stack = "21-network-smoke-test", Owner = var.owner }
  }
}

variable "owner" {
  type = string
}

data "terraform_remote_state" "net" {
  backend = "local"
  config  = { path = "${path.module}/../20-aws-network/terraform.tfstate" }
}

locals {
  net = data.terraform_remote_state.net.outputs
  d   = local.net.domain

  # name | url | expectation (documentation only; the console shows the actual HTTP code)
  png_checks = [
    ["servicedesk healthz", "https://servicedesk.${local.d}/healthz", "200"],
    ["servicedesk MCP without token", "https://servicedesk.${local.d}/mcp", "401"],
    ["assets healthz", "https://assets.${local.d}/healthz", "200"],
    ["orders without token", "https://orders.${local.d}/orders", "401"],
    ["legacy parts, no auth (shadow IT)", "https://legacy.${local.d}/parts?site_id=BER-01", "200 (or blocked in per_service firewall mode)"],
    ["unknown host on the ALB", "https://nothing.${local.d}/", "404"],
    ["internet from the gateway subnet", "https://pypi.org/simple/", "000 (gateway SG has no internet egress)"],
  ]
  svc_checks = [
    ["allowlisted login.microsoftonline.com", "https://login.microsoftonline.com/common/discovery/v2.0/keys", "200"],
    ["not allowlisted example.com", "https://example.com/", "200 without firewall, 000 with firewall"],
  ]

  checks_sh = { for who, list in { png = local.png_checks, svc = local.svc_checks } : who => join("\n", [
    for c in list : "t '${c[0]} (expect ${c[2]})' '${c[1]}'"
  ]) }

  # t <label> <url>: HTTP code with full TLS verification; 000 = no connection / TLS failure.
  header = <<-EOT
    #!/bin/bash
    t() { r=$(curl -s -o /dev/null -w "%%{http_code}" --connect-timeout 8 --max-time 15 "$2"); echo "SMOKE $WHO $1 -> $r" > /dev/console; }
  EOT
}

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

resource "aws_security_group" "client_svc" {
  name        = "pngdemo-smoke-client-svc"
  description = "temp smoke test client in the services network: all egress (the firewall decides)"
  vpc_id      = local.net.services.vpc_id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "client_png" {
  ami                         = data.aws_ssm_parameter.al2023.value
  instance_type               = "t4g.nano"
  subnet_id                   = local.net.connect.png_subnet_id
  vpc_security_group_ids      = [local.net.connect.png_security_group_id]
  associate_public_ip_address = false
  metadata_options { http_tokens = "required" }
  user_data = <<-EOT
    ${local.header}
    WHO=client-png
    echo "SMOKE $WHO dns servicedesk.${local.d} -> $(getent hosts servicedesk.${local.d} | awk '{print $1}' | tr '\n' ' ')" > /dev/console
    ${local.checks_sh.png}
    if timeout 5 bash -c '</dev/tcp/postgres.${local.d}/5432' 2>/dev/null; then pg=open; else pg=closed; fi
    echo "SMOKE $WHO postgres.${local.d}:5432 tcp (expect open) -> $pg" > /dev/console
    echo "SMOKE $WHO done" > /dev/console
  EOT
  tags      = { Name = "pngdemo-smoke-client-png" }
}

resource "aws_instance" "client_svc" {
  ami                         = data.aws_ssm_parameter.al2023.value
  instance_type               = "t4g.nano"
  subnet_id                   = local.net.services.app_subnet_ids[1]
  vpc_security_group_ids      = [aws_security_group.client_svc.id]
  associate_public_ip_address = false
  metadata_options { http_tokens = "required" }
  user_data = <<-EOT
    ${local.header}
    WHO=client-svc
    ${local.checks_sh.svc}
    echo "SMOKE $WHO done" > /dev/console
  EOT
  tags      = { Name = "pngdemo-smoke-client-svc" }
}

output "instances" {
  value = { client_png = aws_instance.client_png.id, client_svc = aws_instance.client_svc.id }
}
