#!/usr/bin/env python3
"""Audit mautrix-imessage portal rooms and identify the live one.

The bridge can create several portals for the same chat name after a profile
migration or service change (iMessage/RCS/any GUIDs). Selecting a room by name
alone is unsafe. This tool lists every portal matching a configured room label,
queries the last messages through Matrix, and marks the portal with the newest
activity as the likely live one.

Run it on lime after the bridge has settled:

  nix run nixpkgs#python3 -- audit_portals.py \
    --config config.toml --secrets /run/agenix/imessage-digest
"""

from __future__ import annotations

import argparse
import sqlite3
import time
import tomllib
from pathlib import Path

from matrix import Matrix, MatrixError

HOME = Path.home()


def load_config(path: Path) -> dict:
    with path.open("rb") as handle:
        return tomllib.load(handle)


def load_secrets(path: Path) -> dict[str, str]:
    secrets: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            secrets[key.strip()] = value.strip().strip('"').strip("'")
    return secrets


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    here = Path(__file__).resolve().parent
    parser.add_argument("--config", default=str(here / "config.toml"))
    parser.add_argument("--secrets", default="/run/agenix/imessage-digest")
    parser.add_argument(
        "--bridge-db", default=str(HOME / "mautrix-imessage/mautrix-imessage.db")
    )
    parser.add_argument(
        "--name",
        action="append",
        help="portal name substring (default: the configured room labels)",
    )
    parser.add_argument("--limit", type=int, default=200)
    args = parser.parse_args()

    config = load_config(Path(args.config))
    secrets = load_secrets(Path(args.secrets))
    matrix = Matrix(
        config["matrix"]["homeserver"],
        secrets["MATRIX_TOKEN"],
        config["matrix"].get("user_id", ""),
    )
    names = args.name or [room.get("label", room["id"]) for room in config["rooms"]]
    configured = {room["id"]: room.get("label", room["id"]) for room in config["rooms"]}

    db = sqlite3.connect(f"file:{args.bridge_db}?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    now_ms = int(time.time() * 1000)

    for name in names:
        rows = db.execute(
            """SELECT mxid, name, guid FROM portal
               WHERE mxid IS NOT NULL AND mxid != '' AND name LIKE ?
               ORDER BY name""",
            (f"%{name}%",),
        ).fetchall()
        print(f"\n== {name} ==")
        candidates: list[tuple[int, str]] = []

        for row in rows:
            room_id = row["mxid"]
            try:
                page = matrix.room_messages(room_id, limit=args.limit)
            except MatrixError as exc:
                print(f"  {room_id:48} not readable: {exc}")
                continue
            events = [
                event
                for event in page.get("chunk", [])
                if event.get("type") == "m.room.message"
            ]
            timestamps = [event.get("origin_server_ts", 0) for event in events]
            senders = {event["sender"] for event in events}
            ghosts = sum(
                1 for event in events if event["sender"].startswith("@imessage_")
            )
            recent = sum(1 for ts in timestamps if ts > now_ms - 86_400_000)
            last = max(timestamps) if timestamps else 0
            marker = "  <-- configured" if room_id in configured else ""
            print(
                f"  {room_id:48} msgs={len(events):3} senders={len(senders):2} "
                f"ghosts={ghosts:3} recent24={recent:3} "
                f"last={time.strftime('%m-%d %H:%M', time.localtime(last / 1000)) if last else '-'}"
                f"  {row['guid']}{marker}"
            )
            candidates.append((last, room_id))

        if candidates:
            candidates.sort(reverse=True)
            print(f"  likely live: {candidates[0][1]}")
            configured_ids = [room["id"] for room in config["rooms"]]
            print(
                "  configured:  "
                + ", ".join(
                    room_id
                    for room_id in configured_ids
                    if room_id in {candidate[1] for candidate in candidates}
                )
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
