#!/usr/bin/env bash
# Switch AWS Network Firewall inspection on or off (persistently) for the hub-and-spoke network.
#   ./scripts/firewall.sh on       # the day before the demo (≈ 5–10 min, ~$10/day while on)
#   ./scripts/firewall.sh off      # back to direct routing (firewall destroyed; rules/policy kept)
#   ./scripts/firewall.sh per-service  # only services with databricks_zone: true are reachable (e.g. legacy is dropped)
#   ./scripts/firewall.sh network      # one zone rule for the whole services network (default)
#   ./scripts/firewall.sh status
# The setting is stored in infra/20-aws-network/firewall.auto.tfvars, so later plain `terraform apply` runs keep it.
set -euo pipefail
STACK="$(cd "$(dirname "$0")/../infra/20-aws-network" && pwd)"
VARS="$STACK/firewall.auto.tfvars"
cur() { sed -n "s/^$1 *= *//p" "$VARS" 2>/dev/null | tr -d '"'; }
write() { printf 'enable_inspection = %s\nfirewall_mode     = "%s"\n' "$1" "$2" > "$VARS"; }
case "${1:-status}" in
  on)          write true "$(cur firewall_mode | grep . || echo network)" ;;
  off)         write false "$(cur firewall_mode | grep . || echo network)" ;;
  per-service) write "$(cur enable_inspection | grep . || echo true)" per_service ;;
  network)     write "$(cur enable_inspection | grep . || echo true)" network ;;
  status) ;;
  *) echo "usage: $0 on|off|per-service|network|status" >&2; exit 2 ;;
esac
[[ ${1:-status} != status ]] && terraform -chdir="$STACK" apply -input=false -auto-approve
terraform -chdir="$STACK" output -json inspection | jq '{enabled, mode, endpoint_id}'
aws network-firewall describe-firewall --firewall-name pngdemo-firewall --profile "${AWS_PROFILE:-pngdemo-sandbox}" \
  --region eu-central-1 --query 'FirewallStatus.Status' --output text 2>/dev/null | sed 's/^/firewall: /' \
  || echo "firewall: not deployed"
