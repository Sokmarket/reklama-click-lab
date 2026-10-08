#!/usr/bin/env python3

import os
import json
import time
import base64
import ipaddress
import json
import os
import urllib.request
import sqlite3
import hashlib
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DB_PATH = os.path.join(BASE_DIR, "analytics.sqlite3")

HOST = "0.0.0.0"
PORT = 8080

HASH_SALT = os.environ.get(
    "ANALYTICS_HASH_SALT",
    "reklama-click-lab-local-salt"
)


def anon_hash(value):
    value = str(value or "")
    return hashlib.sha256(
        (HASH_SALT + value).encode("utf-8")
    ).hexdigest()


def db():
    conn = sqlite3.connect(
        DB_PATH,
        timeout=10
    )
    conn.execute(
        "PRAGMA busy_timeout=10000"
    )
    return conn


def init_db():
    conn = db()

    conn.execute("""
        CREATE TABLE IF NOT EXISTS clicks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            ip TEXT NOT NULL,
            user_agent TEXT,
            referer TEXT,
            ref TEXT NOT NULL,
            consent INTEGER NOT NULL CHECK(consent = 1),
            event TEXT,
            ip_hash TEXT,
            user_agent_hash TEXT,
            created_at INTEGER
        )
    """)

    cols = {
        r[1]: r
        for r in conn.execute(
            "PRAGMA table_info(clicks)"
        )
    }

    additions = {
        "timestamp": "TEXT",
        "ip": "TEXT",
        "user_agent": "TEXT",
        "referer": "TEXT",
        "ref": "TEXT",
        "consent": "INTEGER",
        "event": "TEXT",
        "ip_hash": "TEXT",
        "user_agent_hash": "TEXT",
        "created_at": "INTEGER"
    }

    for name, typ in additions.items():
        if name not in cols:
            conn.execute(
                f"ALTER TABLE clicks ADD COLUMN {name} {typ}"
            )

    now_iso = datetime.now(
        timezone.utc
    ).isoformat()

    now_epoch = int(time.time())

    conn.execute("""
        UPDATE clicks
        SET timestamp = ?
        WHERE timestamp IS NULL
    """, (now_iso,))

    conn.execute("""
        UPDATE clicks
        SET ip = 'LEGACY_ANONYMIZED'
        WHERE ip IS NULL
    """)

    conn.execute("""
        UPDATE clicks
        SET ref = 'LEGACY'
        WHERE ref IS NULL
    """)

    conn.execute("""
        UPDATE clicks
        SET consent = 1
        WHERE consent IS NULL
    """)

    conn.execute("""
        UPDATE clicks
        SET created_at = ?
        WHERE created_at IS NULL
    """, (now_epoch,))

    conn.execute("""
        CREATE INDEX IF NOT EXISTS
        idx_clicks_created_at
        ON clicks(created_at)
    """)

    conn.execute("""
        CREATE INDEX IF NOT EXISTS
        idx_clicks_event_ref
        ON clicks(event, ref)
    """)

    conn.commit()
    conn.close()



def maxmind_lookup(ip):
    """
    MaxMind GeoLite enrichment.
    Ham IP'yi sonuçta döndürmez; yalnızca gerekli enrichment alanlarını döndürür.
    Private/loopback IP'ler MaxMind'e gönderilmez.
    """
    try:
        parsed_ip = ipaddress.ip_address(ip)

        if (
            parsed_ip.is_private
            or parsed_ip.is_loopback
            or parsed_ip.is_reserved
            or parsed_ip.is_link_local
        ):
            return {
                "maxmind_success": False,
                "maxmind_error": "PRIVATE_OR_LOCAL_IP"
            }

    except ValueError:
        return {
            "maxmind_success": False,
            "maxmind_error": "INVALID_IP"
        }

    account_id = os.environ.get("MM_ACCOUNT_ID") or os.environ.get(
        "MAXMIND_ACCOUNT_ID", ""
    )
    license_key = os.environ.get("MM_LICENSE_KEY") or os.environ.get(
        "MAXMIND_LICENSE_KEY", ""
    )

    if not account_id or not license_key:
        return {
            "maxmind_success": False,
            "maxmind_error": "MAXMIND_CREDENTIALS_MISSING"
        }

    url = "https://geolite.info/geoip/v2.1/city/" + ip

    token = base64.b64encode(
        f"{account_id}:{license_key}".encode("utf-8")
    ).decode("ascii")

    request = urllib.request.Request(
        url,
        headers={
            "Authorization": f"Basic {token}",
            "Accept": "application/json",
            "User-Agent": "reklama-click-lab-analytics/1.0"
        }
    )

    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            data = json.loads(response.read().decode("utf-8"))

        country = data.get("country", {})
        continent = data.get("continent", {})
        city = data.get("city", {})
        location = data.get("location", {})
        traits = data.get("traits", {})
        subdivisions = data.get("subdivisions", [])

        return {
            "maxmind_success": True,
            "country": country.get("names", {}).get("en"),
            "country_code": country.get("iso_code"),
            "continent": continent.get("names", {}).get("en"),
            "continent_code": continent.get("code"),
            "region": (
                subdivisions[0].get("names", {}).get("en")
                if subdivisions else None
            ),
            "region_code": (
                subdivisions[0].get("iso_code")
                if subdivisions else None
            ),
            "city": city.get("names", {}).get("en"),
            "postal_code": data.get("postal", {}).get("code"),
            "latitude": location.get("latitude"),
            "longitude": location.get("longitude"),
            "accuracy_radius_km": location.get("accuracy_radius"),
            "timezone": location.get("time_zone"),
            "network": traits.get("network"),
            "asn": traits.get("autonomous_system_number"),
            "organization": traits.get(
                "autonomous_system_organization"
            )
        }

    except Exception as exc:
        print(
            "[MAXMIND ERROR]",
            type(exc).__name__,
            str(exc),
            flush=True
        )

        return {
            "maxmind_success": False,
            "maxmind_error": type(exc).__name__
        }



# === SECURE CLIENT IP START ===
def get_client_ip(handler):
    """
    Güvenli client IP çözümleme.

    Varsayılan:
      - X-Forwarded-For GÜVENİLMEZ.
      - Doğrudan TCP peer adresi kullanılır.

    Reverse proxy arkasında:
      TRUST_PROXY=1
      TRUSTED_PROXY_IPS="proxy_ip1,proxy_ip2"
    ayarlanmalıdır.
    """
    peer_ip = handler.client_address[0]

    trust_proxy = os.environ.get("TRUST_PROXY", "0") == "1"
    trusted = {
        x.strip()
        for x in os.environ.get("TRUSTED_PROXY_IPS", "").split(",")
        if x.strip()
    }

    if trust_proxy and (not trusted or peer_ip in trusted):
        forwarded = handler.headers.get("X-Forwarded-For", "")
        if forwarded:
            candidate = forwarded.split(",")[0].strip()
            try:
                ipaddress.ip_address(candidate)
                return candidate
            except ValueError:
                pass

    return peer_ip
# === SECURE CLIENT IP END ===

class Handler(BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):
        print(
            "[HTTP]",
            self.command,
            self.path,
            flush=True
        )

    def send_json(self, status, payload):
        body = json.dumps(
            payload,
            ensure_ascii=False
        ).encode("utf-8")

        self.send_response(status)

        self.send_header(
            "Content-Type",
            "application/json; charset=utf-8"
        )

        self.send_header(
            "Content-Length",
            str(len(body))
        )

        self.send_header(
            "Access-Control-Allow-Origin",
            "*"
        )

        self.send_header(
            "Access-Control-Allow-Methods",
            "POST, OPTIONS"
        )

        self.send_header(
            "Access-Control-Allow-Headers",
            "Content-Type"
        )

        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_json(204, {})

    def do_GET(self):

        parsed = urlparse(self.path)
        # ### REKLAMA_REPORT_HTML5_FINAL ###
        if parsed.path == "/report.html":
            report_file = os.path.join(BASE_DIR, "report.html")

            try:
                body = report_file.read_bytes()
            except FileNotFoundError:
                self.send_error(404, "report.html not found")
                return

            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
            self.send_header("Pragma", "no-cache")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            self.wfile.write(body)
            return

        
        # ### REKLAMA_REPORT_API_FINAL ###
        if parsed.path == "/api/report":
            try:
                conn = sqlite3.connect(DB_PATH)
                conn.row_factory = sqlite3.Row

                rows = conn.execute("""
                    SELECT
                        id,
                        timestamp,
                        ref,
                        consent,
                        event,
                        country,
                        country_code,
                        continent,
                        continent_code,
                        region,
                        region_code,
                        city,
                        postal_code,
                        latitude,
                        longitude,
                        accuracy_radius_km,
                        timezone,
                        network,
                        asn,
                        organization,
                        maxmind_success
                    FROM clicks
                    ORDER BY id DESC
                    LIMIT 500
                """).fetchall()

                conn.close()

                data = []

                for row in rows:
                    item = dict(row)

                    # Privacy:
                    # Raw IP hiçbir zaman report API'ye çıkmaz.
                    item.pop("ip", None)
                    item.pop("ip_hash", None)
                    item.pop("user_agent", None)
                    item.pop("user_agent_hash", None)

                    data.append(item)

                body = json.dumps(
                    {
                        "ok": True,
                        "count": len(data),
                        "rows": data
                    },
                    ensure_ascii=False
                ).encode("utf-8")

                self.send_response(200)
                self.send_header(
                    "Content-Type",
                    "application/json; charset=utf-8"
                )
                self.send_header(
                    "Access-Control-Allow-Origin",
                    "*"
                )
                self.send_header(
                    "Cache-Control",
                    "no-store"
                )
                self.send_header(
                    "Content-Length",
                    str(len(body))
                )
                self.end_headers()
                self.wfile.write(body)
                return

            except Exception as exc:

                body = json.dumps(
                    {
                        "ok": False,
                        "error": type(exc).__name__
                    },
                    ensure_ascii=False
                ).encode("utf-8")

                self.send_response(500)
                self.send_header(
                    "Content-Type",
                    "application/json; charset=utf-8"
                )
                self.send_header(
                    "Access-Control-Allow-Origin",
                    "*"
                )
                self.send_header(
                    "Content-Length",
                    str(len(body))
                )
                self.end_headers()
                self.wfile.write(body)
                return


        if parsed.path == "/health":
            self.send_json(
                200,
                {
                    "ok": True,
                    "service": "reklama-click-lab",
                    "database": "sqlite"
                }
            )
            return

        self.send_json(
            404,
            {
                "ok": False,
                "error": "not_found"
            }
        )

    def do_POST(self):

        parsed = urlparse(self.path)

        if parsed.path != "/api/click":
            self.send_json(
                404,
                {
                    "ok": False,
                    "error": "not_found"
                }
            )
            return

        conn = None

        try:

            length = int(
                self.headers.get(
                    "Content-Length",
                    "0"
                )
            )

            if length <= 0:
                raise ValueError("empty_body")

            if length > 8192:
                self.send_json(
                    413,
                    {
                        "ok": False,
                        "error": "payload_too_large"
                    }
                )
                return

            body = self.rfile.read(length)

            payload = json.loads(
                body.decode("utf-8")
            )

            if not isinstance(payload, dict):
                raise ValueError(
                    "invalid_json_object"
                )

            event = str(
                payload.get(
                    "event",
                    "image_click"
                )
            )[:64] or "image_click"

            ref = str(
                payload.get(
                    "ref",
                    "AD001"
                )
            )[:128] or "AD001"

            client_ip = get_client_ip(self)

            user_agent = self.headers.get(
                "User-Agent",
                ""
            )

            referer = self.headers.get(
                "Referer",
                ""
            )[:2000]

            ip_hash = anon_hash(client_ip)
            ua_hash = anon_hash(user_agent)

            # MaxMind enrichment.
            # Ham IP veritabanına yazılmaz.
            maxmind = maxmind_lookup(client_ip)

            timestamp = datetime.now(
                timezone.utc
            ).isoformat()

            created_at = int(time.time())

            conn = db()

            conn.execute("""
                INSERT INTO clicks
                (
                    timestamp,
                    ip,
                    user_agent,
                    referer,
                    ref,
                    consent,
                    event,
                    ip_hash,
                    user_agent_hash,
                    created_at,
                    country,
                    country_code,
                    continent,
                    continent_code,
                    region,
                    region_code,
                    city,
                    postal_code,
                    latitude,
                    longitude,
                    accuracy_radius_km,
                    timezone,
                    network,
                    asn,
                    organization,
                    maxmind_success
                )
                VALUES (
                    ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                    ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                    ?, ?, ?, ?, ?, ?
                )
            """, (
                timestamp,
                "ANONYMIZED",
                "",
                referer,
                ref,
                1,
                event,
                ip_hash,
                ua_hash,
                created_at,

                maxmind.get("country"),
                maxmind.get("country_code"),
                maxmind.get("continent"),
                maxmind.get("continent_code"),
                maxmind.get("region"),
                maxmind.get("region_code"),
                maxmind.get("city"),
                maxmind.get("postal_code"),
                maxmind.get("latitude"),
                maxmind.get("longitude"),
                maxmind.get("accuracy_radius_km"),
                maxmind.get("timezone"),
                maxmind.get("network"),
                maxmind.get("asn"),
                maxmind.get("organization"),
                1 if maxmind.get("maxmind_success") else 0
            ))

            conn.commit()

            self.send_json(
                200,
                {
                    "ok": True,
                    "recorded": True
                }
            )

        except Exception as exc:

            if conn is not None:
                try:
                    conn.rollback()
                except Exception:
                    pass

            print(
                "[ERROR]",
                type(exc).__name__,
                str(exc),
                flush=True
            )

            self.send_json(
                400,
                {
                    "ok": False,
                    "error": "invalid_request"
                }
            )

        finally:

            if conn is not None:
                try:
                    conn.close()
                except Exception:
                    pass


if __name__ == "__main__":

    init_db()

    server = ThreadingHTTPServer(
        (HOST, PORT),
        Handler
    )

    print(
        "=============================================="
    )
    print(
        " SQLITE ANALYTICS SERVER"
    )
    print(
        "=============================================="
    )
    print(
        f"HOST : {HOST}"
    )
    print(
        f"PORT : {PORT}"
    )
    print(
        f"DB   : {DB_PATH}"
    )
    print(
        "API  : /api/click"
    )
    print(
        "HEALTH: /health"
    )
    print(
        "==============================================",
        flush=True
    )

    server.serve_forever()
