# ---------- VPC endpoints: image pulls and logs stay inside AWS (no internet, no firewall allowlist needed) ----------

resource "aws_security_group" "endpoints" {
  name        = "pngdemo-services-endpoints"
  description = "Interface endpoints: HTTPS from the internal services network"
  vpc_id      = local.net.services.vpc_id
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [local.services_cidr]
  }
}

# One AZ to save cost (reachable from both AZs); production would use one per AZ.
resource "aws_vpc_endpoint" "interface" {
  for_each            = toset(["ecr.api", "ecr.dkr", "logs"])
  vpc_id              = local.net.services.vpc_id
  service_name        = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [local.app_subnet_ids[0]]
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true
  tags                = { Name = "pngdemo-services-${each.key}" }
}

# ECR image layers live in S3.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = local.net.services.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [local.net.services.route_table_id]
  tags              = { Name = "pngdemo-services-s3" }
}

# ---------- ECS Fargate ----------

resource "aws_ecs_cluster" "this" {
  name = "pngdemo"
}

resource "aws_cloudwatch_log_group" "services" {
  name              = "/pngdemo/services"
  retention_in_days = 7
}

# Execution role only (pull image, write logs). No task role: the services make no AWS API calls.
resource "aws_iam_role" "execution" {
  name = "pngdemo-ecs-execution"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id } }
    }]
  })
}

resource "aws_iam_role_policy" "execution" {
  name = "pull-and-log"
  role = aws_iam_role.execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "ecr:GetAuthorizationToken", Resource = "*" },
      {
        Effect   = "Allow"
        Action   = ["ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage"]
        Resource = aws_ecr_repository.services.arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.services.arn}:*"
      },
    ]
  })
}

resource "aws_security_group" "tasks" {
  name        = "pngdemo-services-tasks"
  description = "Service containers: 8080 from the ALB; HTTPS out (Entra JWKS via central egress, AWS endpoints)"
  vpc_id      = local.net.services.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "tasks_from_alb" {
  security_group_id            = aws_security_group.tasks.id
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
}

resource "aws_vpc_security_group_egress_rule" "tasks_https" {
  security_group_id = aws_security_group.tasks.id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_ecs_task_definition" "svc" {
  for_each                 = local.services
  family                   = "pngdemo-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.execution.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([{
    name         = "app"
    image        = local.image
    essential    = true
    portMappings = [{ containerPort = 8080, protocol = "tcp" }]
    environment = [
      { name = "SERVER", value = each.value.server },
      { name = "PORT", value = "8080" },
      { name = "TENANT_ID", value = local.entra.TENANT_ID },
      { name = "MCP_API_APP_ID", value = local.entra.MCP_API_APP_ID },
      { name = "ALLOWED_CLIENT_IDS", value = local.entra.MCP_CLIENT_APP_ID },
      { name = "DEMO_USERS", value = var.demo_users },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.services.name
        awslogs-region        = var.region
        awslogs-stream-prefix = each.key
      }
    }
  }])

  depends_on = [terraform_data.image]
}

resource "aws_ecs_service" "svc" {
  for_each        = local.services
  name            = each.key
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.svc[each.key].arn
  desired_count   = 1
  launch_type     = "FARGATE"

  # One replica: the demo data lives in memory, so all calls must hit the same task. Replace = stop, then start.
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  network_configuration {
    subnets          = local.app_subnet_ids
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.svc[each.key].arn
    container_name   = "app"
    container_port   = 8080
  }

  depends_on = [aws_lb_listener.https, aws_vpc_endpoint.interface, aws_vpc_endpoint.s3]
}
