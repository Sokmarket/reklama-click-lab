#!/usr/bin/env python3

import os
import json
import urllib.request
import base64
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse

ACCOUNT_ID = os.environ.get("MAXMIND_ACCOUNT_ID", "")
LICENSE_KEY = os.environ.get("MAXMIND_LICENSE_KEY", "")

HOST = "127.0.0.1"
PORT = 8787

def get_client_ip(handler):
    # Proxy/CDN arkasındaysan bu header'ları yalnızca güvendiğin
    # proxy/CDN tarafından üretildiğinden emin ol.
    forwarded = handler.headers.get("X-Forwarded-For", "")
    if forwarded:
        return forwarded.split(",")[0].strip()

    real_ip = handler.headers.get("X-Real-IP", "")
    if real_ip:
        return real_ip.strip()

    return handler.client_address[0]

def maxmind_lookup(ip):
    if not ACCOUNT_ID or not LICENSE_KEY:
        return {
            "success": False,
            "error": "MAXMIND_CREDENTIALS_MISSING"
        }

    url = "https://geolite.info/geoip/v2.1/city/" + ip

    token = base64.b64encode(
        f"{ACCOUNT_ID}:{LICENSE_KEY}".encode()
    ).decode()

    request = urllib.request.Request(
        url,
        headers={
            "Authorization": f"Basic {token}",
            "Accept": "application/json",
            "User-Agent": "reklama-click-lab/1.0"
        }
    )

    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            data = json.loads(response.read().decode())

        country = data.get("country", {})
        continent = data.get("continent", {})
        city = data.get("city", {})
        location = data.get("location", {})
        traits = data.get("traits", {})
        subdivisions = data.get("subdivisions", [])

        return {
            "success": True,
            "ip": traits.get("ip_address", ip),
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

    except Exception as e:
        return {
            "success": False,
            "ip": ip,
            "error": str(e)
        }

class Handler(BaseHTTPRequestHandler):

    def send_json(self, status, payload):
        body = json.dumps(
            payload,
            ensure_ascii=False,
            indent=2
        ).encode()

        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):

        parsed = urlparse(self.path)

        if parsed.path == "/health":
            self.send_json(200, {
                "service": "maxmind-ip-enrichment",
                "status": "ok"
            })
            return

        if parsed.path == "/api/maxmind":
            ip = get_client_ip(self)
            result = maxmind_lookup(ip)

            result["request"] = {
                "ip_source": "server_request"
            }

            self.send_json(
                200 if result.get("success") else 502,
                result
            )
            return

        self.send_json(404, {
            "error": "NOT_FOUND"
        })

    def log_message(self, format, *args):
        print("[HTTP]", format % args)

print("========================================")
print(" MAXMIND VISITOR IP ENRICHMENT SERVER")
print("========================================")
print(f"Listening: http://{HOST}:{PORT}")
print()
print("Endpoints:")
print("  /health")
print("  /api/maxmind")
print()

HTTPServer((HOST, PORT), Handler).serve_forever()
