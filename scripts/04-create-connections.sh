#!/usr/bin/env bash
# Creates one UC HTTP connection per internal service in services.yaml (hosts from infra/30-aws-services), in
# schema ops_demo.tools. Connection name: <service>_conn.
#   auth: entra  -> per-user OAuth (U2M) with Entra ID: credential_type OAUTH_U2M_MAPPING; each user signs in once
#   auth: none   -> bearer connection with a dummy value (the service checks nothing: "shadow IT")
# Created with the Connections API.
# The Entra client secret is generated here and piped into the API: never printed, never written to disk. One secret
# (90 days) is shared by the connections created in one run. Idempotent: existing connections are left alone.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/.state/entra.env"
source "$ROOT/.state/entra-obo.env"
PROFILE="${DATABRICKS_CONFIG_PROFILE:-pngdemo-ws}"
PARENT="schemas/ops_demo.tools"

# name|kind|auth|host from services.yaml + terraform outputs (bash 3.2 compatible)
SERVICES=$(python3 -I - "$ROOT/services.yaml" <<'PY'
import json, re, sys
# Minimal parser for the flat structure of services.yaml (avoids a PyYAML dependency).
txt = open(sys.argv[1]).read()
domain = re.search(r"^domain:\s*(\S+)", txt, re.M).group(1)
block = re.search(r"^services:\n(.*?)(?=^\S)", txt, re.M | re.S).group(1)
for name, body in re.findall(r"^  (\w[\w-]*):\n((?:    .*\n)+)", block, re.M):
    kind = re.search(r"kind:\s*(\w+)", body).group(1)
    auth = re.search(r"auth:\s*(\w+)", body).group(1)
    print(f"{name}|{kind}|{auth}|{name}.{domain}")
PY
)

missing=()
for s in $SERVICES; do
  name=${s%%|*}
  databricks connections get "ops_demo.tools.${name}_conn" -p "$PROFILE" >/dev/null 2>&1 || missing+=("$s")
done
[[ ${#missing[@]} -eq 0 ]] && { echo "All connections exist."; exit 0; }

secret=""
for s in "${missing[@]}"; do
  IFS='|' read -r name kind auth host <<< "$s"
  base_path=$([[ $kind == mcp ]] && echo /mcp || echo /)
  if [[ $auth == entra ]]; then
    if [[ -z "$secret" ]]; then
      secret=$(az ad app credential reset --id "$MCP_CLIENT_APP_ID" --append \
        --display-name "uc-connections-$(date +%Y%m%d)" --end-date "$(date -v+90d +%Y-%m-%d)" \
        --query password -o tsv 2>/dev/null)
    fi
    jq -n --arg n "${name}_conn" --arg p "$PARENT" --arg h "https://$host" --arg bp "$base_path" \
          --arg cid "$MCP_CLIENT_APP_ID" --arg sec "$secret" --arg sc "$MCP_OAUTH_SCOPE" \
          --arg az "$MCP_AUTHORIZATION_ENDPOINT" --arg tk "$MCP_TOKEN_ENDPOINT" --arg k "$kind" '{
      name: $n, parent: $p, connection_type: "HTTP",
      comment: ("Internal " + $k + " via private network gateway; per-user OAuth with Entra ID"),
      options: {host: $h, port: "443", base_path: $bp, client_id: $cid, client_secret: $sec, oauth_scope: $sc,
                authorization_endpoint: $az, token_endpoint: $tk, oauth_credential_exchange_method: "body_only"}}'
  else
    jq -n --arg n "${name}_conn" --arg p "$PARENT" --arg h "https://$host" --arg bp "$base_path" '{
      name: $n, parent: $p, connection_type: "HTTP",
      comment: "Internal API without SSO (shadow IT) via private network gateway; dummy bearer value",
      options: {host: $h, port: "443", base_path: $bp, bearer_token: "no-auth-at-target"}}'
  fi | databricks api post /api/2.1/unity-catalog/connections -p "$PROFILE" --json @/dev/stdin \
     | jq -c '{full_name, credential_type, host: .options.host, base_path: .options.base_path}'
done
unset secret

# The creator owns the connections (owner change isn't supported on schema-level connections yet).
# Nobody else gets USE CONNECTION: end users get EXECUTE on the MCP services (bundle).
