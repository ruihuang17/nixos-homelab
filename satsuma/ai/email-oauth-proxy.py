#!/usr/bin/env python3
"""Local OAuth2 token endpoint for the UWaterloo email-mcp account.

email-mcp always sends a `client_secret` when refreshing a token. Thunderbird's
Microsoft client ID is a public client, and Microsoft rejects a secret
(AADSTS7000215), so the request cannot go to Microsoft directly. This proxy
accepts email-mcp's form post, drops the secret, refreshes with the stored
refresh token, and returns Microsoft's JSON response unchanged.

The refresh token lives in the agenix secret on first start, then in a root-only
state file so rotated tokens survive restarts. It never leaves the host.
"""

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TENANT = "723a5a87-f39a-4a22-9247-3fc240c01396"
CLIENT_ID = "9e5f94bc-e8a4-4e73-b8be-63364c29d753"
TOKEN_URL = f"https://login.microsoftonline.com/{TENANT}/oauth2/v2.0/token"

STATE_DIR = os.environ.get("EMAIL_MCP_OAUTH_STATE_DIR", "/var/lib/email-mcp-oauth")
TOKEN_PATH = os.path.join(STATE_DIR, "refresh-token")
SEED_PATH = os.environ["EMAIL_MCP_OAUTH_SEED"]
HOST = os.environ.get("EMAIL_MCP_OAUTH_HOST", "127.0.0.1")
PORT = int(os.environ.get("EMAIL_MCP_OAUTH_PORT", "8799"))


def write_token(token: str) -> None:
    os.makedirs(STATE_DIR, exist_ok=True)
    tmp = TOKEN_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(token)
    os.chmod(tmp, 0o600)
    os.replace(tmp, TOKEN_PATH)


def read_token() -> str:
    try:
        with open(TOKEN_PATH, encoding="utf-8") as f:
            token = f.read().strip()
        if token:
            return token
    except FileNotFoundError:
        pass
    with open(SEED_PATH, encoding="utf-8") as f:
        token = f.read().strip()
    if not token:
        raise RuntimeError(f"empty seed token at {SEED_PATH}")
    write_token(token)
    return token


def refresh() -> tuple[int, bytes]:
    data = urllib.parse.urlencode(
        {
            "grant_type": "refresh_token",
            "client_id": CLIENT_ID,
            "refresh_token": read_token(),
        }
    ).encode()
    req = urllib.request.Request(TOKEN_URL, data=data, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = resp.read()
            status = resp.status
    except urllib.error.HTTPError as exc:
        body = exc.read()
        status = exc.code
    try:
        parsed = json.loads(body)
    except ValueError:
        return status, body
    new_token = parsed.get("refresh_token")
    if new_token:
        write_token(new_token)
    return status, body


class Handler(BaseHTTPRequestHandler):
    def _path(self) -> str:
        return urllib.parse.urlparse(self.path).path

    def do_POST(self) -> None:
        if self._path() != "/token":
            self.send_error(404)
            return
        # email-mcp's body is ignored: client_secret is not valid for this
        # public client and the refresh token comes from the state file.
        length = int(self.headers.get("content-length") or 0)
        if length:
            self.rfile.read(length)
        try:
            status, body = refresh()
        except Exception as exc:  # keep the failure visible to email-mcp
            body = json.dumps(
                {"error": "temporary_failure", "error_description": str(exc)}
            ).encode()
            status = 502
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        if self._path() == "/health":
            body = b"ok\n"
            self.send_response(200)
            self.send_header("content-type", "text/plain")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_error(404)

    def log_message(self, fmt: str, *args: object) -> None:
        print("%s - %s" % (self.address_string(), fmt % args), file=sys.stderr)


def main() -> None:
    os.makedirs(STATE_DIR, exist_ok=True)
    read_token()  # fail fast if the seed is missing
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"email-mcp OAuth proxy listening on {HOST}:{PORT}", file=sys.stderr)
    server.serve_forever()


if __name__ == "__main__":
    main()
