# internal services in the "corporate network" (internal-services VPC):
#   ECR + CodeBuild image build · VPC endpoints · ECS Fargate (one service per services.yaml entry)
#   internal ALB (TLS with the public wildcard certificate, host-based routing) · private DNS · RDS Postgres
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.8"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.4"
    }
  }
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile
  default_tags {
    tags = { project = "pngdemo", stack = "30-aws-services", Owner = var.owner }
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

variable "demo_users" {
  description = "UPNs that own seeded records (comma-separated): persona A first. Keep in sync with the bundle."
  type        = string
}

variable "enable_postgres" {
  type    = bool
  default = true
}

data "terraform_remote_state" "net" {
  backend = "local"
  config  = { path = "${path.module}/../20-aws-network/terraform.tfstate" }
}

data "terraform_remote_state" "cert" {
  backend = "local"
  config  = { path = "${path.module}/../25-certificate/terraform.tfstate" }
}

data "aws_caller_identity" "current" {}

locals {
  net      = data.terraform_remote_state.net.outputs
  registry = yamldecode(file("${path.module}/../../services.yaml"))
  domain   = local.registry.domain

  # Entra IDs written by scripts/01-entra-apps.sh (IDs only, no secrets).
  entra = {
    for k in ["TENANT_ID", "MCP_API_APP_ID", "MCP_CLIENT_APP_ID"] :
    k => regex("${k}=(\\S+)", file("${path.module}/../../.state/entra.env"))[0]
  }

  # One container per service; MCP services pick their tool set, REST services their API.
  services = {
    for name, s in local.registry.services : name => {
      server = s.kind == "mcp" ? s.server : name
      fqdn   = "${name}.${local.domain}"
      kind   = s.kind
      auth   = s.auth
    }
  }

  services_cidr   = local.net.cidr.services
  png_subnet_cidr = local.net.cidr.png_subnet
  app_subnet_ids  = local.net.services.app_subnet_ids
}
