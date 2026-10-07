#!/usr/bin/env python3

import os
import json
import sqlite3
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

BASE = os.path.dirname(os.path.abspath(__file__))
DB = os.path.join(BASE, "analytics.sqlite3")

HOST = "127.0.0.1"
PORT = int(os.environ.get("ANALYTICS_PORT", "8080"))


def connect():
    conn = sqlite3.connect(DB)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS clicks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            ip TEXT NOT NULL,
            user_agent TEXT,
            referer TEXT,
            ref TEXT,
            consent INTEGER NOT NULL
        )
    """)
    conn.commit()
    return conn


def json_response(handler, data, status=200):

    raw = json.dumps(
        data,
        ensure_ascii=False
    ).encode("utf-8")

    handler.send_response(status)

    handler.send_header(
        "Content-Type",
        "application/json; charset=utf-8"
    )

    handler.send_header(
        "Content-Length",
        str(len(raw))
    )

    handler.send_header(
        "Cache-Control",
        "no-store"
    )

    handler.end_headers()

    handler.wfile.write(raw)


class Handler(BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):
        print("[HTTP]", fmt % args)

    def file(self, name, content_type):

        path = os.path.join(BASE, name)

        if not os.path.isfile(path):
            self.send_error(404)
            return

        with open(path, "rb") as f:
            data = f.read()

        self.send_response(200)

        self.send_header(
            "Content-Type",
            content_type
        )

        self.send_header(
            "Content-Length",
            str(len(data))
        )

        self.end_headers()

        self.wfile.write(data)

    def do_GET(self):

        parsed = urlparse(self.path)
        path = parsed.path

        if path == "/":
            return self.file(
                "index.html",
                "text/html; charset=utf-8"
            )

        if path == "/report":
            return self.file(
                "report.html",
                "text/html; charset=utf-8"
            )

        if path == "/health":

            return json_response(
                self,
                {
                    "ok": True,
                    "service": "privacy-analytics",
                    "port": PORT
                }
            )

        if path == "/api/count":

            conn = connect()

            count = conn.execute(
                "SELECT COUNT(*) FROM clicks"
            ).fetchone()[0]

            conn.close()

            return json_response(
                self,
                {
                    "ok": True,
                    "count": count
                }
            )

        if path == "/api/logs":

            conn = connect()

            rows = conn.execute("""
                SELECT
                    id,
                    timestamp,
                    ip,
                    user_agent,
                    referer,
                    ref,
                    consent
                FROM clicks
                ORDER BY id DESC
                LIMIT 500
            """).fetchall()

            conn.close()

            fields = [
                "id",
                "timestamp",
                "ip",
                "user_agent",
                "referer",
                "ref",
                "consent"
            ]

            return json_response(
                self,
                [
                    dict(zip(fields, row))
                    for row in rows
                ]
            )

        self.send_error(404)

    def do_POST(self):

        parsed = urlparse(self.path)

        if parsed.path != "/track":
            self.send_error(404)
            return

        try:
            length = int(
                self.headers.get(
                    "Content-Length",
                    "0"
                )
            )

            if length > 16384:
                return json_response(
                    self,
                    {
                        "ok": False,
                        "error": "payload_too_large"
                    },
                    413
                )

            raw = self.rfile.read(length)

            payload = json.loads(
                raw.decode("utf-8")
            )

        except Exception:

            return json_response(
                self,
                {
                    "ok": False,
                    "error": "invalid_json"
                },
                400
            )

        # Açık rıza zorunlu.
        if payload.get("consent") is not True:

            return json_response(
                self,
                {
                    "ok": False,
                    "error": "consent_required"
                },
                403
            )

        ip = self.client_address[0]

        ref = str(
            payload.get(
                "ref",
                "A001"
            )
        )[:100]

        user_agent = self.headers.get(
            "User-Agent",
            ""
        )[:1000]

        referer = self.headers.get(
            "Referer",
            ""
        )[:1000]

        timestamp = datetime.now(
            timezone.utc
        ).isoformat()

        conn = connect()

        cursor = conn.execute("""
            INSERT INTO clicks
            (
                timestamp,
                ip,
                user_agent,
                referer,
                ref,
                consent
            )
            VALUES (?, ?, ?, ?, ?, ?)
        """, (
            timestamp,
            ip,
            user_agent,
            referer,
            ref,
            1
        ))

        conn.commit()

        record_id = cursor.lastrowid

        conn.close()

        return json_response(
            self,
            {
                "ok": True,
                "id": record_id
            }
        )


connect()

print("================================================")
print(" PRIVACY ANALYTICS SERVER")
print("================================================")
print(f"URL    : http://{HOST}:{PORT}")
print(f"REPORT : http://{HOST}:{PORT}/report")
print(f"DB     : {DB}")
print("================================================")

server = ThreadingHTTPServer(
    (HOST, PORT),
    Handler
)

server.serve_forever()
