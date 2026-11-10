#!/usr/bin/env bash
# Shows, from the customer's side, that Databricks serverless traffic arrives through the private network gateway.
# Terminal fallback for the CloudWatch dashboard (infra/60-observability).
#
#   ./scripts/show-traffic.sh enis          # the gateway's network interfaces in your subnet (your account, your SG)
#   ./scripts/show-traffic.sh calls [10m]   # follow service calls live: time, service, user, source IP, via gateway?
#   ./scripts/show-traffic.sh flows [10m]   # follow VPC flow log records from the gateway subnet (1–10 min delay)
#   ./scripts/show-traffic.sh all   [10m]   # enis, then calls + flows interleaved (Ctrl+C to stop)
#
# Read-only: needs ec2:DescribeNetworkInterfaces and logs:FilterLogEvents/StartLiveTail only.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export AWS_PROFILE="${AWS_PROFILE:-pngdemo-sandbox}" AWS_REGION="${AWS_REGION:-eu-central-1}"
CMD="${1:-all}" SINCE="${2:-10m}"

NET=$(terraform -chdir="$ROOT/infra/20-aws-network" output -json)
SUBNET_ID=$(jq -r .connect.value.png_subnet_id <<<"$NET")
CIDR=$(jq -r .cidr.value.png_subnet <<<"$NET")
FLOW_LOG=$(jq -r .log_groups.value.png_flow <<<"$NET")
SVC_LOG=$(terraform -chdir="$ROOT/infra/30-aws-services" output -raw log_group)

# True if an IPv4 address is inside $CIDR (pure bash, no extra tools).
ip2int() { local IFS=.; read -r a b c d <<<"$1"; echo $(( (a << 24) + (b << 16) + (c << 8) + d )); }
NET_INT=$(ip2int "${CIDR%/*}"); BITS=${CIDR#*/}; MASK=$(( (0xFFFFFFFF << (32 - BITS)) & 0xFFFFFFFF ))
in_cidr() { [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && (( ($(ip2int "$1") & MASK) == (NET_INT & MASK) )); }

enis() {
  printf '\n== Private network gateway interfaces in %s (%s)\n' "$SUBNET_ID" "$CIDR"
  aws ec2 describe-network-interfaces --filters "Name=subnet-id,Values=$SUBNET_ID" \
    --query 'NetworkInterfaces[].{Interface:NetworkInterfaceId,IP:PrivateIpAddress,SecurityGroup:Groups[0].GroupName,Status:Status,ManagedBy:TagSet[?Key==`Vendor`]|[0].Value,AttachedToAccount:Attachment.InstanceOwnerId}' \
    --output table
}

calls() {
  printf '\n== Calls to internal services (log %s), live. Source in %s = through the gateway\n' "$SVC_LOG" "$CIDR"
  aws logs tail "$SVC_LOG" --follow --since "$SINCE" --format short --filter-pattern '"mcp.auth call"' |
    while read -r ts rest; do
      user=$(sed -n 's/.*user=\([^ ]*\).*/\1/p' <<<"$rest"); src=$(sed -n 's/.*src=\([^ ]*\).*/\1/p' <<<"$rest")
      roles=$(sed -n 's/.*roles=\([^ ]*\).*/\1/p' <<<"$rest")
      via=$(in_cidr "$src" && echo "via gateway" || echo "NOT via gateway")
      printf 'CALL  %s  user=%-36s roles=%-20s src=%-12s %s\n' "$ts" "$user" "$roles" "$src" "$via"
    done
}

flows() {
  printf '\n== VPC flow logs from the gateway subnet (log %s), live; records arrive with a 1–10 min delay\n' "$FLOW_LOG"
  aws logs tail "$FLOW_LOG" --follow --since "$SINCE" --format short |
    while read -r ts _v _acct eni src dst _sp dport _proto _pk bytes _s _e action _st; do
      in_cidr "$src" || continue
      printf 'FLOW  %s  %s  %-12s -> %-12s :%-5s %-6s %s bytes\n' "$ts" "$eni" "$src" "$dst" "$dport" "$action" "$bytes"
    done
}

case "$CMD" in
  enis)  enis ;;
  calls) calls ;;
  flows) flows ;;
  all)   enis; trap 'kill 0' INT TERM; calls & flows & wait ;;
  *)     sed -n '2,10p' "$0"; exit 1 ;;
esac
