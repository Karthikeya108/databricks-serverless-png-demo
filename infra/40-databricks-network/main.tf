# the demo's network connectivity configuration (NCC): one object, two private paths.
#
#   Path 1  Private Link (private endpoint rule) → customer S3 bucket (catalog managed location)
#   Path 2  Private network gateway → dbx-connect VPC → TGW (→ firewall) → internal services
#
# S3 rule order (documented): create the rule → bucket policy with the endpoint ID → enable the rule. Two applies:
#   terraform apply                          # rule created (disabled), gateway, binding
#   terraform apply -var s3_rule_enabled=true  # bucket policy + rule enabled (persist it in terraform.tfvars)
#
# Binding this NCC to the workspace makes it the workspace's NCC (it replaces any previously bound NCC).
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    databricks = {
      source  = "databricks/databricks"
      version = ">= 1.137, < 2.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile
  default_tags {
    tags = { project = "pngdemo", stack = "40-databricks-network", Owner = var.owner }
  }
}

provider "databricks" {
  host       = "https://accounts.cloud.databricks.com"
  account_id = var.databricks_account_id
  profile    = var.databricks_account_profile
}

variable "region" {
  type    = string
  default = "eu-central-1"
}

variable "aws_profile" {
  type    = string
  default = "pngdemo-sandbox"
}

variable "databricks_account_id" {
  description = "Databricks account ID (accounts console, top right). Set it in terraform.tfvars."
  type        = string
}

variable "databricks_account_profile" {
  type    = string
  default = "png-aws-acct"
}

variable "owner" {
  type = string
}

variable "admin_role_arn" {
  description = "IAM role exempted from the bucket's deny-all policy (your SSO admin role), so nobody gets locked out."
  type        = string
}

variable "s3_rule_enabled" {
  description = "Second apply: write the bucket policy and enable the S3 private endpoint rule."
  type        = bool
  default     = false
}

variable "enable_png" {
  description = "Create the private network gateway (false shows the 'before' state in the demo)."
  type        = bool
  default     = true
}

variable "png_traffic_mode" {
  description = "SPECIFIC_DESTINATIONS (internal services only) or ALL_TRAFFIC (all serverless egress via the customer network)."
  type        = string
  default     = "SPECIFIC_DESTINATIONS"
}

# Databricks control-plane VPCs for eu-central-1 (docs: "IP addresses and domains for Databricks services").
# Unity Catalog reaches the bucket from here (e.g. external location validation).
variable "control_plane_vpc_ids" {
  type    = list(string)
  default = ["vpc-0fac49d340642f67b", "vpc-0b6768aacb36c9425"]
}

data "terraform_remote_state" "net" {
  backend = "local"
  config  = { path = "${path.module}/../20-aws-network/terraform.tfstate" }
}

data "terraform_remote_state" "data" {
  backend = "local"
  config  = { path = "${path.module}/../35-aws-data/terraform.tfstate" }
}

data "terraform_remote_state" "ws" {
  backend = "local"
  config  = { path = "${path.module}/../10-databricks-workspace/terraform.tfstate" }
}

data "aws_caller_identity" "current" {}

locals {
  net    = data.terraform_remote_state.net.outputs
  bucket = data.terraform_remote_state.data.outputs.data_bucket
  ncc_id = databricks_mws_network_connectivity_config.this.network_connectivity_config_id
}

# ---------- NCC ----------

resource "databricks_mws_network_connectivity_config" "this" {
  name   = "pngdemo-ncc-euc1"
  region = var.region
}

# ---------- Path 1: Private Link to the customer bucket ----------

resource "databricks_mws_ncc_private_endpoint_rule" "s3" {
  network_connectivity_config_id = local.ncc_id
  endpoint_service               = "com.amazonaws.${var.region}.s3"
  resource_names                 = [local.bucket]
  # Can only be set after the rule exists (documented): second apply.
  enabled = var.s3_rule_enabled ? true : null
}

# Deny everything that doesn't come through the serverless private endpoint or the UC control plane,
# except the admin role (console/CLI/Terraform) so nobody is locked out.
resource "aws_s3_bucket_policy" "data" {
  count  = var.s3_rule_enabled ? 1 : 0
  bucket = local.bucket
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyUnlessServerlessPrivateEndpointOrUnityCatalog"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = ["arn:aws:s3:::${local.bucket}", "arn:aws:s3:::${local.bucket}/*"]
      Condition = {
        StringNotEqualsIfExists = {
          "aws:SourceVpce" = databricks_mws_ncc_private_endpoint_rule.s3.vpc_endpoint_id
          "aws:SourceVpc"  = var.control_plane_vpc_ids
        }
        ArnNotEquals = {
          "aws:PrincipalArn" = var.admin_role_arn
        }
      }
    }]
  })

  lifecycle {
    precondition {
      condition     = databricks_mws_ncc_private_endpoint_rule.s3.vpc_endpoint_id != null && databricks_mws_ncc_private_endpoint_rule.s3.vpc_endpoint_id != ""
      error_message = "The S3 rule has no VPC endpoint ID yet; wait until it is ESTABLISHED, then re-apply."
    }
  }
}

# ---------- Path 2: private network gateway ----------

resource "aws_iam_role" "png" {
  name        = "pngdemo-png-role"
  description = "Databricks private network gateway: manages the gateway ENIs in the dbx-connect VPC only"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::414351767826:role/png-management-role" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "sts:ExternalId" = var.databricks_account_id } }
    }]
  })
}

# Verbatim from the setup guide ("All statements are required"), scoped to this region, account and VPC.
resource "aws_iam_role_policy" "png" {
  name = "pngdemo-png-policy"
  role = aws_iam_role.png.id
  policy = templatefile("${path.module}/policies/png-permissions.json.tftpl", {
    region     = var.region
    account_id = data.aws_caller_identity.current.account_id
    vpc_id     = local.net.connect.vpc_id
  })
}

resource "time_sleep" "iam_propagation" {
  create_duration = "30s"
  triggers = {
    role_arn  = aws_iam_role.png.arn
    policy_id = aws_iam_role_policy.png.id
  }
}

# Destroy guard: Databricks removes the gateway ENIs asynchronously AFTER the gateway delete returns, using the
# cross-account role, so the role must stay until that cleanup has finished.
# Destroy order: gateway → this (waits until no Databricks ENI is left in the subnet) → role.
resource "terraform_data" "png_eni_cleanup_guard" {
  input = {
    subnet_id = local.net.connect.png_subnet_id
    profile   = var.aws_profile
    region    = var.region
    role_arn  = time_sleep.iam_propagation.triggers["role_arn"]
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      for i in $(seq 1 90); do
        n=$(aws ec2 describe-network-interfaces --region ${self.input.region} --profile ${self.input.profile} \
          --filters Name=subnet-id,Values=${self.input.subnet_id} Name=tag:Vendor,Values=Databricks \
          --query 'length(NetworkInterfaces)' --output text)
        [ "$n" = "0" ] && { echo "gateway ENIs cleaned up"; exit 0; }
        echo "waiting for $n gateway ENI(s) to be removed by Databricks..."; sleep 20
      done
      echo "gateway ENIs still present after 30 min" >&2; exit 1
    EOT
  }
}

resource "databricks_private_network_gateway" "this" {
  count        = var.enable_png ? 1 : 0
  depends_on   = [terraform_data.png_eni_cleanup_guard]
  parent       = "accounts/${var.databricks_account_id}/network-connectivity-configs/${local.ncc_id}"
  display_name = "pngdemo-png"
  traffic_mode = var.png_traffic_mode

  aws_cloud_connection = {
    cross_account_role = {
      role_arn = time_sleep.iam_propagation.triggers["role_arn"]
    }
    gateway_subnets    = [{ subnet_id = local.net.connect.png_subnet_id }]
    security_group_ids = [local.net.connect.png_security_group_id]
  }

  # One suffix covers every current and future internal service (suffix match).
  destinations = var.png_traffic_mode == "SPECIFIC_DESTINATIONS" ? [{
    destination_type = "DNS_NAME"
    value            = local.net.domain
  }] : null

  private_dns_resolvers = [] # Amazon-provided DNS: the private zone is associated with the dbx-connect VPC
}

# ---------- Attach to the workspace ----------

resource "databricks_mws_ncc_binding" "this" {
  network_connectivity_config_id = local.ncc_id
  workspace_id                   = data.terraform_remote_state.ws.outputs.workspace_id
}

output "ncc_id" {
  value = local.ncc_id
}

output "s3_rule" {
  value = {
    rule_id          = databricks_mws_ncc_private_endpoint_rule.s3.rule_id
    connection_state = databricks_mws_ncc_private_endpoint_rule.s3.connection_state
    vpc_endpoint_id  = databricks_mws_ncc_private_endpoint_rule.s3.vpc_endpoint_id
    enabled          = databricks_mws_ncc_private_endpoint_rule.s3.enabled
  }
}

output "png" {
  value = var.enable_png ? {
    name  = databricks_private_network_gateway.this[0].name
    state = databricks_private_network_gateway.this[0].state
  } : null
}
