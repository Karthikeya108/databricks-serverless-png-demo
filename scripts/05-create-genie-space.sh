#!/usr/bin/env bash
# Creates the Genie space "Operations history" over ops_demo.lakehouse in the caller's user folder
# (not /Workspace/Shared, which would give all users CAN_MANAGE) and grants the demo groups.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DATABRICKS_CONFIG_PROFILE="${DATABRICKS_CONFIG_PROFILE:-pngdemo-ws}"
WH=$(terraform -chdir="$ROOT/infra/50-databricks-uc" output -raw warehouse_id)
ME=$(databricks current-user me -o json | jq -r .userName)
FOLDER="/Workspace/Users/$ME/pngdemo"

databricks workspace mkdirs "$FOLDER"
SPACE=$(databricks genie create-space -o json --json "$(jq -n --arg wh "$WH" --arg p "$FOLDER" \
  --arg s "$(jq -c . "$ROOT/bundle/genie/genie_space.json")" '{
    warehouse_id: $wh, parent_path: $p, serialized_space: $s, title: "Operations history",
    description: "Historical service requests, SLA and asset uptime (Delta in customer S3 via Private Link)"}')" \
  | jq -r .space_id)

databricks api patch "/api/2.0/permissions/genie/$SPACE" --json '{"access_control_list":[
  {"group_name":"pngdemo-users","permission_level":"CAN_RUN"},
  {"group_name":"pngdemo-assets-only","permission_level":"CAN_RUN"},
  {"group_name":"pngdemo-admins","permission_level":"CAN_MANAGE"}]}' >/dev/null

mkdir -p "$ROOT/.state" && echo "$SPACE" > "$ROOT/.state/genie_space_id"
echo "Genie space: $SPACE  (set genie_space_id in bundle/.databricks/bundle/dev/variable-overrides.json)"
