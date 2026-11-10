# Database seeding on the database team's side: a Lambda function in the internal-services VPC creates the inventory
# schema and data, and the read-only role that Databricks (Lakehouse Federation) uses. Invoked by
# scripts/07-postgres-federation.sh, which passes the passwords in the payload (never stored or logged).
# No internet access needed: the package contains a pure-Python driver and the RDS CA bundle.

data "external" "pg_seed_build" {
  count   = var.enable_postgres ? 1 : 0
  program = ["bash", "${path.module}/../../scripts/build-pg-seed.sh"]
}

data "archive_file" "pg_seed" {
  count       = var.enable_postgres ? 1 : 0
  type        = "zip"
  source_dir  = data.external.pg_seed_build[0].result.dir
  output_path = "${path.module}/.build/pg-seed.zip"
  excludes    = [".stamp"]
}

resource "aws_security_group" "pg_seed" {
  count       = var.enable_postgres ? 1 : 0
  name        = "pngdemo-pg-seed"
  description = "Database seeding function: Postgres only"
  vpc_id      = local.net.services.vpc_id
}

resource "aws_vpc_security_group_egress_rule" "pg_seed" {
  count             = var.enable_postgres ? 1 : 0
  security_group_id = aws_security_group.pg_seed[0].id
  description       = "Postgres in the services network"
  ip_protocol       = "tcp"
  from_port         = 5432
  to_port           = 5432
  cidr_ipv4         = local.services_cidr
}

resource "aws_iam_role" "pg_seed" {
  count       = var.enable_postgres ? 1 : 0
  name        = "pngdemo-pg-seed"
  description = "Database seeding function: VPC networking and its own log group only"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_cloudwatch_log_group" "pg_seed" {
  count             = var.enable_postgres ? 1 : 0
  name              = "/aws/lambda/pngdemo-pg-seed"
  retention_in_days = 7
}

resource "aws_iam_role_policy" "pg_seed" {
  count = var.enable_postgres ? 1 : 0
  name  = "pngdemo-pg-seed"
  role  = aws_iam_role.pg_seed[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.pg_seed[0].arn}:*"
      },
      {
        # Lambda VPC networking (ENI management). These EC2 actions don't support resource-level restrictions.
        Sid      = "VpcNetworking"
        Effect   = "Allow"
        Action   = ["ec2:CreateNetworkInterface", "ec2:DescribeNetworkInterfaces", "ec2:DeleteNetworkInterface", "ec2:AssignPrivateIpAddresses", "ec2:UnassignPrivateIpAddresses"]
        Resource = "*"
      },
    ]
  })
}

resource "aws_lambda_function" "pg_seed" {
  count            = var.enable_postgres ? 1 : 0
  function_name    = "pngdemo-pg-seed"
  description      = "Seeds the inventory database and the read-only federation role"
  role             = aws_iam_role.pg_seed[0].arn
  runtime          = "python3.12"
  architectures    = ["arm64"]
  handler          = "handler.handler"
  filename         = data.archive_file.pg_seed[0].output_path
  source_code_hash = data.archive_file.pg_seed[0].output_base64sha256
  timeout          = 60
  memory_size      = 256
  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.pg_seed[0].name
  }
  environment {
    variables = {
      DB_HOST       = aws_db_instance.pg[0].address
      DB_NAME       = aws_db_instance.pg[0].db_name
      DB_ADMIN_USER = aws_db_instance.pg[0].username
    }
  }
  vpc_config {
    subnet_ids         = local.app_subnet_ids
    security_group_ids = [aws_security_group.pg_seed[0].id]
  }
  depends_on = [aws_iam_role_policy.pg_seed]
}
