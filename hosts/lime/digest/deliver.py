"""Delivery: Matrix digest posts and Discord DM alerts."""

from __future__ import annotations

import json
import logging
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime
from zoneinfo import ZoneInfo

from matrix import Matrix
from state import State

log = logging.getLogger(__name__)


class Discord:
    def __init__(self, api_base: str, token: str, user_id: str, state: State):
        self.api_base = api_base.rstrip("/")
        self.token = token
        self.user_id = user_id
        self.state = state
        self._channel: str | None = None

    def _request(self, method: str, path: str, body: dict | None = None) -> dict:
        data = json.dumps(body).encode() if body is not None else None
        headers = {
            "Authorization": f"Bot {self.token}",
            "User-Agent": "imessage-digest/1.0",
        }
        if data is not None:
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(
            self.api_base + path, data=data, headers=headers, method=method
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                raw = resp.read().decode()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as exc:
            raw = exc.read().decode(errors="replace")
            if exc.code == 429:
                wait = 5
                try:
                    wait = float(json.loads(raw).get("retry_after", 5))
                except Exception:
                    pass
                log.warning("Discord rate limit; sleeping %.1fs", wait)
                time.sleep(wait)
                return self._request(method, path, body)
            raise RuntimeError(f"Discord {exc.code} on {path}: {raw[:400]}") from exc

    def dm_channel(self) -> str:
        if self._channel:
            return self._channel
        cached = self.state.get("discord_dm_channel")
        if cached:
            self._channel = cached
            return cached
        result = self._request(
            "POST", "/users/@me/channels", {"recipient_id": self.user_id}
        )
        channel = result.get("id")
        if not channel:
            raise RuntimeError("Discord did not return a DM channel id")
        self._channel = channel
        self.state.set("discord_dm_channel", channel)
        return channel

    def send(self, text: str) -> None:
        channel = self.dm_channel()
        for part in split_discord(text):
            self._request("POST", f"/channels/{channel}/messages", {"content": part})


def split_discord(text: str, limit: int = 1900) -> list[str]:
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


def format_alert(
    *,
    room_label: str,
    room_id: str,
    event_id: str,
    event: dict,
    source,
    tz: ZoneInfo,
) -> str:
    summary = str(event.get("summary", "")).strip()
    when = str(event.get("when", "")).strip()
    quote = str(event.get("quote", "")).strip()
    needs_action = bool(event.get("needs_action"))

    headline = f"⚠️ {room_label} — {summary}"
    if when:
        headline += f" ({when})"

    lines = [headline]
    if needs_action:
        lines.append("→ needs action from you")
    if source is not None:
        stamp = datetime.fromtimestamp(int(source["ts"]) / 1000, tz).strftime("%a %H:%M")
        lines.append(f'"{quote}" — {source["sender_name"]}, {stamp}')
    else:
        lines.append(f'"{quote}"')
    lines.append(
        "https://matrix.to/#/"
        + urllib.parse.quote(room_id, safe="!/:._-")
        + "/"
        + urllib.parse.quote(event_id, safe="!$:._-")
    )
    return "\n".join(lines)


def deliver_digest(
    matrix: Matrix,
    digest_room: str,
    room_label: str,
    body: str,
    *,
    window_start: int,
    window_end: int,
    message_count: int,
    tz: ZoneInfo,
) -> None:
    start = datetime.fromtimestamp(window_start / 1000, tz).strftime("%a %d %b %H:%M")
    end = datetime.fromtimestamp(window_end / 1000, tz).strftime("%a %d %b %H:%M")
    header = (
        f"iMessage digest — {room_label}\n"
        f"{start} → {end} · {message_count} messages\n"
    )
    matrix.send_text(digest_room, header + "\n" + body.strip())


# Section keys in display order. The JSON schema constrains the model to these.
DIGEST_SECTIONS = [
    ("plans", "Plans & events"),
    ("decisions", "Decisions"),
    ("requests", "Requests for Rui"),
    ("questions", "Open questions"),
    ("money_travel_health", "Money / travel / health"),
]


def _item_key(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", text.lower()).strip()


def render_digest(data: dict) -> str:
    """Render schema output as clean Markdown, de-duplicated across sections."""
    seen: set[str] = set()
    sections: dict[str, list[str]] = {}

    for key, _title in DIGEST_SECTIONS:
        items: list[str] = []
        for raw in data.get(key) or []:
            item = " ".join(str(raw).strip().lstrip("-* ").split())
            if not item:
                continue
            lower = item.lower()
            if lower in ("no activity", "none", "n/a"):
                continue
            # The small model likes to fill empty sections with "No money or
            # travel issues mentioned"; treat those as empty, not as an item.
            if re.match(
                r"^no\b.*\b(activity|concern|conflict|issue|mention|note|report|found)\b",
                lower,
            ):
                continue
            if len(item) > 500:
                item = item[:497] + "..."
            dedupe = _item_key(item)
            if not dedupe or dedupe in seen:
                continue
            seen.add(dedupe)
            items.append(item)
        sections[key] = items

    if not any(sections.values()):
        return "No activity."

    # Highlights are a curated top four, in priority order. They intentionally
    # summarise items that also appear in their section below.
    highlights: list[str] = []
    for key in ("requests", "plans", "decisions", "money_travel_health", "questions"):
        for item in sections[key]:
            if len(highlights) >= 4:
                break
            if item not in highlights:
                highlights.append(item)
        if len(highlights) >= 4:
            break

    lines = ["## Highlights"]
    lines.extend(f"- {item}" for item in highlights)
    for key, title in DIGEST_SECTIONS:
        if not sections[key]:
            continue
        lines.extend(["", f"## {title}"])
        lines.extend(f"- {item}" for item in sections[key])
    return "\n".join(lines)

