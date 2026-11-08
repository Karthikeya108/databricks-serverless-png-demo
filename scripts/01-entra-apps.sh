#!/usr/bin/env bash
# Creates the Entra app registrations for per-user OAuth between the UC connections and the MCP servers:
#   pngdemo-aws-mcp-api (audience of MCP tokens) and pngdemo-aws-mcp-client (OAuth client of the UC connections).
# No Graph permissions, no admin consent. Scope/role/redirect URI/role assignment: 02-entra-obo.sh;
# client secret: created when the UC connections are created, never stored.
set -euo pipefail

TENANT_ID="${TENANT_ID:?set TENANT_ID to the Entra tenant of the subscription and workspace}"
API_APP_NAME="${API_APP_NAME:-pngdemo-aws-mcp-api}"
CLIENT_APP_NAME="${CLIENT_APP_NAME:-pngdemo-aws-mcp-client}"
OUT_FILE="${OUT_FILE:-$(dirname "$0")/../.state/entra.env}"

current_tenant=$(az account show --query tenantId -o tsv)
[[ "$current_tenant" == "$TENANT_ID" ]] || { echo "az CLI is on tenant $current_tenant, expected $TENANT_ID" >&2; exit 1; }

get_or_create_app() {
  local name=$1 id
  id=$(az ad app list --display-name "$name" --query "[0].appId" -o tsv)
  if [[ -z "$id" ]]; then
    id=$(az ad app create --display-name "$name" --sign-in-audience AzureADMyOrg --query appId -o tsv)
  fi
  az ad sp show --id "$id" >/dev/null 2>&1 || az ad sp create --id "$id" >/dev/null
  echo "$id"
}

API_APP_ID=$(get_or_create_app "$API_APP_NAME")
API_OBJECT_ID=$(az ad app show --id "$API_APP_ID" --query id -o tsv)
az rest --method PATCH --url "https://graph.microsoft.com/v1.0/applications/$API_OBJECT_ID" \
  --headers "Content-Type=application/json" \
  --body "{\"identifierUris\":[\"api://$API_APP_ID\"],\"api\":{\"requestedAccessTokenVersion\":2}}"

CLIENT_APP_ID=$(get_or_create_app "$CLIENT_APP_NAME")

mkdir -p "$(dirname "$OUT_FILE")"
cat > "$OUT_FILE" <<EOF
TENANT_ID=$TENANT_ID
MCP_API_APP_ID=$API_APP_ID
MCP_API_AUDIENCE=api://$API_APP_ID
MCP_CLIENT_APP_ID=$CLIENT_APP_ID
EOF
echo "Wrote $OUT_FILE"
cat "$OUT_FILE"
