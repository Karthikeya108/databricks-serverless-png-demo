"""Seeds the internal inventory database and creates the read-only role used by Lakehouse Federation.

Runs as a Lambda function inside the internal-services VPC: the database team's side, not Databricks. Databricks only
ever gets the read-only role. Passwords arrive in the invocation payload and are never logged or returned.
TLS: full verification (CA + hostname) against the AWS RDS CA bundle, using the RDS endpoint name.
"""

from __future__ import annotations

import os
import ssl

import pg8000.native

import seed_data

HERE = os.path.dirname(__file__)


def handler(event, _context):
    ctx = ssl.create_default_context(cafile=os.path.join(HERE, "rds-ca-bundle.pem"))
    conn = pg8000.native.Connection(
        host=os.environ["DB_HOST"], database=os.environ["DB_NAME"], user=os.environ["DB_ADMIN_USER"],
        password=event["admin_password"], ssl_context=ctx, timeout=15)
    try:
        conn.run("CREATE SCHEMA IF NOT EXISTS inventory")
        conn.run("""CREATE TABLE IF NOT EXISTS inventory.stock (
                      site_id text NOT NULL, part_no text NOT NULL, description text NOT NULL,
                      on_hand int NOT NULL, reorder_level int NOT NULL, updated_at timestamptz NOT NULL DEFAULT now(),
                      PRIMARY KEY (site_id, part_no))""")
        for p in seed_data.parts():
            conn.run("""INSERT INTO inventory.stock (site_id, part_no, description, on_hand, reorder_level)
                        VALUES (:s, :p, :d, :o, :r)
                        ON CONFLICT (site_id, part_no) DO UPDATE
                        SET description = EXCLUDED.description, on_hand = EXCLUDED.on_hand,
                            reorder_level = EXCLUDED.reorder_level, updated_at = now()""",
                     s=p["site_id"], p=p["part_no"], d=p["description"], o=p["on_hand"], r=p["reorder_level"])
        # Least privilege for Databricks: login + SELECT on this one schema.
        exists = conn.run("SELECT 1 FROM pg_roles WHERE rolname = 'dbx_reader'")
        verb = "ALTER" if exists else "CREATE"
        conn.run(f"{verb} ROLE dbx_reader WITH LOGIN PASSWORD {pg8000.native.literal(event['reader_password'])}")
        db = pg8000.native.identifier(os.environ["DB_NAME"])
        conn.run(f"GRANT CONNECT ON DATABASE {db} TO dbx_reader")
        conn.run("GRANT USAGE ON SCHEMA inventory TO dbx_reader")
        conn.run("GRANT SELECT ON ALL TABLES IN SCHEMA inventory TO dbx_reader")
        conn.run("ALTER DEFAULT PRIVILEGES IN SCHEMA inventory GRANT SELECT ON TABLES TO dbx_reader")
        total, low = conn.run("""SELECT count(*), sum(CASE WHEN on_hand < reorder_level THEN 1 ELSE 0 END)
                                 FROM inventory.stock""")[0]
    finally:
        conn.close()
    return {"rows": total, "below_reorder": int(low or 0), "reader_role": "dbx_reader (SELECT on schema inventory)"}
