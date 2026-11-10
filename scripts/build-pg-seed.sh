#!/usr/bin/env bash
# Terraform external data source (infra/30-aws-services/postgres_seed.tf): builds the Lambda package directory for the
# database seeding function (pure-Python driver, no compiled code). Prints {"dir": "..."} on stdout.
# Packages come from PIP_INDEX_URL (e.g. a corporate PyPI mirror; default: pypi.org). Rebuilds only on change.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/services"
OUT="$ROOT/infra/30-aws-services/.build/pg-seed"
REQ="pg8000==1.31.6"
stamp=$(cat "$SRC/pg_seed/handler.py" "$SRC/seed_data.py" "$SRC/pg_seed/rds-eu-central-1-bundle.pem" | shasum | cut -c1-16)-$REQ
if [[ ! -f "$OUT/.stamp" || "$(cat "$OUT/.stamp")" != "$stamp" ]]; then
  rm -rf "$OUT" && mkdir -p "$OUT"
  python3 -m pip install -q --target "$OUT" --index-url "${PIP_INDEX_URL:-https://pypi.org/simple}" \
    --no-compile --only-binary=:all: "$REQ" >&2
  cp "$SRC/pg_seed/handler.py" "$SRC/seed_data.py" "$OUT/"
  cp "$SRC/pg_seed/rds-eu-central-1-bundle.pem" "$OUT/rds-ca-bundle.pem"
  rm -rf "$OUT"/*.dist-info/RECORD
  echo "$stamp" > "$OUT/.stamp"
fi
jq -n --arg d "$OUT" '{dir: $d}'
