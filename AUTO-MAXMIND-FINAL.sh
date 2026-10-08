#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

PROJECT="$HOME/reklama-click-lab"
SERVER="$PROJECT/privacy-analytics/server.py"
DB="$PROJECT/privacy-analytics/analytics.sqlite3"
CFG="$HOME/.maxmind/config"
STAMP="$(date +%Y%m%d-%H%M%S)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ok(){ echo -e "${GREEN}[OK]${NC} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $*"; }
die(){ echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
info(){ echo -e "${CYAN}[INFO]${NC} $*"; }

echo
echo "======================================================"
echo "   REKLAMA CLICK LAB — MAXMIND A-Z AUTOMATION"
echo "======================================================"
echo

cd "$PROJECT" || die "Proje bulunamadı: $PROJECT"
[ -f "$SERVER" ] || die "server.py bulunamadı"
[ -f "$DB" ] || die "analytics.sqlite3 bulunamadı"
[ -f "$CFG" ] || die "MaxMind config bulunamadı: $CFG"

# ------------------------------------------------------
# 1. MaxMind credentials
# ------------------------------------------------------
source "$CFG"

export MM_ACCOUNT_ID="${MM_ACCOUNT_ID:-}"
export MM_LICENSE_KEY="${MM_LICENSE_KEY:-}"

[ -n "$MM_ACCOUNT_ID" ] || die "MM_ACCOUNT_ID boş"
[ -n "$MM_LICENSE_KEY" ] || die "MM_LICENSE_KEY boş"

echo "Account ID       : $MM_ACCOUNT_ID"
echo "License length   : ${#MM_LICENSE_KEY}"

[ "$MM_ACCOUNT_ID" = "1424720" ] || warn "Account ID beklenenden farklı."
[ "${#MM_LICENSE_KEY}" -eq 40 ] || die "License Key uzunluğu 40 değil."

# ------------------------------------------------------
# 2. Backup
# ------------------------------------------------------
BACKUP_DIR="$PROJECT/backups-maxmind"
mkdir -p "$BACKUP_DIR"

cp "$SERVER" "$BACKUP_DIR/server.py.$STAMP"
cp "$DB" "$BACKUP_DIR/analytics.sqlite3.$STAMP"

ok "Server ve SQLite yedeği oluşturuldu."

# ------------------------------------------------------
# 3. Python syntax
# ------------------------------------------------------
python -m py_compile "$SERVER"
ok "Mevcut server.py syntax kontrolü geçti."

# ------------------------------------------------------
# 4. Secure X-Forwarded-For handling
# ------------------------------------------------------
export SERVER_PATH="$SERVER"

python - <<'PY'
from pathlib import Path
import os
import re

p = Path(os.environ["SERVER_PATH"])
s = p.read_text()

marker = "# === SECURE CLIENT IP START ==="

if marker not in s:
    helper = r'''
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

'''

    # Insert before Handler class.
    m = re.search(r'(?m)^class Handler\b', s)
    if not m:
        raise SystemExit("Handler class bulunamadı; otomatik patch durduruldu.")

    s = s[:m.start()] + helper + s[m.start():]

# Replace the old insecure X-Forwarded-For block.
old_pattern = re.compile(
    r'client_ip\s*=\s*\(\s*'
    r'self\.headers\.get\(\s*'
    r'"X-Forwarded-For"\s*,\s*'
    r'""\s*'
    r'\)\.split\(","\)\[0\]\.strip\(\)\s*'
    r'or\s*self\.client_address\[0\]\s*'
    r'\)',
    re.S
)

s2, n = old_pattern.subn(
    "client_ip = get_client_ip(self)",
    s
)

if n:
    s = s2
    print("[OK] Güvensiz X-Forwarded-For kullanımı düzeltildi.")
else:
    if "client_ip = get_client_ip(self)" in s:
        print("[OK] Güvenli client IP fonksiyonu zaten aktif.")
    else:
        print("[WARN] Eski client_ip bloğu bulunamadı; mevcut yapı korunuyor.")

p.write_text(s)
PY

python -m py_compile "$SERVER"
ok "Güvenli IP çözümleme patch'i syntax kontrolünden geçti."

# ------------------------------------------------------
# 5. SQLite schema verification
# ------------------------------------------------------
python - <<'PY'
import sqlite3

db = "privacy-analytics/analytics.sqlite3"

required = [
    "country",
    "country_code",
    "continent",
    "continent_code",
    "region",
    "region_code",
    "city",
    "postal_code",
    "latitude",
    "longitude",
    "accuracy_radius_km",
    "timezone",
    "network",
    "asn",
    "organization",
    "maxmind_success",
]

con = sqlite3.connect(db)
cols = {x[1] for x in con.execute("PRAGMA table_info(clicks)")}

missing = [x for x in required if x not in cols]

if missing:
    print("Eksik SQLite kolonları:", ", ".join(missing))
    con.close()
    raise SystemExit(1)

print("[OK] Tüm MaxMind SQLite kolonları mevcut.")
con.close()
PY

# ------------------------------------------------------
# 6. MaxMind direct API test
# ------------------------------------------------------
info "MaxMind doğrudan API testi: 8.8.8.8"

python - <<'PY'
import os
import base64
import urllib.request
import json

account = os.environ["MM_ACCOUNT_ID"]
key = os.environ["MM_LICENSE_KEY"]

url = "https://geolite.info/geoip/v2.1/city/8.8.8.8"

token = base64.b64encode(
    f"{account}:{key}".encode()
).decode()

req = urllib.request.Request(
    url,
    headers={
        "Authorization": f"Basic {token}",
        "User-Agent": "reklama-click-lab-analytics/1.0"
    }
)

with urllib.request.urlopen(req, timeout=15) as r:
    data = json.load(r)

country = data.get("country", {}).get("names", {}).get("en")
cc = data.get("country", {}).get("iso_code")
asn = data.get("traits", {}).get("autonomous_system_number")
org = data.get("traits", {}).get("organization")

print("[OK] MaxMind HTTP 200")
print("Country      :", country)
print("Country code :", cc)
print("ASN          :", asn)
print("Organization :", org)

if cc != "US":
    raise SystemExit("MaxMind test sonucu beklenmedik.")
PY

# ------------------------------------------------------
# 7. Stop old analytics server only
# ------------------------------------------------------
pkill -f 'privacy-analytics/server.py' 2>/dev/null || true
sleep 1

# ------------------------------------------------------
# 8. Start server
# ------------------------------------------------------
export TRUST_PROXY=0
unset TRUSTED_PROXY_IPS || true

info "Analytics server başlatılıyor..."

nohup python "$SERVER" \
    > "$PROJECT/privacy-analytics/server.log" 2>&1 &

SERVER_PID=$!

mkdir -p "$PROJECT/privacy-analytics/.runtime"
echo "$SERVER_PID" > "$PROJECT/privacy-analytics/.runtime/server.pid"

sleep 2

if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo
    cat "$PROJECT/privacy-analytics/server.log"
    die "Analytics server başlatılamadı."
fi

ok "Server PID: $SERVER_PID"

# ------------------------------------------------------
# 9. Health test
# ------------------------------------------------------
HEALTH="$(curl -fsS --max-time 10 http://127.0.0.1:8080/health)"

echo "$HEALTH"

echo "$HEALTH" | grep -q '"ok"' \
    || die "Health endpoint başarısız."

ok "Health endpoint çalışıyor."

# ------------------------------------------------------
# 10. Normal localhost click test
# ------------------------------------------------------
CLICK="$(curl -fsS --max-time 15 \
    -X POST \
    -H 'Content-Type: application/json' \
    -d '{"event":"image_click","ref":"AUTO-LOCAL"}' \
    http://127.0.0.1:8080/api/click)"

echo "$CLICK"

echo "$CLICK" | grep -q '"recorded": true' \
    || die "Local click kaydı başarısız."

ok "Local click kaydı başarılı."

# ------------------------------------------------------
# 11. Controlled public-IP MaxMind integration test
# ------------------------------------------------------
info "Kontrollü MaxMind IP testi: 8.8.8.8"

# TRUST_PROXY sadece bu kontrollü test sırasında açık.
export TRUST_PROXY=1
export TRUSTED_PROXY_IPS="127.0.0.1"

TEST_CLICK="$(curl -fsS --max-time 20 \
    -X POST \
    -H 'Content-Type: application/json' \
    -H 'X-Forwarded-For: 8.8.8.8' \
    -d '{"event":"image_click","ref":"AUTO-MAXMIND"}' \
    http://127.0.0.1:8080/api/click)"

echo "$TEST_CLICK"

echo "$TEST_CLICK" | grep -q '"recorded": true' \
    || die "MaxMind click testi kayıt başarısız."

# Güvenli varsayılanı geri getir.
export TRUST_PROXY=0
unset TRUSTED_PROXY_IPS

# ------------------------------------------------------
# 12. DB verification
# ------------------------------------------------------
python - <<'PY'
import sqlite3

db = "privacy-analytics/analytics.sqlite3"

con = sqlite3.connect(db)
con.row_factory = sqlite3.Row

row = con.execute("""
SELECT
    id,
    ref,
    ip,
    country,
    country_code,
    city,
    timezone,
    asn,
    organization,
    maxmind_success
FROM clicks
ORDER BY id DESC
LIMIT 1
""").fetchone()

if not row:
    raise SystemExit("Son click kaydı bulunamadı.")

print()
print("===== SON CLICK =====")

for k in row.keys():
    print(f"{k}: {row[k]}")

if row["ref"] == "AUTO-MAXMIND":
    if row["maxmind_success"] != 1:
        raise SystemExit("MaxMind enrichment başarısız.")
    if row["country_code"] != "US":
        raise SystemExit("MaxMind country_code beklenmedik.")
    if row["asn"] != 15169:
        raise SystemExit("MaxMind ASN beklenmedik.")

print()
print("[OK] SQLite + MaxMind enrichment doğrulandı.")

con.close()
PY

# ------------------------------------------------------
# 13. Security verification
# ------------------------------------------------------
grep -n "client_ip = get_client_ip(self)" "$SERVER" \
    >/dev/null \
    && ok "Secure client IP resolver aktif." \
    || warn "client_ip resolver otomatik doğrulanamadı."

grep -n "MAXMIND_LICENSE\|MM_LICENSE_KEY" "$PROJECT/privacy-analytics/index.html" \
    >/dev/null 2>&1 \
    && die "UYARI: License Key frontend dosyasına sızmış!" \
    || ok "MaxMind License Key frontend'de bulunamadı."

# ------------------------------------------------------
# 14. Final status
# ------------------------------------------------------
echo
echo "======================================================"
echo "              AUTOMATION TAMAMLANDI"
echo "======================================================"
echo
echo "Project : $PROJECT"
echo "Server  : $SERVER"
echo "DB      : $DB"
echo "PID     : $SERVER_PID"
echo "URL     : http://127.0.0.1:8080"
echo
echo "Health:"
curl -fsS http://127.0.0.1:8080/health
echo
echo
echo "Backup : $BACKUP_DIR"
echo "Log    : $PROJECT/privacy-analytics/server.log"
echo
echo "MaxMind : AKTİF"
echo "Raw IP  : ANONYMIZED"
echo "XFF     : Güvenli mod (varsayılan kapalı)"
echo
echo "======================================================"
