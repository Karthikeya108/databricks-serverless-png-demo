"""Deterministic sample data shared by the MCP servers (live systems) and the Delta tables (history).

Same seed -> same sites, assets and request IDs everywhere, so the agent can join live MCP data
with lakehouse history. Standard library only, so it also runs unchanged on Databricks serverless.
"""

from __future__ import annotations

import random
from datetime import date, datetime, timedelta, timezone

SEED = 42
TODAY = date(2026, 10, 25)

SITES = [
    ("BER-01", "Berlin Plant", "DE", "Central"),
    ("MUC-01", "Munich Campus", "DE", "Central"),
    ("ZRH-01", "Zurich Office", "CH", "Central"),
    ("VIE-01", "Vienna Hub", "AT", "Central"),
    ("AMS-01", "Amsterdam DC", "NL", "West"),
    ("LYO-01", "Lyon Works", "FR", "West"),
    ("MIL-01", "Milan Depot", "IT", "South"),
    ("WAW-01", "Warsaw Centre", "PL", "East"),
]

ASSET_TYPES = ["Compressor", "Conveyor", "Server Rack", "HVAC Unit", "Forklift", "Network Switch", "Generator", "Printer Fleet"]
CATEGORIES = ["Hardware fault", "Network", "Access request", "Facilities", "Software", "Safety"]
PRIORITIES = ["P1", "P2", "P3", "P4"]
SLA_HOURS = {"P1": 4, "P2": 8, "P3": 24, "P4": 72}
OPEN_STATUSES = ["New", "In progress", "Waiting on vendor"]

# Site-level "quality" so the SLA analysis tells a story (BER-01 and MIL-01 struggle).
SITE_SLA_BIAS = {"BER-01": 0.62, "MIL-01": 0.68, "WAW-01": 0.80}
DEFAULT_SLA_RATE = 0.9


def sites() -> list[dict]:
    return [dict(site_id=s, name=n, country=c, region=r) for s, n, c, r in SITES]


def assets() -> list[dict]:
    rng = random.Random(SEED)
    out = []
    for i in range(1, 121):
        site_id = SITES[(i - 1) % len(SITES)][0]
        installed = TODAY - timedelta(days=rng.randint(200, 3000))
        out.append(
            dict(
                asset_id=f"AST-{i:04d}",
                asset_type=rng.choice(ASSET_TYPES),
                site_id=site_id,
                serial_no=f"SN{rng.randint(10**7, 10**8 - 1)}",
                install_date=installed.isoformat(),
                warranty_end=(installed + timedelta(days=rng.choice([1095, 1825, 2555]))).isoformat(),
                status=rng.choices(["Operational", "Degraded", "Down", "Retired"], [80, 12, 5, 3])[0],
            )
        )
    return out


def requests(demo_users: list[str] | None = None) -> list[dict]:
    """~3000 requests over 18 months. The newest ~60 are still open (the 'live' service desk)."""
    rng = random.Random(SEED + 1)
    users = demo_users or ["user.a@example.com", "user.b@example.com"]
    requesters = users + [f"employee{n:03d}@example.com" for n in range(1, 41)]
    all_assets = assets()
    start = datetime.combine(TODAY - timedelta(days=540), datetime.min.time(), tzinfo=timezone.utc)
    out = []
    n = 3000
    for i in range(1, n + 1):
        asset = rng.choice(all_assets)
        priority = rng.choices(PRIORITIES, [5, 20, 45, 30])[0]
        opened = start + timedelta(minutes=int((i / n) * 540 * 24 * 60) + rng.randint(0, 600))
        is_open = i > n - 60
        sla_rate = SITE_SLA_BIAS.get(asset["site_id"], DEFAULT_SLA_RATE)
        sla_met = rng.random() < sla_rate
        hours = SLA_HOURS[priority] * (rng.uniform(0.2, 0.95) if sla_met else rng.uniform(1.1, 3.5))
        out.append(
            dict(
                request_id=f"REQ-{i:04d}",
                title=f"{rng.choice(CATEGORIES)}: {asset['asset_type']} at {asset['site_id']}",
                category=rng.choice(CATEGORIES),
                priority=priority,
                site_id=asset["site_id"],
                asset_id=asset["asset_id"],
                requester=rng.choice(requesters),
                status=rng.choice(OPEN_STATUSES) if is_open else "Resolved",
                opened_at=opened.isoformat(),
                closed_at=None if is_open else (opened + timedelta(hours=hours)).isoformat(),
                sla_met=None if is_open else sla_met,
                updated_by=None,
            )
        )
    # Guarantee the scripted demo record: an open P1 at the weakest site, owned by demo user A.
    demo = out[n - 1 - 17]
    demo.update(request_id="REQ-1042", priority="P1", site_id="BER-01", status="New", requester=users[0])
    demo_asset = next(a for a in all_assets if a["site_id"] == "BER-01")
    demo.update(asset_id=demo_asset["asset_id"], title=f"Hardware fault: {demo_asset['asset_type']} at BER-01")
    # Keep IDs unique: the original REQ-1042 (historic) is renamed.
    for r in out:
        if r is not demo and r["request_id"] == "REQ-1042":
            r["request_id"] = "REQ-1042H"
    return out


def asset_daily_metrics(days: int = 365) -> list[dict]:
    rng = random.Random(SEED + 2)
    out = []
    for a in assets():
        base = {"Operational": 99.0, "Degraded": 93.0, "Down": 80.0, "Retired": 0.0}[a["status"]]
        site_penalty = 4.0 if a["site_id"] in SITE_SLA_BIAS else 0.0
        for d in range(days):
            day = TODAY - timedelta(days=days - d)
            uptime = max(0.0, min(100.0, rng.gauss(base - site_penalty, 2.5))) if base else 0.0
            out.append(
                dict(
                    asset_id=a["asset_id"],
                    metric_date=day.isoformat(),
                    uptime_pct=round(uptime, 2),
                    incident_count=rng.choices([0, 1, 2, 3], [85, 10, 4, 1])[0] if base else 0,
                )
            )
    return out


PARTS = [
    ("PRT-100", "Bearing kit"), ("PRT-110", "Drive belt"), ("PRT-120", "Air filter"), ("PRT-130", "Cooling fan"),
    ("PRT-140", "Power supply"), ("PRT-150", "Control board"), ("PRT-160", "Hydraulic hose"), ("PRT-170", "Sensor module"),
    ("PRT-180", "Battery pack"), ("PRT-190", "Fuse set"),
]
ORDER_STATUSES = ["Requested", "Approved", "Ordered", "Delivered"]


def parts() -> list[dict]:
    """Spare-parts stock per site (the 'legacy' inventory API, no SSO)."""
    rng = random.Random(SEED + 3)
    return [dict(site_id=s, part_no=p, description=d, on_hand=rng.randint(0, 40), reorder_level=rng.choice([5, 10]))
            for s, *_ in SITES for p, d in PARTS]


def orders(demo_users: list[str] | None = None) -> list[dict]:
    """~200 purchase orders for spare parts, linked to assets (the 'orders' API, Entra-protected)."""
    rng = random.Random(SEED + 4)
    users = demo_users or ["user.a@example.com", "user.b@example.com"]
    requesters = users + [f"employee{n:03d}@example.com" for n in range(1, 41)]
    all_assets = assets()
    out = []
    for i in range(1, 201):
        asset = rng.choice(all_assets)
        part_no, desc = rng.choice(PARTS)
        qty = rng.randint(1, 6)
        created = TODAY - timedelta(days=rng.randint(0, 120))
        out.append(dict(
            order_id=f"PO-{i:04d}", asset_id=asset["asset_id"], site_id=asset["site_id"], part_no=part_no,
            description=desc, qty=qty, total_eur=round(qty * rng.uniform(40, 900), 2),
            status=rng.choices(ORDER_STATUSES, [15, 20, 25, 40])[0], requested_by=rng.choice(requesters),
            created_at=created.isoformat(),
        ))
    return out
