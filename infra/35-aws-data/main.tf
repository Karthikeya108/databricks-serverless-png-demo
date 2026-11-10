# Your S3 bucket for the catalog's managed location, plus evidence logging.
#
# The bucket policy (deny everything except the serverless private endpoint, the UC control plane and the admin role)
# lives in infra/40-databricks-network, because it needs the VPC endpoint ID that Databricks creates for the NCC rule.
# S3 server access logs record the source IP and status of every request (evidence for the Private Link path).
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
    tags = { project = "pngdemo", stack = "35-aws-data", Owner = var.owner }
  }
}

variable "owner" {
  type = string
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account     = data.aws_caller_identity.current.account_id
  data_bucket = "pngdemo-ops-${local.account}-euc1"
}

# ---------- Data bucket: catalog managed location ----------

resource "aws_s3_bucket" "data" {
  bucket        = local.data_bucket
  force_destroy = true # demo: destroy removes the Delta files too
}

resource "aws_s3_bucket_public_access_block" "data" {
  bucket                  = aws_s3_bucket.data.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "data" {
  bucket = aws_s3_bucket.data.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "data" {
  bucket = aws_s3_bucket.data.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ---------- Evidence: S3 server access logs for the data bucket ----------
# Access logs show the requester's source IP (private = through an endpoint, public = not) and the HTTP status
# (403 = denied by the bucket policy). Delivery is best effort: minutes to hours.

resource "aws_s3_bucket" "logs" {
  bucket        = "pngdemo-s3logs-${local.account}-euc1"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket                  = aws_s3_bucket.logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    id     = "expire"
    status = "Enabled"
    filter {}
    expiration {
      days = 14
    }
  }
}

# Only S3 log delivery for the data bucket, from this account, may write.
resource "aws_s3_bucket_policy" "logs" {
  bucket = aws_s3_bucket.logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "S3ServerAccessLogs"
      Effect    = "Allow"
      Principal = { Service = "logging.s3.amazonaws.com" }
      Action    = "s3:PutObject"
      Resource  = "${aws_s3_bucket.logs.arn}/data-bucket/*"
      Condition = {
        ArnLike      = { "aws:SourceArn" = aws_s3_bucket.data.arn }
        StringEquals = { "aws:SourceAccount" = local.account }
      }
    }]
  })
  depends_on = [aws_s3_bucket_public_access_block.logs]
}

resource "aws_s3_bucket_logging" "data" {
  bucket        = aws_s3_bucket.data.id
  target_bucket = aws_s3_bucket.logs.id
  target_prefix = "data-bucket/"
  target_object_key_format {
    partitioned_prefix {
      partition_date_source = "EventTime"
    }
  }
  depends_on = [aws_s3_bucket_policy.logs]
}

output "data_bucket" {
  value = aws_s3_bucket.data.bucket
}

output "data_bucket_arn" {
  value = aws_s3_bucket.data.arn
}

output "logs_bucket" {
  value = aws_s3_bucket.logs.bucket
}
