#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

PROJECT="$HOME/reklama-click-lab"
SERVER="$PROJECT/privacy-analytics/server.py"
RUNTIME="$PROJECT/privacy-analytics/.runtime"
PIDFILE="$RUNTIME/server.pid"
LOGFILE="$PROJECT/privacy-analytics/server.log"

source "$HOME/.maxmind/config"

export MM_ACCOUNT_ID="$MM_ACCOUNT_ID"
export MM_LICENSE_KEY="$MM_LICENSE_KEY"

echo "======================================================"
echo "       MAXMIND ENRICHMENT FINAL TEST"
echo "======================================================"

# Runtime klasörü
mkdir -p "$RUNTIME"

# Eski server'ı kapat
if [ -f "$PIDFILE" ]; then
    OLD_PID="$(cat "$PIDFILE" 2>/dev/null || true)"

    if [ -n "${OLD_PID:-}" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        echo "[INFO] Eski server kapatılıyor: PID $OLD_PID"
        kill "$OLD_PID" 2>/dev/null || true
        sleep 2
    fi
fi

pkill -f 'privacy-analytics/server.py' 2>/dev/null || true
sleep 2

# ------------------------------------------------------
# KONTROLLÜ TEST SERVER
# ------------------------------------------------------

export TRUST_PROXY=1
export TRUSTED_PROXY_IPS="127.0.0.1"

echo "[INFO] Kontrollü MaxMind testi"
echo "TRUST_PROXY=$TRUST_PROXY"
echo "TRUSTED_PROXY_IPS=$TRUSTED_PROXY_IPS"

nohup env \
    MM_ACCOUNT_ID="$MM_ACCOUNT_ID" \
    MM_LICENSE_KEY="$MM_LICENSE_KEY" \
    TRUST_PROXY="$TRUST_PROXY" \
    TRUSTED_PROXY_IPS="$TRUSTED_PROXY_IPS" \
    python "$SERVER" > "$LOGFILE" 2>&1 &

TEST_PID=$!

echo "$TEST_PID" > "$PIDFILE"

sleep 2

if ! kill -0 "$TEST_PID" 2>/dev/null; then
    echo
    echo "[ERROR] Test server başlatılamadı."
    cat "$LOGFILE"
    exit 1
fi

echo "[OK] Test server PID: $TEST_PID"

# ------------------------------------------------------
# HEALTH
# ------------------------------------------------------

echo
echo "[INFO] Health testi"

curl -fsS --max-time 10 \
    http://127.0.0.1:8080/health

echo
echo "[OK] Health başarılı."

# ------------------------------------------------------
# MAXMIND TEST
# ------------------------------------------------------

echo
echo "[INFO] 8.8.8.8 MaxMind enrichment testi"

RESULT="$(
curl -fsS --max-time 20 \
    -X POST \
    -H 'Content-Type: application/json' \
    -H 'X-Forwarded-For: 8.8.8.8' \
    -d '{"event":"image_click","ref":"AUTO-MAXMIND-FINAL"}' \
    http://127.0.0.1:8080/api/click
)"

echo "$RESULT"

echo "$RESULT" | grep -q '"recorded": true' || {
    echo "[ERROR] Click kaydı başarısız."
    cat "$LOGFILE"
    exit 1
}

# ------------------------------------------------------
# SQLITE DOĞRULAMA
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
WHERE ref='AUTO-MAXMIND-FINAL'
ORDER BY id DESC
LIMIT 1
""").fetchone()

if row is None:
    raise SystemExit("[ERROR] Test kaydı bulunamadı.")

print()
print("========== MAXMIND TEST SONUCU ==========")

for key in row.keys():
    print(f"{key}: {row[key]}")

if row["maxmind_success"] != 1:
    raise SystemExit(
        "[ERROR] maxmind_success != 1"
    )

if row["country_code"] != "US":
    raise SystemExit(
        f"[ERROR] country_code beklenmedik: {row['country_code']}"
    )

if row["asn"] != 15169:
    raise SystemExit(
        f"[ERROR] ASN beklenmedik: {row['asn']}"
    )

print()
print("[OK] MAXMIND ENRICHMENT BAŞARILI")

con.close()
PY

# ------------------------------------------------------
# TEST SERVER KAPAT
# ------------------------------------------------------

echo
echo "[INFO] Test server kapatılıyor..."

kill "$TEST_PID" 2>/dev/null || true
sleep 2

# ------------------------------------------------------
# PRODUCTION SERVER
# ------------------------------------------------------

unset TRUSTED_PROXY_IPS
export TRUST_PROXY=0

echo "[INFO] Production server başlatılıyor..."
echo "[INFO] TRUST_PROXY=0"

nohup env \
    MM_ACCOUNT_ID="$MM_ACCOUNT_ID" \
    MM_LICENSE_KEY="$MM_LICENSE_KEY" \
    TRUST_PROXY=0 \
    python "$SERVER" > "$LOGFILE" 2>&1 &

PROD_PID=$!

echo "$PROD_PID" > "$PIDFILE"

sleep 2

if ! kill -0 "$PROD_PID" 2>/dev/null; then
    echo
    echo "[ERROR] Production server başlatılamadı."
    cat "$LOGFILE"
    exit 1
fi

# ------------------------------------------------------
# FINAL HEALTH
# ------------------------------------------------------

echo
echo "[INFO] Production health testi"

HEALTH="$(curl -fsS --max-time 10 \
    http://127.0.0.1:8080/health)"

echo "$HEALTH"

echo "$HEALTH" | grep -q '"ok"' || {
    echo "[ERROR] Production health başarısız."
    cat "$LOGFILE"
    exit 1
}

echo
echo "======================================================"
echo "           MAXMIND FINAL TEST TAMAMLANDI"
echo "======================================================"
echo "Test PID       : $TEST_PID"
echo "Production PID : $PROD_PID"
echo "MaxMind        : AKTİF"
echo "Production XFF : GÜVENLİ / KAPALI"
echo "Raw IP         : ANONYMIZED"
echo "Database       : $PROJECT/privacy-analytics/analytics.sqlite3"
echo "Log            : $LOGFILE"
echo "PID file       : $PIDFILE"
echo "======================================================"
