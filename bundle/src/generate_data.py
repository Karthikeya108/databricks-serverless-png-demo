# Databricks serverless job: writes the historical Delta tables into ops_demo.lakehouse.
# The catalog's managed location is your S3 bucket (deny-all policy except the serverless private
# endpoint and UC), so a successful run proves serverless reaches it through the NCC private endpoint rule.
import argparse
import os
import sys

from pyspark.sql import SparkSession, functions as F

parser = argparse.ArgumentParser()
parser.add_argument("--src_dir", default=os.getcwd())
parser.add_argument("--catalog", default="ops_demo")
parser.add_argument("--schema", default="lakehouse")
parser.add_argument("--demo_users", default="")
args = parser.parse_args()

sys.path.insert(0, args.src_dir)
import seed_data  # noqa: E402  (same generator as the MCP servers -> matching IDs)

spark = SparkSession.builder.getOrCreate()
target = f"{args.catalog}.{args.schema}"
demo_users = [u for u in args.demo_users.split(",") if u] or None

# updated_by only matters in the live system (MCP writes); history doesn't carry it.
closed = [{k: v for k, v in r.items() if k != "updated_by"}
          for r in seed_data.requests(demo_users) if r["status"] == "Resolved"]

tables = {
    "sites": (seed_data.sites(), "Site reference data"),
    "assets_dim": (seed_data.assets(), "Asset master snapshot (same IDs as the asset-inventory MCP)"),
    "request_history": (closed, "Closed service requests, ~18 months (same IDs as the service-desk MCP)"),
    "asset_daily_metrics": (seed_data.asset_daily_metrics(), "Daily uptime and incident counts per asset"),
}

for name, (rows, comment) in tables.items():
    df = spark.createDataFrame(rows)
    for col in ("install_date", "warranty_end", "metric_date"):
        if col in df.columns:
            df = df.withColumn(col, F.to_date(col))
    for col in ("opened_at", "closed_at"):
        if col in df.columns:
            df = df.withColumn(col, F.to_timestamp(col))
    if name == "request_history":
        df = df.withColumn("resolution_hours",
                           F.round((F.unix_timestamp("closed_at") - F.unix_timestamp("opened_at")) / 3600, 1))
    df.write.mode("overwrite").option("overwriteSchema", "true").saveAsTable(f"{target}.{name}")
    spark.sql(f"COMMENT ON TABLE {target}.{name} IS '{comment}'")
    print(f"{target}.{name}: {df.count()} rows")

# Show where the files live: the catalog's managed location in your storage.
loc = spark.sql(f"DESCRIBE DETAIL {target}.request_history").select("location").first()[0]
print(f"request_history files: {loc}")
