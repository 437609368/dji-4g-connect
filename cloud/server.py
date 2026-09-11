#!/usr/bin/env python3
"""Minimal authenticated SMS relay for the DJI QDC507 iOS agent."""

from __future__ import annotations

import hmac
import json
import os
import sqlite3
import ssl
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse


ROOT = Path(__file__).resolve().parent
DB_PATH = Path(os.environ.get("DJI4G_DB", str(ROOT / "relay.sqlite3")))
TOKEN = os.environ.get("DJI4G_CLOUD_TOKEN", "")


def connect_db() -> sqlite3.Connection:
    db = sqlite3.connect(DB_PATH)
    db.row_factory = sqlite3.Row
    db.execute(
        """CREATE TABLE IF NOT EXISTS messages (
            id TEXT PRIMARY KEY,
            device_id TEXT NOT NULL,
            direction TEXT NOT NULL CHECK(direction IN ('incoming', 'outgoing')),
            number TEXT NOT NULL,
            body TEXT NOT NULL,
            date TEXT NOT NULL,
            created_at REAL NOT NULL
        )"""
    )
    db.execute(
        """CREATE TABLE IF NOT EXISTS commands (
            id TEXT PRIMARY KEY,
            device_id TEXT NOT NULL,
            type TEXT NOT NULL,
            payload TEXT NOT NULL,
            status TEXT NOT NULL CHECK(status IN ('pending', 'claimed', 'done', 'failed')),
            created_at REAL NOT NULL,
            claimed_at REAL
        )"""
    )
    db.execute(
        """CREATE TABLE IF NOT EXISTS calls (
            id TEXT PRIMARY KEY,
            device_id TEXT NOT NULL,
            number TEXT NOT NULL,
            status TEXT NOT NULL CHECK(status IN ('pending_backend', 'ringing', 'connected', 'ended', 'failed')),
            media_url TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        )"""
    )
    db.commit()
    return db


def json_bytes(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format: str, *args: object) -> None:
        return

    def send_json(self, status: int, value: object) -> None:
        body = json_bytes(value)
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def read_json(self) -> dict:
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length > 64 * 1024:
                raise ValueError("request too large")
            value = json.loads(self.rfile.read(length) or b"{}")
            if not isinstance(value, dict):
                raise ValueError("JSON object required")
            return value
        except (ValueError, json.JSONDecodeError) as exc:
            raise ValueError(str(exc)) from exc

    def authorized(self) -> bool:
        supplied = self.headers.get("Authorization", "")
        expected = f"Bearer {TOKEN}" if TOKEN else ""
        return bool(TOKEN) and hmac.compare_digest(supplied, expected)

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path == "/health":
            self.send_json(200, {"ok": True})
            return
        if not self.authorized():
            self.send_json(401, {"error": "unauthorized"})
            return

        parts = parsed.path.strip("/").split("/")
        if len(parts) == 5 and parts[:3] == ["api", "v1", "devices"]:
            device_id = parts[3]
            if parts[4] == "messages":
                self.list_messages(device_id, parse_qs(parsed.query))
                return
            if parts[4] == "commands":
                self.list_commands(device_id)
                return
        if len(parts) == 6 and parts[:3] == ["api", "v1", "devices"] and parts[4] == "calls":
            self.get_call(parts[3], parts[5])
            return
        self.send_json(404, {"error": "not found"})

    def do_POST(self) -> None:
        if not self.authorized():
            self.send_json(401, {"error": "unauthorized"})
            return
        parsed = urlparse(self.path)
        parts = parsed.path.strip("/").split("/")
        try:
            payload = self.read_json()
        except ValueError as exc:
            self.send_json(400, {"error": str(exc)})
            return

        if len(parts) == 5 and parts[:2] == ["api", "v1"] and parts[2] == "devices":
            device_id = parts[3]
            if parts[4] == "messages":
                self.insert_message(device_id, payload)
                return
            if parts[4] == "commands":
                self.create_command(device_id, payload)
                return
            if parts[4] == "calls":
                self.create_call(device_id, payload)
                return
        if len(parts) == 7 and parts[:3] == ["api", "v1", "devices"] and parts[4] == "calls" and parts[6] == "events":
            self.call_event(parts[3], parts[5], payload)
            return
        if len(parts) == 6 and parts[:2] == ["api", "v1"] and parts[2] == "devices" and parts[4] == "commands" and parts[5] == "ack":
            self.ack_command(parts[3], payload)
            return
        self.send_json(404, {"error": "not found"})

    def do_DELETE(self) -> None:
        if not self.authorized():
            self.send_json(401, {"error": "unauthorized"})
            return
        parts = urlparse(self.path).path.strip("/").split("/")
        if len(parts) == 6 and parts[:2] == ["api", "v1"] and parts[2] == "devices" and parts[4] == "calls":
            self.end_call(parts[3], parts[5])
            return
        self.send_json(404, {"error": "not found"})

    def list_messages(self, device_id: str, query: dict[str, list[str]]) -> None:
        after = query.get("after", [""])[0]
        db = connect_db()
        rows = db.execute(
            "SELECT id, direction, number, body, date FROM messages WHERE device_id = ? AND created_at > COALESCE((SELECT created_at FROM messages WHERE id = ?), 0) ORDER BY created_at LIMIT 200",
            (device_id, after),
        ).fetchall()
        db.close()
        self.send_json(200, {"messages": [dict(row) for row in rows]})

    def insert_message(self, device_id: str, payload: dict) -> None:
        required = ("id", "direction", "number", "body", "date")
        if any(not isinstance(payload.get(key), str) or not payload[key] for key in required):
            self.send_json(400, {"error": "id, direction, number, body and date are required"})
            return
        if payload["direction"] not in ("incoming", "outgoing"):
            self.send_json(400, {"error": "invalid direction"})
            return
        db = connect_db()
        db.execute(
            "INSERT OR IGNORE INTO messages(id, device_id, direction, number, body, date, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
            (payload["id"], device_id, payload["direction"], payload["number"], payload["body"], payload["date"], time.time()),
        )
        db.commit()
        db.close()
        self.send_json(201, {"ok": True})

    def list_commands(self, device_id: str) -> None:
        db = connect_db()
        now = time.time()
        db.execute("UPDATE commands SET status = 'pending' WHERE device_id = ? AND status = 'claimed' AND claimed_at < ?", (device_id, now - 60))
        rows = db.execute(
            "SELECT id, type, payload FROM commands WHERE device_id = ? AND status = 'pending' ORDER BY created_at LIMIT 20",
            (device_id,),
        ).fetchall()
        ids = [row["id"] for row in rows]
        if ids:
            db.executemany("UPDATE commands SET status = 'claimed', claimed_at = ? WHERE id = ?", [(now, item) for item in ids])
            db.commit()
        db.close()
        commands = []
        for row in rows:
            commands.append({"id": row["id"], "type": row["type"], **json.loads(row["payload"])})
        self.send_json(200, {"commands": commands})

    def create_command(self, device_id: str, payload: dict) -> None:
        if payload.get("type") != "send_sms" or not payload.get("to") or not payload.get("body"):
            self.send_json(400, {"error": "type=send_sms, to and body are required"})
            return
        command_id = str(uuid.uuid4())
        body = {"to": str(payload["to"]), "body": str(payload["body"])}
        db = connect_db()
        db.execute(
            "INSERT INTO commands(id, device_id, type, payload, status, created_at) VALUES (?, ?, ?, ?, 'pending', ?)",
            (command_id, device_id, "send_sms", json.dumps(body, ensure_ascii=False), time.time()),
        )
        db.commit()
        db.close()
        self.send_json(202, {"id": command_id, "status": "pending"})

    def create_call(self, device_id: str, payload: dict) -> None:
        number = payload.get("number")
        if not isinstance(number, str) or not number.strip():
            self.send_json(400, {"error": "number is required"})
            return
        call_id = str(uuid.uuid4())
        now = time.time()
        db = connect_db()
        db.execute(
            "INSERT INTO calls(id, device_id, number, status, media_url, created_at, updated_at) VALUES (?, ?, ?, 'pending_backend', NULL, ?, ?)",
            (call_id, device_id, number.strip(), now, now),
        )
        db.commit()
        db.close()
        self.send_json(202, {"id": call_id, "status": "pending_backend", "mediaURL": None})

    def get_call(self, device_id: str, call_id: str) -> None:
        db = connect_db()
        row = db.execute(
            "SELECT id, status, media_url AS mediaURL FROM calls WHERE id = ? AND device_id = ?",
            (call_id, device_id),
        ).fetchone()
        db.close()
        if row is None:
            self.send_json(404, {"error": "call not found"})
            return
        self.send_json(200, dict(row))

    def call_event(self, device_id: str, call_id: str, payload: dict) -> None:
        status = payload.get("status")
        media_url = payload.get("mediaURL")
        if status not in ("ringing", "connected", "ended", "failed"):
            self.send_json(400, {"error": "status must be ringing, connected, ended or failed"})
            return
        if media_url is not None and not isinstance(media_url, str):
            self.send_json(400, {"error": "mediaURL must be a string or null"})
            return
        db = connect_db()
        result = db.execute(
            "UPDATE calls SET status = ?, media_url = COALESCE(?, media_url), updated_at = ? WHERE id = ? AND device_id = ?",
            (status, media_url, time.time(), call_id, device_id),
        )
        db.commit()
        db.close()
        if result.rowcount == 0:
            self.send_json(404, {"error": "call not found"})
            return
        self.send_json(200, {"ok": True})

    def end_call(self, device_id: str, call_id: str) -> None:
        db = connect_db()
        result = db.execute(
            "UPDATE calls SET status = 'ended', updated_at = ? WHERE id = ? AND device_id = ?",
            (time.time(), call_id, device_id),
        )
        db.commit()
        db.close()
        if result.rowcount == 0:
            self.send_json(404, {"error": "call not found"})
            return
        self.send_json(200, {"ok": True})

    def ack_command(self, device_id: str, payload: dict) -> None:
        command_id = payload.get("id")
        status = payload.get("status")
        if not isinstance(command_id, str) or status not in ("done", "failed"):
            self.send_json(400, {"error": "id and status=done|failed are required"})
            return
        db = connect_db()
        db.execute("UPDATE commands SET status = ? WHERE id = ? AND device_id = ?", (status, command_id, device_id))
        db.commit()
        db.close()
        self.send_json(200, {"ok": True})


def main() -> None:
    if not TOKEN:
        raise SystemExit("Set DJI4G_CLOUD_TOKEN before starting the relay")
    host = os.environ.get("DJI4G_BIND", "127.0.0.1")
    port = int(os.environ.get("DJI4G_PORT", "8787"))
    connect_db().close()
    httpd = ThreadingHTTPServer((host, port), Handler)
    cert = os.environ.get("DJI4G_CERT", "")
    key = os.environ.get("DJI4G_KEY", "")
    if bool(cert) != bool(key):
        raise SystemExit("Set both DJI4G_CERT and DJI4G_KEY for HTTPS")
    scheme = "http"
    if cert:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(certfile=cert, keyfile=key)
        httpd.socket = context.wrap_socket(httpd.socket, server_side=True)
        scheme = "https"
    print(f"DJI 4G relay listening on {scheme}://{host}:{port}")
    httpd.serve_forever()


if __name__ == "__main__":
    main()
