"""SQLite state: room cursors, raw messages, alert dedupe, digest history."""

from __future__ import annotations

import sqlite3
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Message:
    event_id: str
    room_id: str
    ts: int
    sender: str
    sender_name: str
    body: str


SCHEMA = """
CREATE TABLE IF NOT EXISTS rooms (
    room_id        TEXT PRIMARY KEY,
    last_ts        INTEGER NOT NULL DEFAULT 0,
    last_digest_ts INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS messages (
    event_id    TEXT PRIMARY KEY,
    room_id     TEXT NOT NULL,
    ts          INTEGER NOT NULL,
    sender      TEXT NOT NULL,
    sender_name TEXT NOT NULL,
    body        TEXT NOT NULL,
    processed   INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS messages_room_ts ON messages(room_id, ts);
CREATE INDEX IF NOT EXISTS messages_pending ON messages(processed, room_id, ts);
CREATE TABLE IF NOT EXISTS alerts (
    dedupe  TEXT PRIMARY KEY,
    room_id TEXT NOT NULL,
    ts      INTEGER NOT NULL,
    summary TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS alerts_room_ts ON alerts(room_id, ts);
CREATE TABLE IF NOT EXISTS digests (
    id      INTEGER PRIMARY KEY AUTOINCREMENT,
    room_id TEXT NOT NULL,
    ts      INTEGER NOT NULL,
    slot    TEXT NOT NULL,
    body    TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS kv (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
"""


class State:
    def __init__(self, path: str | Path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(self.path, timeout=15)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.executescript(SCHEMA)
        self.db.commit()

    def close(self) -> None:
        self.db.close()

    # -- rooms -------------------------------------------------------------

    def room(self, room_id: str) -> sqlite3.Row:
        self.db.execute("INSERT OR IGNORE INTO rooms(room_id) VALUES (?)", (room_id,))
        self.db.commit()
        return self.db.execute(
            "SELECT * FROM rooms WHERE room_id = ?", (room_id,)
        ).fetchone()

    def set_last_ts(self, room_id: str, ts: int) -> None:
        self.room(room_id)
        self.db.execute(
            "UPDATE rooms SET last_ts = MAX(last_ts, ?) WHERE room_id = ?",
            (ts, room_id),
        )
        self.db.commit()

    def set_last_digest(self, room_id: str, ts: int) -> None:
        self.room(room_id)
        self.db.execute(
            "UPDATE rooms SET last_digest_ts = MAX(last_digest_ts, ?) WHERE room_id = ?",
            (ts, room_id),
        )
        self.db.commit()

    # -- messages ----------------------------------------------------------

    def insert_messages(self, messages: list[Message]) -> int:
        if not messages:
            return 0
        before = self.db.total_changes
        self.db.executemany(
            """INSERT OR IGNORE INTO messages
               (event_id, room_id, ts, sender, sender_name, body)
               VALUES (?, ?, ?, ?, ?, ?)""",
            [
                (m.event_id, m.room_id, m.ts, m.sender, m.sender_name, m.body)
                for m in messages
            ],
        )
        self.db.commit()
        return self.db.total_changes - before

    def pending(self, room_id: str, older_than: int) -> list[sqlite3.Row]:
        return self.db.execute(
            """SELECT * FROM messages
               WHERE room_id = ? AND processed = 0 AND ts <= ?
               ORDER BY ts, event_id""",
            (room_id, older_than),
        ).fetchall()

    def newest_pending_ts(self, room_id: str) -> int:
        row = self.db.execute(
            "SELECT MAX(ts) AS ts FROM messages WHERE room_id = ? AND processed = 0",
            (room_id,),
        ).fetchone()
        return int(row["ts"] or 0)

    def mark_processed(self, event_ids: list[str]) -> None:
        if not event_ids:
            return
        self.db.executemany(
            "UPDATE messages SET processed = 1 WHERE event_id = ?",
            [(event_id,) for event_id in event_ids],
        )
        self.db.commit()

    def messages_since(self, room_id: str, since_ts: int) -> list[sqlite3.Row]:
        return self.db.execute(
            """SELECT * FROM messages
               WHERE room_id = ? AND ts > ?
               ORDER BY ts, event_id""",
            (room_id, since_ts),
        ).fetchall()

    def prune(self, before_ts: int) -> int:
        cursor = self.db.execute(
            "DELETE FROM messages WHERE ts < ? AND processed = 1", (before_ts,)
        )
        self.db.commit()
        return cursor.rowcount

    # -- alerts ------------------------------------------------------------

    def alert_seen(self, dedupe: str) -> bool:
        row = self.db.execute(
            "SELECT 1 FROM alerts WHERE dedupe = ?", (dedupe,)
        ).fetchone()
        return row is not None

    def alerts_since(self, room_id: str, since_ts: int) -> int:
        row = self.db.execute(
            "SELECT COUNT(*) AS n FROM alerts WHERE room_id = ? AND ts >= ?",
            (room_id, since_ts),
        ).fetchone()
        return int(row["n"])

    def record_alert(self, dedupe: str, room_id: str, ts: int, summary: str) -> None:
        self.db.execute(
            "INSERT OR IGNORE INTO alerts(dedupe, room_id, ts, summary) VALUES (?, ?, ?, ?)",
            (dedupe, room_id, ts, summary),
        )
        self.db.commit()

    def prune_alerts(self, before_ts: int) -> None:
        self.db.execute("DELETE FROM alerts WHERE ts < ?", (before_ts,))
        self.db.commit()

    # -- digests -----------------------------------------------------------

    def previous_digest(self, room_id: str) -> str:
        row = self.db.execute(
            "SELECT body FROM digests WHERE room_id = ? ORDER BY ts DESC LIMIT 1",
            (room_id,),
        ).fetchone()
        return str(row["body"]) if row else ""

    def record_digest(self, room_id: str, ts: int, slot: str, body: str) -> None:
        self.db.execute(
            "INSERT INTO digests(room_id, ts, slot, body) VALUES (?, ?, ?, ?)",
            (room_id, ts, slot, body),
        )
        self.db.commit()

    # -- kv ----------------------------------------------------------------

    def get(self, key: str, default: str = "") -> str:
        row = self.db.execute("SELECT value FROM kv WHERE key = ?", (key,)).fetchone()
        return str(row["value"]) if row else default

    def set(self, key: str, value: str) -> None:
        self.db.execute(
            """INSERT INTO kv(key, value) VALUES (?, ?)
               ON CONFLICT(key) DO UPDATE SET value = excluded.value""",
            (key, value),
        )
        self.db.commit()
