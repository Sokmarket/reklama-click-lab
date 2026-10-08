#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

PROJECT="$HOME/reklama-click-lab"
SERVER="$PROJECT/privacy-analytics/server.py"
DB="$PROJECT/privacy-analytics/analytics.sqlite3"
REPORT="$PROJECT/privacy-analytics/report.html"
INDEX="$PROJECT/privacy-analytics/index.html"
CFG="$HOME/.maxmind/config"

RUNTIME="$PROJECT/privacy-analytics/.runtime"
PIDFILE="$RUNTIME/server.pid"
TUNNEL_PIDFILE="$RUNTIME/cloudflared.pid"
PUBLIC_FILE="$RUNTIME/public-url.txt"
LOG="$PROJECT/privacy-analytics/server.log"
TUNNEL_LOG="$RUNTIME/cloudflared.log"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$PROJECT/backups-final/$STAMP"

CF="$HOME/bin/cloudflared"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ok(){ echo -e "${GREEN}[OK]${NC} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $*"; }
info(){ echo -e "${CYAN}[INFO]${NC} $*"; }
die(){ echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

mkdir -p "$RUNTIME" "$BACKUP" "$HOME/bin"

cd "$PROJECT"

echo
echo "======================================================"
echo "      REKLAMA CLICK LAB — PUBLIC A-Z AUTOMATION"
echo "======================================================"
echo

# ======================================================
# 1. ZORUNLU DOSYALAR
# ======================================================

[ -f "$SERVER" ] || die "server.py bulunamadı."
[ -f "$DB" ] || die "analytics.sqlite3 bulunamadı."
[ -f "$CFG" ] || die "MaxMind config bulunamadı."

ok "Mevcut backend bulundu."

# ======================================================
# 2. BACKUP
# ======================================================

cp "$SERVER" "$BACKUP/server.py"
cp "$DB" "$BACKUP/analytics.sqlite3"

[ -f "$REPORT" ] && cp "$REPORT" "$BACKUP/report.html"
[ -f "$INDEX" ] && cp "$INDEX" "$BACKUP/index.html"

ok "Yeni güvenlik yedeği: $BACKUP"

# ======================================================
# 3. MAXMIND CREDENTIAL
# ======================================================

source "$CFG"

export MM_ACCOUNT_ID="${MM_ACCOUNT_ID:-}"
export MM_LICENSE_KEY="${MM_LICENSE_KEY:-}"

[ -n "$MM_ACCOUNT_ID" ] || die "MM_ACCOUNT_ID boş."
[ -n "$MM_LICENSE_KEY" ] || die "MM_LICENSE_KEY boş."

[ "${#MM_LICENSE_KEY}" -eq 40 ] \
    || die "License Key uzunluğu 40 değil."

echo "Account ID     : $MM_ACCOUNT_ID"
echo "License length : ${#MM_LICENSE_KEY}"

# ======================================================
# 4. BACKEND DEĞİŞİKLİK KORUMASI
# ======================================================

python -m py_compile "$SERVER"
ok "server.py syntax OK."

# ======================================================
# 5. MAXMIND DIRECT TEST
# ======================================================

python - <<'PY'
import os
import base64
import json
import urllib.request

account=os.environ["MM_ACCOUNT_ID"]
key=os.environ["MM_LICENSE_KEY"]

url="https://geolite.info/geoip/v2.1/city/8.8.8.8"

auth=base64.b64encode(
    f"{account}:{key}".encode()
).decode()

req=urllib.request.Request(
    url,
    headers={
        "Authorization":f"Basic {auth}",
        "User-Agent":"reklama-click-lab/1.0"
    }
)

with urllib.request.urlopen(req,timeout=20) as r:
    data=json.load(r)

cc=data.get("country",{}).get("iso_code")
asn=data.get("traits",{}).get("autonomous_system_number")

print("HTTP:",200)
print("Country:",data.get("country",{}).get("names",{}).get("en"))
print("Country Code:",cc)
print("ASN:",asn)

if cc!="US" or asn!=15169:
    raise SystemExit("MaxMind doğrulama başarısız.")

print("[OK] MaxMind API çalışıyor.")
PY

# ======================================================
# 6. GITIGNORE
# ======================================================

touch "$PROJECT/.gitignore"

for item in \
    "privacy-analytics/analytics.sqlite3" \
    "privacy-analytics/server.log" \
    "privacy-analytics/.runtime/" \
    "backups-final/" \
    "*.sqlite3" \
    "*.log"
do
    grep -qxF "$item" "$PROJECT/.gitignore" 2>/dev/null \
        || echo "$item" >> "$PROJECT/.gitignore"
done

ok ".gitignore koruması aktif."

# ======================================================
# 7. FRONTEND SECRET SCAN
# ======================================================

info "Gerçek MaxMind License Key sızıntısı taranıyor..."

SECRET_SCAN="$PROJECT/.runtime/maxmind-secret-scan.txt"
rm -f "$SECRET_SCAN"

# Gerçek key değerini config'ten al.
REAL_KEY="${MM_LICENSE_KEY:-}"

[ "${#REAL_KEY}" -eq 40 ] \
    || die "License Key uzunluğu beklenen 40 değil."

FOUND=0

# Sadece gerçek dosya içeriklerini tara.
# Backup, .git, runtime, log, DB ve shell scriptleri hariç.
while IFS= read -r -d '' FILE; do

    case "$FILE" in
        "$PROJECT/.git/"*)
            continue
            ;;
        "$PROJECT/backups-"*)
            continue
            ;;
        "$PROJECT/backups-final/"*)
            continue
            ;;
        "$PROJECT/privacy-analytics/.runtime/"*)
            continue
            ;;
        *.sqlite3)
            continue
            ;;
        *.log)
            continue
            ;;
        *.sh)
            continue
            ;;
    esac

    if grep -Fq "$REAL_KEY" "$FILE" 2>/dev/null; then
        echo "$FILE" >> "$SECRET_SCAN"
        FOUND=1
    fi

done < <(
    find "$PROJECT" \
        -type f \
        -not -path "$PROJECT/.git/*" \
        -not -path "$PROJECT/backups-final/*" \
        -not -path "$PROJECT/backups-maxmind/*" \
        -not -path "$PROJECT/privacy-analytics/.runtime/*" \
        -print0
)

if [ "$FOUND" -eq 1 ]; then
    echo
    echo "[ERROR] GERÇEK MaxMind License Key proje dosyasında bulundu:"
    cat "$SECRET_SCAN"
    die "Secret sızıntısı bulundu."
else
    ok "Gerçek MaxMind License Key frontend/proje dosyalarında bulunamadı."
fi

# Değişken isimlerinin frontend'e yanlışlıkla eklenmesini ayrıca kontrol et.
NAME_HITS="$PROJECT/.runtime/maxmind-name-scan.txt"
rm -f "$NAME_HITS"

grep -RniE \
    'MM_LICENSE_KEY|MAXMIND_LICENSE_KEY|MM_ACCOUNT_ID|MAXMIND_ACCOUNT_ID' \
    "$PROJECT" \
    --exclude='*.sh' \
    --exclude='*.sqlite3' \
    --exclude='*.log' \
    --exclude-dir='.git' \
    --exclude-dir='backups-final' \
    --exclude-dir='backups-maxmind' \
    --exclude-dir='.runtime' \
    > "$NAME_HITS" 2>/dev/null || true

if [ -s "$NAME_HITS" ]; then
    warn "Değişken isimleri bulundu; gerçek secret değeri bulunmadı."
    warn "Bu tek başına secret sızıntısı değildir."
else
    ok "Frontend MaxMind credential isimleri de temiz."
fi

# ======================================================
# 8. REPORT ANALİZİ
# ======================================================

if [ -f "$REPORT" ]; then

    info "report.html analiz ediliyor."

    if grep -qE \
        'country_code|country|timezone|asn|organization|maxmind_success' \
        "$REPORT"
    then
        ok "Report MaxMind alanlarına zaten referans veriyor."
    else
        warn "Report MaxMind alanlarını henüz göstermiyor."
        warn "Mevcut report.html değiştirilmedi."
    fi

else
    warn "report.html yok."
fi

# ======================================================
# 9. MEVCUT BACKEND DURUMU
# ======================================================

if [ -f "$PIDFILE" ]; then
    OLD_PID="$(cat "$PIDFILE" 2>/dev/null || true)"

    if [ -n "${OLD_PID:-}" ] &&
       kill -0 "$OLD_PID" 2>/dev/null
    then
        info "Mevcut backend aktif: PID $OLD_PID"
    fi
fi

# ======================================================
# 10. HEALTH
# ======================================================

if curl -fsS --max-time 5 \
    http://127.0.0.1:8080/health \
    >/dev/null 2>&1
then
    ok "Backend zaten aktif."
else
    info "Backend aktif değil; mevcut production server başlatılıyor."

    source "$CFG"

    export MM_ACCOUNT_ID
    export MM_LICENSE_KEY
    export TRUST_PROXY=0

    nohup env \
        MM_ACCOUNT_ID="$MM_ACCOUNT_ID" \
        MM_LICENSE_KEY="$MM_LICENSE_KEY" \
        TRUST_PROXY=0 \
        python "$SERVER" \
        > "$LOG" 2>&1 &

    PID=$!

    echo "$PID" > "$PIDFILE"

    sleep 2

    kill -0 "$PID" 2>/dev/null \
        || {
            cat "$LOG"
            die "Backend başlatılamadı."
        }

    ok "Backend başlatıldı: $PID"
fi

# ======================================================
# 11. LOCAL HEALTH
# ======================================================

LOCAL_HEALTH="$(
curl -fsS --max-time 10 \
http://127.0.0.1:8080/health
)"

echo "$LOCAL_HEALTH"

echo "$LOCAL_HEALTH" | grep -q '"ok"' \
    || die "Local health başarısız."

ok "Local backend doğrulandı."

# ======================================================
# 12. CLOUDFLARED
# ======================================================

if command -v cloudflared >/dev/null 2>&1; then
    CF="$(command -v cloudflared)"
    ok "cloudflared zaten kurulu: $CF"

elif [ -x "$CF" ]; then
    ok "Yerel cloudflared bulundu: $CF"

else

    info "cloudflared bulunamadı."
    info "Resmi Cloudflare ARM64 release kurulumu deneniyor."

    ARCH="$(uname -m)"

    case "$ARCH" in
        aarch64|arm64)
            CF_URL="https://github.com/cloudflare/cloudflared/releases/download/2026.10.0/cloudflared-linux-arm64"
            CF_SHA="d2b49df8dbb3a36e743ce00b091c180e0942a0b67487257c573a631db001796"
            ;;
        armv7l|armv8l)
            CF_URL="https://github.com/cloudflare/cloudflared/releases/download/2026.10.0/cloudflared-linux-arm"
            CF_SHA=""
            ;;
        x86_64|amd64)
            CF_URL="https://github.com/cloudflare/cloudflared/releases/download/2026.10.0/cloudflared-linux-amd64"
            CF_SHA=""
            ;;
        *)
            warn "Desteklenmeyen mimari: $ARCH"
            warn "Public tunnel kurulmadı."
            CF=""
            ;;
    esac

    if [ -n "${CF:-}" ]; then

        curl -fL \
            --retry 3 \
            --connect-timeout 15 \
            --max-time 120 \
            "$CF_URL" \
            -o "$CF"

        chmod 700 "$CF"

        if [ -n "${CF_SHA:-}" ]; then

            ACTUAL_SHA="$(
                sha256sum "$CF" | awk '{print $1}'
            )"

            if [ "$ACTUAL_SHA" != "$CF_SHA" ]; then
                rm -f "$CF"
                die "cloudflared SHA256 doğrulaması başarısız."
            fi

            ok "cloudflared SHA256 doğrulandı."
        fi

        "$CF" --version

        ok "cloudflared kuruldu."
    fi
fi

# ======================================================
# 13. PUBLIC QUICK TUNNEL
# ======================================================

if [ -x "$CF" ]; then

    pkill -f 'cloudflared.*127.0.0.1:8080' \
        2>/dev/null || true

    sleep 1

    rm -f "$PUBLIC_FILE"

    info "Cloudflare Quick Tunnel başlatılıyor."

    nohup "$CF" tunnel \
        --url http://127.0.0.1:8080 \
        --no-autoupdate \
        > "$TUNNEL_LOG" 2>&1 &

    TUNNEL_PID=$!

    echo "$TUNNEL_PID" > "$TUNNEL_PIDFILE"

    sleep 8

    URL="$(
        grep -oE \
        'https://[a-zA-Z0-9.-]+\.trycloudflare\.com' \
        "$TUNNEL_LOG" \
        | head -1 \
        || true
    )"

    if [ -z "$URL" ]; then
        warn "Public URL bulunamadı."
        warn "Cloudflare log:"
        tail -30 "$TUNNEL_LOG"
    else

        echo "$URL" > "$PUBLIC_FILE"

        echo
        echo "PUBLIC URL:"
        echo "$URL"
        echo

        ok "Public HTTPS tunnel aktif."

        # ==================================================
        # 14. PUBLIC HEALTH
        # ==================================================

        sleep 3

        PUBLIC_HEALTH="$(
            curl -fsS \
                --max-time 20 \
                "$URL/health"
        )"

        echo "$PUBLIC_HEALTH"

        echo "$PUBLIC_HEALTH" | grep -q '"ok"' \
            || die "Public health başarısız."

        ok "Public HTTPS → backend bağlantısı başarılı."

        # ==================================================
        # 15. PUBLIC CLICK
        # ==================================================

        PUBLIC_CLICK="$(
            curl -fsS \
                --max-time 20 \
                -X POST \
                -H 'Content-Type: application/json' \
                -d '{"event":"image_click","ref":"PUBLIC-FINAL-TEST"}' \
                "$URL/api/click"
        )"

        echo "$PUBLIC_CLICK"

        echo "$PUBLIC_CLICK" | grep -q '"recorded": true' \
            || die "Public click başarısız."

        ok "Public click endpoint çalışıyor."

    fi
else
    warn "cloudflared mevcut değil; public endpoint kurulamadı."
fi

# ======================================================
# 16. DB SON TEST
# ======================================================

python - <<'PY'
import sqlite3

db="privacy-analytics/analytics.sqlite3"

con=sqlite3.connect(db)
con.row_factory=sqlite3.Row

row=con.execute("""
SELECT
    id,
    timestamp,
    ip,
    event,
    ref,
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

if row:
    print()
    print("========== SON CLICK ==========")
    for key in row.keys():
        print(f"{key}: {row[key]}")
else:
    raise SystemExit("SQLite click kaydı bulunamadı.")

con.close()
PY

# ======================================================
# 17. PROCESS CHECK
# ======================================================

echo
echo "========== PROCESS =========="

if [ -f "$PIDFILE" ]; then
    PID="$(cat "$PIDFILE")"

    if kill -0 "$PID" 2>/dev/null; then
        ok "Production backend PID $PID çalışıyor."
    else
        warn "PID dosyası var ancak process çalışmıyor."
    fi
fi

if [ -f "$TUNNEL_PIDFILE" ]; then
    TPID="$(cat "$TUNNEL_PIDFILE")"

    if kill -0 "$TPID" 2>/dev/null; then
        ok "Cloudflare tunnel PID $TPID çalışıyor."
    fi
fi

# ======================================================
# 18. FINAL
# ======================================================

echo
echo "======================================================"
echo "             A-Z PUBLIC AUTOMATION"
echo "                  TAMAMLANDI"
echo "======================================================"

echo "Backend       : AKTİF"
echo "SQLite        : AKTİF"
echo "MaxMind       : AKTİF"
echo "Raw IP        : ANONYMIZED"
echo "Production XFF: GÜVENLİ / KAPALI"
echo "Backup        : $BACKUP"
echo "Server Log    : $LOG"
echo "Tunnel Log    : $TUNNEL_LOG"

if [ -f "$PUBLIC_FILE" ]; then
    echo
    echo "PUBLIC HTTPS:"
    cat "$PUBLIC_FILE"
else
    echo
    echo "PUBLIC HTTPS: KURULAMADI"
fi

echo
echo "======================================================"
