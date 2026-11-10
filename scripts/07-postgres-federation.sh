#!/usr/bin/env bash
# Internal database via Lakehouse Federation, through the private network gateway:
#   1. seed (database team's side): Lambda pngdemo-pg-seed in the services VPC creates inventory.stock and the read-only
#      role dbx_reader. The RDS admin password (AWS Secrets Manager) and a newly generated read-only password are
#      piped into the invocation payload: never printed, never written to disk, never in a command line.
#   2. UC connection pngdemo_pg (POSTGRESQL, user dbx_reader) + foreign catalog ops_inventory, granted to pngdemo-users
#   3. test query on the serverless SQL warehouse (→ NCC → gateway → firewall → Postgres)
# Re-running rotates the read-only password (role and connection updated together). Idempotent otherwise.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
P="${DATABRICKS_CONFIG_PROFILE:-pngdemo-ws}"
export AWS_PROFILE="${AWS_PROFILE:-pngdemo-sandbox}" AWS_REGION="${AWS_REGION:-eu-central-1}"
CONN=pngdemo_pg CATALOG=ops_inventory
PG=$(terraform -chdir="$ROOT/infra/30-aws-services" output -json postgres)
HOST=$(jq -r .host <<<"$PG") DB=$(jq -r .database <<<"$PG") SECRET_ARN=$(jq -r .secret_arn <<<"$PG")
WAREHOUSE=$(terraform -chdir="$ROOT/infra/50-databricks-uc" output -raw warehouse_id)
READER_PW=$(openssl rand -base64 33 | tr -d '/+=\n' | cut -c1-32)

echo "== 1. seed the database (Lambda in the services VPC)"
out=$(mktemp); trap 'rm -f "$out"' EXIT
aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" --query SecretString --output text |
  jq -c --rawfile r <(printf '%s' "$READER_PW") '{admin_password: .password, reader_password: $r}' |
  aws lambda invoke --function-name pngdemo-pg-seed --cli-binary-format raw-in-base64-out \
    --payload fileb:///dev/stdin "$out" --query FunctionError --output text | grep -v None && { cat "$out"; exit 1; }
jq -c . "$out"

echo "== 2. connection + foreign catalog"
conn_json() {
  jq -nc --rawfile pw <(printf '%s' "$READER_PW") --arg n "$CONN" --arg h "$HOST" '{name: $n, connection_type: "POSTGRESQL",
    comment: "Internal inventory database (RDS Postgres) via the private network gateway; read-only role",
    options: {host: $h, port: "5432", user: "dbx_reader", password: $pw}}'
}
if databricks connections get "$CONN" -p "$P" >/dev/null 2>&1; then
  conn_json | jq -c '{options}' | databricks api patch "/api/2.1/unity-catalog/connections/$CONN" -p "$P" --json @/dev/stdin >/dev/null
  echo "connection $CONN updated"
else
  conn_json | databricks api post /api/2.1/unity-catalog/connections -p "$P" --json @/dev/stdin >/dev/null
  echo "connection $CONN created"
fi
unset READER_PW
if ! databricks catalogs get "$CATALOG" -p "$P" >/dev/null 2>&1; then
  jq -nc --arg n "$CATALOG" --arg c "$CONN" --arg d "$DB" '{name: $n, connection_name: $c, options: {database: $d},
    comment: "Live inventory (internal Postgres) via Lakehouse Federation and the private network gateway"}' |
    databricks api post /api/2.1/unity-catalog/catalogs -p "$P" --json @/dev/stdin >/dev/null
  echo "catalog $CATALOG created"
fi
jq -nc '{changes: [{principal: "pngdemo-users", add: ["USE_CATALOG", "USE_SCHEMA", "SELECT"]}]}' |
  databricks api patch "/api/2.1/unity-catalog/permissions/catalog/$CATALOG" -p "$P" --json @/dev/stdin >/dev/null
echo "granted USE_CATALOG, USE_SCHEMA, SELECT on $CATALOG to pngdemo-users"

echo "== 3. test query (serverless SQL warehouse → gateway → Postgres)"
jq -nc --arg w "$WAREHOUSE" --arg c "$CATALOG" '{warehouse_id: $w, wait_timeout: "50s",
  statement: ("SELECT site_id, count(*) AS parts, sum(CASE WHEN on_hand < reorder_level THEN 1 ELSE 0 END) AS below_reorder FROM " + $c + ".inventory.stock GROUP BY site_id ORDER BY site_id")}' |
  databricks api post /api/2.0/sql/statements -p "$P" --json @/dev/stdin |
  jq -r '.status.state as $s | if $s == "SUCCEEDED" then (.result.data_array[] | join("  ")) else "\($s): \(.status.error.message // "")" end'
