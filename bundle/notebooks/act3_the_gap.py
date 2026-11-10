# Databricks notebook source
# MAGIC %md
# MAGIC # The gap, and how the gateway closes it
# MAGIC
# MAGIC Serverless compute runs in the **Databricks** network. The internal load balancer has private addresses
# MAGIC (`10.80.x.x`) in **your** network. The private network gateway connects the two, but only for the
# MAGIC destinations it's configured with: here one DNS suffix, the internal domain.
# MAGIC
# MAGIC Same load balancer, two names:
# MAGIC
# MAGIC | Name | Matches the gateway destination? |
# MAGIC |---|---|
# MAGIC | `servicedesk.<internal domain>` | yes (suffix) → routed into your network |
# MAGIC | the load balancer's AWS name `internal-….elb.amazonaws.com` | no → not routed through the gateway |

# COMMAND ----------

import ssl
import time
import urllib.error
import urllib.request

dbutils.widgets.text("domain", "examplecorp-internal.duckdns.org", "Internal domain")  # noqa: F821
dbutils.widgets.text("alb_name", "", "Load balancer AWS name (terraform output alb_dns_name)")  # noqa: F821
DOMAIN = dbutils.widgets.get("domain")  # noqa: F821
ALB = dbutils.widgets.get("alb_name")  # noqa: F821
HOST = f"servicedesk.{DOMAIN}"


def probe(name: str) -> None:
    started = time.perf_counter()
    # The AWS name doesn't match the certificate, so skip verification for it: this test is about the route only.
    ctx = ssl.create_default_context() if name == HOST else ssl._create_unverified_context()
    try:
        req = urllib.request.Request(f"https://{name}/healthz", headers={"Host": HOST})
        with urllib.request.urlopen(req, timeout=8, context=ctx) as r:
            outcome = f"HTTP {r.status} → reached the internal load balancer"
    except urllib.error.HTTPError as e:
        outcome = f"HTTP {e.code} → reached the internal load balancer"
    except Exception as e:
        outcome = f"no connection ({type(e).__name__}: {str(e)[:90]})"
    print(f"{name:72} {round((time.perf_counter() - started) * 1000):5} ms  {outcome}")


probe(HOST)
if ALB:
    probe(ALB)
else:
    print("Set the widget alb_name to the load balancer's AWS name to compare.")

# COMMAND ----------

# MAGIC %md
# MAGIC **Result:** only the name under the gateway's destination reaches the internal network. Everything else stays
# MAGIC outside, whatever address it resolves to. One suffix entry covers every current and future internal service.
