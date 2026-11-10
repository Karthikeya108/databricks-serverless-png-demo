# Databricks serverless job: checks both private paths of the NCC from serverless compute.
#   1. Private network gateway -> internal MCP servers (expects 200 on /healthz, 401 on /mcp without a token)
#   2. Private Link -> catalog managed location in your S3 bucket (reads a Delta table)
import argparse
import socket
import urllib.error
import urllib.request

from pyspark.sql import SparkSession

parser = argparse.ArgumentParser()
parser.add_argument("--mcp_hosts", required=True, help="comma-separated internal MCP hostnames")
parser.add_argument("--table", default="ops_demo.lakehouse.sites")
args = parser.parse_args()


def check(url: str) -> str:
    try:
        with urllib.request.urlopen(url, timeout=10) as r:
            return f"HTTP {r.status}"
    except urllib.error.HTTPError as e:
        return f"HTTP {e.code}"
    except Exception as e:  # DNS failure / timeout = no private route
        return f"FAILED ({type(e).__name__}: {e})"


print("== Private network gateway -> internal MCP servers")
for host in args.mcp_hosts.split(","):
    # The name is resolved by the gateway (private DNS zone linked to the hub VNet), not by the
    # serverless container, so a local lookup failing is expected.
    try:
        ip = socket.gethostbyname(host)
    except OSError:
        ip = "resolved by gateway"
    print(f"{host}  dns={ip}  /healthz={check(f'https://{host}/healthz')}  /mcp(no token)={check(f'https://{host}/mcp')}")

print("== Private Link -> catalog managed location")
spark = SparkSession.builder.getOrCreate()
try:
    print(f"{args.table}: {spark.table(args.table).count()} rows")
except Exception as e:
    print(f"{args.table}: FAILED ({e})")
