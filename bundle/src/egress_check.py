# Databricks serverless job: what can serverless compute reach on the internet, and with which source IP?
# Run it once per egress setup (label = which controls are active) and compare the runs side by side:
#   SELECT * FROM ops_demo.lakehouse.egress_checks ORDER BY run_at DESC
#
# Destinations (one per class):
#   allowlisted package index / code host, a site that is NOT allowlisted, a public S3 bucket that is not ours
#   (exfiltration channel), the internal services through the private network gateway, and an IP echo service that
#   shows the source IP the internet sees (Databricks egress IPs vs. the customer's NAT IP).
import argparse
import datetime as dt
import time
import urllib.error
import urllib.request

from pyspark.sql import SparkSession

parser = argparse.ArgumentParser()
parser.add_argument("--label", required=True, help="which egress controls are active, e.g. 'baseline'")
parser.add_argument("--internal_host", required=True, help="an internal service hostname (via the gateway)")
parser.add_argument("--table", default="ops_demo.lakehouse.egress_checks")
args = parser.parse_args()

TARGETS = [
    ("allowlisted: package index", "https://pypi.org/simple/requests/"),
    ("allowlisted: package files", "https://files.pythonhosted.org/"),
    ("allowlisted: code host", "https://api.github.com/zen"),
    ("not allowlisted: website", "https://example.com/"),
    ("not allowlisted: paste site", "https://pastebin.com/"),
    ("foreign S3 bucket (exfiltration)", "https://noaa-ghcn-pds.s3.amazonaws.com/index.html"),
    ("internal service via gateway", f"https://{args.internal_host}/healthz"),
    ("source IP seen by the internet", "https://checkip.amazonaws.com/"),
]


def probe(url: str) -> tuple[str, str, int]:
    started = time.perf_counter()
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "egress-check"}), timeout=10) as r:
            body = r.read(200).decode(errors="replace").strip()
            return "reachable", f"HTTP {r.status}" + (f" · {body}" if "checkip" in url else ""), _ms(started)
    except urllib.error.HTTPError as e:  # a response came back: the network path is open
        return "reachable", f"HTTP {e.code}", _ms(started)
    except Exception as e:  # DNS refused, connection reset/refused or timeout: blocked on the way
        return "blocked", f"{type(e).__name__}: {str(e)[:160]}", _ms(started)


def _ms(started: float) -> int:
    return round((time.perf_counter() - started) * 1000)


run_at = dt.datetime.now(dt.timezone.utc)
rows = []
print(f"== Egress check · {args.label} · {run_at:%Y-%m-%d %H:%M:%S} UTC")
for kind, url in TARGETS:
    result, detail, ms = probe(url)
    rows.append((run_at, args.label, kind, url, result, detail, ms))
    print(f"{'✓' if result == 'reachable' else '✗'} {kind:34} {result:9} {ms:6} ms  {detail}")

spark = SparkSession.builder.getOrCreate()
(spark.createDataFrame(rows, "run_at timestamp, label string, destination string, url string, result string, detail string, ms int")
 .write.mode("append").saveAsTable(args.table))
print(f"appended {len(rows)} rows to {args.table}")
