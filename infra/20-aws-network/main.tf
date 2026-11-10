# Landing-zone simulation (your corporate network): hub-and-spoke network with inspection and central egress.
#
#   dbx-connect VPC   (Databricks landing zone: private network gateway subnet)  ┐
#   internal-services VPC (corporate network: internal ALB, services, Postgres)   ├─ Transit Gateway
#   inspection VPC    (AWS Network Firewall, toggle: enable_inspection)           │
#   egress VPC        (NAT + IGW: the only way to the internet)                   ┘
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
    tags = {
      project = "pngdemo"
      stack   = "20-aws-network"
      Owner   = var.owner
    }
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

variable "enable_inspection" {
  description = <<-EOT
    Route all spoke traffic through AWS Network Firewall. Default false: the firewall (~$10/day, billed per
    endpoint-hour) doesn't exist and the TGW routes spokes directly. Turn on the day before the demo:
    ./scripts/firewall.sh on   (≈ 5–10 min; rules and policy are kept while off, so nothing else changes)
  EOT
  type        = bool
  default     = false
}

variable "firewall_mode" {
  description = "network: one rule lets the Databricks zone reach the services network. per_service: only services with databricks_zone = true in services.yaml (TLS SNI match)."
  type        = string
  default     = "network"
  validation {
    condition     = contains(["network", "per_service"], var.firewall_mode)
    error_message = "firewall_mode must be network or per_service."
  }
}

variable "png_allow_internet" {
  description = "Let the gateway ENIs send HTTPS to the internet (needed only when the gateway runs in ALL_TRAFFIC mode)."
  type        = bool
  default     = false
}

locals {
  registry = yamldecode(file("${path.module}/../../services.yaml"))
  domain   = local.registry.domain

  # Placement by AZ ID (zone names differ per AWS account). The gateway supports euc1-az1/2/3.
  az1 = "euc1-az1"
  az2 = "euc1-az2"

  cidr = {
    connect    = "10.70.0.0/24"
    inspection = "10.71.0.0/24"
    services   = "10.80.0.0/20"
    egress     = "10.90.0.0/24"
  }
  png_subnet_cidr = "10.70.0.0/28"
  spoke_cidrs     = [local.cidr.connect, local.cidr.services]
}
