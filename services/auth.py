"""Entra ID token validation for delegated (on-behalf-of-user) calls.

Every request must carry a user token issued by Entra to the allowed client (the UC connection's
OAuth app) for this API, with the delegated scope. App-only tokens are rejected.
All settings come from environment variables so the same image works with any OIDC IdP.
"""

from __future__ import annotations

import contextvars
import logging
import os
from dataclasses import dataclass, field

import jwt
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import JSONResponse

log = logging.getLogger("mcp.auth")

TENANT_ID = os.environ["TENANT_ID"]
ISSUER = os.environ.get("TOKEN_ISSUER", f"https://login.microsoftonline.com/{TENANT_ID}/v2.0")
JWKS_URL = os.environ.get("JWKS_URL", f"https://login.microsoftonline.com/{TENANT_ID}/discovery/v2.0/keys")
API_APP_ID = os.environ["MCP_API_APP_ID"]
AUDIENCES = [API_APP_ID, f"api://{API_APP_ID}"]
ALLOWED_CLIENTS = set(os.environ["ALLOWED_CLIENT_IDS"].split(","))
REQUIRED_SCOPE = os.environ.get("REQUIRED_SCOPE", "MCP.Access")
CLIENT_CLAIM = os.environ.get("CLIENT_CLAIM", "azp")
USER_CLAIM = os.environ.get("USER_CLAIM", "preferred_username")

_jwks = jwt.PyJWKClient(JWKS_URL, cache_keys=True, lifespan=3600)


@dataclass(frozen=True)
class Caller:
    user: str
    oid: str
    client_id: str
    scopes: frozenset[str]
    roles: frozenset[str] = field(default_factory=frozenset)

    def has_role(self, role: str) -> bool:
        return role in self.roles


current_caller: contextvars.ContextVar[Caller] = contextvars.ContextVar("current_caller")


def validate(token: str) -> Caller:
    key = _jwks.get_signing_key_from_jwt(token).key
    claims = jwt.decode(
        token,
        key,
        algorithms=["RS256"],
        audience=AUDIENCES,
        issuer=ISSUER,
        options={"require": ["exp", "iat", "iss", "aud"]},
    )
    client_id = claims.get(CLIENT_CLAIM, "")
    if client_id not in ALLOWED_CLIENTS:
        raise PermissionError(f"client {client_id!r} is not allowed")
    scopes = frozenset(claims.get("scp", "").split())
    if REQUIRED_SCOPE not in scopes:
        raise PermissionError("delegated scope missing (app-only tokens are not accepted)")
    return Caller(
        user=claims.get(USER_CLAIM) or claims.get("upn") or claims.get("sub", ""),
        oid=claims.get("oid", ""),
        client_id=client_id,
        scopes=scopes,
        roles=frozenset(claims.get("roles", [])),
    )


class EntraAuthMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        if request.url.path == "/healthz":
            return await call_next(request)
        header = request.headers.get("authorization", "")
        if not header.lower().startswith("bearer "):
            return JSONResponse({"error": "missing bearer token"}, status_code=401,
                                headers={"WWW-Authenticate": "Bearer"})
        try:
            caller = validate(header.split(" ", 1)[1])
        except PermissionError as e:
            log.warning("forbidden: %s", e)
            return JSONResponse({"error": str(e)}, status_code=403)
        except jwt.PyJWTError as e:
            log.warning("invalid token: %s", e)
            return JSONResponse({"error": "invalid token"}, status_code=401,
                                headers={"WWW-Authenticate": 'Bearer error="invalid_token"'})
        log.info("call user=%s client=%s scp=%s roles=%s src=%s",
                 caller.user, caller.client_id, " ".join(sorted(caller.scopes)),
                 ",".join(sorted(caller.roles)) or "-", request.client.host if request.client else "-")
        token = current_caller.set(caller)
        try:
            return await call_next(request)
        finally:
            current_caller.reset(token)
