-- Databricks notebook source
-- MAGIC %md
-- MAGIC # Egress control: two options, one allowlist
-- MAGIC
-- MAGIC The same job (`pngdemo-egress-check`) ran from serverless once per egress setup. Each run tries the same
-- MAGIC destinations: allowlisted package index and code host, two sites that are **not** allowlisted, a foreign S3 bucket
-- MAGIC (exfiltration channel), an internal service through the gateway, and an IP echo service.
-- MAGIC
-- MAGIC | | Option A: Databricks network policy | Option B: gateway ALL_TRAFFIC + customer firewall |
-- MAGIC |---|---|---|
-- MAGIC | Who decides | Databricks account admin | Network/security team |
-- MAGIC | Allowlist | `services.yaml` → policy | `services.yaml` → firewall rules |
-- MAGIC | Logs | Denials in `system.access.outbound_network` | Allow **and** deny with hostname, in the customer's logging |
-- MAGIC | Source IP on the internet | Databricks egress IPs | Customer NAT IP |

-- COMMAND ----------

-- MAGIC %md ## 1. Side by side: what each setup lets through
-- MAGIC The last column is always the most recent run: start one live with
-- MAGIC `databricks bundle run egress_check --params label="live"` (≈ 30 s), then re-run this cell.

-- COMMAND ----------

WITH latest AS (
  SELECT label, max(run_at) AS run_at FROM ops_demo.lakehouse.egress_checks GROUP BY label
),
runs AS (
  SELECT c.* FROM ops_demo.lakehouse.egress_checks c JOIN latest USING (label, run_at)
),
pick AS (
  SELECT destination,
         max_by(CASE WHEN result = 'reachable' THEN '✓' ELSE '✗' END || CASE WHEN url LIKE '%checkip%' THEN ' ' || regexp_extract(detail, '([0-9.]+)$', 1) ELSE '' END,
                run_at) FILTER (WHERE label LIKE '1 %') AS `no controls`,
         max_by(CASE WHEN result = 'reachable' THEN '✓' ELSE '✗' END || CASE WHEN url LIKE '%checkip%' THEN ' ' || regexp_extract(detail, '([0-9.]+)$', 1) ELSE '' END,
                run_at) FILTER (WHERE label LIKE '3 %') AS `A: network policy`,
         max_by(CASE WHEN result = 'reachable' THEN '✓' ELSE '✗' END || CASE WHEN url LIKE '%checkip%' THEN ' ' || regexp_extract(detail, '([0-9.]+)$', 1) ELSE '' END,
                run_at) FILTER (WHERE label LIKE '4 %') AS `B: ALL_TRAFFIC + firewall`,
         max_by(CASE WHEN result = 'reachable' THEN '✓' ELSE '✗' END || CASE WHEN url LIKE '%checkip%' THEN ' ' || regexp_extract(detail, '([0-9.]+)$', 1) ELSE '' END,
                run_at) FILTER (WHERE label LIKE '6 %') AS `today: policy + firewall`,
         max_by(CASE WHEN result = 'reachable' THEN '✓' ELSE '✗' END || CASE WHEN url LIKE '%checkip%' THEN ' ' || regexp_extract(detail, '([0-9.]+)$', 1) ELSE '' END,
                run_at) FILTER (WHERE run_at = (SELECT max(run_at) FROM ops_demo.lakehouse.egress_checks)) AS `latest run`
  FROM runs
  GROUP BY destination
)
SELECT * FROM pick
ORDER BY CASE WHEN destination LIKE 'allowlisted%' THEN 1 WHEN destination LIKE 'not allowlisted%' THEN 2
              WHEN destination LIKE 'foreign%' THEN 3 WHEN destination LIKE 'internal%' THEN 4 ELSE 5 END, destination

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## 2. Option A evidence: the denial log
-- MAGIC Every block by the network policy, with time, destination and product (`General Compute` = notebooks and jobs,
-- MAGIC `DBSQL` = SQL warehouses). Run the egress check now and refresh this cell after a few minutes.

-- COMMAND ----------

SELECT event_time, access_type, destination_type, destination, network_source_type
FROM system.access.outbound_network
WHERE event_time > now() - INTERVAL 7 DAYS
ORDER BY event_time DESC
LIMIT 50

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## 3. Option B evidence: the customer firewall
-- MAGIC In CloudWatch (dashboard `pngdemo-private-network-gateway`, or saved query
-- MAGIC "3 Firewall verdicts for the gateway subnet"): `allowed … sni=pypi.org`, `blocked … sni=example.com`, and the
-- MAGIC customer NAT IP as the source the internet sees.
-- MAGIC
-- MAGIC ## 4. All runs in detail

-- COMMAND ----------

SELECT run_at, label, destination, result, detail, ms
FROM ops_demo.lakehouse.egress_checks
ORDER BY run_at DESC, destination
