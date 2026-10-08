#!/data/data/com.termux/files/usr/bin/bash

set -u
set -o pipefail

ROOT="$HOME/reklama-click-lab"
APP="$ROOT/privacy-analytics"
SERVER="$APP/server.py"
REPORT="$APP/report.html"
DB="$APP/analytics.sqlite3"
RUNTIME="$APP/.runtime"
PIDFILE="$RUNTIME/server.pid"
LOG="$APP/server.log"
BACKUP="$ROOT/backups-final/report-fix-$(date +%Y%m%d-%H%M%S)"

LOCAL="http://127.0.0.1:8080"

mkdir -p "$RUNTIME" "$BACKUP"

echo
echo "============================================================"
echo "       REPORT API FINAL FIX"
echo "============================================================"

OK=0
WARN=0
FAIL=0

ok(){ echo "[OK] $1"; OK=$((OK+1)); }
warn(){ echo "[WARN] $1"; WARN=$((WARN+1)); }
fail(){ echo "[ERROR] $1"; FAIL=$((FAIL+1)); }

# ============================================================
# 1 — BACKUP
# ============================================================

echo
echo "------------------------------------------------------------"
echo "1/8 — BACKUP"
echo "------------------------------------------------------------"

cp -f "$SERVER" "$BACKUP/server.py" || {
    fail "server.py backup başarısız"
    exit 1
}

cp -f "$REPORT" "$BACKUP/report.html" 2>/dev/null || true
cp -f "$DB" "$BACKUP/analytics.sqlite3" 2>/dev/null || true

echo "Backup:"
echo "$BACKUP"

ok "Backup tamamlandı"

# ============================================================
# 2 — PYTHON IMPORT / STRUCTURE
# ============================================================

echo
echo "------------------------------------------------------------"
echo "2/8 — SERVER STRUCTURE"
echo "------------------------------------------------------------"

grep -nE \
    'def do_GET|urlparse|parsed\.path|/health|/api/click|DB_PATH|sqlite3' \
    "$SERVER" |
    head -100

if grep -q 'def do_GET' "$SERVER"; then
    ok "do_GET bulundu"
else
    fail "do_GET bulunamadı"
    exit 1
fi

if grep -q 'parsed.path == "/health"' "$SERVER"; then
    ok "Mevcut /health yapısı tespit edildi"
else
    warn "Standart /health yapısı farklı"
fi

# ============================================================
# 3 — /api/report EKLE
# ============================================================

echo
echo "------------------------------------------------------------"
echo "3/8 — /api/report EKLENİYOR"
echo "------------------------------------------------------------"

python3 - "$SERVER" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

MARKER = "### REKLAMA_REPORT_API_FINAL ###"

if MARKER in text:
    print("[OK] /api/report zaten mevcut.")
    raise SystemExit(0)

# Gerçek dosyadaki yapı:
#
# def do_GET(self):
#     parsed = urlparse(self.path)
#     if parsed.path == "/health":

needle = 'if parsed.path == "/health":'

if needle not in text:
    print("[ERROR] parsed.path /health route bulunamadı.")
    raise SystemExit(2)

block = r'''
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

'''

text = text.replace(
    needle,
    block + "\n        " + needle,
    1
)

path.write_text(text, encoding="utf-8")

print("[OK] /api/report eklendi.")
PY

if grep -q '### REKLAMA_REPORT_API_FINAL ###' "$SERVER"; then
    ok "/api/report endpoint eklendi"
else
    fail "/api/report eklenemedi"
    exit 1
fi

# ============================================================
# 4 — SYNTAX
# ============================================================

echo
echo "------------------------------------------------------------"
echo "4/8 — PYTHON SYNTAX"
echo "------------------------------------------------------------"

if python3 -m py_compile "$SERVER"; then
    ok "server.py syntax OK"
else
    fail "Syntax hatası — backup geri yükleniyor"
    cp -f "$BACKUP/server.py" "$SERVER"
    exit 1
fi

# ============================================================
# 5 — BACKEND RESTART
# ============================================================

echo
echo "------------------------------------------------------------"
echo "5/8 — BACKEND RESTART"
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

# MaxMind config
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
) >> "$LOG" 2>&1 &

NEW_PID=$!

echo "$NEW_PID" > "$PIDFILE"

sleep 4

if kill -0 "$NEW_PID" 2>/dev/null; then
    ok "Backend aktif PID=$NEW_PID"
else
    fail "Backend başlatılamadı"
    tail -80 "$LOG"
    exit 1
fi

# ============================================================
# 6 — HEALTH + REPORT API
# ============================================================

echo
echo "------------------------------------------------------------"
echo "6/8 — API TEST"
echo "------------------------------------------------------------"

HEALTH="$RUNTIME/report-fix-health.json"
REPORT_JSON="$RUNTIME/report-fix.json"

H="$(
curl -sS \
    --connect-timeout 10 \
    --max-time 20 \
    -o "$HEALTH" \
    -w '%{http_code}' \
    "$LOCAL/health" \
    2>/dev/null || true
)"

echo "Health HTTP=$H"

if [ "$H" = "200" ]; then
    ok "/health HTTP 200"
else
    fail "/health HTTP=$H"
fi

R="$(
curl -sS \
    --connect-timeout 10 \
    --max-time 30 \
    -o "$REPORT_JSON" \
    -w '%{http_code}' \
    "$LOCAL/api/report" \
    2>/dev/null || true
)"

echo "Report API HTTP=$R"

if [ "$R" = "200" ]; then
    ok "/api/report HTTP 200"
else
    fail "/api/report HTTP=$R"
    cat "$REPORT_JSON" 2>/dev/null || true
fi

# JSON doğrulama
python3 - "$REPORT_JSON" <<'PY'
import json
import sys

p=sys.argv[1]

try:
    with open(p,encoding="utf-8") as f:
        data=json.load(f)

    assert data.get("ok") is True

    rows=data.get("rows",[])

    print("Kayıt sayısı:",len(rows))

    mm=sum(
        1
        for r in rows
        if int(r.get("maxmind_success") or 0)==1
    )

    print("MaxMind başarılı:",mm)

    raw=0

    for r in rows:
        if "ip" in r:
            raw+=1

        if "ip_hash" in r:
            raw+=1

    print("Report API raw IP/hash alanı:",raw)

    if raw != 0:
        raise SystemExit("RAW_IP_EXPOSED")

    print("[OK] Report API privacy kontrolü başarılı")

except Exception as e:
    print("[ERROR]",type(e).__name__,str(e))
    raise SystemExit(1)
PY

if [ "$?" -eq 0 ]; then
    ok "Report API JSON + privacy kontrolü OK"
else
    fail "Report API JSON/privacy kontrolü başarısız"
fi

# ============================================================
# 7 — REPORT HTML
# ============================================================

echo
echo "------------------------------------------------------------"
echo "7/8 — REPORT UI"
echo "------------------------------------------------------------"

cat > "$REPORT" <<'HTML'
<!doctype html>
<html lang="tr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="theme-color" content="#080c16">
<title>Reklama Click Lab — Rapor</title>

<style>
:root{
 --bg:#080c16;
 --panel:#111827;
 --panel2:#172033;
 --text:#f4f7fb;
 --muted:#98a2b3;
 --line:#293449;
 --accent:#7c9cff;
 --ok:#42d392;
}

*{box-sizing:border-box}

body{
 margin:0;
 background:var(--bg);
 color:var(--text);
 font-family:system-ui,-apple-system,Segoe UI,sans-serif;
}

main{
 max-width:1500px;
 margin:auto;
 padding:20px;
}

header{
 display:flex;
 justify-content:space-between;
 align-items:center;
 gap:15px;
 margin-bottom:20px;
}

h1{
 margin:0;
 font-size:28px;
}

.sub{
 color:var(--muted);
 margin-top:5px;
}

button{
 border:1px solid var(--line);
 background:var(--panel2);
 color:var(--text);
 border-radius:12px;
 padding:10px 15px;
 cursor:pointer;
}

.stats{
 display:grid;
 grid-template-columns:repeat(4,1fr);
 gap:12px;
 margin-bottom:18px;
}

.stat{
 background:var(--panel);
 border:1px solid var(--line);
 border-radius:16px;
 padding:16px;
}

.stat small{
 display:block;
 color:var(--muted);
}

.stat strong{
 display:block;
 margin-top:7px;
 font-size:24px;
}

.status{
 padding:12px;
 border:1px solid var(--line);
 background:var(--panel);
 border-radius:12px;
 margin-bottom:18px;
}

.table{
 overflow:auto;
 border:1px solid var(--line);
 border-radius:16px;
 background:var(--panel);
}

table{
 width:100%;
 min-width:1550px;
 border-collapse:collapse;
}

th,td{
 padding:11px 9px;
 border-bottom:1px solid var(--line);
 text-align:left;
 font-size:13px;
 white-space:nowrap;
}

th{
 background:var(--panel2);
 position:sticky;
 top:0;
}

.ok{
 color:var(--ok);
 font-weight:700;
}

.muted{
 color:var(--muted);
}

@media(max-width:800px){
 .stats{
  grid-template-columns:repeat(2,1fr);
 }

 main{
  padding:12px;
 }

 header{
  align-items:flex-start;
  flex-direction:column;
 }
}
</style>
</head>

<body>

<main>

<header>
 <div>
  <h1>Reklama Click Lab</h1>
  <div class="sub">
   MaxMind GeoIP · Privacy-aware analytics
  </div>
 </div>

 <button onclick="load()">Yenile</button>
</header>

<div id="status" class="status">
 Rapor yükleniyor...
</div>

<section class="stats">

 <div class="stat">
  <small>Toplam kayıt</small>
  <strong id="total">—</strong>
 </div>

 <div class="stat">
  <small>MaxMind başarılı</small>
  <strong id="mm">—</strong>
 </div>

 <div class="stat">
  <small>Ülke</small>
  <strong id="country">—</strong>
 </div>

 <div class="stat">
  <small>Şehir</small>
  <strong id="city">—</strong>
 </div>

</section>

<div class="table">

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

</main>

<script>
"use strict";

const esc = v => {
 if(v === null || v === undefined || v === "")
  return "—";

 return String(v)
  .replaceAll("&","&amp;")
  .replaceAll("<","&lt;")
  .replaceAll(">","&gt;")
  .replaceAll('"',"&quot;")
  .replaceAll("'","&#039;");
};

async function load(){

 const status=document.getElementById("status");

 status.textContent="Rapor yükleniyor...";

 try{

  const response=await fetch(
   "/api/report",
   {
    cache:"no-store",
    headers:{
     "Accept":"application/json"
    }
   }
  );

  if(!response.ok)
   throw new Error("HTTP "+response.status);

  const data=await response.json();

  if(data.ok !== true)
   throw new Error("API error");

  const rows=Array.isArray(data.rows)
   ? data.rows
   : [];

  document.getElementById("total").textContent=rows.length;

  document.getElementById("mm").textContent=
   rows.filter(
    r=>Number(r.maxmind_success)===1
   ).length;

  document.getElementById("country").textContent=
   new Set(
    rows
     .map(r=>r.country_code)
     .filter(Boolean)
   ).size;

  document.getElementById("city").textContent=
   new Set(
    rows
     .map(r=>r.city)
     .filter(Boolean)
   ).size;

  document.getElementById("rows").innerHTML=
   rows.map(r=>`

    <tr>
     <td>${esc(r.id)}</td>
     <td>${esc(r.timestamp)}</td>
     <td>${esc(r.ref)}</td>
     <td>${esc(r.event)}</td>
     <td>${esc(r.country)}</td>
     <td>${esc(r.country_code)}</td>
     <td>${esc(r.continent)}</td>
     <td>${esc(r.region)}</td>
     <td>${esc(r.city)}</td>
     <td>${esc(r.postal_code)}</td>
     <td>${esc(r.latitude)}</td>
     <td>${esc(r.longitude)}</td>
     <td>${r.accuracy_radius_km
       ? esc(r.accuracy_radius_km)+" km"
       : "—"}</td>
     <td>${esc(r.timezone)}</td>
     <td>${esc(r.network)}</td>
     <td>${esc(r.asn)}</td>
     <td>${esc(r.organization)}</td>
     <td>
       ${
        Number(r.maxmind_success)===1
        ? '<span class="ok">OK</span>'
        : '<span class="muted">—</span>'
       }
     </td>
    </tr>

   `).join("");

  status.innerHTML=
   '<span class="ok">●</span> '+
   'Canlı rapor hazır · Raw IP gösterilmez.';

 }catch(error){

  console.error(error);

  status.textContent=
   "Rapor yüklenemedi: "+error.message;
 }
}

load();
</script>

</body>
</html>
HTML

ok "report.html MaxMind tablosu hazır"

# ============================================================
# 8 — FINAL TEST
# ============================================================

echo
echo "------------------------------------------------------------"
echo "8/8 — FINAL"
echo "------------------------------------------------------------"

echo
echo "Local:"
echo "$LOCAL/report.html"

echo
echo "API:"
echo "$LOCAL/api/report"

echo
echo "PID:"
cat "$PIDFILE" 2>/dev/null || true

echo
echo "Backup:"
echo "$BACKUP"

echo
echo "============================================================"
echo "OK    : $OK"
echo "WARN  : $WARN"
echo "ERROR : $FAIL"
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
