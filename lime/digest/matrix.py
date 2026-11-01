"""Minimal Matrix client for the digest service (stdlib only).

Only the four calls this service needs: whoami, room /messages, joined_members
and send. Uses the LAN vhost so traffic never hairpins through Cloudflare.
"""

from __future__ import annotations

import json
import logging
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

log = logging.getLogger(__name__)


class MatrixError(RuntimeError):
    def __init__(self, status: int, body: str, path: str):
        super().__init__(f"Matrix {status} on {path}: {body[:500]}")
        self.status = status
        self.body = body
        self.path = path


class Matrix:
    def __init__(self, homeserver: str, token: str, user_id: str):
        self.homeserver = homeserver.rstrip("/")
        self.token = token
        self.user_id = user_id

    # -- transport ---------------------------------------------------------

    def _request(
        self,
        method: str,
        path: str,
        *,
        query: dict[str, str] | None = None,
        body: dict | None = None,
        retries: int = 3,
    ) -> dict:
        url = self.homeserver + path
        if query:
            url += "?" + urllib.parse.urlencode(query)
        data = None
        headers = {"Authorization": f"Bearer {self.token}"}
        if body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"

        last_error: Exception | None = None
        for attempt in range(1, retries + 1):
            req = urllib.request.Request(url, data=data, headers=headers, method=method)
            try:
                with urllib.request.urlopen(req, timeout=30) as resp:
                    raw = resp.read().decode()
                    return json.loads(raw) if raw else {}
            except urllib.error.HTTPError as exc:
                raw = exc.read().decode(errors="replace")
                if exc.code == 429:
                    retry_after = 5
                    try:
                        retry_after = int(
                            json.loads(raw).get("retry_after_ms", 5000) / 1000
                        )
                    except Exception:
                        pass
                    log.warning("Matrix rate limit on %s; sleeping %ss", path, retry_after)
                    time.sleep(retry_after)
                    last_error = MatrixError(exc.code, raw, path)
                    continue
                if exc.code >= 500 and attempt < retries:
                    last_error = MatrixError(exc.code, raw, path)
                    time.sleep(2 * attempt)
                    continue
                raise MatrixError(exc.code, raw, path) from exc
            except urllib.error.URLError as exc:
                last_error = exc
                if attempt < retries:
                    time.sleep(2 * attempt)
                    continue
                raise
        raise last_error or RuntimeError(f"Matrix request failed: {method} {path}")

    # -- API ---------------------------------------------------------------

    def whoami(self) -> str:
        result = self._request("GET", "/_matrix/client/v3/account/whoami")
        user_id = result.get("user_id", "")
        if user_id != self.user_id:
            raise RuntimeError(
                f"Matrix token belongs to {user_id!r}, expected {self.user_id!r}"
            )
        return user_id

    def joined_members(self, room_id: str) -> dict[str, str]:
        """Return sender -> display name for everyone currently joined."""
        path = (
            "/_matrix/client/v3/rooms/"
            + urllib.parse.quote(room_id, safe="")
            + "/joined_members"
        )
        result = self._request("GET", path)
        names: dict[str, str] = {}
        for mxid, member in (result.get("joined") or {}).items():
            name = (member.get("display_name") or "").strip()
            # The bridge appends " (iMessage)" / " (SMS)" to contact names.
            for suffix in (" (iMessage)", " (SMS)", " (RCS)"):
                if name.endswith(suffix):
                    name = name[: -len(suffix)]
            names[mxid] = name or mxid
        return names

    def room_messages(
        self,
        room_id: str,
        *,
        from_token: str | None = None,
        limit: int = 100,
        direction: str = "b",
    ) -> dict:
        """One page of /messages, newest first by stream order."""
        path = (
            "/_matrix/client/v3/rooms/"
            + urllib.parse.quote(room_id, safe="")
            + "/messages"
        )
        query: dict[str, str] = {"dir": direction, "limit": str(limit)}
        if from_token:
            query["from"] = from_token
        return self._request("GET", path, query=query)

    def send_text(self, room_id: str, text: str) -> list[str]:
        """Send text, splitting on line boundaries if it exceeds Matrix limits."""
        path = (
            "/_matrix/client/v3/rooms/"
            + urllib.parse.quote(room_id, safe="")
            + "/send/m.room.message/"
        )
        event_ids: list[str] = []
        for part in split_message(text, 30000):
            result = self._request(
                "PUT",
                path + uuid.uuid4().hex,
                body={"msgtype": "m.text", "body": part},
            )
            event_ids.append(result.get("event_id", ""))
        return event_ids


def split_message(text: str, limit: int) -> list[str]:
    text = text.strip()
    if len(text) <= limit:
        return [text] if text else []
    parts: list[str] = []
    while len(text) > limit:
        cut = text.rfind("\n", 0, limit)
        if cut < limit // 2:
            cut = limit
        parts.append(text[:cut].rstrip())
        text = text[cut:].lstrip()
    if text:
        parts.append(text)
    return parts
