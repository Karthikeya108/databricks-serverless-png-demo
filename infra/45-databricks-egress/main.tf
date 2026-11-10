# Databricks-native egress control for serverless (network policy), attached to the demo workspace.
#
#   egress_mode = "off"       the workspace uses the account's default policy (the policy object is kept)
#   egress_mode = "dry_run"   RESTRICTED rules evaluated and logged, nothing blocked
#   egress_mode = "enforced"  RESTRICTED: only the allowlist below (+ Unity Catalog locations and NCC destinations)
#
# The allowlist comes from services.yaml: egress_allowlist.databricks_zone (the same list your firewall uses in
# ALL_TRAFFIC mode, so both egress options enforce one policy) plus the internal services approved for the zone.
# Denials (and dry-run would-be denials) are logged in system.access.outbound_network.
#   terraform apply -var egress_mode=enforced     (or persist it in egress.auto.tfvars)
terraform {
  required_version = ">= 1.6"
  required_providers {
    databricks = {
      source  = "databricks/databricks"
      version = ">= 1.137, < 2.0"
    }
  }
}

provider "databricks" {
  host       = "https://accounts.cloud.databricks.com"
  account_id = var.databricks_account_id
  profile    = var.databricks_account_profile
}

variable "databricks_account_id" {
  description = "Databricks account ID (accounts console, top right). Set it in terraform.tfvars."
  type        = string
}

variable "databricks_account_profile" {
  type    = string
  default = "png-aws-acct"
}

variable "egress_mode" {
  type    = string
  default = "off"
  validation {
    condition     = contains(["off", "dry_run", "enforced"], var.egress_mode)
    error_message = "egress_mode must be off, dry_run or enforced."
  }
}

data "terraform_remote_state" "ws" {
  backend = "local"
  config  = { path = "${path.module}/../10-databricks-workspace/terraform.tfstate" }
}

locals {
  registry = yamldecode(file("${path.module}/../../services.yaml"))
  # Internet destinations (same list as the firewall) + the internal services. In SPECIFIC_DESTINATIONS mode the
  # gateway destinations are allowed automatically; in ALL_TRAFFIC mode they must be listed, so they always are.
  internal = concat([for n, s in local.registry.services : "${n}.${local.registry.domain}" if s.databricks_zone],
  [for n, d in local.registry.databases : "${n}.${local.registry.domain}" if d.databricks_zone])
  allowlist = concat(local.registry.egress_allowlist.databricks_zone, local.internal)
}

resource "databricks_account_network_policy" "egress" {
  account_id        = var.databricks_account_id # set explicitly: otherwise a mode change forces a replacement
  network_policy_id = "pngdemo-egress"
  egress = {
    network_access = {
      restriction_mode = "RESTRICTED_ACCESS"
      allowed_internet_destinations = [for d in local.allowlist : {
        destination               = d
        internet_destination_type = "DNS_NAME"
      }]
      policy_enforcement = {
        enforcement_mode = var.egress_mode == "enforced" ? "ENFORCED" : "DRY_RUN"
      }
    }
  }
}

resource "databricks_workspace_network_option" "demo" {
  workspace_id      = data.terraform_remote_state.ws.outputs.workspace_id
  network_policy_id = var.egress_mode == "off" ? "default-policy" : databricks_account_network_policy.egress.network_policy_id
}

output "egress" {
  value = {
    mode           = var.egress_mode
    policy_id      = databricks_account_network_policy.egress.network_policy_id
    attached       = databricks_workspace_network_option.demo.network_policy_id
    allowlist      = local.allowlist
    denials_sample = "SELECT event_time, access_type, destination_type, destination, network_source_type FROM system.access.outbound_network WHERE workspace_id = ${data.terraform_remote_state.ws.outputs.workspace_id} ORDER BY event_time DESC LIMIT 50"
  }
}
