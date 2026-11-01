#!/usr/bin/env python3
"""iMessage group-chat digest service.

One-shot runner for a macOS launchd agent:
  * polls the mautrix-imessage portal rooms through Matrix /messages
  * stores messages in SQLite, debounces bursts, extracts grounded events
  * sends Discord DM alerts and scheduled Matrix digests
  * writes a node_exporter textfile heartbeat

No third-party Python packages; inference is Apple's on-device model via apfel.
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import logging
import os
import re
import sys
import time
import tomllib
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

from chunk import (
    chunk_lines,
    format_lines,
    format_ts,
    reduce_notes,
)
from cloud import CloudModel
from deliver import Discord, deliver_digest, format_alert, render_digest
from matrix import Matrix, MatrixError
from model import Model, ModelError
from state import Message, State

log = logging.getLogger("imessage-digest")

IGNORED_SENDERS = ("@imessagebot:", "@smsbot:", "@digestbot:")
IGNORED_MSG_TYPES = {"m.notice", "m.reaction", "m.room.member", "m.room.topic"}


# ---------------------------------------------------------------------------
# configuration and secrets
# ---------------------------------------------------------------------------


def load_config(path: Path) -> dict:
    with path.open("rb") as handle:
        return tomllib.load(handle)


def load_secrets(path: Path) -> dict[str, str]:
    raw = path.read_text(encoding="utf-8").strip()
    if raw.startswith("{"):
        data = json.loads(raw)
        return {str(k): str(v) for k, v in data.items()}
    secrets: dict[str, str] = {}
    for line in raw.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        secrets[key.strip()] = value.strip().strip('"').strip("'")
    return secrets


def parse_clock(value: str) -> tuple[int, int]:
    hour, minute = value.split(":", 1)
    return int(hour), int(minute)


def minutes_of_day(moment: datetime) -> int:
    return moment.hour * 60 + moment.minute


def in_quiet_hours(moment: datetime, start: str, end: str) -> bool:
    start_minutes = minutes_of_day(datetime(2000, 1, 1, *parse_clock(start)))
    end_minutes = minutes_of_day(datetime(2000, 1, 1, *parse_clock(end)))
    now_minutes = minutes_of_day(moment)
    if start_minutes <= end_minutes:
        return start_minutes <= now_minutes < end_minutes
    return now_minutes >= start_minutes or now_minutes < end_minutes


def latest_slot(moment: datetime, times: list[str]) -> datetime | None:
    candidates = [
        moment.replace(hour=hour, minute=minute, second=0, microsecond=0)
        for hour, minute in (parse_clock(value) for value in times)
    ]
    past = [candidate for candidate in candidates if candidate <= moment]
    return max(past) if past else None


def day_start_ms(moment: datetime, tz: ZoneInfo) -> int:
    return int(
        moment.replace(hour=0, minute=0, second=0, microsecond=0).timestamp() * 1000
    )


# ---------------------------------------------------------------------------
# message parsing
# ---------------------------------------------------------------------------


def normalise(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip().lower()


def clean_body(body: str) -> str:
    """Drop Matrix reply fallbacks and collapse whitespace."""
    lines = []
    for line in body.splitlines():
        if line.startswith("> "):
            continue
        lines.append(line)
    return " ".join(" ".join(lines).split()).strip()


def parse_event(event: dict, room_id: str, names: dict[str, str]) -> Message | None:
    if event.get("type") != "m.room.message":
        return None
    content = event.get("content") or {}
    if content.get("msgtype") in IGNORED_MSG_TYPES:
        return None
    if (content.get("m.relates_to") or {}).get("rel_type") == "m.replace":
        return None
    if content.get("msgtype") not in ("m.text", "m.emote"):
        return None

    sender = str(event.get("sender", ""))
    if any(sender.startswith(prefix) for prefix in IGNORED_SENDERS):
        return None
    body = clean_body(str(content.get("body", "")))
    if not body:
        return None
    name = names.get(sender) or sender
    if content.get("msgtype") == "m.emote":
        body = f"* {body}"
    return Message(
        event_id=str(event.get("event_id", "")),
        room_id=room_id,
        ts=int(event.get("origin_server_ts", 0)),
        sender=sender,
        sender_name=name,
        body=body,
    )


# ---------------------------------------------------------------------------
# service
# ---------------------------------------------------------------------------


class DigestService:
    def __init__(self, config: dict, secrets: dict[str, str], dry_run: bool = False):
        self.config = config
        self.dry_run = dry_run
        self.paused = bool(config.get("service", {}).get("paused", False))

        matrix_cfg = config.get("matrix", {})
        self.tz = ZoneInfo(config.get("digest", {}).get("timezone", "America/Toronto"))
        self.rooms = list(config.get("rooms", []))
        if not self.rooms:
            raise RuntimeError("config.toml has no [[rooms]]")

        self.state_dir = Path(matrix_cfg["state_dir"])
        self.state_dir.mkdir(parents=True, exist_ok=True)
        self.state = State(self.state_dir / "state.sqlite3")

        token = secrets.get("MATRIX_TOKEN", "")
        if not token:
            raise RuntimeError("MATRIX_TOKEN missing from secrets file")
        self.matrix = Matrix(
            matrix_cfg["homeserver"],
            token,
            matrix_cfg.get("user_id", ""),
        )
        self.digest_room = matrix_cfg["digest_room"]

        model_cfg = config.get("model", {})
        here = Path(__file__).resolve().parent
        self.model = Model(
            binary=model_cfg.get("binary", "/opt/homebrew/bin/apfel"),
            timeout_seconds=int(model_cfg.get("timeout_seconds", 300)),
            prompts_dir=here / "prompts",
            schemas_dir=here / "schemas",
        )
        self.chunk_tokens = int(model_cfg.get("chunk_tokens", 4200))
        self.note_tokens = int(model_cfg.get("note_tokens", 1400))
        self.event_chunk_tokens = int(model_cfg.get("event_chunk_tokens", 2200))
        self.digest_schema_text = (here / "schemas" / "digest.json").read_text()

        synthesis_cfg = config.get("synthesis", {})
        self.synthesis: CloudModel | None = None
        if synthesis_cfg.get("provider") == "openrouter" and not self.paused:
            openrouter_key = secrets.get("OPENROUTER_API_KEY", "")
            if not openrouter_key:
                raise RuntimeError("OPENROUTER_API_KEY missing from secrets file")
            self.synthesis = CloudModel(
                api_base=synthesis_cfg.get(
                    "api_base", "https://openrouter.ai/api/v1"
                ),
                api_key=openrouter_key,
                model=synthesis_cfg["model"],
                timeout_seconds=int(synthesis_cfg.get("timeout_seconds", 120)),
                max_tokens=int(synthesis_cfg.get("max_tokens", 1800)),
                max_input_tokens=int(synthesis_cfg.get("max_input_tokens", 60000)),
                http_referer=synthesis_cfg.get("http_referer", ""),
                title=synthesis_cfg.get("title", ""),
            )

        discord_cfg = config.get("discord", {})
        self.discord: Discord | None = None
        if discord_cfg.get("enabled") and not dry_run and not self.paused:
            discord_token = secrets.get("DISCORD_BOT_TOKEN", "")
            if not discord_token:
                raise RuntimeError("DISCORD_BOT_TOKEN missing from secrets file")
            self.discord = Discord(
                api_base=discord_cfg.get("api_base", "https://discord.com/api/v10"),
                token=discord_token,
                user_id=discord_cfg["user_id"],
                state=self.state,
            )

    # -- polling -----------------------------------------------------------

    def poll(self, now_ms: int) -> None:
        lookback_ms = int(
            self.config.get("digest", {}).get("initial_lookback_hours", 24)
        ) * 3600 * 1000

        for room in self.rooms:
            room_id = room["id"]
            row = self.state.room(room_id)
            since = int(row["last_ts"])
            if since <= 0:
                since = now_ms - lookback_ms
                log.info("first poll of %s: looking back to %s", room.get("label"), _stamp(since, self.tz))

            try:
                names = self.matrix.joined_members(room_id)
                messages = self.fetch_messages(room_id, since, names)
            except MatrixError as exc:
                log.error("poll failed for %s: %s", room.get("label"), exc)
                continue

            inserted = self.state.insert_messages(messages)
            newest = max((m.ts for m in messages), default=0)
            # Re-scan two minutes for clock skew; event_id dedupe makes that cheap.
            self.state.set_last_ts(room_id, max(newest, now_ms - 120_000))
            log.info(
                "%s: %d new message(s), %d inserted (cursor %s)",
                room.get("label"),
                len(messages),
                inserted,
                _stamp(max(newest, now_ms - 120_000), self.tz),
            )

    def fetch_messages(
        self, room_id: str, since_ms: int, names: dict[str, str]
    ) -> list[Message]:
        messages: list[Message] = []
        token: str | None = None
        for _ in range(30):
            page = self.matrix.room_messages(room_id, from_token=token, limit=100)
            chunk = page.get("chunk") or []
            if not chunk:
                break
            for event in chunk:
                if int(event.get("origin_server_ts", 0)) <= since_ms:
                    continue
                message = parse_event(event, room_id, names)
                if message:
                    messages.append(message)
            timestamps = [
                int(event.get("origin_server_ts", 0))
                for event in chunk
                if event.get("origin_server_ts")
            ]
            # Once an entire page predates the cursor we are done. Backfilled
            # old events can appear between new ones, so check max, not min.
            if timestamps and max(timestamps) <= since_ms:
                break
            token = page.get("end")
            if not token:
                break
        messages.sort(key=lambda m: (m.ts, m.event_id))
        return messages

    # -- event detection ---------------------------------------------------

    def scan_events(self, now_ms: int, force: bool = False) -> None:
        alerts_cfg = self.config.get("alerts", {})
        if not alerts_cfg.get("enabled", True):
            return
        if self.dry_run:
            log.info("dry run: alerts will be logged, not sent")

        debounce_ms = int(alerts_cfg.get("debounce_seconds", 90)) * 1000
        cutoff = now_ms if force else now_ms - debounce_ms
        now_dt = datetime.fromtimestamp(now_ms / 1000, self.tz)
        quiet = (
            False
            if force
            else in_quiet_hours(
                now_dt,
                alerts_cfg.get("quiet_start", "23:00"),
                alerts_cfg.get("quiet_end", "07:00"),
            )
        )

        for room in self.rooms:
            room_id = room["id"]
            newest_pending = self.state.newest_pending_ts(room_id)
            if newest_pending == 0:
                continue
            if not force and newest_pending > cutoff:
                log.info(
                    "%s: burst still active (last %s), holding alerts",
                    room.get("label"),
                    _stamp(newest_pending, self.tz),
                )
                continue

            pending_all = self.state.pending(room_id, cutoff)
            if not pending_all:
                continue

            max_age_ms = int(alerts_cfg.get("max_age_minutes", 120)) * 60_000
            if force:
                pending = pending_all
            else:
                pending = [
                    row for row in pending_all if int(row["ts"]) >= now_ms - max_age_ms
                ]
                stale = [
                    row for row in pending_all if int(row["ts"]) < now_ms - max_age_ms
                ]
                if stale:
                    self.state.mark_processed([str(row["event_id"]) for row in stale])
                    log.info(
                        "%s: %d stale message(s) skipped for alerts (digest only)",
                        room.get("label"),
                        len(stale),
                    )
            if not pending:
                continue

            try:
                events = self.detect_events(room, pending)
            except ModelError as exc:
                log.error("event detection failed for %s: %s", room.get("label"), exc)
                continue

            sent = self.send_alerts(room, events, now_ms, quiet)
            if not self.dry_run:
                self.state.mark_processed([str(row["event_id"]) for row in pending])
            log.info(
                "%s: scanned %d message(s), %d candidate event(s), %d alert(s)",
                room.get("label"),
                len(pending),
                len(events),
                sent,
            )

    def detect_events(self, room: dict, rows: list) -> list[dict]:
        room_id = room["id"]
        label = room.get("label", room_id)
        now = datetime.fromtimestamp(rows[-1]["ts"] / 1000, self.tz)
        lines = format_lines(rows, self.tz)
        chunks = chunk_lines(lines, self.event_chunk_tokens, self.model.estimate_tokens)
        system = self.model.prompt("event")
        schema = self.model.schema("event")
        found: list[dict] = []

        row_offset = 0
        for index, chunk in enumerate(chunks, 1):
            # Map the chunk back to rows by consuming the same number of lines.
            chunk_line_count = len(chunk.splitlines())
            chunk_rows = rows[row_offset : row_offset + chunk_line_count]
            row_offset += chunk_line_count
            log.info("%s: event chunk %d/%d", label, index, len(chunks))
            try:
                result = self.model.generate_json(
                    system=system,
                    prompt=(
                        f"Chat: {label}\n"
                        f"Today: {now.strftime('%Y-%m-%d %H:%M')} ({self.tz})\n"
                        "Extract up to 3 concrete events from this transcript. "
                        "Copy `quote` verbatim from one message.\n\n"
                        f"{chunk}"
                    ),
                    schema=schema,
                    max_tokens=700,
                )
            except ModelError as exc:
                log.error("%s: event chunk %d failed: %s", label, index, exc)
                continue

            if not result.get("has_event"):
                continue
            for event in result.get("events") or []:
                grounded = self.ground_event(event, chunk_rows)
                if grounded:
                    found.append(grounded)
        return found

    def ground_event(self, event: dict, rows: list) -> dict | None:
        quote = str(event.get("quote", "")).strip().strip('"“”')
        summary = str(event.get("summary", "")).strip()
        when = str(event.get("when", "")).strip()
        confidence = float(event.get("confidence", 0))
        if not quote or not summary:
            return None
        if confidence < float(self.config.get("alerts", {}).get("min_confidence", 0.7)):
            log.debug("rejecting low-confidence event: %s", summary)
            return None

        event = dict(event)
        wanted = normalise(quote)
        source = None
        for row in rows:
            if wanted in normalise(str(row["body"])):
                source = row
                break
        if source is None:
            log.info("rejecting ungrounded event: %s", summary[:120])
            return None

        # A message from the service's own user is not a request aimed at them.
        # Keep genuine commitments (plans, deadlines, money, travel, health,
        # conflict) but never label them as "needs action from you", and drop
        # self-authored questions/offers.
        if str(source["sender"]) == self.matrix.user_id:
            if str(event.get("kind", "")) in ("request", "other"):
                log.info("rejecting self-authored request/offer: %s", summary[:120])
                return None
            event = dict(event)
            event["needs_action"] = False

        # "Needs action" only makes sense for a concrete ask, deadline or money
        # item. A plan or a status update is not an action item.
        if bool(event.get("needs_action")) and str(event.get("kind", "")) not in (
            "request",
            "deadline",
            "money",
        ):
            event = dict(event)
            event["needs_action"] = False

        return {
            "event": event,
            "source": source,
            "dedupe": _dedupe_key(source["room_id"], summary, when),
        }

    def send_alerts(
        self, room: dict, events: list[dict], now_ms: int, quiet: bool
    ) -> int:
        alerts_cfg = self.config.get("alerts", {})
        max_per_day = int(alerts_cfg.get("max_per_room_per_day", 3))
        override = float(alerts_cfg.get("quiet_override_confidence", 0.9))
        day_start = day_start_ms(datetime.fromtimestamp(now_ms / 1000, self.tz), self.tz)
        sent = 0

        for item in sorted(
            events,
            key=lambda value: float(value["event"].get("confidence", 0)),
            reverse=True,
        ):
            event = item["event"]
            confidence = float(event.get("confidence", 0))
            needs_action = bool(event.get("needs_action"))

            if quiet and not (needs_action and confidence >= override):
                log.info("quiet hours: suppressing alert %r", event.get("summary"))
                continue
            if self.state.alert_seen(item["dedupe"]):
                log.info("duplicate alert suppressed: %r", event.get("summary"))
                continue
            if self.state.alerts_since(room["id"], day_start) >= max_per_day:
                log.info("%s: daily alert cap reached", room.get("label"))
                continue

            text = format_alert(
                room_label=room.get("label", room["id"]),
                room_id=room["id"],
                event_id=str(item["source"]["event_id"]),
                event=event,
                source=item["source"],
                tz=self.tz,
            )
            if self.dry_run:
                print(text)
                print("-" * 60)
            elif self.discord:
                self.discord.send(text)
            else:
                log.warning("Discord disabled; alert not delivered:\n%s", text)

            if not self.dry_run:
                self.state.record_alert(
                    item["dedupe"],
                    room["id"],
                    now_ms,
                    str(event.get("summary", "")),
                )
            sent += 1
        return sent

    # -- digests -----------------------------------------------------------

    def maybe_digest(self, now_ms: int, force: bool = False) -> None:
        digest_cfg = self.config.get("digest", {})
        if not digest_cfg.get("enabled", True) and not force:
            return

        now_dt = datetime.fromtimestamp(now_ms / 1000, self.tz)
        slot_dt = latest_slot(now_dt, digest_cfg.get("times", ["08:00", "18:00"]))
        if slot_dt is None:
            return
        slot_key = slot_dt.strftime("%Y-%m-%dT%H:%M")

        for room in self.rooms:
            room_id = room["id"]
            label = room.get("label", room_id)
            if force:
                due = True
            else:
                last_slot = self.state.get(f"digest_slot:{room_id}")
                if not last_slot:
                    # First run: remember the most recent slot without sending
                    # a digest for a time before the service existed.
                    self.state.set(f"digest_slot:{room_id}", slot_key)
                    log.info("%s: initialised digest slot to %s", label, slot_key)
                    continue
                if last_slot == slot_key:
                    continue
                slot_epoch_ms = int(slot_dt.timestamp() * 1000)
                catchup_ms = int(digest_cfg.get("catchup_minutes", 360)) * 60_000
                if now_ms - slot_epoch_ms > catchup_ms:
                    self.state.set(f"digest_slot:{room_id}", slot_key)
                    log.info("%s: missed slot %s is too old, skipping", label, slot_key)
                    continue
                due = True

            retry_key = f"digest_retry_after:{room_id}"
            retry_after = int(self.state.get(retry_key, "0"))
            if now_ms < retry_after:
                log.info("%s: digest backoff until %s", label, _stamp(retry_after, self.tz))
                continue

            try:
                self.build_and_send_digest(room, now_ms)
            except (ModelError, MatrixError) as exc:
                log.error("%s: digest failed: %s", label, exc)
                self.state.set(retry_key, str(now_ms + 30 * 60_000))
                continue
            self.state.set(retry_key, "0")
            if not force:
                self.state.set(f"digest_slot:{room_id}", slot_key)

    def _synthesise(self, prompt: str) -> dict:
        system = self.model.prompt("digest")
        if self.synthesis is not None:
            log.info("digest synthesis via %s", self.synthesis.model)
            return self.synthesis.generate_json(
                system=system,
                prompt=prompt,
                schema_text=self.digest_schema_text,
                max_tokens=self.synthesis.max_tokens,
            )
        return self.model.generate_json(
            system=system,
            prompt=prompt,
            schema=self.model.schema("digest"),
            max_tokens=1800,
        )

    def build_and_send_digest(self, room: dict, now_ms: int) -> None:
        digest_cfg = self.config.get("digest", {})
        room_id = room["id"]
        label = room.get("label", room_id)
        row = self.state.room(room_id)
        since = int(row["last_digest_ts"])
        if since <= 0:
            since = now_ms - int(digest_cfg.get("initial_lookback_hours", 24)) * 3600_000

        messages = self.state.messages_since(room_id, since)
        if not messages:
            log.info("%s: no messages for this digest", label)
            if not self.dry_run:
                self.state.set_last_digest(room_id, now_ms)
            return

        lines = format_lines(messages, self.tz)
        transcript_text = "\n".join(lines)
        self.model.calibrate(transcript_text)
        transcript_tokens = self.model.estimate_tokens(transcript_text)
        cloud_direct = (
            self.synthesis is not None
            and transcript_tokens <= self.synthesis.max_input_tokens
        )

        if cloud_direct or transcript_tokens <= self.chunk_tokens:
            # Send the raw transcript: the cloud model sees the original
            # speaker/timestamp prefixes, and the on-device model can handle
            # small windows without a chunk-note round trip.
            source_label = "Transcript"
            source_text = transcript_text
            log.info(
                "%s: %s transcript (%d est. tokens)",
                label,
                "cloud" if cloud_direct else "direct",
                transcript_tokens,
            )
        else:
            chunks = chunk_lines(
                lines, self.chunk_tokens, self.model.estimate_tokens
            )
            log.info(
                "%s: digesting %d messages in %d chunk(s)",
                label,
                len(messages),
                len(chunks),
            )
            chunk_system = self.model.prompt("chunk")
            notes: list[str] = []
            for index, chunk in enumerate(chunks, 1):
                log.info("%s: chunk note %d/%d", label, index, len(chunks))
                notes.append(
                    self.model.generate(
                        system=chunk_system,
                        prompt=(
                            f"Chat: {label}\n"
                            f"Today: {datetime.fromtimestamp(now_ms / 1000, self.tz).strftime('%Y-%m-%d %H:%M')} ({self.tz})\n\n"
                            f"{chunk}"
                        ),
                        max_tokens=self.note_tokens,
                    )
                )
            note_target = int(digest_cfg.get("note_target_tokens", 3000))
            source_label = "Notes from this period"
            source_text = reduce_notes(
                self.model, notes, target_tokens=note_target, label=label
            )

        previous = self.state.previous_digest(room_id)
        previous = previous[: int(digest_cfg.get("previous_digest_chars", 2400))]
        window_start = max(since, int(messages[0]["ts"]))
        window_end = int(messages[-1]["ts"])
        prompt = (
            f"Chat: {label}\n"
            f"Today: {datetime.fromtimestamp(now_ms / 1000, self.tz).strftime('%Y-%m-%d %H:%M')} ({self.tz})\n"
            f"Period: {_stamp(window_start, self.tz)} to {_stamp(window_end, self.tz)}\n\n"
            "Previous digest (continuity only):\n"
            f"{previous or '(none)'}\n\n"
            f"{source_label}:\n"
            f"{source_text}"
        )
        body = render_digest(
            annotate_digest(
                self._synthesise(prompt),
                messages,
                self.matrix.joined_members(room_id),
                self.matrix.user_id,
                self.tz,
            )
        )

        if self.dry_run:
            print(f"===== {label} =====")
            print(body)
            print()
        else:
            deliver_digest(
                self.matrix,
                self.digest_room,
                label,
                body,
                window_start=window_start,
                window_end=window_end,
                message_count=len(messages),
                tz=self.tz,
            )

        if not self.dry_run:
            self.state.set_last_digest(room_id, max(now_ms, window_end + 1))
            self.state.record_digest(room_id, now_ms, "", body)
        log.info("%s: digest delivered (%d chars)", label, len(body))

    # -- heartbeat ---------------------------------------------------------

    def pending_count(self) -> int:
        return sum(self.state.newest_pending_ts(room["id"]) > 0 for room in self.rooms)

    def write_heartbeat(self, success: bool, now_ms: int) -> None:
        prom_path = Path(
            self.config.get("heartbeat", {}).get(
                "prom_path", str(self.state_dir / "textfile" / "imessage_digest.prom")
            )
        )
        prom_path.parent.mkdir(parents=True, exist_ok=True)
        if success:
            self.state.set("last_success_ms", str(now_ms))
        last_success = int(self.state.get("last_success_ms", "0")) / 1000
        lines = [
            "# HELP imessage_digest_last_success_timestamp_seconds Last successful run.",
            "# TYPE imessage_digest_last_success_timestamp_seconds gauge",
            f"imessage_digest_last_success_timestamp_seconds {last_success:.0f}",
            "# HELP imessage_digest_last_run_success Whether the last run succeeded.",
            "# TYPE imessage_digest_last_run_success gauge",
            f"imessage_digest_last_run_success {1 if success else 0}",
            "# HELP imessage_digest_rooms_configured Configured digest rooms.",
            "# TYPE imessage_digest_rooms_configured gauge",
            f"imessage_digest_rooms_configured {len(self.rooms)}",
            "# HELP imessage_digest_rooms_with_pending Rooms with unprocessed messages.",
            "# TYPE imessage_digest_rooms_with_pending gauge",
            f"imessage_digest_rooms_with_pending {self.pending_count()}",
            "# HELP imessage_digest_paused Whether the service is paused by config.",
            "# TYPE imessage_digest_paused gauge",
            f"imessage_digest_paused {1 if self.paused else 0}",
        ]
        temporary = prom_path.with_suffix(".tmp")
        temporary.write_text("\n".join(lines) + "\n", encoding="utf-8")
        os.replace(temporary, prom_path)

    # -- top level ---------------------------------------------------------

    def run(self, *, force_digest: bool, skip_poll: bool, force_events: bool) -> None:
        now_ms = int(time.time() * 1000)
        if self.paused:
            log.info("service paused (service.paused=true); heartbeat only")
            self.write_heartbeat(True, now_ms)
            return
        self.matrix.whoami()
        if not skip_poll:
            self.poll(now_ms)
        self.scan_events(now_ms, force=force_events)
        self.maybe_digest(now_ms, force=force_digest)
        self.write_heartbeat(True, now_ms)
        self.state.prune(
            now_ms
            - int(self.config.get("state", {}).get("retention_days", 14)) * 86_400_000
        )
        self.state.prune_alerts(
            now_ms
            - int(self.config.get("alerts", {}).get("dedupe_days", 7)) * 86_400_000
        )


def _stamp(ts_ms: int, tz: ZoneInfo) -> str:
    if ts_ms <= 0:
        return "never"
    return datetime.fromtimestamp(ts_ms / 1000, tz).strftime("%Y-%m-%d %H:%M")


def _dedupe_key(room_id: str, summary: str, when: str) -> str:
    payload = f"{room_id}\n{normalise(summary)}\n{normalise(when)}"
    return hashlib.sha256(payload.encode()).hexdigest()


# Common words that do not identify which message a digest item came from.
_STOPWORDS = {
    "about",
    "after",
    "again",
    "all",
    "also",
    "and",
    "any",
    "are",
    "asked",
    "before",
    "being",
    "between",
    "but",
    "can",
    "could",
    "did",
    "does",
    "doing",
    "for",
    "from",
    "get",
    "got",
    "had",
    "has",
    "have",
    "how",
    "into",
    "just",
    "like",
    "make",
    "need",
    "needs",
    "not",
    "only",
    "our",
    "out",
    "over",
    "said",
    "should",
    "some",
    "that",
    "their",
    "them",
    "then",
    "there",
    "these",
    "they",
    "this",
    "want",
    "was",
    "were",
    "what",
    "when",
    "where",
    "which",
    "who",
    "why",
    "will",
    "with",
    "would",
    "you",
    "your",
}


def _words(text: str) -> set[str]:
    # Keep times such as 9:30 and 12:42 as single tokens.
    return {
        word
        for word in re.findall(r"[a-z0-9][a-z0-9':@.-]{2,}", text.lower())
        if word not in _STOPWORDS
    }


def _match_source(item: str, messages: list) -> object | None:
    """Find the message a digest item most likely came from (word overlap)."""
    wanted = _words(item)
    if len(wanted) < 2:
        return None
    best = None
    best_overlap = 0
    for message in messages:
        overlap = len(wanted & _words(str(message["body"])))
        if overlap > best_overlap:
            best = message
            best_overlap = overlap
    # Two shared content words is a deliberately conservative threshold.
    if best_overlap >= 2:
        return best

    # Fallback: a long, distinctive token that appears in exactly one message
    # (a time like 12:42, a place like Costco, a name like Dollarama).
    for token in sorted(wanted, key=len, reverse=True):
        if len(token) < 5:
            continue
        candidates = [
            message for message in messages if token in _words(str(message["body"]))
        ]
        if len(candidates) == 1:
            return candidates[0]
    return None


def _addressed_to_someone_else(
    body: str, source_sender: str, names: dict[str, str], user_id: str
) -> bool:
    lower = body.lower()
    if "rui" in lower or "you" in lower or " ur " in lower or "@" in lower:
        return False
    for mxid, name in names.items():
        if mxid in (user_id, source_sender):
            continue
        first = (name.split() or [""])[0].lower()
        if len(first) >= 3 and re.search(rf"\b{re.escape(first)}\b", lower):
            return True
    return False


def annotate_digest(
    data: dict,
    messages: list,
    names: dict[str, str],
    user_id: str,
    tz: ZoneInfo,
) -> dict:
    """Attach the source message's timestamp/speaker to each digest item.

    The 8k on-device model reliably classifies items but often drops the time.
    Grounding each item against the transcript restores it and lets us reject
    "requests for Rui" that were actually aimed at someone else.
    """
    annotated: dict[str, list[str]] = {}
    dropped = 0
    unmatched = 0

    for key, items in data.items():
        if not isinstance(items, list):
            continue
        output: list[str] = []
        for raw in items:
            item = " ".join(str(raw).strip().lstrip("-* ").split())
            if not item:
                continue
            source = _match_source(item, messages)
            if key == "requests" and source is not None:
                sender = str(source["sender"])
                body = str(source["body"])
                if sender == user_id or _addressed_to_someone_else(
                    body, sender, names, user_id
                ):
                    dropped += 1
                    continue
            if source is None:
                unmatched += 1
                output.append(item)
                continue
            when = format_ts(int(source["ts"]), tz)
            speaker = str(source["sender_name"] or source["sender"])
            if speaker.lower() in item.lower():
                output.append(f"[{when}] {item}")
            else:
                output.append(f"[{when}] {speaker}: {item}")
        annotated[key] = output

    if dropped or unmatched:
        log.info(
            "digest grounding: %d request(s) reclassified/dropped, %d item(s) unmatched",
            dropped,
            unmatched,
        )
    return annotated



# ---------------------------------------------------------------------------
# entrypoint
# ---------------------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    here = Path(__file__).resolve().parent
    parser.add_argument("--config", default=str(here / "config.toml"))
    parser.add_argument("--secrets", default="/run/agenix/imessage-digest")
    parser.add_argument("--once", action="store_true", help="run one pass and exit")
    parser.add_argument("--digest", action="store_true", help="force a digest now")
    parser.add_argument("--events", action="store_true", help="ignore debounce/quiet")
    parser.add_argument("--skip-poll", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--log-level", default="INFO")
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=getattr(logging, args.log_level.upper(), logging.INFO),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        stream=sys.stderr,
    )

    config = load_config(Path(args.config))
    secrets = load_secrets(Path(args.secrets))
    service: DigestService | None = None
    lock_handle = None

    try:
        state_dir = Path(config["matrix"]["state_dir"])
        state_dir.mkdir(parents=True, exist_ok=True)
        lock_handle = (state_dir / "run.lock").open("w")
        try:
            fcntl.flock(lock_handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            log.info("another run is already in progress; exiting")
            return 0

        service = DigestService(config, secrets, dry_run=args.dry_run)
        service.run(
            force_digest=args.digest,
            skip_poll=args.skip_poll,
            force_events=args.events,
        )
        return 0
    except Exception as exc:  # noqa: BLE001 - launchd log is the only surface
        log.exception("run failed: %s", exc)
        if service is not None:
            try:
                service.write_heartbeat(False, int(time.time() * 1000))
            except Exception:
                log.exception("could not write failure heartbeat")
        return 1
    finally:
        if lock_handle is not None:
            lock_handle.close()


if __name__ == "__main__":
    raise SystemExit(main())
