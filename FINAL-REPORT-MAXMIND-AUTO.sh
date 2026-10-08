#!/data/data/com.termux/files/usr/bin/bash

set -u
set -o pipefail

ROOT="$HOME/reklama-click-lab"
APP="$ROOT/privacy-analytics"
SERVER="$APP/server.py"
REPORT="$APP/report.html"
DB="$APP/analytics.sqlite3"
RUNTIME="$APP/.runtime"
BACKUP="$ROOT/backups-final/report-$(date +%Y%m%d-%H%M%S)"

LOCAL="http://127.0.0.1:8080"
PIDFILE="$RUNTIME/server.pid"
CFPID="$RUNTIME/cloudflared.pid"
CFLOG="$RUNTIME/cloudflared.log"

mkdir -p "$RUNTIME" "$BACKUP"

echo
echo "============================================================"
echo "     REKLAMA-CLICK-LAB FINAL REPORT + MAXMIND AUTOMATION"
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
echo "1/10 — BACKUP"
echo "------------------------------------------------------------"

cp -f "$REPORT" "$BACKUP/report.html" 2>/dev/null || true
cp -f "$SERVER" "$BACKUP/server.py" 2>/dev/null || true
cp -f "$DB" "$BACKUP/analytics.sqlite3" 2>/dev/null || true

echo "Backup:"
echo "$BACKUP"

ok "Backup tamamlandı"

# ============================================================
# 2 — DOSYA / DB KONTROL
# ============================================================

echo
echo "------------------------------------------------------------"
echo "2/10 — DOSYA VE SQLITE"
echo "------------------------------------------------------------"

[ -f "$REPORT" ] && ok "report.html mevcut" || {
    fail "report.html bulunamadı"
    exit 1
}

[ -f "$SERVER" ] && ok "server.py mevcut" || {
    fail "server.py bulunamadı"
    exit 1
}

[ -f "$DB" ] && ok "SQLite mevcut" || {
    fail "SQLite bulunamadı"
    exit 1
}

REQUIRED="
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

for COL in $REQUIRED; do
    if ! sqlite3 "$DB" "PRAGMA table_info(clicks);" |
        awk -F'|' '{print $2}' |
        grep -qx "$COL"; then

        echo "[MISSING] $COL"
        MISSING=$((MISSING+1))
    fi
done

if [ "$MISSING" -eq 0 ]; then
    ok "MaxMind SQLite alanları tam"
else
    fail "SQLite alanları eksik: $MISSING"
    exit 1
fi

# ============================================================
# 3 — SERVER API TARAMA
# ============================================================

echo
echo "------------------------------------------------------------"
echo "3/10 — EXISTING API DISCOVERY"
echo "------------------------------------------------------------"

echo "Mevcut GET endpointleri:"

grep -nE \
    'path|do_GET|/api/|/health|SELECT .*clicks|json.dumps' \
    "$SERVER" |
    head -120 || true

# ============================================================
# 4 — SERVER'E RAPOR ENDPOINTİ EKLE
# ============================================================

echo
echo "------------------------------------------------------------"
echo "4/10 — REPORT API"
echo "------------------------------------------------------------"

python3 - "$SERVER" <<'PY'
from pathlib import Path
import re
import shutil
import sys

p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8")

marker = "### MAXMIND_REPORT_API ###"

if marker in s:
    print("[OK] MaxMind report API zaten mevcut.")
    raise SystemExit(0)

# Do_GET içine ekleme için güvenli hedef:
# /health kontrolünün hemen öncesine yeni route ekleniyor.
needle = "if self.path == \"/health\":"

if needle not in s:
    print("[ERROR] /health route bulunamadı.")
    raise SystemExit(2)

block = r'''
        # ### MAXMIND_REPORT_API ###
        if self.path.split("?", 1)[0] == "/api/report":
            try:
                conn = sqlite3.connect(DB_PATH)
                conn.row_factory = sqlite3.Row

                rows = conn.execute("""
                    SELECT
                        id,
                        timestamp,
                        ref,
                        event,
                        consent,
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

                    # Raw IP kesinlikle report API'ye çıkmaz.
                    item.pop("ip", None)
                    item.pop("ip_hash", None)

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
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.send_header("Access-Control-Allow-Origin", "*")
                self.send_header("Cache-Control", "no-store")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return

            except Exception as exc:
                body = json.dumps(
                    {
                        "ok": False,
                        "error": type(exc).__name__
                    }
                ).encode("utf-8")

                self.send_response(500)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.send_header("Access-Control-Allow-Origin", "*")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return

'''

s = s.replace(needle, block + "\n" + needle, 1)

p.write_text(s, encoding="utf-8")
print("[OK] /api/report eklendi.")
PY

if grep -q '### MAXMIND_REPORT_API ###' "$SERVER"; then
    ok "MaxMind report API hazır"
else
    fail "Report API eklenemedi"
    exit 1
fi

# ============================================================
# 5 — PYTHON SYNTAX
# ============================================================

echo
echo "------------------------------------------------------------"
echo "5/10 — PYTHON SYNTAX"
echo "------------------------------------------------------------"

if python3 -m py_compile "$SERVER"; then
    ok "server.py syntax OK"
else
    fail "server.py syntax hatalı"
    cp -f "$BACKUP/server.py" "$SERVER"
    exit 1
fi

# ============================================================
# 6 — REPORT HTML
# ============================================================

echo
echo "------------------------------------------------------------"
echo "6/10 — REPORT UI"
echo "------------------------------------------------------------"

cat > "$REPORT" <<'HTML'
<!doctype html>
<html lang="tr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="theme-color" content="#0b1020">
<title>Reklama Click Lab — Analytics</title>

<style>
:root{
  --bg:#080c16;
  --panel:#111827;
  --panel2:#172033;
  --text:#f4f7fb;
  --muted:#98a2b3;
  --line:#263247;
  --ok:#42d392;
  --warn:#f5b942;
  --bad:#ff6b6b;
  --accent:#7c9cff;
}

*{
  box-sizing:border-box;
}

html,body{
  margin:0;
  padding:0;
  background:var(--bg);
  color:var(--text);
  font-family:
    Inter,
    system-ui,
    -apple-system,
    BlinkMacSystemFont,
    "Segoe UI",
    sans-serif;
}

body{
  min-height:100vh;
}

.container{
  width:min(1400px,100%);
  margin:auto;
  padding:20px;
}

header{
  display:flex;
  justify-content:space-between;
  align-items:center;
  gap:16px;
  margin-bottom:20px;
}

h1{
  margin:0;
  font-size:clamp(22px,4vw,34px);
}

.subtitle{
  margin-top:6px;
  color:var(--muted);
  font-size:14px;
}

button{
  border:1px solid var(--line);
  background:var(--panel2);
  color:var(--text);
  border-radius:12px;
  padding:11px 15px;
  cursor:pointer;
}

button:hover{
  border-color:var(--accent);
}

.cards{
  display:grid;
  grid-template-columns:repeat(4,minmax(0,1fr));
  gap:12px;
  margin-bottom:20px;
}

.card{
  background:var(--panel);
  border:1px solid var(--line);
  border-radius:16px;
  padding:16px;
}

.card .label{
  color:var(--muted);
  font-size:12px;
}

.card .value{
  margin-top:7px;
  font-size:24px;
  font-weight:700;
}

.table-wrap{
  overflow:auto;
  border:1px solid var(--line);
  border-radius:16px;
  background:var(--panel);
}

table{
  width:100%;
  border-collapse:collapse;
  min-width:1500px;
}

th,td{
  padding:12px 10px;
  border-bottom:1px solid var(--line);
  text-align:left;
  white-space:nowrap;
  font-size:13px;
}

th{
  position:sticky;
  top:0;
  background:var(--panel2);
  z-index:2;
}

.muted{
  color:var(--muted);
}

.ok{
  color:var(--ok);
  font-weight:700;
}

.warn{
  color:var(--warn);
  font-weight:700;
}

.bad{
  color:var(--bad);
  font-weight:700;
}

.status{
  margin-bottom:16px;
  padding:12px 14px;
  border-radius:12px;
  background:var(--panel);
  border:1px solid var(--line);
}

@media(max-width:900px){
  .cards{
    grid-template-columns:repeat(2,minmax(0,1fr));
  }

  .container{
    padding:14px;
  }

  header{
    align-items:flex-start;
    flex-direction:column;
  }
}

@media(max-width:520px){
  .cards{
    grid-template-columns:1fr 1fr;
  }

  .card{
    padding:13px;
  }

  .card .value{
    font-size:20px;
  }
}
</style>
</head>

<body>

<div class="container">

<header>
  <div>
    <h1>Reklama Click Lab</h1>
    <div class="subtitle">
      Privacy-aware analytics · MaxMind GeoIP enrichment
    </div>
  </div>

  <button onclick="loadReport()">Yenile</button>
</header>

<div id="status" class="status">
  Rapor yükleniyor...
</div>

<section class="cards">

  <div class="card">
    <div class="label">Toplam kayıt</div>
    <div id="total" class="value">—</div>
  </div>

  <div class="card">
    <div class="label">MaxMind başarılı</div>
    <div id="maxmind" class="value">—</div>
  </div>

  <div class="card">
    <div class="label">Ülke sayısı</div>
    <div id="countries" class="value">—</div>
  </div>

  <div class="card">
    <div class="label">Şehir bilgisi</div>
    <div id="cities" class="value">—</div>
  </div>

</section>

<div class="table-wrap">

<table>

<thead>
<tr>
<th>ID</th>
<th>Zaman</th>
<th>Ref</th>
<th>Event</th>
<th>Ülke</th>
<th>Kod</th>
<th>Kıta</th>
<th>Bölge</th>
<th>Şehir</th>
<th>Posta</th>
<th>Latitude</th>
<th>Longitude</th>
<th>Accuracy</th>
<th>Timezone</th>
<th>Network</th>
<th>ASN</th>
<th>Organization</th>
<th>MaxMind</th>
</tr>
</thead>

<tbody id="rows"></tbody>

</table>

</div>

</div>

<script>
"use strict";

const esc = value => {
  if(value === null || value === undefined || value === ""){
    return "—";
  }

  return String(value)
    .replaceAll("&","&amp;")
    .replaceAll("<","&lt;")
    .replaceAll(">","&gt;")
    .replaceAll('"',"&quot;")
    .replaceAll("'","&#039;");
};

function cell(value){
  return `<td>${esc(value)}</td>`;
}

async function loadReport(){

  const status = document.getElementById("status");

  status.textContent = "Rapor yükleniyor...";

  try{

    const response = await fetch("/api/report",{
      method:"GET",
      cache:"no-store",
      headers:{
        "Accept":"application/json"
      }
    });

    if(!response.ok){
      throw new Error("HTTP " + response.status);
    }

    const result = await response.json();

    if(!result.ok){
      throw new Error("API error");
    }

    const rows = Array.isArray(result.rows) ? result.rows : [];

    document.getElementById("total").textContent = rows.length;

    const maxmindCount =
      rows.filter(r => Number(r.maxmind_success) === 1).length;

    document.getElementById("maxmind").textContent = maxmindCount;

    const countries = new Set(
      rows
        .map(r => r.country_code)
        .filter(Boolean)
    );

    document.getElementById("countries").textContent = countries.size;

    const cities = new Set(
      rows
        .map(r => r.city)
        .filter(Boolean)
    );

    document.getElementById("cities").textContent = cities.size;

    const tbody = document.getElementById("rows");

    tbody.innerHTML = rows.map(r => {

      const mm =
        Number(r.maxmind_success) === 1
          ? '<span class="ok">OK</span>'
          : '<span class="muted">Yok</span>';

      return `
        <tr>
          ${cell(r.id)}
          ${cell(r.timestamp)}
          ${cell(r.ref)}
          ${cell(r.event)}
          ${cell(r.country)}
          ${cell(r.country_code)}
          ${cell(r.continent)}
          ${cell(r.region)}
          ${cell(r.city)}
          ${cell(r.postal_code)}
          ${cell(r.latitude)}
          ${cell(r.longitude)}
          ${cell(r.accuracy_radius_km ? r.accuracy_radius_km + " km" : null)}
          ${cell(r.timezone)}
          ${cell(r.network)}
          ${cell(r.asn)}
          ${cell(r.organization)}
          <td>${mm}</td>
        </tr>
      `;

    }).join("");

    status.innerHTML =
      '<span class="ok">●</span> ' +
      'Canlı SQLite raporu · Raw IP rapora dahil edilmez.';

  }catch(error){

    console.error(error);

    status.innerHTML =
      '<span class="bad">●</span> ' +
      'Rapor yüklenemedi: ' +
      esc(error.message);

  }
}

loadReport();
</script>

</body>
</html>
HTML

ok "report.html MaxMind UI ile güncellendi"

# ============================================================
# 7 — SERVER RESTART
# ============================================================

echo
echo "------------------------------------------------------------"
echo "7/10 — BACKEND RESTART"
echo "------------------------------------------------------------"

OLD_PID=""

if [ -f "$PIDFILE" ]; then
    OLD_PID="$(cat "$PIDFILE" 2>/dev/null || true)"
fi

if [ -n "$OLD_PID" ] &&
   kill -0 "$OLD_PID" 2>/dev/null; then

    kill "$OLD_PID" 2>/dev/null || true
    sleep 2

    if kill -0 "$OLD_PID" 2>/dev/null; then
        kill -9 "$OLD_PID" 2>/dev/null || true
    fi
fi

# MaxMind credentials'i config'ten güvenli oku
MM_CONFIG="$HOME/.maxmind/config"

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

(
    cd "$APP" || exit 1

    export MM_ACCOUNT_ID
    export MM_LICENSE_KEY
    export TRUST_PROXY="1"
    export TRUSTED_PROXY_IPS="127.0.0.1"
    export PYTHONUNBUFFERED="1"

    exec python3 "$SERVER"
) >> "$APP/server.log" 2>&1 &

NEW_PID=$!

echo "$NEW_PID" > "$PIDFILE"

sleep 4

if kill -0 "$NEW_PID" 2>/dev/null; then
    ok "Backend yeniden başladı PID=$NEW_PID"
else
    fail "Backend başlatılamadı"
    tail -80 "$APP/server.log"
    exit 1
fi

# ============================================================
# 8 — LOCAL API REPORT TEST
# ============================================================

echo
echo "------------------------------------------------------------"
echo "8/10 — REPORT API TEST"
echo "------------------------------------------------------------"

REPORT_JSON="$RUNTIME/report-test.json"

HTTP="$(
curl -sS \
    --connect-timeout 10 \
    --max-time 30 \
    -o "$REPORT_JSON" \
    -w '%{http_code}' \
    "$LOCAL/api/report" \
    2>"$RUNTIME/report-test.err" || true
)"

echo "HTTP=$HTTP"

if [ "$HTTP" = "200" ] &&
   grep -q '"ok": true' "$REPORT_JSON" 2>/dev/null; then

    ok "/api/report başarılı"

    python3 - "$REPORT_JSON" <<'PY'
import json
import sys

p=sys.argv[1]

d=json.load(open(p,encoding="utf-8"))

rows=d.get("rows",[])

print("Kayıt:", len(rows))

mm=sum(
    1 for r in rows
    if int(r.get("maxmind_success") or 0)==1
)

print("MaxMind başarılı:", mm)

raw=[]

for r in rows:
    if "ip" in r:
        raw.append(r)

print("Report API raw IP alanı:", len(raw))
PY

else

    fail "/api/report başarısız"

    cat "$RUNTIME/report-test.err" 2>/dev/null || true
    cat "$REPORT_JSON" 2>/dev/null || true
fi

# ============================================================
# 9 — RAW IP + HTML SECRET CHECK
# ============================================================

echo
echo "------------------------------------------------------------"
echo "9/10 — PRIVACY CHECK"
echo "------------------------------------------------------------"

if grep -Eqi \
    'ip_hash|client_ip|remote_addr|x-forwarded-for' \
    "$REPORT"; then

    warn "Frontend kaynakta IP ile ilgili teknik kelimeler bulundu"

else

    ok "report.html raw IP erişimi içermiyor"
fi

RAW_REPORT_API="$(
python3 - "$REPORT_JSON" <<'PY'
import json
import sys

try:
    d=json.load(open(sys.argv[1],encoding="utf-8"))
    rows=d.get("rows",[])
    print(sum(1 for r in rows if "ip" in r))
except Exception:
    print(999)
PY
)"

if [ "$RAW_REPORT_API" = "0" ]; then
    ok "Report API raw IP döndürmüyor"
else
    fail "Report API raw IP alanı döndürüyor"
fi

# ============================================================
# 10 — FINAL
# ============================================================

echo
echo "------------------------------------------------------------"
echo "10/10 — FINAL"
echo "------------------------------------------------------------"

echo "Backend:"
echo "$LOCAL"

echo
echo "Report:"
echo "$LOCAL/report.html"

echo
echo "Report API:"
echo "$LOCAL/api/report"

echo
echo "Backup:"
echo "$BACKUP"

echo
echo "============================================================"
echo " OK    : $OK"
echo " WARN  : $WARN"
echo " ERROR : $FAIL"
echo "============================================================"

if [ "$FAIL" -eq 0 ]; then
    echo
    echo "REPORT + MAXMIND OTOMASYONU BAŞARILI"
    echo
else
    echo
    echo "REPORT OTOMASYONUNDA HATA VAR"
    echo "Backup:"
    echo "$BACKUP"
    echo
fi

echo "============================================================"
