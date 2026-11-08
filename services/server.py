"""Internal services. SERVER selects what this container serves:
  service_desk | asset_inventory  MCP servers (FastMCP, streamable HTTP on /mcp), Entra on-behalf-of
  orders | legacy                 plain REST APIs (see rest_apis.py)

Runs as streamable HTTP on /mcp behind Entra ID auth. Every tool acts on behalf of the calling user.
"""

from __future__ import annotations

import logging
import os
import sqlite3
from datetime import datetime, timezone

import uvicorn
from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings
from starlette.responses import PlainTextResponse
from starlette.routing import Route

import seed_data
from auth import EntraAuthMiddleware, current_caller

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
log = logging.getLogger("mcp.server")

SERVER = os.environ.get("SERVER", "service_desk")
AGENT_ROLE = os.environ.get("AGENT_ROLE", "ServiceDesk.Agent")
DEMO_USERS = [u for u in os.environ.get("DEMO_USERS", "").split(",") if u]
MAX_ROWS = 25


def _db() -> sqlite3.Connection:
    con = sqlite3.connect(":memory:", check_same_thread=False)
    con.row_factory = sqlite3.Row
    con.execute("create table sites (site_id text primary key, name text, country text, region text)")
    con.execute("""create table assets (asset_id text primary key, asset_type text, site_id text, serial_no text,
                   install_date text, warranty_end text, status text)""")
    con.execute("""create table requests (request_id text primary key, title text, category text, priority text,
                   site_id text, asset_id text, requester text, status text, opened_at text, closed_at text,
                   sla_met integer, updated_by text)""")
    con.execute("create table asset_events (asset_id text, at text, event text)")
    con.execute("""create table orders (order_id text primary key, asset_id text, site_id text, part_no text,
                   description text, qty integer, total_eur real, status text, requested_by text, created_at text)""")
    con.execute("""create table parts (site_id text, part_no text, description text, on_hand integer,
                   reorder_level integer)""")
    for table, rows in (("sites", seed_data.sites()), ("assets", seed_data.assets()),
                        ("requests", seed_data.requests(DEMO_USERS or None)),
                        ("orders", seed_data.orders(DEMO_USERS or None)), ("parts", seed_data.parts())):
        cols = list(rows[0])
        con.executemany(f"insert into {table} ({','.join(cols)}) values ({','.join('?' * len(cols))})",
                        [tuple(r[c] for c in cols) for r in rows])
    # Asset history = install + every request against the asset.
    con.execute("insert into asset_events select asset_id, install_date, 'Installed' from assets")
    con.execute("insert into asset_events select asset_id, opened_at, request_id || ' opened: ' || title from requests")
    con.commit()
    return con


DB = _db()


def _rows(sql: str, args: tuple = ()) -> list[dict]:
    return [dict(r) for r in DB.execute(sql, args).fetchall()]


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


mcp = FastMCP(
    name=SERVER.replace("_", "-") + "-mcp",
    stateless_http=True,
    json_response=True,
    # Host header is the internal ACA FQDN; requests are authenticated, so rebinding checks are off.
    transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False),
)


if SERVER == "service_desk":

    @mcp.tool()
    def search_requests(site_id: str | None = None, status: str | None = None, priority: str | None = None,
                        mine: bool = False, open_only: bool = True) -> list[dict]:
        """Search service requests. Filters: site_id (e.g. BER-01), status, priority (P1-P4),
        mine=true for the calling user's own requests, open_only (default true)."""
        clauses, args = [], []
        if open_only:
            clauses.append("status != 'Resolved'")
        for col, val in (("site_id", site_id), ("status", status), ("priority", priority)):
            if val:
                clauses.append(f"{col} = ?")
                args.append(val)
        if mine:
            clauses.append("lower(requester) = lower(?)")
            args.append(current_caller.get().user)
        where = f"where {' and '.join(clauses)}" if clauses else ""
        return _rows(f"select request_id, title, priority, status, site_id, asset_id, requester, opened_at "
                     f"from requests {where} order by priority, opened_at desc limit {MAX_ROWS}", tuple(args))

    @mcp.tool()
    def get_request(request_id: str) -> dict:
        """Get one service request by ID (e.g. REQ-1042)."""
        rows = _rows("select * from requests where request_id = ?", (request_id,))
        return rows[0] if rows else {"error": f"{request_id} not found"}

    @mcp.tool()
    def create_request(title: str, site_id: str, priority: str = "P3", asset_id: str | None = None,
                       category: str = "Hardware fault") -> dict:
        """Create a service request on behalf of the calling user."""
        caller = current_caller.get()
        n = DB.execute("select count(*) from requests").fetchone()[0] + 1
        request_id = f"REQ-{n:04d}N"
        DB.execute("insert into requests values (?,?,?,?,?,?,?,?,?,?,?,?)",
                   (request_id, title, category, priority, site_id, asset_id, caller.user, "New", _now(),
                    None, None, caller.user))
        if asset_id:
            DB.execute("insert into asset_events values (?,?,?)", (asset_id, _now(), f"{request_id} opened: {title}"))
        DB.commit()
        log.info("create_request %s by %s", request_id, caller.user)
        return get_request(request_id)

    @mcp.tool()
    def update_request_status(request_id: str, status: str) -> dict:
        """Change a request's status (e.g. 'In progress', 'Resolved'). Requires the service-desk agent role."""
        caller = current_caller.get()
        if not caller.has_role(AGENT_ROLE):
            log.warning("update_request_status denied for %s (missing role %s)", caller.user, AGENT_ROLE)
            return {"error": f"Denied: {caller.user} does not have the '{AGENT_ROLE}' role in the service desk."}
        closed = _now() if status == "Resolved" else None
        cur = DB.execute("update requests set status = ?, closed_at = coalesce(?, closed_at), updated_by = ? "
                         "where request_id = ?", (status, closed, caller.user, request_id))
        DB.commit()
        if cur.rowcount == 0:
            return {"error": f"{request_id} not found"}
        log.info("update_request_status %s -> %s by %s", request_id, status, caller.user)
        return get_request(request_id)

elif SERVER == "asset_inventory":

    @mcp.tool()
    def get_asset(asset_id: str) -> dict:
        """Get an asset (type, site, serial, install date, warranty end, status) by ID (e.g. AST-0001)."""
        rows = _rows("select a.*, s.name as site_name from assets a join sites s using (site_id) where asset_id = ?",
                     (asset_id,))
        if not rows:
            return {"error": f"{asset_id} not found"}
        asset = rows[0]
        asset["under_warranty"] = asset["warranty_end"] >= seed_data.TODAY.isoformat()
        return asset

    @mcp.tool()
    def search_assets(site_id: str | None = None, asset_type: str | None = None,
                      status: str | None = None) -> list[dict]:
        """Search assets by site_id, asset_type or status (Operational, Degraded, Down, Retired)."""
        clauses, args = [], []
        for col, val in (("site_id", site_id), ("asset_type", asset_type), ("status", status)):
            if val:
                clauses.append(f"{col} = ?")
                args.append(val)
        where = f"where {' and '.join(clauses)}" if clauses else ""
        return _rows(f"select asset_id, asset_type, site_id, status, warranty_end from assets {where} "
                     f"order by asset_id limit {MAX_ROWS}", tuple(args))

    @mcp.tool()
    def get_asset_history(asset_id: str, limit: int = 20) -> list[dict]:
        """Recent events for an asset (installation and service requests), newest first."""
        return _rows("select at, event from asset_events where asset_id = ? order by at desc limit ?",
                     (asset_id, min(limit, MAX_ROWS)))

elif SERVER not in ("orders", "legacy"):
    raise SystemExit(f"unknown SERVER={SERVER!r}")


def build_app():
    if SERVER in ("orders", "legacy"):
        import rest_apis
        return rest_apis.build_orders_app(DB) if SERVER == "orders" else rest_apis.build_legacy_app(DB)
    app = mcp.streamable_http_app()
    app.router.routes.append(Route("/healthz", lambda _: PlainTextResponse("ok")))
    app.add_middleware(EntraAuthMiddleware)
    return app


if __name__ == "__main__":
    uvicorn.run(build_app(), host="0.0.0.0", port=int(os.environ.get("PORT", "8080")), proxy_headers=True,
                forwarded_allow_ips="*")
