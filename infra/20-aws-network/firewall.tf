# AWS Network Firewall: stateful, STRICT_ORDER, default drop. Rules are generated from services.yaml, so a
# change is a pull request + terraform apply, not a firewall ticket. No TLS decryption: domain rules match
# the unencrypted SNI of the TLS handshake.
#
# Logging: ALERT log (allowed connections with their SNI, and every drop) + FLOW log (all flows).

locals {
  zone_services = [for name, s in local.registry.services : "${name}.${local.domain}" if s.databricks_zone]
  zone_db_ports = [for name, d in local.registry.databases : d.port if d.databricks_zone]

  # One allowed TLS destination = an alert rule (logs the SNI, non-terminal) + a pass rule (terminal).
  tls_allow = flatten([
    for i, r in concat(
      [for f in(var.firewall_mode == "per_service" ? local.zone_services : []) : { src = "$DBX_ZONE", dst = "$SERVICES", sni = f, what = "dbx-zone -> ${f}" }],
      [for d in local.registry.egress_allowlist.internal_services : { src = "$SERVICES", dst = "!$HOME_NET", sni = d, what = "internal services -> internet ${d}" }],
      [for d in local.registry.egress_allowlist.databricks_zone : { src = "$DBX_ZONE", dst = "!$HOME_NET", sni = d, what = "dbx-zone -> internet ${d}" }],
      ) : [
      "alert tls ${r.src} any -> ${r.dst} 443 (msg:\"ALLOW ${r.what}\"; tls.sni; content:\"${r.sni}\"; nocase; startswith; endswith; flow:to_server; sid:${2000 + 2 * i}; rev:1;)",
      "pass tls ${r.src} any -> ${r.dst} 443 (tls.sni; content:\"${r.sni}\"; nocase; startswith; endswith; flow:to_server; sid:${2001 + 2 * i}; rev:1;)",
    ]
  ])

  # network mode: one zone rule for the whole services network (scales by network, not by service).
  # The pass matches only established packets, so the TLS ClientHello is logged with its SNI first
  # (the TCP handshake is allowed by the drop_established default).
  zone_rules_network = [
    "alert tls $DBX_ZONE any -> $SERVICES 443 (msg:\"ALLOW dbx-zone -> internal services (zone rule)\"; flow:to_server; sid:1000; rev:1;)",
    "pass tcp $DBX_ZONE any -> $SERVICES 443 (flow:to_server,established; sid:1001; rev:1;)",
  ]

  db_rules = flatten([for i, p in local.zone_db_ports : [
    "alert tcp $DBX_ZONE any -> $SERVICES ${p} (msg:\"ALLOW dbx-zone -> database port ${p}\"; flow:to_server; flags:S; sid:${1100 + 2 * i}; rev:1;)",
    "pass tcp $DBX_ZONE any -> $SERVICES ${p} (flow:to_server; sid:${1101 + 2 * i}; rev:1;)",
  ]])

  # Non-TCP egress to the internet is never allowed (drop_established doesn't cover all UDP/ICMP cases).
  final_rules = [
    "drop udp $HOME_NET any -> !$HOME_NET any (msg:\"DROP UDP to internet\"; sid:9001; rev:1;)",
    "drop icmp $HOME_NET any -> !$HOME_NET any (msg:\"DROP ICMP to internet\"; sid:9002; rev:1;)",
  ]

  firewall_rules = concat(
    var.firewall_mode == "network" ? local.zone_rules_network : [],
    local.db_rules,
    local.tls_allow,
    local.final_rules,
  )

  firewall_endpoint_id = var.enable_inspection ? one([
    for s in aws_networkfirewall_firewall.this[0].firewall_status[0].sync_states : s.attachment[0].endpoint_id
  ]) : null
}

resource "aws_networkfirewall_rule_group" "this" {
  name     = "pngdemo-rules"
  type     = "STATEFUL"
  capacity = 200

  rule_group {
    rule_variables {
      ip_sets {
        key = "HOME_NET"
        ip_set { definition = ["10.0.0.0/8"] }
      }
      ip_sets {
        key = "DBX_ZONE"
        ip_set { definition = [local.png_subnet_cidr] }
      }
      ip_sets {
        key = "SERVICES"
        ip_set { definition = [local.cidr.services] }
      }
    }
    rules_source {
      rules_string = join("\n", local.firewall_rules)
    }
    stateful_rule_options {
      rule_order = "STRICT_ORDER"
    }
  }
}

resource "aws_networkfirewall_firewall_policy" "this" {
  name = "pngdemo-policy"

  firewall_policy {
    stateless_default_actions          = ["aws:forward_to_sfe"]
    stateless_fragment_default_actions = ["aws:forward_to_sfe"]
    stateful_engine_options {
      rule_order = "STRICT_ORDER"
    }
    # Default deny for anything not explicitly passed, with an alert log entry.
    stateful_default_actions = ["aws:drop_established", "aws:alert_established"]
    stateful_rule_group_reference {
      priority     = 100
      resource_arn = aws_networkfirewall_rule_group.this.arn
    }
  }
}

resource "aws_networkfirewall_firewall" "this" {
  count               = var.enable_inspection ? 1 : 0
  name                = "pngdemo-firewall"
  firewall_policy_arn = aws_networkfirewall_firewall_policy.this.arn
  vpc_id              = aws_vpc.inspection.id
  delete_protection   = false

  subnet_mapping {
    subnet_id = aws_subnet.firewall.id
  }
}

resource "aws_cloudwatch_log_group" "firewall" {
  for_each          = toset(["alert", "flow"])
  name              = "/pngdemo/network-firewall/${each.key}"
  retention_in_days = 7
}

resource "aws_networkfirewall_logging_configuration" "this" {
  count        = var.enable_inspection ? 1 : 0
  firewall_arn = aws_networkfirewall_firewall.this[0].arn

  logging_configuration {
    log_destination_config {
      log_type             = "ALERT"
      log_destination_type = "CloudWatchLogs"
      log_destination      = { logGroup = aws_cloudwatch_log_group.firewall["alert"].name }
    }
    log_destination_config {
      log_type             = "FLOW"
      log_destination_type = "CloudWatchLogs"
      log_destination      = { logGroup = aws_cloudwatch_log_group.firewall["flow"].name }
    }
  }
}
