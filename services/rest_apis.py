"""Plain REST APIs (not MCP) behind the same private network gateway: proof that the path isn't MCP-specific.

  orders  (SERVER=orders)  Purchase orders for spare parts. Entra-protected, acts on behalf of the caller:
                           GET /orders[?site_id=&status=&mine=true], GET /orders/{id}, POST /orders
  legacy  (SERVER=legacy)  Spare-parts inventory. NO authentication: stands in for "shadow IT" services that
                           were never integrated with the IdP. GET /parts[?site_id=&below_reorder=true]

Both use the shared in-memory SQLite DB from server.py (same seed data as the MCP servers and the lakehouse).
"""

from __future__ import annotations

import logging
from datetime import datetime, timezone

from starlette.applications import Starlette
from starlette.middleware import Middleware
from starlette.requests import Request
from starlette.responses import JSONResponse, PlainTextResponse
from starlette.routing import Route

log = logging.getLogger("rest")
MAX_ROWS = 50


def _rows(db, sql: str, args: tuple = ()) -> list[dict]:
    return [dict(r) for r in db.execute(sql, args).fetchall()]


def _healthz(_request: Request):
    return PlainTextResponse("ok")


def build_orders_app(db) -> Starlette:
    from auth import EntraAuthMiddleware, current_caller

    async def list_orders(request: Request):
        q = request.query_params
        clauses, args = [], []
        for col in ("site_id", "status", "asset_id"):
            if q.get(col):
                clauses.append(f"{col} = ?")
                args.append(q[col])
        if q.get("mine", "").lower() == "true":
            clauses.append("lower(requested_by) = lower(?)")
            args.append(current_caller.get().user)
        where = f"where {' and '.join(clauses)}" if clauses else ""
        rows = _rows(db, f"select * from orders {where} order by created_at desc limit {MAX_ROWS}", tuple(args))
        return JSONResponse({"orders": rows, "caller": current_caller.get().user})

    async def get_order(request: Request):
        rows = _rows(db, "select * from orders where order_id = ?", (request.path_params["order_id"],))
        return JSONResponse(rows[0]) if rows else JSONResponse({"error": "not found"}, status_code=404)

    async def create_order(request: Request):
        body = await request.json()
        caller = current_caller.get()
        asset = _rows(db, "select site_id from assets where asset_id = ?", (body.get("asset_id", ""),))
        part = _rows(db, "select description from parts where part_no = ? limit 1", (body.get("part_no", ""),))
        if not asset or not part:
            return JSONResponse({"error": "unknown asset_id or part_no"}, status_code=400)
        n = db.execute("select count(*) from orders").fetchone()[0] + 1
        order_id = f"PO-{n:04d}N"
        db.execute("insert into orders values (?,?,?,?,?,?,?,?,?,?)",
                   (order_id, body["asset_id"], asset[0]["site_id"], body["part_no"], part[0]["description"],
                    int(body.get("qty", 1)), None, "Requested", caller.user,
                    datetime.now(timezone.utc).date().isoformat()))
        db.commit()
        log.info("create_order %s by %s", order_id, caller.user)
        return JSONResponse(_rows(db, "select * from orders where order_id = ?", (order_id,))[0], status_code=201)

    return Starlette(
        routes=[
            Route("/healthz", _healthz),
            Route("/orders", list_orders, methods=["GET"]),
            Route("/orders", create_order, methods=["POST"]),
            Route("/orders/{order_id}", get_order, methods=["GET"]),
        ],
        middleware=[Middleware(EntraAuthMiddleware)],
    )


def build_legacy_app(db) -> Starlette:
    async def list_parts(request: Request):
        q = request.query_params
        clauses, args = [], []
        if q.get("site_id"):
            clauses.append("site_id = ?")
            args.append(q["site_id"])
        if q.get("below_reorder", "").lower() == "true":
            clauses.append("on_hand < reorder_level")
        where = f"where {' and '.join(clauses)}" if clauses else ""
        # Deliberately no authentication: anyone with a network route gets the data.
        log.warning("UNAUTHENTICATED parts query from %s: %s", request.client.host if request.client else "-",
                    dict(q))
        return JSONResponse({"parts": _rows(db, f"select * from parts {where} order by site_id, part_no "
                                                f"limit {MAX_ROWS}", tuple(args))})

    return Starlette(routes=[Route("/healthz", _healthz), Route("/parts", list_parts)])
