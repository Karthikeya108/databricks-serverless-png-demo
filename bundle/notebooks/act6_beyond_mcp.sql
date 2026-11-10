-- Databricks notebook source
-- MAGIC %md
-- MAGIC # Beyond MCP: REST APIs and databases through the same gateway
-- MAGIC
-- MAGIC One private network gateway, one DNS suffix, one firewall zone rule. What changes per service is only the
-- MAGIC **Unity Catalog object** that governs it:
-- MAGIC
-- MAGIC | Internal system | UC object | Identity at the target |
-- MAGIC |---|---|---|
-- MAGIC | Legacy parts API (no SSO) | HTTP connection `ops_demo.tools.legacy_conn` | none (shadow IT) |
-- MAGIC | Inventory database (Postgres) | Foreign catalog `ops_inventory` (Lakehouse Federation) | read-only service role |
-- MAGIC
-- MAGIC Run on the serverless SQL warehouse `pngdemo-serverless` (or serverless notebook compute).

-- COMMAND ----------

-- MAGIC %md ## 1. Internal REST API from SQL: low stock at Berlin
-- MAGIC `http_request` with a UC HTTP connection, through the same gateway. This legacy API has no SSO: remember it for
-- MAGIC the next notebook (a network route is not a permission).

-- COMMAND ----------

SELECT p.site_id, p.part_no, p.description, p.on_hand, p.reorder_level
FROM (SELECT http_request(conn => 'ops_demo.tools.legacy_conn', method => 'GET', path => '/parts',
                          params => map('site_id', 'BER-01', 'below_reorder', 'true')) AS r)
LATERAL VIEW explode(from_json(get_json_object(r.text, '$.parts'),
  'array<struct<site_id:string,part_no:string,description:string,on_hand:int,reorder_level:int>>')) t AS p

-- COMMAND ----------

-- MAGIC %md ## 2. Internal Postgres via Lakehouse Federation
-- MAGIC A live query against the inventory database (RDS Postgres in the internal-services VPC), through the gateway.

-- COMMAND ----------

SELECT site_id, count(*) AS parts, sum(CASE WHEN on_hand < reorder_level THEN 1 ELSE 0 END) AS below_reorder
FROM ops_inventory.inventory.stock
GROUP BY site_id
ORDER BY below_reorder DESC

-- COMMAND ----------

-- MAGIC %md ## 3. Join live inventory with the lakehouse history
-- MAGIC Postgres (via the gateway) joined with Delta tables in customer S3 (via Private Link): which sites with the
-- MAGIC worst SLA also run low on spare parts?

-- COMMAND ----------

WITH sla AS (
  SELECT site_id, round(avg(CASE WHEN sla_met THEN 1.0 ELSE 0.0 END) * 100, 1) AS sla_pct
  FROM ops_demo.lakehouse.request_history
  WHERE closed_at IS NOT NULL
  GROUP BY site_id
)
SELECT s.site_id, s.name, sla.sla_pct,
       sum(CASE WHEN st.on_hand < st.reorder_level THEN 1 ELSE 0 END) AS parts_below_reorder
FROM ops_demo.lakehouse.sites s
JOIN sla USING (site_id)
JOIN ops_inventory.inventory.stock st USING (site_id)
GROUP BY s.site_id, s.name, sla.sla_pct
ORDER BY sla.sla_pct
