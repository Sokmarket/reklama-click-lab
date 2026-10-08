#!/usr/bin/env python3
"""Local consent-based analytics server for Reklama Click Lab."""

import json
import os
import sqlite3
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

BASE = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(BASE)
DB = os.path.join(BASE, "analytics.sqlite3")
HOST = os.environ.get("ANALYTICS_HOST", "0.0.0.0")
PORT = int(os.environ.get("ANALYTICS_PORT", "8080"))
MAX_BODY = 16 * 1024


def connect():
    conn = sqlite3.connect(DB, timeout=10)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS clicks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            ip TEXT NOT NULL,
            user_agent TEXT,
            referer TEXT,
            ref TEXT NOT NULL,
            consent INTEGER NOT NULL CHECK (consent = 1)
        )
    """)
    conn.commit()
    return conn


def json_response(handler, data, status=200):
    raw = json.dumps(data, ensure_ascii=False).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Content-Length", str(len(raw)))
    handler.send_header("Cache-Control", "no-store")
    handler.send_header("X-Content-Type-Options", "nosniff")
    handler.send_header("X-Frame-Options", "SAMEORIGIN")
    handler.end_headers()
    handler.wfile.write(raw)


def read_project_file(relative_path):
    """Read only explicitly allowed static project files."""
    allowed = {
        "index.html": ("text/html; charset=utf-8",),
        "reklam.png": ("image/png",),
        "privacy-analytics/index.html": ("text/html; charset=utf-8",),
        "privacy-analytics/report.html": ("text/html; charset=utf-8",),
    }
    if relative_path not in allowed:
        return None
    path = os.path.abspath(os.path.join(PROJECT_ROOT, relative_path))
    if not path.startswith(os.path.abspath(PROJECT_ROOT) + os.sep):
        return None
    if not os.path.isfile(path):
        return None
    with open(path, "rb") as f:
        return path, f.read(), allowed[relative_path][0]




class Handler(BaseHTTPRequestHandler):
    server_version = "ReklamaClickLab/1.0"

    def log_message(self, fmt, *args):
        print("[HTTP]", fmt % args)

    def file(self, relative_path):
        result = read_project_file(relative_path)
        if not result:
            self.send_error(404)
            return
        _, data, content_type = result
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "SAMEORIGIN")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path

        if path in ("/", "/index.html"):
            return self.file("index.html")

        if path == "/reklam.png":
            return self.file("reklam.png")

        if path in ("/privacy-analytics", "/privacy-analytics/"):
            return self.file("privacy-analytics/index.html")

        if path == "/privacy-analytics/report":
            return self.file("privacy-analytics/report.html")

        if path == "/report":
            return self.file("privacy-analytics/report.html")

        if path == "/health":
            return json_response(self, {
                "ok": True,
                "service": "privacy-analytics",
                "port": PORT
            })

        if path == "/api/count":
            conn = connect()
            try:
                count = conn.execute(
                    "SELECT COUNT(*) FROM clicks"
                ).fetchone()[0]
            finally:
                conn.close()
            return json_response(self, {"ok": True, "count": count})

        if path == "/api/logs":
            conn = connect()
            try:
                rows = conn.execute("""
                    SELECT id, timestamp, ip, user_agent, referer, ref, consent
                    FROM clicks
                    ORDER BY id DESC
                    LIMIT 500
                """).fetchall()
            finally:
                conn.close()

            fields = [
                "id", "timestamp", "ip", "user_agent",
                "referer", "ref", "consent"
            ]
            return json_response(self, [
                dict(zip(fields, row)) for row in rows
            ])

        self.send_error(404)

    def do_POST(self):
        parsed = urlparse(self.path)

        if parsed.path != "/track":
            self.send_error(404)
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0

        if length <= 0 or length > MAX_BODY:
            return json_response(self, {
                "ok": False,
                "error": "invalid_payload_size"
            }, 400)

        try:
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            return json_response(self, {
                "ok": False,
                "error": "invalid_json"
            }, 400)

        if not isinstance(payload, dict):
            return json_response(self, {
                "ok": False,
                "error": "invalid_payload"
            }, 400)

        # Tracking is only accepted after explicit user consent.
        if payload.get("consent") is not True:
            return json_response(self, {
                "ok": False,
                "error": "consent_required"
            }, 403)

        ref = str(payload.get("ref") or "A001")[:100]
        user_agent = self.headers.get("User-Agent", "")[:1000]
        referer = self.headers.get("Referer", "")[:1000]
        ip = self.client_address[0]
        timestamp = datetime.now(timezone.utc).isoformat()

        conn = connect()
        try:
            cursor = conn.execute("""
                INSERT INTO clicks
                    (timestamp, ip, user_agent, referer, ref, consent)
                VALUES (?, ?, ?, ?, ?, 1)
            """, (timestamp, ip, user_agent, referer, ref))
            conn.commit()
            record_id = cursor.lastrowid
        finally:
            conn.close()

        return json_response(self, {
            "ok": True,
            "id": record_id,
            "timestamp": timestamp,
            "ip": ip,
            "ref": ref
        })


connect()

print("=" * 48)
print(" REKLAMA CLICK LAB - CONSENT ANALYTICS")
print("=" * 48)
print(f"URL    : http://{HOST}:{PORT}")
print(f"REPORT : http://{HOST}:{PORT}/privacy-analytics/report")
print(f"DB     : {DB}")
print("=" * 48)

server = ThreadingHTTPServer((HOST, PORT), Handler)

try:
    server.serve_forever()
except KeyboardInterrupt:
    print("\nSunucu kapatılıyor...")
finally:
    server.server_close()
