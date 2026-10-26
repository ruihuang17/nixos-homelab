#!/usr/bin/env python3
"""Grove insights exporter.

Prometheus already covers the infrastructure side of Grove through
node_exporter, smartctl_exporter, zfs_exporter and exportarr. This small,
dependency-free exporter fills the remaining gaps:

  * application inventory for PostgreSQL, Nextcloud, Paperless, Immich,
    Vaultwarden, Synapse and Tailscale
  * optional Jellyfin library and active-stream counts

It is deliberately read-only. The Jellyfin token is read from its existing
configuration or an agenix runtime secret. Nothing sensitive is written to
the metrics output.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import threading
import time
import urllib.request
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = "2.0.0"


def run(cmd: list[str], timeout: float = 30) -> str:
    result = subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=timeout,
        check=False,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip().splitlines()
        raise RuntimeError(detail[-1] if detail else f"{cmd[0]} exited {result.returncode}")
    return result.stdout


def http_text(
    url: str,
    headers: dict[str, str] | None = None,
    timeout: float = 15,
) -> str:
    request = urllib.request.Request(url, headers=headers or {})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read().decode("utf-8", "replace")


def http_json(
    url: str,
    headers: dict[str, str] | None = None,
    timeout: float = 15,
):
    return json.loads(http_text(url, headers=headers, timeout=timeout))


def number(value, default=None):
    if value is None:
        return default
    try:
        if isinstance(value, str):
            value = value.strip().rstrip("%")
            if value in ("", "-", "null", "None"):
                return default
        return float(value)
    except (TypeError, ValueError):
        return default


def integer(value, default=None):
    parsed = number(value, None)
    if parsed is None:
        return default
    return int(parsed)


def safe_label(value) -> str:
    return str(value).replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


class Metrics:
    def __init__(self) -> None:
        self.definitions: dict[str, tuple[str, str]] = {}
        self.rows: list[tuple[str, dict[str, str], float]] = []

    def add(
        self,
        name: str,
        value,
        labels: dict[str, str] | None = None,
        help_text: str | None = None,
        metric_type: str = "gauge",
    ) -> None:
        if help_text is not None and name not in self.definitions:
            self.definitions[name] = (help_text, metric_type)
        numeric = number(value)
        if numeric is None:
            return
        self.rows.append((name, labels or {}, numeric))

    def render(self) -> str:
        lines: list[str] = []
        for name, (help_text, metric_type) in self.definitions.items():
            lines.append(f"# HELP {name} {help_text}")
            lines.append(f"# TYPE {name} {metric_type}")
        for name, labels, value in self.rows:
            rendered = str(int(value)) if value == int(value) else f"{value:.12g}"
            if labels:
                label_text = ",".join(f'{key}="{safe_label(item)}"' for key, item in labels.items())
                lines.append(f"{name}{{{label_text}}} {rendered}")
            else:
                lines.append(f"{name} {rendered}")
        return "\n".join(lines) + "\n"


def insight(metrics: Metrics, group: str, key: str, value, name: str | None = None) -> None:
    labels = {"group": group, "key": key}
    if name is not None:
        labels["name"] = name
    metrics.add(
        "grove_insight_value",
        value,
        labels,
        "Application inventory and health values for Grove group summaries.",
    )


def media_app_info(
    metrics: Metrics,
    app: str,
    up: bool,
    size: int | None = None,
    version: str = "",
) -> None:
    metrics.add(
        "grove_media_app_info",
        1,
        {
            "app": app,
            "up": "1" if up else "0",
            "size": str(size if size is not None else ""),
            "version": version,
        },
        "Media application availability snapshot.",
    )


def psql(database: str, query: str) -> list[list[str]]:
    commands = []
    for launcher in (["runuser", "-u", "postgres", "--"], ["sudo", "-n", "-u", "postgres", "--"]):
        commands.append(
            launcher
            + ["psql", "-At", "-F", "\t", "-v", "ON_ERROR_STOP=1", "-d", database, "-c", query]
        )
    last_error: Exception | None = None
    for command in commands:
        try:
            output = run(command, timeout=20)
            rows: list[list[str]] = []
            for line in output.splitlines():
                if line.strip():
                    rows.append(line.split("\t"))
            return rows
        except Exception as exc:
            last_error = exc
    raise RuntimeError(f"psql {database}: {last_error}")


def postgres_collector(metrics: Metrics) -> None:
    try:
        connections = psql(
            "postgres",
            "select coalesce(state, 'unknown'), count(*) from pg_stat_activity "
            "where backend_type = 'client backend' group by 1",
        )
        max_connections = psql(
            "postgres", "select setting from pg_settings where name = 'max_connections'"
        )
        sizes = psql(
            "postgres",
            "select datname, pg_database_size(datname) from pg_database where not datistemplate",
        )
        cache = psql(
            "postgres",
            "select coalesce(sum(blks_hit),0), coalesce(sum(blks_read),0) from pg_stat_database",
        )
        uptime = psql("postgres", "select extract(epoch from now() - pg_postmaster_start_time())")
        deadlocks = psql("postgres", "select coalesce(sum(deadlocks),0) from pg_stat_database")
    except Exception as exc:
        insight(metrics, "postgres", "up", 0)
        raise RuntimeError(f"PostgreSQL: {exc}") from exc

    insight(metrics, "postgres", "up", 1)
    total_connections = 0
    for row in connections:
        if len(row) < 2:
            continue
        state = re.sub(r"[^a-z0-9_]+", "_", row[0].lower()).strip("_") or "unknown"
        count = integer(row[1], 0) or 0
        total_connections += count
        insight(metrics, "postgres", f"connections_{state}", count)
    insight(metrics, "postgres", "connections_total", total_connections)
    if max_connections:
        insight(metrics, "postgres", "max_connections", integer(max_connections[0][0], 0))
    total_size = 0
    for row in sizes:
        if len(row) < 2:
            continue
        size = integer(row[1], 0) or 0
        total_size += size
        insight(metrics, "postgres", "database_size_bytes", size, name=row[0])
    insight(metrics, "postgres", "storage_bytes", total_size)
    if cache:
        hits = integer(cache[0][0], 0) or 0
        reads = integer(cache[0][1], 0) or 0
        if hits + reads > 0:
            insight(metrics, "postgres", "cache_hit_ratio", hits / (hits + reads))
    if uptime:
        insight(metrics, "postgres", "uptime_seconds", number(uptime[0][0], 0))
    if deadlocks:
        insight(metrics, "postgres", "deadlocks_total", integer(deadlocks[0][0], 0))


def nextcloud_collector(metrics: Metrics) -> None:
    try:
        users = psql("nextcloud", "select count(*) from oc_users")
        files = psql("nextcloud", "select count(*) from oc_filecache where path <> ''")
        storage = psql("nextcloud", "select coalesce(sum(size),0) from oc_filecache")
    except Exception as exc:
        insight(metrics, "nextcloud", "up", 0)
        raise RuntimeError(f"Nextcloud: {exc}") from exc

    insight(metrics, "nextcloud", "up", 1)
    insight(metrics, "nextcloud", "users", integer(users[0][0], 0) if users else 0)
    insight(metrics, "nextcloud", "files", integer(files[0][0], 0) if files else 0)
    insight(metrics, "nextcloud", "storage_bytes", integer(storage[0][0], 0) if storage else 0)


def paperless_collector(metrics: Metrics) -> None:
    try:
        documents = psql("paperless", "select count(*) from documents_document")
        users = psql("paperless", "select count(*) from auth_user")
        tags = psql("paperless", "select count(*) from documents_tag")
        pending = psql(
            "paperless",
            "select count(*) from documents_paperlesstask where status in ('PENDING','STARTED')",
        )
    except Exception as exc:
        insight(metrics, "paperless", "up", 0)
        raise RuntimeError(f"Paperless: {exc}") from exc

    insight(metrics, "paperless", "up", 1)
    insight(metrics, "paperless", "documents", integer(documents[0][0], 0) if documents else 0)
    insight(metrics, "paperless", "users", integer(users[0][0], 0) if users else 0)
    insight(metrics, "paperless", "tags", integer(tags[0][0], 0) if tags else 0)
    insight(metrics, "paperless", "pending_tasks", integer(pending[0][0], 0) if pending else 0)


def immich_collector(metrics: Metrics) -> None:
    try:
        assets = psql("immich", "select type, count(*) from asset group by type")
        users = psql("immich", 'select count(*) from "user"')
        albums = psql("immich", "select count(*) from album")
    except Exception as exc:
        insight(metrics, "immich", "up", 0)
        raise RuntimeError(f"Immich: {exc}") from exc

    insight(metrics, "immich", "up", 1)
    total = 0
    for row in assets:
        if len(row) < 2:
            continue
        kind = row[0].lower()
        count = integer(row[1], 0) or 0
        total += count
        insight(metrics, f"immich", f"assets_{kind}", count)
    insight(metrics, "immich", "assets_total", total)
    insight(metrics, "immich", "users", integer(users[0][0], 0) if users else 0)
    insight(metrics, "immich", "albums", integer(albums[0][0], 0) if albums else 0)


def vaultwarden_collector(metrics: Metrics) -> None:
    try:
        users = psql("vaultwarden", "select count(*) from users")
        items = psql("vaultwarden", "select count(*) from ciphers")
        organizations = psql("vaultwarden", "select count(*) from organizations")
    except Exception as exc:
        insight(metrics, "vaultwarden", "up", 0)
        raise RuntimeError(f"Vaultwarden: {exc}") from exc

    insight(metrics, "vaultwarden", "up", 1)
    insight(metrics, "vaultwarden", "users", integer(users[0][0], 0) if users else 0)
    insight(metrics, "vaultwarden", "items", integer(items[0][0], 0) if items else 0)
    insight(
        metrics,
        "vaultwarden",
        "organizations",
        integer(organizations[0][0], 0) if organizations else 0,
    )


def synapse_collector(metrics: Metrics) -> None:
    try:
        users = psql("matrix-synapse", "select count(*) from users")
        rooms = psql("matrix-synapse", "select count(*) from rooms")
        events = psql("matrix-synapse", "select count(*) from events")
        devices = psql("matrix-synapse", "select count(*) from devices")
    except Exception as exc:
        insight(metrics, "synapse", "up", 0)
        raise RuntimeError(f"Synapse: {exc}") from exc

    insight(metrics, "synapse", "up", 1)
    insight(metrics, "synapse", "users", integer(users[0][0], 0) if users else 0)
    insight(metrics, "synapse", "rooms", integer(rooms[0][0], 0) if rooms else 0)
    insight(metrics, "synapse", "events", integer(events[0][0], 0) if events else 0)
    insight(metrics, "synapse", "devices", integer(devices[0][0], 0) if devices else 0)


def tailscale_collector(metrics: Metrics) -> None:
    try:
        data = json.loads(run(["tailscale", "status", "--json"], timeout=15))
    except Exception as exc:
        insight(metrics, "network", "up", 0)
        raise RuntimeError(f"Tailscale: {exc}") from exc

    peers = list((data.get("Peer") or {}).values())
    online = sum(1 for peer in peers if peer.get("Online"))
    insight(metrics, "network", "up", 1)
    insight(metrics, "network", "tailscale_online_peers", online)
    insight(metrics, "network", "tailscale_total_peers", len(peers) + 1)
    insight(
        metrics,
        "network",
        "tailscale_self_online",
        1 if (data.get("Self") or {}).get("Online") else 0,
    )


INSIGHT_COLLECTORS = {
    "postgres": postgres_collector,
    "nextcloud": nextcloud_collector,
    "paperless": paperless_collector,
    "immich": immich_collector,
    "vaultwarden": vaultwarden_collector,
    "synapse": synapse_collector,
    "tailscale": tailscale_collector,
}


def insights_collector(metrics: Metrics) -> None:
    for name, collector in INSIGHT_COLLECTORS.items():
        try:
            collector(metrics)
        except Exception as exc:
            print(f"grove-exporter: {exc}", file=sys.stderr)


MEDIA_APP_STATUS = [
    ("Sonarr", "http://127.0.0.1:8989/api/v3/system/status", "sonarr.key"),
    ("Radarr", "http://127.0.0.1:7878/api/v3/system/status", "radarr.key"),
    ("Prowlarr", "http://127.0.0.1:9696/api/v1/system/status", "prowlarr.key"),
]


def media_versions_collector(metrics: Metrics, key_dir: str) -> None:
    for app, url, key_file in MEDIA_APP_STATUS:
        try:
            with open(os.path.join(key_dir, key_file), encoding="utf-8") as handle:
                api_key = handle.read().strip()
            if not api_key:
                continue
            data = http_json(url, headers={"X-Api-Key": api_key, "Accept": "application/json"})
            version = str((data or {}).get("version") or "")
            if version:
                metrics.add(
                    "grove_media_app_version",
                    1,
                    {"app": app, "version": version},
                    "Media application version.",
                )
        except Exception as exc:
            print(f"grove-exporter: {app} version: {exc}", file=sys.stderr)


def jellyfin_collector(metrics: Metrics, base_url: str, api_key: str | None) -> None:
    if not base_url or not api_key:
        return

    try:
        headers = {"X-Emby-Token": api_key, "Accept": "application/json"}
        counts = http_json(f"{base_url}/Items/Counts", headers=headers)
        sessions = http_json(f"{base_url}/Sessions", headers=headers)
        info = http_json(f"{base_url}/System/Info", headers=headers)
    except Exception as exc:
        media_app_info(metrics, "Jellyfin", False)
        raise RuntimeError(f"Jellyfin: {exc}") from exc

    library = {
        "movies": integer(counts.get("MovieCount"), 0),
        "series": integer(counts.get("SeriesCount"), 0),
        "episodes": integer(counts.get("EpisodeCount"), 0),
        "songs": integer(counts.get("SongCount"), 0),
        "albums": integer(counts.get("AlbumCount"), 0),
    }
    for kind, value in library.items():
        metrics.add(
            "grove_media_library_items",
            value,
            {"app": "Jellyfin", "kind": kind},
            "Library item counts per media application.",
        )

    active_streams = sum(1 for session in sessions or [] if session.get("NowPlayingItem"))
    metrics.add(
        "grove_media_streams",
        active_streams,
        {"app": "Jellyfin"},
        "Active Jellyfin streams.",
    )
    media_app_info(
        metrics,
        "Jellyfin",
        True,
        size=sum(value or 0 for value in library.values()),
        version=str((info or {}).get("Version") or ""),
    )


def collect(settings: dict) -> str:
    metrics = Metrics()
    metrics.add(
        "grove_exporter_info",
        1,
        {"version": VERSION},
        "Grove insights exporter build information.",
    )

    collectors: list[tuple[str, callable]] = [
        ("insights", insights_collector),
        ("media_versions", lambda m: media_versions_collector(m, settings["arr_key_dir"])),
    ]
    if settings.get("jellyfin_url") and settings.get("jellyfin_api_key"):
        collectors.append(
            (
                "jellyfin",
                lambda m: jellyfin_collector(
                    m, settings["jellyfin_url"], settings["jellyfin_api_key"]
                ),
            )
        )

    for name, collector in collectors:
        started = time.monotonic()
        try:
            collector(metrics)
            ok = 1
        except Exception as exc:
            ok = 0
            print(f"grove-exporter: {name} collector failed: {exc}", file=sys.stderr)
        metrics.add(
            "grove_exporter_collector_up",
            ok,
            {"collector": name},
            "Whether a collector completed without a fatal error.",
        )
        metrics.add(
            "grove_exporter_collector_duration_seconds",
            time.monotonic() - started,
            {"collector": name},
            "Collector runtime in seconds.",
        )

    return metrics.render()


class Handler(BaseHTTPRequestHandler):
    settings: dict = {}
    lock = threading.Lock()

    def do_GET(self) -> None:  # noqa: N802
        if self.path in ("/health", "/-/healthy"):
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(b"ok\n")
            return

        if not self.path.startswith("/metrics"):
            self.send_response(404)
            self.end_headers()
            return

        try:
            with self.lock:
                body = collect(self.settings).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
        except Exception as exc:  # pragma: no cover - defensive
            self.send_response(500)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(f"collector failed: {exc}\n".encode())

    def log_message(self, format: str, *args) -> None:
        print(f"grove-exporter: {self.address_string()} {format % args}", file=sys.stderr)


def main() -> int:
    parser = argparse.ArgumentParser(description="Grove insights Prometheus exporter")
    parser.add_argument("--bind", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=9123)
    parser.add_argument("--once", action="store_true", help="print one metrics snapshot and exit")
    parser.add_argument("--jellyfin-url", default=os.environ.get("GROVE_JELLYFIN_URL", ""))
    parser.add_argument(
        "--jellyfin-api-key",
        default=os.environ.get("GROVE_JELLYFIN_API_KEY", ""),
    )
    parser.add_argument("--jellyfin-api-key-file", default="")
    parser.add_argument("--arr-key-dir", default="/run/grove-exporter")
    args = parser.parse_args()

    jellyfin_api_key = args.jellyfin_api_key
    if not jellyfin_api_key and args.jellyfin_api_key_file:
        try:
            with open(args.jellyfin_api_key_file, encoding="utf-8") as handle:
                jellyfin_api_key = handle.read().strip()
        except OSError as exc:
            print(f"grove-exporter: Jellyfin API key: {exc}", file=sys.stderr)

    settings = {
        "arr_key_dir": args.arr_key_dir,
        "jellyfin_url": args.jellyfin_url.rstrip("/"),
        "jellyfin_api_key": jellyfin_api_key,
    }

    if args.once:
        sys.stdout.write(collect(settings))
        return 0

    Handler.settings = settings
    server = ThreadingHTTPServer((args.bind, args.port), Handler)
    print(
        f"grove-exporter {VERSION} listening on http://{args.bind}:{args.port}/metrics",
        file=sys.stderr,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
