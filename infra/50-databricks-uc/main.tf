# Unity Catalog on customer-owned S3 (reached by serverless over the NCC private endpoint):
#   IAM role for UC → storage credential → external location → catalog ops_demo (MANAGED LOCATION) → schemas,
#   least-privilege grants for the account groups, serverless SQL warehouse.
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
  region  = "eu-central-1"
  profile = "pngdemo-sandbox"
  default_tags {
    tags = { project = "pngdemo", stack = "50-databricks-uc", Owner = var.owner }
  }
}

# Workspace-level OAuth (U2M) via the CLI profile.
provider "databricks" {
  profile = var.workspace_profile
}

variable "owner" {
  type = string
}

variable "workspace_profile" {
  type    = string
  default = "pngdemo-ws"
}

variable "catalog_name" {
  type    = string
  default = "ops_demo"
}

data "terraform_remote_state" "data" {
  backend = "local"
  config  = { path = "${path.module}/../35-aws-data/terraform.tfstate" }
}

data "aws_caller_identity" "current" {}

locals {
  bucket      = data.terraform_remote_state.data.outputs.data_bucket
  uc_role     = "pngdemo-uc-access"
  uc_role_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.uc_role}"
  admins      = "pngdemo-admins"
  users       = "pngdemo-users"
  assets      = "pngdemo-assets-only"
}

# ---------- Storage credential + IAM role (documented order: credential first, then the role trusting it) ----------

resource "databricks_storage_credential" "ops" {
  name    = "pngdemo-uc-s3"
  comment = "UC access to the ops_demo managed location (customer S3, reached via the NCC private endpoint)"
  aws_iam_role {
    role_arn = local.uc_role_arn
  }
  owner = local.admins
}

# Trust: the Unity Catalog master role with this credential's external ID, plus the role itself (self-assume).
data "databricks_aws_unity_catalog_assume_role_policy" "uc" {
  aws_account_id = data.aws_caller_identity.current.account_id
  role_name      = local.uc_role
  external_id    = databricks_storage_credential.ops.aws_iam_role[0].external_id
}

resource "aws_iam_role" "uc" {
  name               = local.uc_role
  description        = "Unity Catalog access to the pngdemo data bucket only"
  assume_role_policy = data.databricks_aws_unity_catalog_assume_role_policy.uc.json
}

# Least privilege: this bucket only, plus self-assume (required by UC). No KMS (SSE-S3), no file events.
resource "aws_iam_role_policy" "uc" {
  name = "pngdemo-data-bucket"
  role = aws_iam_role.uc.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "Bucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads"]
        Resource = "arn:aws:s3:::${local.bucket}"
      },
      {
        Sid      = "Objects"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]
        Resource = "arn:aws:s3:::${local.bucket}/*"
      },
      {
        Sid      = "SelfAssume"
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = local.uc_role_arn
      },
    ]
  })
}

resource "time_sleep" "iam_propagation" {
  create_duration = "30s"
  triggers = {
    role   = aws_iam_role.uc.arn
    policy = aws_iam_role_policy.uc.id
  }
}

resource "databricks_external_location" "ops" {
  name            = "pngdemo-ops"
  url             = "s3://${local.bucket}/ops-demo"
  credential_name = databricks_storage_credential.ops.name
  comment         = "Managed location of catalog ${var.catalog_name}"
  owner           = local.admins
  depends_on      = [time_sleep.iam_propagation]
}

# ---------- Catalog with its managed location in customer S3 ----------

resource "databricks_catalog" "ops" {
  name         = var.catalog_name
  storage_root = databricks_external_location.ops.url
  comment      = "PNG demo: Delta history in customer S3 (Private Link) + MCP services for internal systems (private network gateway)"
  owner        = local.admins
}

resource "databricks_schema" "lakehouse" {
  catalog_name = databricks_catalog.ops.name
  name         = "lakehouse"
  comment      = "Historical operations data (managed Delta tables)"
  owner        = local.admins
}

resource "databricks_schema" "tools" {
  catalog_name = databricks_catalog.ops.name
  name         = "tools"
  comment      = "MCP services and connections for internal systems"
  owner        = local.admins
}

# ---------- Grants (least privilege) ----------

resource "databricks_grants" "catalog" {
  catalog = databricks_catalog.ops.name
  grant {
    principal  = local.users
    privileges = ["USE_CATALOG"]
  }
  grant {
    principal  = local.assets
    privileges = ["USE_CATALOG"]
  }
}

resource "databricks_grants" "lakehouse" {
  schema = "${databricks_catalog.ops.name}.${databricks_schema.lakehouse.name}"
  grant {
    principal  = local.users
    privileges = ["USE_SCHEMA", "SELECT"]
  }
  grant {
    principal  = local.assets
    privileges = ["USE_SCHEMA", "SELECT"]
  }
}

# End users get EXECUTE on individual MCP services (bundle); here only USE_SCHEMA.
resource "databricks_grants" "tools" {
  schema = "${databricks_catalog.ops.name}.${databricks_schema.tools.name}"
  grant {
    principal  = local.users
    privileges = ["USE_SCHEMA"]
  }
  grant {
    principal  = local.assets
    privileges = ["USE_SCHEMA"]
  }
}

# ---------- Serverless SQL warehouse (Genie, demo queries) ----------

resource "databricks_sql_endpoint" "demo" {
  name                      = "pngdemo-serverless"
  cluster_size              = "2X-Small"
  min_num_clusters          = 1
  max_num_clusters          = 1
  auto_stop_mins            = 10
  enable_serverless_compute = true
  warehouse_type            = "PRO"
}

resource "databricks_permissions" "warehouse" {
  sql_endpoint_id = databricks_sql_endpoint.demo.id
  access_control {
    group_name       = local.users
    permission_level = "CAN_USE"
  }
  access_control {
    group_name       = local.assets
    permission_level = "CAN_USE"
  }
  access_control {
    group_name       = local.admins
    permission_level = "CAN_MANAGE"
  }
}

output "catalog" {
  value = databricks_catalog.ops.name
}

output "warehouse_id" {
  value = databricks_sql_endpoint.demo.id
}

output "managed_location" {
  value = databricks_external_location.ops.url
}
