# ---------- Internal ALB: one entry point, TLS with the public wildcard certificate, routing by host name ----------

resource "aws_security_group" "alb" {
  name        = "pngdemo-services-alb"
  description = "Internal ALB: HTTPS from the private network gateway subnet and the services network"
  vpc_id      = local.net.services.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  for_each          = { gateway = local.png_subnet_cidr, services = local.services_cidr }
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from ${each.key}"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_egress_rule" "alb_to_tasks" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.tasks.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
}

resource "aws_lb" "internal" {
  name               = "pngdemo-internal"
  internal           = true
  load_balancer_type = "application"
  subnets            = local.app_subnet_ids
  security_groups    = [aws_security_group.alb.id]
  idle_timeout       = 120
}

resource "aws_lb_target_group" "svc" {
  for_each             = local.services
  name                 = "pngdemo-${each.key}"
  port                 = 8080
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = local.net.services.vpc_id
  deregistration_delay = 5

  health_check {
    path                = "/healthz"
    matcher             = "200"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.internal.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = data.terraform_remote_state.cert.outputs.acm_certificate_arn

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "application/json"
      message_body = "{\"error\":\"unknown service\"}"
      status_code  = "404"
    }
  }
}

resource "aws_lb_listener_rule" "svc" {
  for_each     = local.services
  listener_arn = aws_lb_listener.https.arn
  priority     = 100 + index(sort(keys(local.services)), each.key)

  condition {
    host_header {
      values = [each.value.fqdn]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.svc[each.key].arn
  }
}

# ---------- Private DNS: every <name>.<domain> → the ALB (a new service needs no DNS change) ----------

resource "aws_route53_record" "wildcard" {
  zone_id = local.net.private_zone_id
  name    = "*.${local.domain}"
  type    = "A"
  alias {
    name                   = aws_lb.internal.dns_name
    zone_id                = aws_lb.internal.zone_id
    evaluate_target_health = false
  }
}

# ---------- Postgres: a database behind the same gateway (e.g. for Lakehouse Federation) ----------

resource "aws_db_subnet_group" "pg" {
  count      = var.enable_postgres ? 1 : 0
  name       = "pngdemo-pg"
  subnet_ids = local.app_subnet_ids
}

resource "aws_security_group" "pg" {
  count       = var.enable_postgres ? 1 : 0
  name        = "pngdemo-pg"
  description = "Postgres: 5432 from the private network gateway subnet and the services network"
  vpc_id      = local.net.services.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "pg" {
  for_each          = var.enable_postgres ? { gateway = local.png_subnet_cidr, services = local.services_cidr } : {}
  security_group_id = aws_security_group.pg[0].id
  description       = "Postgres from ${each.key}"
  ip_protocol       = "tcp"
  from_port         = 5432
  to_port           = 5432
  cidr_ipv4         = each.value
}

# Master password generated and stored by RDS in Secrets Manager: never in Terraform config or state.
resource "aws_db_instance" "pg" {
  count                       = var.enable_postgres ? 1 : 0
  identifier                  = "pngdemo-pg"
  engine                      = "postgres"
  engine_version              = "17"
  instance_class              = "db.t4g.micro"
  allocated_storage           = 20
  storage_type                = "gp3"
  storage_encrypted           = true
  db_name                     = "ops"
  username                    = "pngadmin"
  manage_master_user_password = true
  db_subnet_group_name        = aws_db_subnet_group.pg[0].name
  vpc_security_group_ids      = [aws_security_group.pg[0].id]
  publicly_accessible         = false
  multi_az                    = false
  backup_retention_period     = 1
  skip_final_snapshot         = true
  deletion_protection         = false
  apply_immediately           = true
}

# A stable internal name (more specific than the wildcard).
resource "aws_route53_record" "pg" {
  count   = var.enable_postgres ? 1 : 0
  zone_id = local.net.private_zone_id
  name    = "postgres.${local.domain}"
  type    = "CNAME"
  ttl     = 60
  records = [aws_db_instance.pg[0].address]
}

# ---------- Outputs ----------

output "image" {
  value = local.image
}

output "service_urls" {
  value = {
    for k, s in local.services : k => (s.kind == "mcp" ? "https://${s.fqdn}/mcp" : "https://${s.fqdn}")
  }
}

output "alb_dns_name" {
  value = aws_lb.internal.dns_name
}

output "postgres" {
  value = var.enable_postgres ? {
    host            = "postgres.${local.domain}"
    endpoint        = aws_db_instance.pg[0].address
    database        = "ops"
    master_username = "pngadmin"
    secret_arn      = aws_db_instance.pg[0].master_user_secret[0].secret_arn
  } : null
}

output "log_group" {
  value = aws_cloudwatch_log_group.services.name
}
