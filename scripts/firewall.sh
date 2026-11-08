#!/usr/bin/env bash
# Switch AWS Network Firewall inspection on or off (persistently) for the hub-and-spoke network.
#   ./scripts/firewall.sh on       # the day before the demo (≈ 5–10 min, ~$10/day while on)
#   ./scripts/firewall.sh off      # back to direct routing (firewall destroyed; rules/policy kept)
#   ./scripts/firewall.sh status
# The setting is stored in infra/20-aws-network/firewall.auto.tfvars, so later plain `terraform apply` runs keep it.
set -euo pipefail
STACK="$(cd "$(dirname "$0")/../infra/20-aws-network" && pwd)"
case "${1:-status}" in
  on | off)
    want=$([[ $1 == on ]] && echo true || echo false)
    printf 'enable_inspection = %s\n' "$want" > "$STACK/firewall.auto.tfvars"
    terraform -chdir="$STACK" apply -input=false -auto-approve
    ;;
  status) ;;
  *) echo "usage: $0 on|off|status" >&2; exit 2 ;;
esac
terraform -chdir="$STACK" output -json inspection | jq '{enabled, mode, endpoint_id}'
aws network-firewall describe-firewall --firewall-name pngdemo-firewall --profile "${AWS_PROFILE:-pngdemo-sandbox}" \
  --region eu-central-1 --query 'FirewallStatus.Status' --output text 2>/dev/null | sed 's/^/firewall: /' \
  || echo "firewall: not deployed"
