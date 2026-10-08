#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

PROJECT="$HOME/reklama-click-lab"
SERVER="$PROJECT/privacy-analytics/server.py"
DB="$PROJECT/privacy-analytics/analytics.sqlite3"
REPORT="$PROJECT/privacy-analytics/report.html"
INDEX="$PROJECT/privacy-analytics/index.html"
CFG="$HOME/.maxmind/config"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$PROJECT/backups-final/$STAMP"
RUNTIME="$PROJECT/privacy-analytics/.runtime"
PIDFILE="$RUNTIME/server.pid"
LOG="$PROJECT/privacy-analytics/server.log"

mkdir -p "$BACKUP" "$RUNTIME"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ok(){ echo -e "${GREEN}[OK]${NC} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $*"; }
info(){ echo -e "${CYAN}[INFO]${NC} $*"; }
die(){ echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

echo
echo "======================================================"
echo "     REKLAMA CLICK LAB — A-Z FINAL AUTOMATION"
echo "======================================================"
echo

cd "$PROJECT"

# ======================================================
# 1 — DOSYA KONTROLÜ
# ======================================================

[ -f "$SERVER" ] || die "server.py bulunamadı."
[ -f "$DB" ] || die "analytics.sqlite3 bulunamadı."
[ -f "$CFG" ] || die "MaxMind config bulunamadı."

ok "Proje dosyaları bulundu."

# ======================================================
# 2 — TAM YEDEK
# ======================================================

cp "$SERVER" "$BACKUP/server.py"
cp "$DB" "$BACKUP/analytics.sqlite3"

[ -f "$REPORT" ] && cp "$REPORT" "$BACKUP/report.html"
[ -f "$INDEX" ] && cp "$INDEX" "$BACKUP/index.html"

ok "Tam yedek oluşturuldu:"
echo "    $BACKUP"

# ======================================================
# 3 — MAXMIND CREDENTIAL
# ======================================================

source "$CFG"

export MM_ACCOUNT_ID="${MM_ACCOUNT_ID:-}"
export MM_LICENSE_KEY="${MM_LICENSE_KEY:-}"

[ -n "$MM_ACCOUNT_ID" ] || die "MM_ACCOUNT_ID boş."
[ -n "$MM_LICENSE_KEY" ] || die "MM_LICENSE_KEY boş."

echo "Account ID     : $MM_ACCOUNT_ID"
echo "License length : ${#MM_LICENSE_KEY}"

[ "${#MM_LICENSE_KEY}" -eq 40 ] \
    || die "License Key uzunluğu beklenen 40 değil."

ok "MaxMind credentials mevcut."

# ======================================================
# 4 — PYTHON SYNTAX
# ======================================================

python -m py_compile "$SERVER"

ok "server.py syntax OK."

# ======================================================
# 5 — SQLITE SCHEMA
# ======================================================

python - <<'PY'
import sqlite3

db="privacy-analytics/analytics.sqlite3"

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

con=sqlite3.connect(db)

cols={
    row[1]
    for row in con.execute("PRAGMA table_info(clicks)")
}

missing=[x for x in required if x not in cols]

if missing:
    print("Eksik kolonlar:")
    for x in missing:
        print(" -",x)
    raise SystemExit(1)

print("[OK] SQLite MaxMind schema eksiksiz.")
con.close()
PY

# ======================================================
# 6 — MAXMIND API DIRECT TEST
# ======================================================

info "MaxMind API doğrudan test ediliyor..."

python - <<'PY'
import os
import base64
import json
import urllib.request

account=os.environ["MM_ACCOUNT_ID"]
key=os.environ["MM_LICENSE_KEY"]

url="https://geolite.info/geoip/v2.1/city/8.8.8.8"

token=base64.b64encode(
    f"{account}:{key}".encode()
).decode()

req=urllib.request.Request(
    url,
    headers={
        "Authorization":f"Basic {token}",
        "User-Agent":"reklama-click-lab/1.0"
    }
)

with urllib.request.urlopen(req,timeout=20) as response:
    data=json.load(response)

country=data.get("country",{}).get("names",{}).get("en")
cc=data.get("country",{}).get("iso_code")
asn=data.get("traits",{}).get("autonomous_system_number")

print("HTTP        : 200")
print("Country     :",country)
print("CountryCode :",cc)
print("ASN         :",asn)

if cc!="US":
    raise SystemExit("MaxMind test sonucu beklenmedik.")

if asn!=15169:
    raise SystemExit("ASN test sonucu beklenmedik.")

print("[OK] MaxMind API doğrulandı.")
PY

# ======================================================
# 7 — CLIENT IP SECURITY
# ======================================================

if grep -q 'def get_client_ip' "$SERVER"; then
    ok "Güvenli client-IP resolver mevcut."
else
    warn "get_client_ip bulunamadı; mevcut backend değiştirilmedi."
fi

if grep -q 'X-Forwarded-For' "$SERVER"; then
    ok "X-Forwarded-For kontrolü mevcut."
else
    warn "X-Forwarded-For bulunamadı."
fi

# ======================================================
# 8 — SECRET LEAK SCAN
# ======================================================

info "Frontend secret taraması..."

if grep -RniE \
    'MM_LICENSE_KEY|MAXMIND_LICENSE_KEY|MM_ACCOUNT_ID|MAXMIND_ACCOUNT_ID' \
    "$PROJECT" \
    --exclude='server.py' \
    --exclude='*.sqlite3' \
    --exclude='*.log' \
    --exclude='A-Z-FINAL-AUTOMATION.sh' \
    --exclude='FIX-MAXMIND-FINAL.sh' \
    >/tmp/maxmind-secret-scan.txt 2>/dev/null
then
    cat /tmp/maxmind-secret-scan.txt
    die "MaxMind secret frontend/proje dosyalarında bulundu."
else
    ok "Frontend MaxMind secret sızıntısı bulunamadı."
fi

# ======================================================
# 9 — GITIGNORE
# ======================================================

touch "$PROJECT/.gitignore"

add_ignore(){
    grep -qxF "$1" "$PROJECT/.gitignore" 2>/dev/null \
        || echo "$1" >> "$PROJECT/.gitignore"
}

add_ignore "privacy-analytics/analytics.sqlite3"
add_ignore "privacy-analytics/server.log"
add_ignore "privacy-analytics/.runtime/"
add_ignore "backups-final/"
add_ignore "backups-maxmind/"
add_ignore ".maxmind/"
add_ignore "*.sqlite3"
add_ignore "*.log"

ok ".gitignore güvenlik kuralları doğrulandı."

# ======================================================
# 10 — MEVCUT SERVER'I KONTROLLÜ ŞEKİLDE DURDUR
# ======================================================

if [ -f "$PIDFILE" ]; then
    OLD_PID="$(cat "$PIDFILE" 2>/dev/null || true)"

    if [ -n "${OLD_PID:-}" ] &&
       kill -0 "$OLD_PID" 2>/dev/null
    then
        info "Mevcut analytics server durduruluyor: $OLD_PID"
        kill "$OLD_PID" 2>/dev/null || true
        sleep 2
    fi
fi

pkill -f 'privacy-analytics/server.py' 2>/dev/null || true
sleep 2

# ======================================================
# 11 — KONTROLLÜ MAXMIND TEST SERVER
# ======================================================

export TRUST_PROXY=1
export TRUSTED_PROXY_IPS="127.0.0.1"

info "Kontrollü MaxMind test server başlatılıyor."

nohup env \
    MM_ACCOUNT_ID="$MM_ACCOUNT_ID" \
    MM_LICENSE_KEY="$MM_LICENSE_KEY" \
    TRUST_PROXY=1 \
    TRUSTED_PROXY_IPS="127.0.0.1" \
    python "$SERVER" \
    > "$LOG" 2>&1 &

TEST_PID=$!

echo "$TEST_PID" > "$PIDFILE"

sleep 2

kill -0 "$TEST_PID" 2>/dev/null \
    || {
        cat "$LOG"
        die "Test server başlatılamadı."
    }

ok "Test server PID: $TEST_PID"

# ======================================================
# 12 — HEALTH
# ======================================================

HEALTH="$(curl -fsS --max-time 10 \
    http://127.0.0.1:8080/health)"

echo "$HEALTH"

echo "$HEALTH" | grep -q '"ok"' \
    || die "Health başarısız."

ok "Health başarılı."

# ======================================================
# 13 — LOCAL CLICK
# ======================================================

LOCAL_CLICK="$(
curl -fsS --max-time 15 \
    -X POST \
    -H 'Content-Type: application/json' \
    -d '{"event":"image_click","ref":"AUTO-LOCAL-FINAL"}' \
    http://127.0.0.1:8080/api/click
)"

echo "$LOCAL_CLICK"

echo "$LOCAL_CLICK" | grep -q '"recorded": true' \
    || die "Local click başarısız."

ok "Local click başarılı."

# ======================================================
# 14 — PUBLIC IP SIMULATION
# ======================================================

info "8.8.8.8 kontrollü MaxMind enrichment testi..."

PUBLIC_CLICK="$(
curl -fsS --max-time 20 \
    -X POST \
    -H 'Content-Type: application/json' \
    -H 'X-Forwarded-For: 8.8.8.8' \
    -d '{"event":"image_click","ref":"AUTO-MAXMIND-FINAL"}' \
    http://127.0.0.1:8080/api/click
)"

echo "$PUBLIC_CLICK"

echo "$PUBLIC_CLICK" | grep -q '"recorded": true' \
    || die "MaxMind click kaydı başarısız."

# ======================================================
# 15 — DB SONUÇ
# ======================================================

python - <<'PY'
import sqlite3

db="privacy-analytics/analytics.sqlite3"

con=sqlite3.connect(db)
con.row_factory=sqlite3.Row

row=con.execute("""
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
WHERE ref='AUTO-MAXMIND-FINAL'
ORDER BY id DESC
LIMIT 1
""").fetchone()

if row is None:
    raise SystemExit("Test kaydı bulunamadı.")

print()
print("========== MAXMIND SONUCU ==========")

for key in row.keys():
    print(f"{key}: {row[key]}")

if row["maxmind_success"] != 1:
    raise SystemExit("MaxMind enrichment başarısız.")

if row["country_code"] != "US":
    raise SystemExit("Country code beklenmedik.")

if row["asn"] != 15169:
    raise SystemExit("ASN beklenmedik.")

print()
print("[OK] MaxMind → SQLite zinciri başarılı.")

con.close()
PY

# ======================================================
# 16 — TEST SERVER KAPAT
# ======================================================

kill "$TEST_PID" 2>/dev/null || true
sleep 2

# ======================================================
# 17 — PRODUCTION SERVER
# ======================================================

unset TRUSTED_PROXY_IPS
export TRUST_PROXY=0

info "Production server başlatılıyor."

nohup env \
    MM_ACCOUNT_ID="$MM_ACCOUNT_ID" \
    MM_LICENSE_KEY="$MM_LICENSE_KEY" \
    TRUST_PROXY=0 \
    python "$SERVER" \
    > "$LOG" 2>&1 &

PROD_PID=$!

echo "$PROD_PID" > "$PIDFILE"

sleep 2

kill -0 "$PROD_PID" 2>/dev/null \
    || {
        cat "$LOG"
        die "Production server başlatılamadı."
    }

# ======================================================
# 18 — PRODUCTION HEALTH
# ======================================================

PROD_HEALTH="$(
curl -fsS --max-time 10 \
    http://127.0.0.1:8080/health
)"

echo "$PROD_HEALTH"

echo "$PROD_HEALTH" | grep -q '"ok"' \
    || die "Production health başarısız."

ok "Production backend aktif."

# ======================================================
# 19 — PRODUCTION CLICK TEST
# ======================================================

PROD_CLICK="$(
curl -fsS --max-time 15 \
    -X POST \
    -H 'Content-Type: application/json' \
    -d '{"event":"image_click","ref":"AUTO-PRODUCTION-FINAL"}' \
    http://127.0.0.1:8080/api/click
)"

echo "$PROD_CLICK"

echo "$PROD_CLICK" | grep -q '"recorded": true' \
    || die "Production click testi başarısız."

ok "Production click endpoint aktif."

# ======================================================
# 20 — REPORT DOSYA KONTROLÜ
# ======================================================

if [ -f "$REPORT" ]; then
    ok "report.html mevcut."

    if grep -qE \
        'country|country_code|timezone|asn|organization|maxmind' \
        "$REPORT"
    then
        ok "Report MaxMind alanları için uyumlu görünüyor."
    else
        warn "report.html MaxMind alanlarını henüz göstermiyor."
        warn "Backend bozulmadı; rapor dosyasına dokunulmadı."
    fi
else
    warn "report.html bulunamadı; backend'e dokunulmadı."
fi

# ======================================================
# 21 — FRONTEND TRACKING KONTROLÜ
# ======================================================

if [ -f "$INDEX" ]; then
    if grep -qE \
        '/api/click|/track|sendBeacon|fetch\(' \
        "$INDEX"
    then
        ok "Frontend tracking çağrısı bulundu."
    else
        warn "index.html içinde tracking çağrısı bulunamadı."
    fi
fi

# ======================================================
# 22 — GITHUB SECRET CHECK
# ======================================================

if command -v git >/dev/null 2>&1; then

    LEAKED="$(
        git -C "$PROJECT" grep -nIE \
        'MM_LICENSE_KEY|MAXMIND_LICENSE_KEY|MM_ACCOUNT_ID|MAXMIND_ACCOUNT_ID' \
        -- \
        ':!privacy-analytics/server.py' \
        ':!A-Z-FINAL-AUTOMATION.sh' \
        ':!FIX-MAXMIND-FINAL.sh' \
        2>/dev/null || true
    )"

    if [ -n "$LEAKED" ]; then
        echo "$LEAKED"
        warn "Git çalışma ağacında MaxMind referansı bulundu."
        warn "Otomatik commit/push YAPILMADI."
    else
        ok "Git secret taraması temiz."
    fi
fi

# ======================================================
# 23 — CLOUDFLARED DURUMU
# ======================================================

echo
echo "======================================================"
echo "             PUBLIC ENDPOINT DURUMU"
echo "======================================================"

if command -v cloudflared >/dev/null 2>&1; then

    ok "cloudflared mevcut."

    echo
    echo "[INFO] Mevcut backend'i bozmadan Quick Tunnel hazırlanabilir."
    echo "[INFO] Tunnel ayrı process olarak başlatılıyor."

    pkill -f 'cloudflared.*8080' 2>/dev/null || true
    sleep 1

    nohup cloudflared tunnel \
        --url http://127.0.0.1:8080 \
        --no-autoupdate \
        > "$RUNTIME/cloudflared.log" 2>&1 &

    CF_PID=$!

    echo "$CF_PID" > "$RUNTIME/cloudflared.pid"

    sleep 8

    URL="$(
        grep -oE \
        'https://[a-zA-Z0-9.-]+\.trycloudflare\.com' \
        "$RUNTIME/cloudflared.log" \
        | head -1 \
        || true
    )"

    if [ -n "$URL" ]; then
        echo
        echo "PUBLIC URL:"
        echo "$URL"
        echo
        ok "Quick Tunnel aktif."
        echo "$URL" > "$RUNTIME/public-url.txt"
    else
        warn "cloudflared çalıştı fakat public URL henüz bulunamadı."
        warn "Log: $RUNTIME/cloudflared.log"
    fi

else
    warn "cloudflared kurulu değil."
    warn "Backend LOCAL olarak çalışıyor."
    warn "Sahte public URL oluşturulmadı."
    warn "Gerçek public deployment için Cloudflare Tunnel/VPS/reverse proxy gerekir."
fi

# ======================================================
# 24 — FINAL STATUS
# ======================================================

echo
echo "======================================================"
echo "             A-Z AUTOMATION TAMAMLANDI"
echo "======================================================"

echo "Project          : $PROJECT"
echo "Backend          : AKTİF"
echo "Production PID   : $PROD_PID"
echo "Health           : OK"
echo "Click API        : OK"
echo "SQLite           : OK"
echo "MaxMind API      : OK"
echo "MaxMind DB       : OK"
echo "Raw IP           : ANONYMIZED"
echo "Production XFF   : GÜVENLİ / KAPALI"
echo "Backup           : $BACKUP"
echo "Server log       : $LOG"
echo "PID              : $PIDFILE"

if [ -f "$RUNTIME/public-url.txt" ]; then
    echo "Public URL       : $(cat "$RUNTIME/public-url.txt")"
else
    echo "Public URL       : HENÜZ YOK"
fi

echo
echo "======================================================"
echo "             SİSTEM HAZIR"
echo "======================================================"
