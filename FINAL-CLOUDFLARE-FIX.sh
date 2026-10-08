#!/data/data/com.termux/files/usr/bin/bash

set -u
set -o pipefail

ROOT="$HOME/reklama-click-lab"
APP="$ROOT/privacy-analytics"
RUNTIME="$APP/.runtime"
SERVER="$APP/server.py"
DB="$APP/analytics.sqlite3"

LOCAL="http://127.0.0.1:8080"
CFLOG="$RUNTIME/cloudflared.log"
CFPID="$RUNTIME/cloudflared.pid"
PIDFILE="$RUNTIME/server.pid"

mkdir -p "$RUNTIME"

echo
echo "============================================================"
echo "        FINAL CLOUDFLARE PUBLIC ACCESS FIX"
echo "============================================================"
echo

OK=0
WARN=0
FAIL=0

ok(){ echo "[OK] $1"; OK=$((OK+1)); }
warn(){ echo "[WARN] $1"; WARN=$((WARN+1)); }
fail(){ echo "[ERROR] $1"; FAIL=$((FAIL+1)); }

# ============================================================
# 1 — BACKEND KONTROL
# ============================================================

echo "------------------------------------------------------------"
echo "1/8 — BACKEND"
echo "------------------------------------------------------------"

if curl -fsS \
    --connect-timeout 10 \
    --max-time 20 \
    "$LOCAL/health" >/dev/null 2>&1; then

    ok "Backend localhost:8080 çalışıyor"

else
    fail "Backend çalışmıyor"
    exit 1
fi

# ============================================================
# 2 — CLOUDFLARED KONTROL
# ============================================================

echo
echo "------------------------------------------------------------"
echo "2/8 — CLOUDFLARED"
echo "------------------------------------------------------------"

if ! command -v cloudflared >/dev/null 2>&1; then
    fail "cloudflared bulunamadı"
    exit 1
fi

cloudflared --version

# ============================================================
# 3 — ESKİ TUNNEL TEMİZLE
# ============================================================

echo
echo "------------------------------------------------------------"
echo "3/8 — ESKİ TUNNEL TEMİZLEME"
echo "------------------------------------------------------------"

if [ -f "$CFPID" ]; then

    OLD_CF_PID="$(cat "$CFPID" 2>/dev/null || true)"

    if [ -n "$OLD_CF_PID" ] &&
       kill -0 "$OLD_CF_PID" 2>/dev/null; then

        kill "$OLD_CF_PID" 2>/dev/null || true
        sleep 2
    fi
fi

pkill -f 'cloudflared tunnel --url' 2>/dev/null || true

sleep 2

rm -f "$CFLOG"

ok "Eski Quick Tunnel temizlendi"

# ============================================================
# 4 — HTTP/2 QUICK TUNNEL
# ============================================================

echo
echo "------------------------------------------------------------"
echo "4/8 — YENİ QUICK TUNNEL"
echo "------------------------------------------------------------"

nohup cloudflared tunnel \
    --url "$LOCAL" \
    --protocol http2 \
    --no-autoupdate \
    > "$CFLOG" 2>&1 &

CF_PID=$!

echo "$CF_PID" > "$CFPID"

echo "Cloudflared PID=$CF_PID"

PUBLIC_URL=""

for i in $(seq 1 45); do

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

if [ -z "$PUBLIC_URL" ]; then
    fail "Quick Tunnel URL oluşmadı"
    tail -100 "$CFLOG"
    exit 1
fi

ok "Quick Tunnel oluşturuldu"

echo
echo "PUBLIC URL:"
echo "$PUBLIC_URL"

# ============================================================
# 5 — CLOUDFLARE CONNECTION BEKLE
# ============================================================

echo
echo "------------------------------------------------------------"
echo "5/8 — CLOUDFLARE CONNECTION"
echo "------------------------------------------------------------"

CONNECTED=0

for i in $(seq 1 30); do

    sleep 2

    if grep -Eq \
        'Registered tunnel connection|Connection.*registered|connIndex=' \
        "$CFLOG" 2>/dev/null; then

        CONNECTED=1
        break
    fi

    if ! kill -0 "$CF_PID" 2>/dev/null; then
        break
    fi

done

if [ "$CONNECTED" = "1" ]; then
    ok "Cloudflare tunnel bağlantısı oluştu"
else
    warn "Tunnel bağlantı satırı henüz görülmedi"
fi

# ============================================================
# 6 — DNS RETRY
# ============================================================

echo
echo "------------------------------------------------------------"
echo "6/8 — PUBLIC DNS"
echo "------------------------------------------------------------"

DNS_OK=0

for i in $(seq 1 30); do

    echo "DNS denemesi $i/30"

    if getent hosts "$(
        printf '%s' "$PUBLIC_URL" |
        sed 's#https://##;s#/# #g' |
        awk '{print $1}'
    )" >/dev/null 2>&1; then

        DNS_OK=1
        break
    fi

    sleep 3
done

if [ "$DNS_OK" = "1" ]; then
    ok "Public hostname DNS çözülüyor"
else
    warn "Termux resolver hostname'i henüz çözemiyor"
fi

# ============================================================
# 7 — PUBLIC HEALTH + CLICK
# ============================================================

echo
echo "------------------------------------------------------------"
echo "7/8 — PUBLIC API TEST"
echo "------------------------------------------------------------"

PUBLIC_HEALTH="$RUNTIME/final-public-health.json"

PUBLIC_HTTP=""

for i in $(seq 1 20); do

    PUBLIC_HTTP="$(
        curl -sS \
            --connect-timeout 10 \
            --max-time 30 \
            -o "$PUBLIC_HEALTH" \
            -w '%{http_code}' \
            "$PUBLIC_URL/health" \
            2>/dev/null || true
    )"

    echo "Public health attempt $i/20 -> HTTP=$PUBLIC_HTTP"

    if [ "$PUBLIC_HTTP" = "200" ]; then
        break
    fi

    sleep 5
done

if [ "$PUBLIC_HTTP" = "200" ]; then

    ok "PUBLIC /health HTTP 200"

    cat "$PUBLIC_HEALTH"

else

    fail "PUBLIC /health başarısız HTTP=$PUBLIC_HTTP"

    echo
    echo "Cloudflared son log:"
    tail -100 "$CFLOG"

    echo
    echo "Not:"
    echo "Quick Tunnel oluşturulmuş olsa bile Cloudflare edge/DNS"
    echo "hazırlığı gecikebilir."
fi

# ------------------------------------------------------------
# PUBLIC CLICK
# ------------------------------------------------------------

if [ "$PUBLIC_HTTP" = "200" ]; then

    echo
    echo "Public click testi..."

    CLICK_OUT="$RUNTIME/final-public-click.json"

    CLICK_HTTP="$(
        curl -sS \
            --connect-timeout 15 \
            --max-time 45 \
            -X POST \
            -H 'Content-Type: application/json' \
            -d '{"event":"image_click","ref":"FINAL-PUBLIC-CLICK","consent":true}' \
            -o "$CLICK_OUT" \
            -w '%{http_code}' \
            "$PUBLIC_URL/api/click" \
            2>/dev/null || true
    )"

    echo "Public click HTTP=$CLICK_HTTP"

    if [ "$CLICK_HTTP" = "200" ]; then
        ok "PUBLIC /api/click başarılı"
        cat "$CLICK_OUT"
    else
        fail "PUBLIC /api/click başarısız"
    fi
fi

# ============================================================
# 8 — DATABASE
# ============================================================

echo
echo "------------------------------------------------------------"
echo "8/8 — DATABASE FINAL"
echo "------------------------------------------------------------"

if [ -f "$DB" ]; then

    echo
    echo "Son kayıtlar:"

    sqlite3 "$DB" \
    "SELECT id,timestamp,ip,ref,country,country_code,timezone,asn,organization,maxmind_success FROM clicks ORDER BY id DESC LIMIT 5;" \
    2>/dev/null || true

    RAW_COUNT="$(
        sqlite3 "$DB" \
        "SELECT COUNT(*) FROM clicks WHERE ip IS NOT NULL AND ip NOT IN ('ANONYMIZED','');" \
        2>/dev/null || echo 0
    )"

    echo
    echo "Raw IP count=$RAW_COUNT"

    if [ "$RAW_COUNT" = "0" ]; then
        ok "Raw IP bulunmuyor"
    elif [ "$RAW_COUNT" = "1" ]; then

        LEGACY="$(
            sqlite3 "$DB" \
            "SELECT COUNT(*) FROM clicks WHERE id=1 AND ip='127.0.0.1' AND ref='AD001' AND event='legacy';" \
            2>/dev/null || echo 0
        )"

        if [ "$LEGACY" = "1" ]; then
            ok "Tek raw IP eski legacy kayıt: id=1 / 127.0.0.1"
        else
            warn "Raw IP var fakat legacy kaydı değil"
        fi

    else
        warn "Raw IP sayısı: $RAW_COUNT"
    fi

else
    fail "SQLite bulunamadı"
fi

# ============================================================
# FINAL
# ============================================================

echo
echo "============================================================"
echo "                     FINAL RESULT"
echo "============================================================"

echo "OK    : $OK"
echo "WARN  : $WARN"
echo "ERROR : $FAIL"

echo
echo "Backend:"
echo "$LOCAL"

echo
echo "Cloudflared PID:"
echo "$CF_PID"

echo
echo "PUBLIC URL:"
echo "$PUBLIC_URL"

echo
echo "Cloudflared log:"
echo "$CFLOG"

echo
echo "============================================================"

if [ "$FAIL" -eq 0 ]; then

    echo " PUBLIC SYSTEM READY"
    echo "============================================================"

else

    echo " PUBLIC SYSTEM HENÜZ READY DEĞİL"
    echo " Backend + MaxMind hazır."
    echo " Sorun Cloudflare public erişim katmanında."
    echo "============================================================"

fi
