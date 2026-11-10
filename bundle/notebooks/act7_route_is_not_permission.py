# Databricks notebook source
# MAGIC %md
# MAGIC # A network route is not a permission
# MAGIC
# MAGIC The private network gateway routes `*.<internal domain>` for **all serverless compute of the workspace**, like a
# MAGIC corporate laptop on the office LAN. So anyone in the workspace can open a socket to an internal service from a
# MAGIC notebook, without any Unity Catalog object. What protects the services is the same as on the LAN:
# MAGIC
# MAGIC 1. **The service authenticates and authorizes** (Entra token, per user) → a bare request gets **401**.
# MAGIC 2. **The firewall decides which services the Databricks zone may reach at all** (`per_service` mode) → services
# MAGIC    without SSO can be kept out of reach entirely.
# MAGIC 3. **Unity Catalog governs the sanctioned path**: connections, MCP services and `EXECUTE` grants, per user, audited.

# COMMAND ----------

import time
import urllib.error
import urllib.request

dbutils.widgets.text("domain", "examplecorp-internal.duckdns.org", "Internal domain")  # noqa: F821
DOMAIN = dbutils.widgets.get("domain")  # noqa: F821


def call(name: str, path: str) -> None:
    url = f"https://{name}.{DOMAIN}{path}"
    started = time.perf_counter()
    try:
        with urllib.request.urlopen(url, timeout=8) as r:
            outcome = f"HTTP {r.status} · {r.read(160).decode(errors='replace')}…"
    except urllib.error.HTTPError as e:
        outcome = f"HTTP {e.code} · {e.read(120).decode(errors='replace')}"
    except Exception as e:  # timeout / reset = dropped by the firewall
        outcome = f"NO CONNECTION ({type(e).__name__}) → blocked on the network"
    print(f"{name:12} {path:28} {round((time.perf_counter() - started) * 1000):5} ms  {outcome}")

# COMMAND ----------

# MAGIC %md ## 1. Direct calls from a notebook, no token, no UC object

# COMMAND ----------

call("orders", "/orders")                       # Entra-protected REST API
call("servicedesk", "/mcp")                     # Entra-protected MCP server
call("legacy", "/parts?site_id=BER-01")         # no SSO ("shadow IT")

# COMMAND ----------

# MAGIC %md
# MAGIC **Result:** the route exists for everyone, but the protected services answer **401** without a valid user token.
# MAGIC The legacy API answers anyone: that's the risk of services without SSO, not of the gateway.
# MAGIC
# MAGIC ## 2. The network team closes the gap without touching Databricks
# MAGIC In `services.yaml`, `legacy` has `databricks_zone: false`. Switching the firewall to `per_service` mode
# MAGIC generates one rule per **approved** service (TLS SNI match), so `legacy` is dropped and logged:
# MAGIC
# MAGIC ```
# MAGIC terraform -chdir=infra/20-aws-network apply -var firewall_mode=per_service
# MAGIC ```
# MAGIC Then re-run the cell above: `orders` and `servicedesk` still answer, `legacy` gets no connection. Show the drop in
# MAGIC CloudWatch (saved query "3 Firewall verdicts for the gateway subnet").

# COMMAND ----------

call("legacy", "/parts?site_id=BER-01")
call("orders", "/orders")
