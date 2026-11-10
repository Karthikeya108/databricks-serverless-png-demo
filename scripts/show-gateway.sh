#!/usr/bin/env bash
# Shows the private network gateway's live configuration as Databricks has it (account API, read-only):
# state, traffic mode, destinations, subnet, security group and cross-account role.
#   ./scripts/show-gateway.sh          # readable summary
#   ./scripts/show-gateway.sh --json   # raw API response
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ACCT="${DATABRICKS_ACCOUNT_PROFILE:-png-aws-acct}"
NAME=$(terraform -chdir="$ROOT/infra/40-databricks-network" output -json png | jq -r .name)
GW=$(databricks api get "/api/networking/v1/$NAME" -p "$ACCT")
[[ "${1:-}" == --json ]] && { jq . <<<"$GW"; exit 0; }
jq -r '
  "Private network gateway  \(.display_name)",
  "  state                  \(.state)",
  "  traffic mode           \(.traffic_mode)",
  "  destinations           \(if (.destinations // []) == [] then "(none: all traffic)" else ([.destinations[] | "\(.value)  [\(.destination_type), suffix match]"] | join("\n                         ")) end)",
  "  subnet                 \([.aws_cloud_connection.gateway_subnets[]?.subnet_id] | join(", "))",
  "  security group         \(.aws_cloud_connection.security_group_ids // [] | join(", "))",
  "  cross-account role     \(.aws_cloud_connection.cross_account_role.role_arn // "-" | sub("arn:aws:iam::[0-9]+:role/"; "role/"))"
' <<<"$GW"
