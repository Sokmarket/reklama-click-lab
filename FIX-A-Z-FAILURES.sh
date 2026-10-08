#!/data/data/com.termux/files/usr/bin/bash

set -u
set -o pipefail

ROOT="$HOME/reklama-click-lab"
APP="$ROOT/privacy-analytics"
SERVER="$APP/server.py"
DB="$APP/analytics.sqlite3"
RUNTIME="$APP/.runtime"
BACKUP="$ROOT/backups-final"
LOG="$APP/server.log"
CFLOG="$RUNTIME/cloudflared.log"
CFPID="$RUNTIME/cloudflared.pid"
PIDFILE="$RUNTIME/server.pid"

LOCAL="http://127.0.0.1:8080"
STAMP="$(date +%Y%m%d-%H%M%S)"
BK="$BACKUP/fix-$STAMP"

mkdir -p "$RUNTIME" "$BACKUP" "$BK"

echo
echo "============================================================"
echo "       REKLAMA-CLICK-LAB A-Z FAILURE RECOVERY"
echo "============================================================"
echo

OK=0
WARN=0
FAIL=0

ok(){ echo "[OK] $1"; OK=$((OK+1)); }
warn(){ echo "[WARN] $1"; WARN=$((WARN+1)); }
fail(){ echo "[ERROR] $1"; FAIL=$((FAIL+1)); }

# ============================================================
# 1 — BACKUP
# ============================================================

echo "------------------------------------------------------------"
echo "1/12 — BACKUP"
echo "------------------------------------------------------------"

cp -f "$SERVER" "$BK/server.py" 2>/dev/null || true
cp -f "$DB" "$BK/analytics.sqlite3" 2>/dev/null || true
cp -f "$APP/report.html" "$BK/report.html" 2>/dev/null || true
cp -f "$APP/index.html" "$BK/index.html" 2>/dev/null || true

echo "Backup: $BK"
ok "Backup oluşturuldu"

# ============================================================
# 2 — MAXMIND CONFIG NORMALIZE
# ============================================================

echo
echo "------------------------------------------------------------"
echo "2/12 — MAXMIND CONFIG DÜZELTME"
echo "------------------------------------------------------------"

MM_CONFIG="$HOME/.maxmind/config"

if [ ! -f "$MM_CONFIG" ]; then
    fail "MaxMind config yok: $MM_CONFIG"
    exit 1
fi

chmod 600 "$MM_CONFIG" 2>/dev/null || true

# Değeri güvenli biçimde oku.
# Boşluk, CR ve çevresel tırnakları temizle.
MM_ACCOUNT_ID="$(
    sed -n 's/^MM_ACCOUNT_ID[[:space:]]*=[[:space:]]*//p' "$MM_CONFIG" |
    head -1 |
    tr -d '\r' |
    sed 's/^["'\'']//;s/["'\'']$//' |
    tr -d '[:space:]'
)"

MM_LICENSE_KEY="$(
    sed -n 's/^MM_LICENSE_KEY[[:space:]]*=[[:space:]]*//p' "$MM_CONFIG" |
    head -1 |
    tr -d '\r' |
    sed 's/^["'\'']//;s/["'\'']$//' |
    tr -d '[:space:]'
)"

echo "Account ID uzunluğu: ${#MM_ACCOUNT_ID}"
echo "License key uzunluğu: ${#MM_LICENSE_KEY}"

if [ "${#MM_ACCOUNT_ID}" -gt 0 ]; then
    ok "MaxMind Account ID okundu"
else
    fail "MaxMind Account ID boş"
fi

if [ "${#MM_LICENSE_KEY}" -eq 40 ]; then
    ok "MaxMind License Key 40 karakter"
else
    fail "MaxMind License Key uzunluğu 40 değil"
    echo
    echo "Config formatı kontrol ediliyor:"
    sed \
        -e 's/^MM_LICENSE_KEY=.*/MM_LICENSE_KEY=[REDACTED]/' \
        "$MM_CONFIG"
    exit 1
fi

# ============================================================
# 3 — MAXMIND API
# ============================================================

echo
echo "------------------------------------------------------------"
echo "3/12 — MAXMIND API"
echo "------------------------------------------------------------"

MM_OUT="$RUNTIME/maxmind-fix-test.json"
MM_ERR="$RUNTIME/maxmind-fix-error.txt"

HTTP="$(
curl -sS \
    --connect-timeout 15 \
    --max-time 60 \
    -u "$MM_ACCOUNT_ID:$MM_LICENSE_KEY" \
    -A "reklama-click-lab-analytics/1.0" \
    -o "$MM_OUT" \
    -w '%{http_code}' \
    "https://geolite.info/geoip/v2.1/city/8.8.8.8" \
    2>"$MM_ERR" || true
)"

echo "MaxMind HTTP=$HTTP"

if [ "$HTTP" = "200" ]; then
    ok "MaxMind API başarılı"

    python3 - "$MM_OUT" <<'PY'
import json
import sys

p=sys.argv[1]

try:
    d=json.load(open(p))

    c=d.get("country",{})
    loc=d.get("location",{})

    print("Country:", c.get("names",{}).get("en"))
    print("Country Code:", c.get("iso_code"))
    print("Timezone:", loc.get("time_zone"))
    print("Latitude:", loc.get("latitude"))
    print("Longitude:", loc.get("longitude"))

except Exception as e:
    print("JSON parse error:", type(e).__name__)
PY

else
    fail "MaxMind API HTTP=$HTTP"
    cat "$MM_ERR" 2>/dev/null || true
    exit 1
fi

# ============================================================
# 4 — BACKEND SYNTAX
# ============================================================

echo
echo "------------------------------------------------------------"
echo "4/12 — BACKEND SYNTAX"
echo "------------------------------------------------------------"

if python3 -m py_compile "$SERVER"; then
    ok "server.py syntax OK"
else
    fail "server.py syntax hatalı"
    exit 1
fi

# ============================================================
# 5 — ESKİ PROCESSES
# ============================================================

echo
echo "------------------------------------------------------------"
echo "5/12 — ESKİ PROCESS TEMİZLİĞİ"
echo "------------------------------------------------------------"

OLD_PID=""

if [ -f "$PIDFILE" ]; then
    OLD_PID="$(cat "$PIDFILE" 2>/dev/null || true)"
fi

if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    kill "$OLD_PID" 2>/dev/null || true
    sleep 2

    if kill -0 "$OLD_PID" 2>/dev/null; then
        kill -9 "$OLD_PID" 2>/dev/null || true
    fi

    ok "Eski backend kapatıldı"
else
    echo "Aktif eski backend PID bulunmadı."
fi

# Eski cloudflared
if [ -f "$CFPID" ]; then
    OLD_CF="$(cat "$CFPID" 2>/dev/null || true)"

    if [ -n "$OLD_CF" ] && kill -0 "$OLD_CF" 2>/dev/null; then
        kill "$OLD_CF" 2>/dev/null || true
        sleep 2
    fi
fi

pkill -f 'cloudflared tunnel --url' 2>/dev/null || true
sleep 2

rm -f "$CFLOG" "$CFPID"

# ============================================================
# 6 — BACKEND
# ============================================================

echo
echo "------------------------------------------------------------"
echo "6/12 — BACKEND"
echo "------------------------------------------------------------"

(
    cd "$APP" || exit 1

    export MM_ACCOUNT_ID="$MM_ACCOUNT_ID"
    export MM_LICENSE_KEY="$MM_LICENSE_KEY"

    export TRUST_PROXY="1"
    export TRUSTED_PROXY_IPS="127.0.0.1"

    export PYTHONUNBUFFERED="1"

    exec python3 "$SERVER"
) >> "$LOG" 2>&1 &

SERVER_PID=$!

echo "$SERVER_PID" > "$PIDFILE"

sleep 4

if kill -0 "$SERVER_PID" 2>/dev/null; then
    ok "Backend aktif PID=$SERVER_PID"
else
    fail "Backend başlatılamadı"
    tail -80 "$LOG"
    exit 1
fi

# ============================================================
# 7 — LOCAL HEALTH
# ============================================================

echo
echo "------------------------------------------------------------"
echo "7/12 — LOCAL HEALTH"
echo "------------------------------------------------------------"

LOCAL_HEALTH="$RUNTIME/local-health.json"

LOCAL_HTTP="$(
curl -sS \
    --connect-timeout 10 \
    --max-time 20 \
    -o "$LOCAL_HEALTH" \
    -w '%{http_code}' \
    "$LOCAL/health" || true
)"

echo "Local HTTP=$LOCAL_HTTP"

if [ "$LOCAL_HTTP" = "200" ]; then
    ok "Local backend erişilebilir"
    cat "$LOCAL_HEALTH"
else
    fail "Local backend erişilemiyor"
    tail -80 "$LOG"
    exit 1
fi

# ============================================================
# 8 — LOCAL MAXMIND TEST
# ============================================================

echo
echo "------------------------------------------------------------"
echo "8/12 — LOCAL MAXMIND ENRICHMENT"
echo "------------------------------------------------------------"

LOCAL_TEST="$RUNTIME/maxmind-local-test.json"

LOCAL_TEST_HTTP="$(
curl -sS \
    --connect-timeout 10 \
    --max-time 30 \
    -X POST \
    -H 'Content-Type: application/json' \
    -H 'X-Forwarded-For: 8.8.8.8' \
    -d '{"event":"image_click","ref":"FIX-MAXMIND-8.8.8.8","consent":true}' \
    -o "$LOCAL_TEST" \
    -w '%{http_code}' \
    "$LOCAL/api/click" || true
)"

echo "HTTP=$LOCAL_TEST_HTTP"

if [ "$LOCAL_TEST_HTTP" = "200" ]; then
    ok "Local click kaydı başarılı"
    cat "$LOCAL_TEST"
else
    fail "Local MaxMind click testi başarısız"
fi

# ============================================================
# 9 — CLOUDFLARED ORIGIN TEST
# ============================================================

echo
echo "------------------------------------------------------------"
echo "9/12 — CLOUDFLARED"
echo "------------------------------------------------------------"

nohup cloudflared tunnel \
    --url "$LOCAL" \
    --no-autoupdate \
    > "$CFLOG" 2>&1 &

CF_PID=$!

echo "$CF_PID" > "$CFPID"

PUBLIC_URL=""

for i in $(seq 1 30); do
    sleep 2

    PUBLIC_URL="$(
        grep -Eo \
        'https://[-a-zA-Z0-9]+\.trycloudflare\.com' \
        "$CFLOG" 2>/dev/null |
        tail -1
    )"

    [ -n "$PUBLIC_URL" ] && break

    if ! kill -0 "$CF_PID" 2>/dev/null; then
        break
    fi
done

if [ -n "$PUBLIC_URL" ]; then
    ok "Quick Tunnel URL oluşturuldu"
    echo "$PUBLIC_URL"
else
    fail "Quick Tunnel URL alınamadı"
    tail -100 "$CFLOG"
    exit 1
fi

# ============================================================
# 10 — PUBLIC HEALTH
# ============================================================

echo
echo "------------------------------------------------------------"
echo "10/12 — PUBLIC HEALTH"
echo "------------------------------------------------------------"

PUBLIC_HEALTH="$RUNTIME/public-health-fix.json"

PH="$(
curl -sS \
    --connect-timeout 20 \
    --max-time 60 \
    -o "$PUBLIC_HEALTH" \
    -w '%{http_code}' \
    "$PUBLIC_URL/health" \
    2>"$RUNTIME/public-health-fix.err" || true
)"

echo "Public HTTP=$PH"

if [ "$PH" = "200" ]; then
    ok "Public /health başarılı"
    cat "$PUBLIC_HEALTH"
else
    fail "Public /health HTTP=$PH"
    echo
    echo "Cloudflared log:"
    tail -120 "$CFLOG"
    echo
    echo "Backend log:"
    tail -80 "$LOG"
fi

# ============================================================
# 11 — PUBLIC CLICK
# ============================================================

echo
echo "------------------------------------------------------------"
echo "11/12 — PUBLIC CLICK + DATABASE"
echo "------------------------------------------------------------"

PUBLIC_CLICK="$RUNTIME/public-click-fix.json"

PC="$(
curl -sS \
    --connect-timeout 20 \
    --max-time 60 \
    -X POST \
    -H 'Content-Type: application/json' \
    -d '{"event":"image_click","ref":"FIX-PUBLIC-FINAL","consent":true}' \
    -o "$PUBLIC_CLICK" \
    -w '%{http_code}' \
    "$PUBLIC_URL/api/click" \
    2>"$RUNTIME/public-click-fix.err" || true
)"

echo "Public click HTTP=$PC"

if [ "$PC" = "200" ]; then
    ok "Public click başarılı"
    cat "$PUBLIC_CLICK"
else
    fail "Public click başarısız HTTP=$PC"
    cat "$RUNTIME/public-click-fix.err" 2>/dev/null || true
fi

sleep 2

echo
echo "Son database kayıtları:"

sqlite3 "$DB" \
"SELECT id,timestamp,ip,ref,event,country,country_code,timezone,asn,organization,maxmind_success FROM clicks ORDER BY id DESC LIMIT 8;" \
2>/dev/null || true

# ============================================================
# 12 — RAW IP EXACT DIAGNOSTIC
# ============================================================

echo
echo "------------------------------------------------------------"
echo "12/12 — RAW IP EXACT DIAGNOSTIC"
echo "------------------------------------------------------------"

RAW_COUNT="$(
sqlite3 "$DB" \
"SELECT COUNT(*) FROM clicks WHERE ip IS NOT NULL AND ip NOT IN ('ANONYMIZED','');" \
2>/dev/null || echo 0
)"

echo "Raw IP count=$RAW_COUNT"

if [ "$RAW_COUNT" = "0" ]; then
    ok "Raw IP yok"
else
    warn "Raw IP içeren kayıt bulundu: $RAW_COUNT"

    echo
    echo "Raw IP kayıtlarının ID/ref bilgisi:"
    sqlite3 "$DB" \
    "SELECT id,timestamp,ref,event,ip FROM clicks WHERE ip IS NOT NULL AND ip NOT IN ('ANONYMIZED','');" \
    2>/dev/null || true

    echo
    echo "Bu kontrol mevcut eski veriyi gösteriyor olabilir."
    echo "Yeni backend testleri raw IP yazmamalıdır."
fi

# ============================================================
# FINAL
# ============================================================

echo
echo "============================================================"
echo "                    FINAL RESULT"
echo "============================================================"

echo "OK    : $OK"
echo "WARN  : $WARN"
echo "ERROR : $FAIL"
echo
echo "Backend PID:"
echo "$SERVER_PID"
echo
echo "Cloudflared PID:"
echo "$CF_PID"
echo
echo "PUBLIC URL:"
echo "$PUBLIC_URL"
echo
echo "Backup:"
echo "$BK"
echo
echo "Cloudflared log:"
echo "$CFLOG"
echo
echo "Backend log:"
echo "$LOG"
echo

if [ "$FAIL" -eq 0 ]; then
    echo "============================================================"
    echo " A-Z RECOVERY BAŞARILI"
    echo "============================================================"
else
    echo "============================================================"
    echo " A-Z RECOVERY TAM BAŞARILI DEĞİL"
    echo " Hatalar yukarıdaki loglarda."
    echo "============================================================"
fi
