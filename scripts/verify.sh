#!/usr/bin/env bash
# Pre-demo check and warm-up. Run 30 minutes before the demo; every line should be ✓.
#   ./scripts/verify.sh            # check + warm-up calls (fills the service and flow logs for the dashboard)
#   ./scripts/verify.sh --no-warmup
#   ./scripts/verify.sh --restart-warehouse   # also restarts the SQL warehouse (e.g. after a network policy change)
# Read-only, except that it starts the SQL warehouse and sends test calls through Unity Gateway as you.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export AWS_PROFILE="${AWS_PROFILE:-pngdemo-sandbox}" AWS_REGION="${AWS_REGION:-eu-central-1}"
WS="${DATABRICKS_CONFIG_PROFILE:-pngdemo-ws}" ACCT="${DATABRICKS_ACCOUNT_PROFILE:-png-aws-acct}"
WARMUP=true RESTART_WH=false
for a in "$@"; do case $a in --no-warmup) WARMUP=false ;; --restart-warehouse) RESTART_WH=true ;; esac; done
fails=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; fails=$((fails + 1)); }
info() { printf '  · %s\n' "$*"; }
check() { local label=$1; shift; if out=$("$@" 2>&1); then ok "$label${out:+: $out}"; else bad "$label${out:+: $out}"; fi; }
tfout() { terraform -chdir="$ROOT/infra/$1" output -json "$2" 2>/dev/null; }

echo "== Logins"
check "AWS ($AWS_PROFILE)" bash -c 'aws sts get-caller-identity --query Account --output text >/dev/null && echo ok'
check "Databricks workspace ($WS)" bash -c "databricks current-user me -p $WS -o json | jq -er .userName >/dev/null && echo ok"
check "Databricks account ($ACCT)" bash -c "databricks account workspaces list -p $ACCT -o json >/dev/null && echo ok"

echo "== Your network (AWS)"
NET=$(tfout 20-aws-network connect); SUBNET=$(jq -r .png_subnet_id <<<"$NET")
check "Gateway network interfaces in the gateway subnet" bash -c "n=\$(aws ec2 describe-network-interfaces --filters Name=subnet-id,Values=$SUBNET Name=tag:Vendor,Values=Databricks --query 'length(NetworkInterfaces[?Status==\`in-use\`])' --output text); echo \"\$n in use\"; [ \"\$n\" -ge 1 ]"
check "ECS services" bash -c "aws ecs describe-services --cluster pngdemo --services servicedesk assets orders legacy --query 'services[].[serviceName,runningCount]' --output text | awk '{s=s \$1\"=\"\$2\" \"; if (\$2<1) f=1} END {print s; exit f}'"
check "Load balancer targets" bash -c "for tg in \$(aws elbv2 describe-target-groups --query 'TargetGroups[?starts_with(TargetGroupName,\`pngdemo-\`)].TargetGroupArn' --output text); do aws elbv2 describe-target-health --target-group-arn \$tg --query 'TargetHealthDescriptions[].TargetHealth.State' --output text; done | sort | uniq -c | tr -s ' ' | tr '\n' ' '; ! aws elbv2 describe-target-groups --query 'TargetGroups[?starts_with(TargetGroupName,\`pngdemo-\`)].TargetGroupArn' --output text | xargs -n1 -I{} aws elbv2 describe-target-health --target-group-arn {} --query 'TargetHealthDescriptions[].TargetHealth.State' --output text | grep -vq healthy"
check "RDS Postgres" bash -c "s=\$(aws rds describe-db-instances --db-instance-identifier pngdemo-pg --query 'DBInstances[0].DBInstanceStatus' --output text); echo \$s; [ \"\$s\" = available ]"
fw=$(aws network-firewall describe-firewall --firewall-name pngdemo-firewall --query 'FirewallStatus.Status' --output text 2>/dev/null || echo "not deployed")
mode=$(tfout 20-aws-network inspection | jq -r .mode)
[[ $fw == READY ]] && ok "Network Firewall: READY ($mode mode)" || bad "Network Firewall: $fw (./scripts/firewall.sh on)"
check "VPC endpoints (ECR, logs, S3)" bash -c "aws ec2 describe-vpc-endpoints --filters Name=tag:project,Values=pngdemo --query 'VpcEndpoints[].[ServiceName,State]' --output text | awk '{n++; if (\$2!=\"available\") f=1} END {print n\" available\"; exit f}'"
check "Certificate (ACM)" bash -c "aws acm list-certificates --query 'CertificateSummaryList[?starts_with(DomainName,\`*.\`)].[DomainName,Status,NotAfter]' --output text | head -1 | tee /dev/stderr | grep -q ISSUED"

echo "== Databricks network (NCC)"
PNG=$(tfout 40-databricks-network png | jq -r .name)
check "Private network gateway" bash -c "databricks api get /api/networking/v1/$PNG -p $ACCT | jq -er '\"\(.state) · \(.traffic_mode)\" | select(startswith(\"ESTABLISHED\"))'"
NCC=$(terraform -chdir="$ROOT/infra/40-databricks-network" output -raw ncc_id)
check "S3 private endpoint rule" bash -c "databricks account network-connectivity list-private-endpoint-rules $NCC -p $ACCT -o json | jq -er '.[] | select(.endpoint_service|endswith(\".s3\")) | \"\(.connection_state) · enabled=\(.enabled)\" | select(startswith(\"ESTABLISHED · enabled=true\"))'"
EG=$(tfout 45-databricks-egress egress)
if [[ -n $EG ]]; then
  live=$(databricks account workspace-network-configuration get-workspace-network-option-rpc "$(tfout 10-databricks-workspace workspace_id)" -p "$ACCT" -o json 2>/dev/null | jq -r .network_policy_id)
  [[ $live == "$(jq -r .attached <<<"$EG")" ]] && ok "Network policy: $(jq -r .mode <<<"$EG") (workspace uses $live)" \
    || bad "Network policy: workspace uses $live, expected $(jq -r .attached <<<"$EG")"
else
  info "Network policy: stack 45 not applied"
fi

echo "== Unity Catalog, identity, app"
for s in servicedesk assets; do
  check "Your credential for MCP service $s" bash -c "databricks ai-gateway get-mcp-service-user-mapped-credential mcp-services/ops_demo.tools.$s -p $WS -o json | jq -er '.provisioning_info.state | select(. == \"ACTIVE\")'"
done
check "App pngdemo-ops-assistant" bash -c "databricks apps get pngdemo-ops-assistant -p $WS -o json | jq -er '\"\(.app_status.state) · compute \(.compute_status.state)\" | select(startswith(\"RUNNING\"))'"
WH=$(terraform -chdir="$ROOT/infra/50-databricks-uc" output -raw warehouse_id 2>/dev/null)
if $RESTART_WH; then databricks warehouses stop "$WH" -p "$WS" >/dev/null 2>&1; info "SQL warehouse stopped for a fresh start"; fi
check "SQL warehouse (starting it)" bash -c "databricks warehouses start $WH -p $WS >/dev/null 2>&1; databricks warehouses get $WH -p $WS -o json | jq -r .state"
check "Postgres via federation (warehouse → gateway → RDS)" bash -c "jq -nc --arg w $WH '{warehouse_id:\$w, wait_timeout:\"50s\", statement:\"SELECT count(*) FROM ops_inventory.inventory.stock\"}' | databricks api post /api/2.0/sql/statements -p $WS --json @/dev/stdin | jq -er '.result.data_array[0][0] // empty | . + \" rows\"'"

if $WARMUP; then
  echo "== Warm-up: calls through Unity Gateway → gateway → services (as you)"
  init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"verify","version":"1"}}}'
  for s in servicedesk assets; do
    for i in 1 2 3; do  # the first call after a while can be slow; retry
      r=$(databricks api post "/ai-gateway/mcp-services/ops_demo.tools.$s" -p "$WS" --json "$init" 2>&1 | jq -r '.result.serverInfo.name // .error.message // "no answer"')
      [[ $r == *-mcp ]] && break; sleep 3
    done
    [[ $r == *-mcp ]] && ok "MCP $s: $r" || bad "MCP $s: $r"
  done
  # The app opens its own MCP sessions as you; the first one after a while can fail once, so warm it up too.
  APP_URL=$(databricks apps get pngdemo-ops-assistant -p "$WS" -o json 2>/dev/null | jq -r .url)
  TOKEN=$(databricks auth token -p "$WS" 2>/dev/null | jq -r .access_token)
  for i in 1 2 3; do
    st=$(curl -s --max-time 90 -H "Authorization: Bearer $TOKEN" "$APP_URL/api/status" | jq -r '[.services[]? | "\(.service | split(".") | last)=\(if .ok then "ok" else "fail" end)"] | join(" ")')
    [[ -n $st && $st != *fail* ]] && break
  done
  unset TOKEN
  [[ -n $st && $st != *fail* ]] && ok "App → MCP services: $st" || bad "App → MCP services: ${st:-no answer}"
fi

echo "== Demo links"
info "Dashboard: $(terraform -chdir="$ROOT/infra/60-observability" output -raw dashboard_url 2>/dev/null)"
info "App: $(databricks apps get pngdemo-ops-assistant -p "$WS" -o json 2>/dev/null | jq -r .url)"
info "Flow and firewall logs lag 1–10 min behind the calls above."
echo
[[ $fails -eq 0 ]] && echo "All checks passed." || { echo "$fails check(s) failed."; exit 1; }
