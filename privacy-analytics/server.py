#!/usr/bin/env python3

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs
import sqlite3
import json
import os
from datetime import datetime, timezone

BASE = os.path.dirname(os.path.abspath(__file__))
DB = os.path.join(BASE, "analytics.sqlite3")

HOST = "0.0.0.0"
PORT = 8080


def db():
    conn = sqlite3.connect(DB)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS clicks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            ip TEXT NOT NULL,
            user_agent TEXT,
            referer TEXT,
            ref TEXT,
            consent INTEGER NOT NULL DEFAULT 1
        )
    """)
    conn.commit()
    return conn


def get_client_ip(handler):
    # Gerçek bağlantı adresi.
    # Proxy başlıklarına güvenilmez.
    return handler.client_address[0]


class Handler(BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):
        print("[HTTP]", fmt % args)

    def send_json(self, obj, status=200):
        raw = json.dumps(
            obj,
            ensure_ascii=False
        ).encode("utf-8")

        self.send_response(status)
        self.send_header(
            "Content-Type",
            "application/json; charset=utf-8"
        )
        self.send_header(
            "Content-Length",
            str(len(raw))
        )
        self.send_header(
            "Cache-Control",
            "no-store"
        )
        self.end_headers()
        self.wfile.write(raw)

    def send_file(self, path, content_type):
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
        qs = parse_qs(parsed.query)

        if path == "/":
            return self.send_file(
                os.path.join(BASE, "index.html"),
                "text/html; charset=utf-8"
            )

        if path == "/report":
            return self.send_file(
                os.path.join(BASE, "report.html"),
                "text/html; charset=utf-8"
            )

        if path == "/api/logs":

            conn = db()

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

            return self.send_json([
                dict(zip(fields, row))
                for row in rows
            ])

        if path == "/api/count":

            conn = db()

            count = conn.execute(
                "SELECT COUNT(*) FROM clicks"
            ).fetchone()[0]

            conn.close()

            return self.send_json({
                "count": count
            })

        self.send_error(404)

    def do_POST(self):

        parsed = urlparse(self.path)

        if parsed.path != "/track":
            self.send_error(404)
            return

        length = int(
            self.headers.get(
                "Content-Length",
                "0"
            )
        )

        raw = self.rfile.read(length)

        try:
            payload = json.loads(
                raw.decode("utf-8")
            )
        except Exception:
            self.send_json(
                {"ok": False, "error": "invalid_json"},
                400
            )
            return

        # Sunucu tarafında açık rıza zorunlu.
        if payload.get("consent") is not True:
            self.send_json(
                {
                    "ok": False,
                    "error": "consent_required"
                },
                403
            )
            return

        ip = get_client_ip(self)

        ref = str(
            payload.get("ref", "A001")
        )[:100]

        ua = self.headers.get(
            "User-Agent",
            ""
        )[:1000]

        referer = self.headers.get(
            "Referer",
            ""
        )[:1000]

        now = datetime.now(
            timezone.utc
        ).isoformat()

        conn = db()

        conn.execute("""
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
            now,
            ip,
            ua,
            referer,
            ref,
            1
        ))

        conn.commit()

        record_id = conn.execute(
            "SELECT last_insert_rowid()"
        ).fetchone()[0]

        conn.close()

        self.send_json({
            "ok": True,
            "id": record_id
        })


db()

print()
print("==============================================")
print(" IP ANALYTICS SERVER")
print("==============================================")
print("Listening: http://127.0.0.1:8080")
print("Report   : http://127.0.0.1:8080/report")
print("Database :", DB)
print("==============================================")
print()

ThreadingHTTPServer(
    (HOST, PORT),
    Handler
).serve_forever()
