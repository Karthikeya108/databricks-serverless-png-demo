# Remote image build: no local Docker. The image tag is a hash of the service sources, so a code change produces a new
# tag, a new task definition revision and a rolling redeploy; an unchanged tree is never rebuilt.

resource "aws_ecr_repository" "services" {
  name                 = "pngdemo/internal-services"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true
  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_s3_bucket" "build_src" {
  bucket_prefix = "pngdemo-build-src-"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "build_src" {
  bucket                  = aws_s3_bucket.build_src.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "build_src" {
  bucket = aws_s3_bucket.build_src.id
  rule {
    id     = "expire-sources"
    status = "Enabled"
    filter {}
    expiration {
      days = 7
    }
  }
}

resource "aws_cloudwatch_log_group" "codebuild" {
  name              = "/aws/codebuild/pngdemo-image-build"
  retention_in_days = 7
}

resource "aws_iam_role" "codebuild" {
  name = "pngdemo-codebuild"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id } }
    }]
  })
}

# Least privilege: read the source bundle, write its own log group, push to the one repository.
resource "aws_iam_role_policy" "codebuild" {
  name = "build-and-push"
  role = aws_iam_role.codebuild.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.codebuild.arn}:*"
      },
      {
        Sid      = "Source"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion"]
        Resource = "${aws_s3_bucket.build_src.arn}/src/*"
      },
      {
        Sid      = "EcrAuth"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid    = "EcrPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage",
        ]
        Resource = aws_ecr_repository.services.arn
      },
    ]
  })
}

resource "aws_codebuild_project" "image" {
  name          = "pngdemo-image-build"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 20

  source {
    type      = "S3"
    location  = "${aws_s3_bucket.build_src.bucket}/src/placeholder.zip" # overridden per build
    buildspec = <<-EOT
      version: 0.2
      phases:
        pre_build:
          commands:
            - aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $REGISTRY
        build:
          commands:
            - docker build -t $REPO_URI:$IMAGE_TAG .
            - docker push $REPO_URI:$IMAGE_TAG
    EOT
  }

  artifacts {
    type = "NO_ARTIFACTS"
  }

  # Graviton (arm64): matches the Fargate ARM64 tasks.
  environment {
    type            = "ARM_CONTAINER"
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/amazonlinux-aarch64-standard:3.0"
    privileged_mode = true
    environment_variable {
      name  = "REGISTRY"
      value = split("/", aws_ecr_repository.services.repository_url)[0]
    }
    environment_variable {
      name  = "REPO_URI"
      value = aws_ecr_repository.services.repository_url
    }
    environment_variable {
      name  = "IMAGE_TAG"
      value = "unset"
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.codebuild.name
    }
  }

  depends_on = [aws_iam_role_policy.codebuild]
}

locals {
  src_dir   = "${path.module}/../../services"
  src_files = sort(concat(tolist(fileset(local.src_dir, "*.py")), ["requirements.txt", "Dockerfile"]))
  image_tag = substr(sha256(join("", [for f in local.src_files : filesha256("${local.src_dir}/${f}")])), 0, 16)
  image     = "${aws_ecr_repository.services.repository_url}:${local.image_tag}"
}

resource "terraform_data" "image" {
  triggers_replace = [local.image_tag]

  provisioner "local-exec" {
    command = "${path.module}/../../scripts/build-image.sh"
    environment = {
      TAG         = local.image_tag
      BUCKET      = aws_s3_bucket.build_src.bucket
      PROJECT     = aws_codebuild_project.image.name
      REPO_NAME   = aws_ecr_repository.services.name
      AWS_PROFILE = var.aws_profile
      AWS_REGION  = var.region
    }
  }
}
