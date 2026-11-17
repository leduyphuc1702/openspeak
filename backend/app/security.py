"""Access control and basic abuse protection for a shared server.

One process can serve several learners. Each learner gets an access key; the key is
checked on every request except `/health` and the static `/download` folder (an
over-the-air install is opened by Safari, which cannot send an Authorization header,
and the folder path itself is unguessable). Requests are then limited per key (or per
IP when no keys are configured), large bodies are refused before they reach the
acoustic model, and only a few expensive requests run at once.

Nothing here is logged with the key: log lines and rate-limit identities use a short
SHA-256 prefix, never the key itself.
"""
from __future__ import annotations

import asyncio
import hashlib
import hmac
import json
import logging
import os
import time
from collections import defaultdict, deque
from dataclasses import dataclass, field
from typing import Deque, Dict, List, Optional, Tuple

log = logging.getLogger("openspeak.access")

OPEN_PATHS = {"/health"}
OPEN_PREFIXES = ("/download/",)
# Endpoints that load the acoustic model, call an LLM or decode audio.
HEAVY_PATHS = (
    "/v1/assess",
    "/v1/exercises",
    "/v1/path/next",
    "/v1/path/exam",
    "/v1/vocab/lesson",
    "/v1/vocab/next",
    "/v1/roleplay/start",
    "/v1/roleplay/turn",
    "/v1/llm/check",
    "/v1/dictionary",
    "/v1/audio/word",
    "/v1/articulation-feedback",
)


def _env_int(name: str, default: int, minimum: int = 1) -> int:
    try:
        return max(minimum, int(os.getenv(name, str(default))))
    except ValueError:
        return default


def configured_keys() -> List[str]:
    raw = os.getenv("OPENSPEAK_API_KEYS", "")
    return [key.strip() for key in raw.split(",") if key.strip()]


def trust_proxy() -> bool:
    return os.getenv("TRUST_PROXY", "0") == "1"


def access_info() -> Dict[str, object]:
    return {"auth_required": bool(configured_keys()),
            "rate_limit_per_min": _env_int("OPENSPEAK_RATE_LIMIT", 120),
            "max_body_mb": _env_int("OPENSPEAK_MAX_BODY_MB", 16),
            "max_concurrent": _env_int("OPENSPEAK_MAX_CONCURRENT", 2)}


def presented_key(headers: Dict[str, str]) -> str:
    auth = headers.get("authorization", "")
    if auth[:7].lower() == "bearer ":
        return auth[7:].strip()
    return headers.get("x-api-key", "").strip()


def key_identity(key: str) -> str:
    return hashlib.sha256(key.encode()).hexdigest()[:12]


def client_ip(scope, trusted: bool) -> str:
    if trusted:
        for name, value in scope.get("headers", []):
            if name.lower() == b"x-forwarded-for":
                return value.decode("latin-1").split(",")[0].strip() or "unknown"
    client = scope.get("client")
    return client[0] if client else "unknown"


class RateLimiter:
    """A sliding one-minute window per identity. Small and in-process; run one worker."""

    def __init__(self, per_minute: int):
        self.per_minute = per_minute
        self.events: Dict[str, Deque[float]] = defaultdict(deque)

    def allow(self, identity: str) -> Tuple[bool, float, int]:
        now = time.monotonic()
        queue = self.events[identity]
        while queue and now - queue[0] >= 60:
            queue.popleft()
        if len(queue) >= self.per_minute:
            return False, max(0.1, 60 - (now - queue[0])), 0
        queue.append(now)
        if len(self.events) > 10_000:
            for name in [n for n, q in self.events.items() if not q]:
                del self.events[name]
        return True, 0.0, self.per_minute - len(queue)


class Gate:
    def __init__(self, limit: int, wait: float):
        self.limit = limit
        self.wait = wait
        self.semaphore = asyncio.Semaphore(limit)

    async def acquire(self) -> bool:
        try:
            await asyncio.wait_for(self.semaphore.acquire(), timeout=self.wait)
            return True
        except asyncio.TimeoutError:
            return False

    def release(self) -> None:
        self.semaphore.release()


@dataclass
class Policy:
    keys: Tuple[str, ...]
    rate_limit: int
    max_body: int
    max_concurrent: int
    queue_seconds: float
    limiter: RateLimiter = field(init=False)
    gate: Gate = field(init=False)

    def __post_init__(self):
        self.limiter = RateLimiter(self.rate_limit)
        self.gate = Gate(self.max_concurrent, self.queue_seconds)


_policies: Dict[Tuple, Policy] = {}


def policy() -> Policy:
    """The policy for the current environment; rebuilt (and rate limits reset) when values change."""
    key = (tuple(configured_keys()),
           _env_int("OPENSPEAK_RATE_LIMIT", 120),
           _env_int("OPENSPEAK_MAX_BODY_MB", 16) * 1024 * 1024,
           _env_int("OPENSPEAK_MAX_CONCURRENT", 2),
           float(os.getenv("OPENSPEAK_QUEUE_SECONDS", "2")))
    if key not in _policies:
        _policies.clear()
        _policies[key] = Policy(keys=key[0], rate_limit=key[1], max_body=key[2],
                                max_concurrent=key[3], queue_seconds=key[4])
    return _policies[key]


class _BodyTooLarge(Exception):
    pass


def _json_response(status: int, code: str, message: str,
                   extra_headers: Optional[Dict[str, str]] = None) -> Tuple[bytes, List[Tuple[bytes, bytes]]]:
    body = json.dumps({"detail": {"code": code, "message": message}}).encode()
    headers = [(b"content-type", b"application/json"),
               (b"content-length", str(len(body)).encode()),
               (b"cache-control", b"no-store"),
               (b"x-content-type-options", b"nosniff")]
    for name, value in (extra_headers or {}).items():
        headers.append((name.lower().encode(), value.encode()))
    return body, headers


class SecurityMiddleware:
    """Authentication, per-identity rate limiting, body-size and concurrency limits."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        path: str = scope.get("path", "")
        if path in OPEN_PATHS or path.startswith(OPEN_PREFIXES) or path == "/download":
            return await self.app(scope, receive, send)

        current = policy()
        headers = {name.decode("latin-1").lower(): value.decode("latin-1")
                   for name, value in scope.get("headers", [])}
        key = presented_key(headers)
        authenticated = bool(current.keys) and any(
            hmac.compare_digest(key, expected) for expected in current.keys)
        if current.keys and not authenticated:
            body, extra = _json_response(401, "unauthorized",
                                         "Thiếu hoặc sai khoá truy cập máy chủ.",
                                         {"WWW-Authenticate": "Bearer"})
            return await self._send(send, 401, body, extra)

        identity = key_identity(key) if authenticated else client_ip(scope, trust_proxy())
        allowed, retry_after, remaining = current.limiter.allow(identity)
        if not allowed:
            body, extra = _json_response(429, "rate_limited",
                                         "Bạn gửi quá nhiều yêu cầu. Thử lại sau ít phút.",
                                         {"Retry-After": str(int(retry_after) + 1)})
            return await self._send(send, 429, body, extra)

        heavy = path.startswith(HEAVY_PATHS)
        if heavy and not await current.gate.acquire():
            body, extra = _json_response(503, "busy",
                                         "Máy chủ đang chấm nhiều yêu cầu. Thử lại sau vài giây.",
                                         {"Retry-After": "5"})
            return await self._send(send, 503, body, extra)

        started = False
        status = 500
        received = 0
        declared = headers.get("content-length", "")
        limit = current.max_body

        async def counted_receive():
            nonlocal received
            message = await receive()
            if message["type"] == "http.request":
                received += len(message.get("body", b""))
                if received > limit:
                    raise _BodyTooLarge
            return message

        async def guarded_send(message):
            nonlocal started, status
            if message["type"] == "http.response.start":
                started = True
                status = message["status"]
                headers_out = list(message.get("headers", []))
                names = {name.lower() for name, _ in headers_out}
                for name, value in ((b"x-content-type-options", b"nosniff"),
                                    (b"referrer-policy", b"no-referrer"),
                                    (b"cache-control", b"no-store")):
                    if name not in names:
                        headers_out.append((name, value))
                headers_out.append((b"x-ratelimit-limit", str(current.rate_limit).encode()))
                headers_out.append((b"x-ratelimit-remaining", str(remaining).encode()))
                message = dict(message, headers=headers_out)
            await send(message)

        began = time.monotonic()
        try:
            if declared.isdigit() and int(declared) > limit:
                raise _BodyTooLarge
            await self.app(scope, counted_receive, guarded_send)
        except _BodyTooLarge:
            if not started:
                body, extra = _json_response(413, "too_large",
                                             f"Yêu cầu vượt quá {limit // (1024 * 1024)} MB.")
                await self._send(send, 413, body, extra)
            status = 413
        finally:
            if heavy:
                current.gate.release()
            if os.getenv("OPENSPEAK_ACCESS_LOG", "1") != "0":
                log.info("%s %s %s %d %dms", identity, scope.get("method", "?"), path, status,
                         int((time.monotonic() - began) * 1000))

    @staticmethod
    async def _send(send, status: int, body: bytes, headers) -> None:
        message_headers = list(headers)
        message_headers += [(b"x-content-type-options", b"nosniff"),
                            (b"referrer-policy", b"no-referrer")]
        await send({"type": "http.response.start", "status": status, "headers": message_headers})
        await send({"type": "http.response.body", "body": body})
