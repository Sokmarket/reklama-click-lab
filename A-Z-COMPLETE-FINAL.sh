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
REPORT="$ROOT/A-Z-FINAL-REPORT.txt"

HOST="127.0.0.1"
PORT="8080"
LOCAL="http://127.0.0.1:${PORT}"

mkdir -p "$RUNTIME" "$BACKUP"

exec > >(tee -a "$REPORT") 2>&1

echo
echo "============================================================"
echo "        REKLAMA-CLICK-LAB A → Z FINAL AUTOMATION"
echo "============================================================"
date
echo

OK=0
WARN=0
FAIL=0

ok() {
    echo "[OK] $1"
    OK=$((OK+1))
}

warn() {
    echo "[WARN] $1"
    WARN=$((WARN+1))
}

fail() {
    echo "[ERROR] $1"
    FAIL=$((FAIL+1))
}

section() {
    echo
    echo "------------------------------------------------------------"
    echo "$1"
    echo "------------------------------------------------------------"
}

# ------------------------------------------------------------
# 0 — TEMEL DOSYA KONTROLÜ
# ------------------------------------------------------------

section "0/15 — Proje ve dosya kontrolü"

if [ ! -d "$ROOT" ]; then
    fail "Proje dizini bulunamadı: $ROOT"
    exit 1
fi

if [ ! -f "$SERVER" ]; then
    fail "Backend bulunamadı: $SERVER"
    exit 1
fi

if [ ! -f "$DB" ]; then
    warn "SQLite veritabanı henüz bulunamadı: $DB"
fi

ok "Proje dizini mevcut"
ok "Backend mevcut"

echo "Python:"
python3 --version 2>&1 || true

echo "Cloudflared:"
if command -v cloudflared >/dev/null 2>&1; then
    cloudflared --version 2>&1 || true
    ok "cloudflared mevcut"
else
    fail "cloudflared bulunamadı"
    exit 1
fi

# ------------------------------------------------------------
# 1 — BACKUP
# ------------------------------------------------------------

section "1/15 — Güvenli backup"

STAMP="$(date +%Y%m%d-%H%M%S)"
BK="$BACKUP/$STAMP"

mkdir -p "$BK"

cp -f "$SERVER" "$BK/server.py" 2>/dev/null || true
cp -f "$DB" "$BK/analytics.sqlite3" 2>/dev/null || true
cp -f "$APP/report.html" "$BK/report.html" 2>/dev/null || true
cp -f "$APP/index.html" "$BK/index.html" 2>/dev/null || true

echo "Backup: $BK"
ok "Backup oluşturuldu"

# ------------------------------------------------------------
# 2 — MAXMIND CONFIG
# ------------------------------------------------------------

section "2/15 — MaxMind yapılandırması"

MM_CONFIG="$HOME/.maxmind/config"

if [ ! -f "$MM_CONFIG" ]; then
    fail "MaxMind config bulunamadı: $MM_CONFIG"
    exit 1
fi

if grep -q '^MM_ACCOUNT_ID=' "$MM_CONFIG" &&
   grep -q '^MM_LICENSE_KEY=' "$MM_CONFIG"; then
    ok "MaxMind credentials bulundu"
else
    fail "MaxMind credentials eksik"
    exit 1
fi

chmod 600 "$MM_CONFIG" 2>/dev/null || true

# Anahtarı ekrana BASMA
MM_ACCOUNT_ID="$(grep '^MM_ACCOUNT_ID=' "$MM_CONFIG" | head -1 | cut -d= -f2-)"
MM_LICENSE_KEY="$(grep '^MM_LICENSE_KEY=' "$MM_CONFIG" | head -1 | cut -d= -f2-)"

if [ -z "$MM_ACCOUNT_ID" ] || [ -z "$MM_LICENSE_KEY" ]; then
    fail "MaxMind credential boş"
    exit 1
fi

if [ "${#MM_LICENSE_KEY}" -ne 40 ]; then
    warn "MaxMind license key uzunluğu 40 değil; mevcut değer kullanılmayacak."
else
    ok "MaxMind license key formatı uygun"
fi

# ------------------------------------------------------------
# 3 — MAXMIND API TEST
# ------------------------------------------------------------

section "3/15 — MaxMind API testi"

MM_TMP="$RUNTIME/maxmind-test.json"

HTTP_CODE="$(
curl -sS \
    --connect-timeout 15 \
    --max-time 45 \
    -u "$MM_ACCOUNT_ID:$MM_LICENSE_KEY" \
    -A "reklama-click-lab-analytics/1.0" \
    -o "$MM_TMP" \
    -w '%{http_code}' \
    "https://geolite.info/geoip/v2.1/city/8.8.8.8" \
    2>"$RUNTIME/maxmind-curl.err" || true
)"

if [ "$HTTP_CODE" = "200" ]; then
    if grep -q '"country"' "$MM_TMP" 2>/dev/null; then
        ok "MaxMind GeoLite API erişimi başarılı"
        echo "HTTP: $HTTP_CODE"
    else
        fail "MaxMind HTTP 200 fakat beklenen JSON bulunamadı"
    fi
else
    fail "MaxMind API başarısız HTTP=$HTTP_CODE"
    cat "$RUNTIME/maxmind-curl.err" 2>/dev/null || true
fi

# ------------------------------------------------------------
# 4 — PYTHON SYNTAX
# ------------------------------------------------------------

section "4/15 — Python syntax kontrolü"

if python3 -m py_compile "$SERVER"; then
    ok "server.py syntax geçerli"
else
    fail "server.py syntax hatalı"
    exit 1
fi

# ------------------------------------------------------------
# 5 — SQLITE SCHEMA
# ------------------------------------------------------------

section "5/15 — SQLite schema kontrolü"

if [ -f "$DB" ]; then

    REQUIRED_COLUMNS="
country
country_code
continent
continent_code
region
region_code
city
postal_code
latitude
longitude
accuracy_radius_km
timezone
network
asn
organization
maxmind_success
"

    MISSING=0

    for COL in $REQUIRED_COLUMNS; do
        if sqlite3 "$DB" "PRAGMA table_info(clicks);" |
            awk -F'|' '{print $2}' |
            grep -qx "$COL"; then
            :
        else
            echo "[MISSING] $COL"
            MISSING=$((MISSING+1))
        fi
    done

    if [ "$MISSING" -eq 0 ]; then
        ok "SQLite MaxMind alanlarının tamamı mevcut"
    else
        fail "$MISSING SQLite alanı eksik"
    fi

else
    warn "SQLite henüz oluşturulmamış; backend başlatılınca kontrol edilecek."
fi

# ------------------------------------------------------------
# 6 — GITIGNORE
# ------------------------------------------------------------

section "6/15 — Git güvenliği"

GITIGNORE="$ROOT/.gitignore"

if [ -f "$GITIGNORE" ]; then

    grep -qxF 'privacy-analytics/analytics.sqlite3' "$GITIGNORE" ||
        echo 'privacy-analytics/analytics.sqlite3' >> "$GITIGNORE"

    grep -qxF 'privacy-analytics/server.log' "$GITIGNORE" ||
        echo 'privacy-analytics/server.log' >> "$GITIGNORE"

    grep -qxF 'privacy-analytics/.runtime/' "$GITIGNORE" ||
        echo 'privacy-analytics/.runtime/' >> "$GITIGNORE"

    grep -qxF 'backups-final/' "$GITIGNORE" ||
        echo 'backups-final/' >> "$GITIGNORE"

    grep -qxF 'backups-maxmind/' "$GITIGNORE" ||
        echo 'backups-maxmind/' >> "$GITIGNORE"

    grep -qxF '*.sqlite3' "$GITIGNORE" ||
        echo '*.sqlite3' >> "$GITIGNORE"

    grep -qxF '*.log' "$GITIGNORE" ||
        echo '*.log' >> "$GITIGNORE"

    ok ".gitignore korumaları mevcut"

else
    cat > "$GITIGNORE" <<'GITEOF'
privacy-analytics/analytics.sqlite3
privacy-analytics/server.log
privacy-analytics/.runtime/
backups-final/
backups-maxmind/
*.sqlite3
*.log
GITEOF
    ok ".gitignore oluşturuldu"
fi

# ------------------------------------------------------------
# 7 — GERÇEK SECRET SCAN
# ------------------------------------------------------------

section "7/15 — MaxMind secret leak kontrolü"

SECRET_FOUND=0

if [ -n "$MM_LICENSE_KEY" ] &&
   [ "${#MM_LICENSE_KEY}" -eq 40 ]; then

    SEARCH_PATHS=(
        "$ROOT/privacy-analytics"
        "$ROOT/index.html"
        "$ROOT/report.html"
        "$ROOT/README.md"
        "$ROOT/package.json"
    )

    for P in "${SEARCH_PATHS[@]}"; do
        if [ -e "$P" ]; then
            if grep -R -F -l \
                --exclude='*.sqlite3' \
                --exclude='*.log' \
                --exclude='*.sh' \
                "$MM_LICENSE_KEY" "$P" 2>/dev/null |
                grep -v '/backups' >/dev/null; then
                echo "[SECRET FOUND] $P"
                SECRET_FOUND=1
            fi
        fi
    done
fi

if [ "$SECRET_FOUND" -eq 0 ]; then
    ok "Gerçek MaxMind license key proje kaynaklarında bulunamadı"
else
    fail "Gerçek MaxMind license key kaynak dosyasında bulundu"
fi

# ------------------------------------------------------------
# 8 — ÇALIŞAN ESKİ BACKEND
# ------------------------------------------------------------

section "8/15 — Mevcut backend durumu"

OLD_PID=""

if [ -f "$PIDFILE" ]; then
    OLD_PID="$(cat "$PIDFILE" 2>/dev/null || true)"
fi

if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "Mevcut backend PID: $OLD_PID"
else
    OLD_PID=""
fi

# Portu kullanan server.py prosesini de tespit et
PORT_PID="$(
    (command -v lsof >/dev/null 2>&1 &&
     lsof -tiTCP:$PORT -sTCP:LISTEN 2>/dev/null | head -1) ||
    true
)"

if [ -n "$PORT_PID" ]; then
    echo "8080 kullanan PID: $PORT_PID"
fi

# ------------------------------------------------------------
# 9 — BACKEND TRUSTED PROXY MODE
# ------------------------------------------------------------

section "9/15 — Trusted proxy güvenli yapılandırması"

echo "Cloudflare/Cloudflared lokal proxy olduğu için:"
echo "TRUST_PROXY=1"
echo "TRUSTED_PROXY_IPS=127.0.0.1"

# Önce sadece bizim PID'imizi kapat
if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    kill "$OLD_PID" 2>/dev/null || true
    sleep 2

    if kill -0 "$OLD_PID" 2>/dev/null; then
        kill -9 "$OLD_PID" 2>/dev/null || true
    fi
fi

# Eğer 8080 hâlâ server.py tarafından kullanılıyorsa kontrollü kapat
if [ -n "$PORT_PID" ] &&
   [ "$PORT_PID" != "$$" ] &&
   [ "$PORT_PID" != "$OLD_PID" ]; then

    CMDLINE="$(tr '\0' ' ' < "/proc/$PORT_PID/cmdline" 2>/dev/null || true)"

    if echo "$CMDLINE" | grep -q 'privacy-analytics/server.py'; then
        kill "$PORT_PID" 2>/dev/null || true
        sleep 2
    fi
fi

# ------------------------------------------------------------
# 10 — BACKEND BAŞLAT
# ------------------------------------------------------------

section "10/15 — Backend yeniden başlatılıyor"

rm -f "$PIDFILE"

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
    tail -80 "$LOG" 2>/dev/null || true
    exit 1
fi

# ------------------------------------------------------------
# 11 — LOCAL HEALTH + LOCAL CLICK
# ------------------------------------------------------------

section "11/15 — Local API testleri"

HEALTH="$RUNTIME/health.json"

curl -fsS \
    --connect-timeout 10 \
    --max-time 20 \
    "$LOCAL/health" \
    -o "$HEALTH" \
    || true

if grep -q '"ok"' "$HEALTH" 2>/dev/null; then
    ok "Local /health başarılı"
    cat "$HEALTH"
else
    fail "Local /health başarısız"
    tail -80 "$LOG" 2>/dev/null || true
fi

LOCAL_CLICK="$RUNTIME/local-click.json"

curl -fsS \
    --connect-timeout 10 \
    --max-time 20 \
    -X POST \
    -H 'Content-Type: application/json' \
    -d '{"event":"image_click","ref":"AZ_LOCAL_TEST","consent":true}' \
    "$LOCAL/api/click" \
    -o "$LOCAL_CLICK" \
    || true

if [ -s "$LOCAL_CLICK" ]; then
    ok "Local click API cevap verdi"
    cat "$LOCAL_CLICK"
else
    fail "Local click API cevap vermedi"
fi

# ------------------------------------------------------------
# 12 — CLOUDFLARED
# ------------------------------------------------------------

section "12/15 — Cloudflare Quick Tunnel"

# Eski tunnel'i kapat
if [ -f "$CFPID" ]; then
    OLD_CF_PID="$(cat "$CFPID" 2>/dev/null || true)"

    if [ -n "$OLD_CF_PID" ] &&
       kill -0 "$OLD_CF_PID" 2>/dev/null; then
        kill "$OLD_CF_PID" 2>/dev/null || true
        sleep 2
    fi
fi

pkill -f 'cloudflared tunnel --url' 2>/dev/null || true
sleep 1

rm -f "$CFLOG" "$CFPID"

nohup cloudflared tunnel \
    --url "$LOCAL" \
    --no-autoupdate \
    > "$CFLOG" 2>&1 &

CF_PID=$!
echo "$CF_PID" > "$CFPID"

echo "Cloudflared PID=$CF_PID"

PUBLIC_URL=""

for i in $(seq 1 30); do

    sleep 2

    PUBLIC_URL="$(
        grep -Eo \
        'https://[-a-zA-Z0-9]+\.trycloudflare\.com' \
        "$CFLOG" 2>/dev/null |
        tail -1
    )"

    if [ -n "$PUBLIC_URL" ]; then
        break
    fi

    if ! kill -0 "$CF_PID" 2>/dev/null; then
        break
    fi

done

if [ -n "$PUBLIC_URL" ]; then
    ok "Public HTTPS URL oluşturuldu"
    echo
    echo "PUBLIC URL:"
    echo "$PUBLIC_URL"
    echo
else
    fail "Cloudflare public URL alınamadı"
    tail -100 "$CFLOG" 2>/dev/null || true
fi

# ------------------------------------------------------------
# 13 — PUBLIC TESTLER
# ------------------------------------------------------------

section "13/15 — Public HTTPS testleri"

if [ -n "$PUBLIC_URL" ]; then

    PUBLIC_HEALTH="$RUNTIME/public-health.json"

    PUBLIC_HTTP="$(
        curl -sS \
            --connect-timeout 15 \
            --max-time 45 \
            -o "$PUBLIC_HEALTH" \
            -w '%{http_code}' \
            "$PUBLIC_URL/health" \
            2>"$RUNTIME/public-health.err" ||
            true
    )"

    echo "Public health HTTP=$PUBLIC_HTTP"

    if [ "$PUBLIC_HTTP" = "200" ] &&
       grep -q '"ok"' "$PUBLIC_HEALTH" 2>/dev/null; then
        ok "Public /health başarılı"
        cat "$PUBLIC_HEALTH"
    else
        fail "Public /health başarısız"
        cat "$RUNTIME/public-health.err" 2>/dev/null || true
    fi

    PUBLIC_CLICK="$RUNTIME/public-click.json"

    PUBLIC_CLICK_HTTP="$(
        curl -sS \
            --connect-timeout 15 \
            --max-time 45 \
            -X POST \
            -H 'Content-Type: application/json' \
            -d '{"event":"image_click","ref":"AZ_PUBLIC_TEST","consent":true}' \
            -o "$PUBLIC_CLICK" \
            -w '%{http_code}' \
            "$PUBLIC_URL/api/click" \
            2>"$RUNTIME/public-click.err" ||
            true
    )"

    echo "Public click HTTP=$PUBLIC_CLICK_HTTP"

    if [ "$PUBLIC_CLICK_HTTP" = "200" ]; then
        ok "Public /api/click başarılı"
        cat "$PUBLIC_CLICK"
    else
        fail "Public /api/click başarısız"
        cat "$RUNTIME/public-click.err" 2>/dev/null || true
    fi

else
    fail "Public test atlandı; URL yok"
fi

# ------------------------------------------------------------
# 14 — DATABASE FINAL VALIDATION
# ------------------------------------------------------------

section "14/15 — Final SQLite / MaxMind validation"

if [ -f "$DB" ]; then

    echo
    echo "Son kayıtlar:"
    sqlite3 "$DB" \
        "SELECT id,timestamp,ip,ref,event,country,country_code,city,timezone,asn,organization,maxmind_success FROM clicks ORDER BY id DESC LIMIT 5;" \
        2>/dev/null || true

    echo

    RAW_COUNT="$(
        sqlite3 "$DB" \
        "SELECT COUNT(*) FROM clicks WHERE ip IS NOT NULL AND ip NOT IN ('ANONYMIZED','');" \
        2>/dev/null || echo "0"
    )"

    if [ "$RAW_COUNT" = "0" ]; then
        ok "Raw IP veritabanında tutulmuyor"
    else
        fail "Raw IP bulundu: $RAW_COUNT kayıt"
    fi

    MM_COUNT="$(
        sqlite3 "$DB" \
        "SELECT COUNT(*) FROM clicks WHERE maxmind_success=1;" \
        2>/dev/null || echo "0"
    )"

    echo "MaxMind başarılı kayıt sayısı: $MM_COUNT"

    if [ "$MM_COUNT" -gt 0 ]; then
        ok "MaxMind enrichment SQLite üzerinde doğrulandı"
    else
        warn "Henüz maxmind_success=1 kayıt yok"
    fi

else
    fail "SQLite veritabanı bulunamadı"
fi

# ------------------------------------------------------------
# 15 — FRONTEND / REPORT / PROCESS FINAL
# ------------------------------------------------------------

section "15/15 — Frontend, report ve process final"

if [ -f "$APP/report.html" ]; then
    ok "report.html mevcut"

    if grep -Eqi \
        'country|country_code|maxmind|timezone|organization|asn' \
        "$APP/report.html"; then
        ok "report.html MaxMind alanlarına referans içeriyor"
    else
        warn "report.html mevcut fakat MaxMind alanlarını göstermiyor"
    fi
else
    warn "report.html bulunamadı"
fi

if [ -f "$APP/index.html" ]; then
    ok "privacy-analytics/index.html mevcut"

    if grep -Eq \
        'fetch\(|/api/click|/track' \
        "$APP/index.html"; then
        ok "Frontend tracking kodu bulundu"
    else
        warn "Frontend tracking çağrısı bulunamadı"
    fi
fi

if kill -0 "$SERVER_PID" 2>/dev/null; then
    ok "Backend final durumda çalışıyor PID=$SERVER_PID"
else
    fail "Backend final kontrolde çalışmıyor"
fi

if [ -f "$CFPID" ]; then
    FINAL_CF_PID="$(cat "$CFPID" 2>/dev/null || true)"

    if [ -n "$FINAL_CF_PID" ] &&
       kill -0 "$FINAL_CF_PID" 2>/dev/null; then
        ok "Cloudflared final durumda çalışıyor PID=$FINAL_CF_PID"
    else
        fail "Cloudflared final kontrolde çalışmıyor"
    fi
fi

# ------------------------------------------------------------
# SONUÇ
# ------------------------------------------------------------

section "FINAL SONUÇ"

echo "Başarılı : $OK"
echo "Uyarı    : $WARN"
echo "Hata     : $FAIL"
echo

echo "Backend:"
echo "$LOCAL"

echo
echo "PID:"
echo "$SERVER_PID"

echo
echo "Cloudflared:"
if [ -n "$PUBLIC_URL" ]; then
    echo "$PUBLIC_URL"
else
    echo "PUBLIC URL YOK"
fi

echo
echo "Backup:"
echo "$BK"

echo
echo "Backend log:"
echo "$LOG"

echo
echo "Cloudflared log:"
echo "$CFLOG"

echo
echo "Final report:"
echo "$REPORT"

echo
echo "============================================================"

if [ "$FAIL" -eq 0 ]; then
    echo " A-Z OTOMASYON BAŞARILI"
    echo "============================================================"
    exit 0
else
    echo " A-Z OTOMASYON TAMAMLANMADI"
    echo " Hatalar yukarıda gösterildi."
    echo "============================================================"
    exit 1
fi
