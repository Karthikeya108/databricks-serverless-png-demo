#!/usr/bin/env bash
# Configures the Entra apps for per-user OAuth (U2M) through the UC connection:
#   API:    delegated scope MCP.Access, app role ServiceDesk.Agent, client pre-authorised (no consent prompt)
#   Client: web redirect URI of the Databricks workspace, required access to MCP.Access + offline_access
#   Role:   ServiceDesk.Agent assigned to the users in AGENT_USERS (as owner of the API app; no admin needed)
# No Graph application permissions, no admin consent. Idempotent.
set -euo pipefail

STATE_DIR="$(cd "$(dirname "$0")/.." && pwd)/.state"
source "$STATE_DIR/entra.env"
WORKSPACE_HOST="${WORKSPACE_HOST:?set WORKSPACE_HOST, e.g. https://dbc-xxxx.cloud.databricks.com}"
AGENT_USERS="${AGENT_USERS:-}"   # comma-separated UPNs that get ServiceDesk.Agent (persona A)
REDIRECT_URI="$WORKSPACE_HOST/login/oauth/http.html"
GRAPH=https://graph.microsoft.com/v1.0

api_obj=$(az ad app show --id "$MCP_API_APP_ID" --query id -o tsv)
client_obj=$(az ad app show --id "$MCP_CLIENT_APP_ID" --query id -o tsv)

# Reuse existing IDs so re-runs don't orphan grants.
scope_id=$(az ad app show --id "$MCP_API_APP_ID" --query "api.oauth2PermissionScopes[?value=='MCP.Access'].id | [0]" -o tsv)
[[ -n "$scope_id" ]] || scope_id=$(uuidgen | tr 'A-Z' 'a-z')
role_id=$(az ad app show --id "$MCP_API_APP_ID" --query "appRoles[?value=='ServiceDesk.Agent'].id | [0]" -o tsv)
[[ -n "$role_id" ]] || role_id=$(uuidgen | tr 'A-Z' 'a-z')

# 1. Scope + app role (scope must exist before it can be pre-authorised).
az rest --method PATCH --url "$GRAPH/applications/$api_obj" --headers "Content-Type=application/json" --body "{
  \"api\": {
    \"requestedAccessTokenVersion\": 2,
    \"oauth2PermissionScopes\": [{
      \"id\": \"$scope_id\", \"value\": \"MCP.Access\", \"type\": \"User\", \"isEnabled\": true,
      \"adminConsentDisplayName\": \"Use internal MCP tools as the signed-in user\",
      \"adminConsentDescription\": \"Allows the app to call the internal MCP servers on behalf of the signed-in user.\",
      \"userConsentDisplayName\": \"Use internal MCP tools as you\",
      \"userConsentDescription\": \"Allows the app to call the internal MCP servers on your behalf.\"
    }]
  },
  \"appRoles\": [{
    \"id\": \"$role_id\", \"value\": \"ServiceDesk.Agent\", \"isEnabled\": true,
    \"allowedMemberTypes\": [\"User\"],
    \"displayName\": \"Service desk agent\",
    \"description\": \"Can change the status of service requests.\"
  }]
}"

# 2. Pre-authorise the client for the scope: users get no consent prompt, no admin consent needed.
az rest --method PATCH --url "$GRAPH/applications/$api_obj" --headers "Content-Type=application/json" --body "{
  \"api\": { \"preAuthorizedApplications\": [{ \"appId\": \"$MCP_CLIENT_APP_ID\", \"delegatedPermissionIds\": [\"$scope_id\"] }] }
}"

# 3. Client: redirect URI + declared access (MCP.Access; offline_access/openid are implicit OIDC scopes).
az rest --method PATCH --url "$GRAPH/applications/$client_obj" --headers "Content-Type=application/json" --body "{
  \"web\": { \"redirectUris\": [\"$REDIRECT_URI\"] },
  \"requiredResourceAccess\": [{
    \"resourceAppId\": \"$MCP_API_APP_ID\",
    \"resourceAccess\": [{ \"id\": \"$scope_id\", \"type\": \"Scope\" }]
  }]
}"

# 4. Persona A: assign the app role (the API owner may do this; no admin consent).
api_sp=$(az ad sp show --id "$MCP_API_APP_ID" --query id -o tsv)
IFS=',' read -r -a agents <<< "$AGENT_USERS"
for upn in "${agents[@]}"; do
  [[ -n "$upn" ]] || continue
  # Guests (B2B) have a UPN like name_domain#EXT#@tenant; fall back to the mail attribute.
  uid=$(az ad user show --id "$upn" --query id -o tsv 2>/dev/null \
    || az ad user list --filter "mail eq '$upn'" --query "[0].id" -o tsv)
  [[ -n "$uid" ]] || { echo "No Entra user found for $upn" >&2; exit 1; }
  have=$(az rest --method GET --url "$GRAPH/servicePrincipals/$api_sp/appRoleAssignedTo" \
    --query "value[?principalId=='$uid' && appRoleId=='$role_id'] | length(@)" -o tsv)
  if [[ "$have" == "0" ]]; then
    az rest --method POST --url "$GRAPH/servicePrincipals/$api_sp/appRoleAssignedTo" --headers "Content-Type=application/json" \
      --body "{\"principalId\":\"$uid\",\"resourceId\":\"$api_sp\",\"appRoleId\":\"$role_id\"}" >/dev/null
    echo "Assigned ServiceDesk.Agent to $upn"
  else
    echo "ServiceDesk.Agent already assigned to $upn"
  fi
done

cat > "$STATE_DIR/entra-obo.env" <<EOF
MCP_SCOPE_ID=$scope_id
MCP_ROLE_ID=$role_id
MCP_REDIRECT_URI=$REDIRECT_URI
MCP_OAUTH_SCOPE="api://$MCP_API_APP_ID/MCP.Access offline_access"
MCP_AUTHORIZATION_ENDPOINT=https://login.microsoftonline.com/$TENANT_ID/oauth2/v2.0/authorize
MCP_TOKEN_ENDPOINT=https://login.microsoftonline.com/$TENANT_ID/oauth2/v2.0/token
EOF
echo "Wrote $STATE_DIR/entra-obo.env"; cat "$STATE_DIR/entra-obo.env"
