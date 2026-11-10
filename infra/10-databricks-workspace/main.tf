# serverless workspace, its own Unity Catalog metastore, account groups and assignments.
# Account-level OAuth (U2M) through the Databricks CLI profile; no AWS resources (serverless workspace).
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

variable "region" {
  type    = string
  default = "eu-central-1"
}

variable "prefix" {
  type    = string
  default = "pngdemo"
}

variable "group_members" {
  description = "Account users per demo group (user names / emails). Users must already exist in the account."
  type        = map(list(string))
}

locals {
  admins = "${var.prefix}-admins"
}

# ---------- Workspace ----------

# Serverless workspace: Databricks-managed compute and default storage; no VPC of your own,
# root bucket or cross-account role.
resource "databricks_mws_workspaces" "this" {
  account_id     = var.databricks_account_id
  workspace_name = "${var.prefix}-euc1"
  aws_region     = var.region
  compute_mode   = "SERVERLESS"
}

# ---------- Account groups ----------

resource "databricks_group" "demo" {
  for_each     = var.group_members
  display_name = each.key
}

data "databricks_user" "members" {
  for_each  = toset(flatten(values(var.group_members)))
  user_name = each.value
}

resource "databricks_group_member" "demo" {
  for_each = { for pair in flatten([
    for g, users in var.group_members : [for u in users : { key = "${g}/${u}", group = g, user = u }]
  ]) : pair.key => pair }

  group_id  = databricks_group.demo[each.value.group].id
  member_id = data.databricks_user.members[each.value.user].id
}

# ---------- Unity Catalog metastore ----------

# Own metastore, no root storage: each catalog gets a managed location in your S3 later.
resource "databricks_metastore" "this" {
  name          = "${var.prefix}-euc1-ms"
  region        = var.region
  owner         = local.admins
  force_destroy = true
  depends_on    = [databricks_group.demo]
}

resource "databricks_metastore_assignment" "this" {
  workspace_id = databricks_mws_workspaces.this.workspace_id
  metastore_id = databricks_metastore.this.id
}

# ---------- Workspace access for the account groups ----------

resource "databricks_mws_permission_assignment" "demo" {
  for_each     = databricks_group.demo
  workspace_id = databricks_mws_workspaces.this.workspace_id
  principal_id = each.value.id
  permissions  = [each.key == local.admins ? "ADMIN" : "USER"]
  depends_on   = [databricks_metastore_assignment.this]
}

output "workspace_id" {
  value = databricks_mws_workspaces.this.workspace_id
}

output "workspace_url" {
  value = databricks_mws_workspaces.this.workspace_url
}

output "metastore_id" {
  value = databricks_metastore.this.id
}

output "group_ids" {
  value = { for k, g in databricks_group.demo : k => g.id }
}
