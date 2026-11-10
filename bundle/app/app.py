"""Operations Assistant — Databricks App with user authorization (on-behalf-of the signed-in user).

Every downstream call uses the *user's* token from the X-Forwarded-Access-Token header:
  - Foundation Model API (agent reasoning)
  - Genie (history in Delta, your S3 bucket via NCC Private Link)
  - Unity Gateway MCP services (internal systems via the private network gateway; the MCP server
    receives the user's own Entra token from the per-user OAuth connection)
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import time
from contextlib import AsyncExitStack

import httpx
from fastapi import FastAPI, Request
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("ops-assistant")

HOST = "https://" + os.environ["DATABRICKS_HOST"].removeprefix("https://").rstrip("/")
MODEL = os.environ.get("MODEL_ENDPOINT", "databricks-claude-sonnet-5-5")
GENIE_SPACE_ID = os.environ["GENIE_SPACE_ID"]
MCP_SERVICES = [s for s in os.environ.get("MCP_SERVICES", "").split(",") if s]  # catalog.schema.service
MAX_STEPS = 8

SYSTEM_PROMPT = """You are the Operations Assistant for internal operations staff.
You have two kinds of tools:
- ask_genie: HISTORICAL analytics (closed requests, SLA performance, asset uptime) from the lakehouse.
- Tools prefixed with an MCP service name: the LIVE internal systems (open service requests, asset register).
  They act as the signed-in user: "my requests" means the caller's own requests.
Use history for trends and live systems for current state and actions. Combine them when useful.
If a tool returns an error (e.g. access denied or sign-in required), say so plainly; never invent data.

Ask before you act:
- If a question is ambiguous or refers to something not established in this conversation ("that site", "this asset",
  "the request"), do NOT guess and do NOT call tools: ask one short clarifying question, offering concrete options
  when you can (e.g. "Which site? For example ZRH-01, or should I first find the sites with the worst SLA?").
  If the conversation makes the reference reasonably clear (e.g. "that site" right after a ranking means the top
  one), use it and state your assumption in one line instead of asking.
- If a question is outside internal operations (sites, service requests, assets, SLA history), say briefly what you
  can help with and ask what they need. Don't answer general-knowledge questions.
- Before any change in a live system (create a request, change a status), confirm the details with the user first,
  unless they already gave all of them explicitly.
Be concise. Use tables for lists."""

app = FastAPI()


def _user_token(request: Request) -> str:
    token = request.headers.get("x-forwarded-access-token")
    if not token:
        raise PermissionError("No user token: enable user authorization for this app.")
    return token


def _path_label(tool_name: str) -> str:
    return "Private Link → Delta (Genie)" if tool_name == "ask_genie" else "Unity Gateway → PNG → internal MCP"


# ---------- Genie (history) ----------

GENIE_TOOL = {
    "type": "function",
    "function": {
        "name": "ask_genie",
        "description": "Ask a natural-language question about historical operations data "
                       "(closed service requests, SLA performance by site/priority, asset uptime and incidents).",
        "parameters": {"type": "object", "properties": {"question": {"type": "string"}}, "required": ["question"]},
    },
}


async def ask_genie(client: httpx.AsyncClient, question: str) -> dict:
    base = f"{HOST}/api/2.0/genie/spaces/{GENIE_SPACE_ID}"
    r = await client.post(f"{base}/start-conversation", json={"content": question})
    r.raise_for_status()
    conv, msg = r.json()["conversation_id"], r.json()["message_id"]
    for _ in range(60):
        m = (await client.get(f"{base}/conversations/{conv}/messages/{msg}")).json()
        if m.get("status") in ("COMPLETED", "FAILED", "CANCELLED"):
            break
        await asyncio.sleep(2)
    if m.get("status") != "COMPLETED":
        return {"error": (m.get("error") or {}).get("error", m.get("status"))}
    out: dict = {}
    for att in m.get("attachments", []):
        if att.get("text"):
            out["text"] = att["text"].get("content")
        if att.get("query"):
            out["sql"] = att["query"].get("query")
            res = (await client.get(f"{base}/conversations/{conv}/messages/{msg}/attachments/"
                                    f"{att['attachment_id']}/query-result")).json()
            stmt = res.get("statement_response", {})
            out["columns"] = [c["name"] for c in stmt.get("manifest", {}).get("schema", {}).get("columns", [])]
            out["rows"] = stmt.get("result", {}).get("data_array", [])[:30]
    return out


# ---------- Unity Gateway MCP services (live systems) ----------

def _tool_prefix(service: str) -> str:
    return service.split(".")[-1]


async def open_mcp_sessions(stack: AsyncExitStack, token: str) -> tuple[list[dict], dict, list[dict]]:
    """Connect to each MCP service as the user. Returns (openai tools, name->(session, tool), status).

    Each service gets its own exit stack: a service the user can't use (not signed in, no EXECUTE, no network path)
    is closed right away and reported in the status, without affecting the other services or the chat."""
    tools, routes, status = [], {}, []
    for service in MCP_SERVICES:
        url = f"{HOST}/ai-gateway/mcp-services/{service}"
        svc = AsyncExitStack()
        try:
            read, write, _ = await svc.enter_async_context(
                streamablehttp_client(url, headers={"Authorization": f"Bearer {token}"}, timeout=30))
            session = await svc.enter_async_context(ClientSession(read, write))
            await session.initialize()
            listed = await session.list_tools()
        except BaseException as e:  # noqa: BLE001  (anyio raises exception groups)
            if isinstance(e, (KeyboardInterrupt, SystemExit)):
                raise
            # The transport's real error (e.g. HTTP 401) often surfaces only when the session is closed; the error
            # seen here is then just the resulting cancellation.
            close_err = await _close_quietly(svc)
            msg = _flatten_error(close_err if close_err is not None and _is_cancel(e) else e)
            log.warning("MCP %s unavailable: %s", service, msg)
            status.append({"service": service, "ok": False, "detail": msg})
            continue
        stack.push_async_callback(_close_quietly, svc)
        status.append({"service": service, "ok": True, "detail": f"{len(listed.tools)} tools"})
        for t in listed.tools:
            name = f"{_tool_prefix(service)}__{t.name}"
            routes[name] = (session, t.name)
            tools.append({"type": "function", "function": {
                "name": name, "description": t.description or t.name,
                "parameters": t.inputSchema or {"type": "object", "properties": {}}}})
    return tools, routes, status


async def _close_quietly(stack: AsyncExitStack) -> BaseException | None:
    try:
        await stack.aclose()
    except BaseException as e:  # noqa: BLE001  (a failed session may raise again on close)
        if isinstance(e, (KeyboardInterrupt, SystemExit)):
            raise
        log.debug("closing MCP session: %s", _flatten_error(e))
        return e
    return None


def _is_cancel(e: BaseException) -> bool:
    while isinstance(e, BaseExceptionGroup) and e.exceptions:
        e = e.exceptions[0]
    return isinstance(e, asyncio.CancelledError) or type(e).__name__ == "CancelledError"


def _flatten_error(e: BaseException) -> str:
    while isinstance(e, BaseExceptionGroup) and e.exceptions:
        e = e.exceptions[0]
    if isinstance(e, httpx.HTTPStatusError):
        code = e.response.status_code
        if code == 401:
            return "Not signed in to this service yet: sign in once under Unity Gateway → MCPs"
        if code == 403:
            return "No access: ask for EXECUTE on this MCP service"
        try:  # streamed responses may not have a readable body
            body = e.response.text[:200]
        except Exception:  # noqa: BLE001
            body = ""
        return f"HTTP {code}{': ' + body if body else ''}"
    return f"{type(e).__name__}: {e}"[:400]


async def call_mcp(routes: dict, name: str, args: dict):
    session, tool = routes[name]
    result = await session.call_tool(tool, args)
    texts = [c.text for c in result.content if getattr(c, "type", "") == "text"]
    payload = "\n".join(texts)
    try:
        return json.loads(payload)
    except (json.JSONDecodeError, TypeError):
        return {"error": payload} if result.isError else payload


# ---------- Agent loop (streamed as server-sent events, so the UI shows each step live) ----------

def _text(content) -> str:
    """Model content can be a string or a list of content parts ({"type": "text", "text": ...}, reasoning, ...)."""
    if content is None:
        return ""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(p.get("text", "") for p in content if isinstance(p, dict) and p.get("type") == "text").strip()
    return str(content)


def _sse(event: dict) -> str:
    return f"data: {json.dumps(event, default=str)}\n\n"


async def run_agent(token: str, messages: list[dict]):
    """Yields progress events: phase, tool_start, tool_end, answer, error."""
    async with AsyncExitStack() as stack:
        http = await stack.enter_async_context(
            httpx.AsyncClient(headers={"Authorization": f"Bearer {token}"}, timeout=120))
        yield {"type": "phase", "text": "Connecting to internal systems as you (Unity Gateway)…"}
        mcp_tools, routes, status = await open_mcp_sessions(stack, token)
        yield {"type": "status", "services": status, "mcp_page": f"{HOST}/ai-gateway/mcps"}
        tools = [GENIE_TOOL] + mcp_tools

        for step in range(MAX_STEPS):
            yield {"type": "phase", "text": "Thinking…" if step == 0 else "Reviewing results…"}
            r = await http.post(f"{HOST}/serving-endpoints/{MODEL}/invocations",
                                json={"messages": messages, "tools": tools, "max_tokens": 2000})
            if r.status_code != 200:
                yield {"type": "error", "error": f"Model call failed: HTTP {r.status_code} {r.text[:300]}"}
                return
            choice = r.json()["choices"][0]["message"]
            messages.append({k: v for k, v in choice.items() if v is not None})
            calls = choice.get("tool_calls") or []
            if not calls:
                yield {"type": "answer", "answer": _text(choice.get("content")) or "(no answer)"}
                return
            for call in calls:
                name = call["function"]["name"]
                args = json.loads(call["function"].get("arguments") or "{}")
                yield {"type": "tool_start", "id": call["id"], "tool": name, "path": _path_label(name), "args": args}
                started = time.perf_counter()
                try:
                    result = await (ask_genie(http, args.get("question", "")) if name == "ask_genie"
                                    else call_mcp(routes, name, args))
                except Exception as e:
                    result = {"error": _flatten_error(e)}
                yield {"type": "tool_end", "id": call["id"], "ms": round((time.perf_counter() - started) * 1000),
                       "error": isinstance(result, dict) and "error" in result,
                       "result": json.dumps(result, default=str)[:1500]}
                messages.append({"role": "tool", "tool_call_id": call["id"],
                                 "content": json.dumps(result, default=str)[:12000]})
        yield {"type": "answer", "answer": "Stopped after too many tool steps."}


@app.post("/api/chat")
async def chat(request: Request):
    try:
        token = _user_token(request)
    except PermissionError as e:
        return JSONResponse({"error": str(e)}, status_code=401)
    body = await request.json()
    messages = [{"role": "system", "content": SYSTEM_PROMPT}] + body.get("messages", [])

    async def events():
        try:
            async for ev in run_agent(token, messages):
                yield _sse(ev)
        except Exception as e:  # surface failures in the chat instead of a broken stream
            log.exception("chat failed")
            yield _sse({"type": "error", "error": _flatten_error(e)})

    return StreamingResponse(events(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})


@app.get("/api/status")
async def mcp_status(request: Request):
    """Connectivity panel: can the signed-in user reach each MCP service right now?"""
    try:
        token = _user_token(request)
    except PermissionError as e:
        return JSONResponse({"error": str(e)}, status_code=401)
    async with AsyncExitStack() as stack:
        _, _, status = await open_mcp_sessions(stack, token)
    return {"user": request.headers.get("x-forwarded-email"), "services": status,
            "mcp_page": f"{HOST}/ai-gateway/mcps"}


@app.get("/")
async def index():
    return FileResponse(os.path.join(os.path.dirname(__file__), "static", "index.html"))
