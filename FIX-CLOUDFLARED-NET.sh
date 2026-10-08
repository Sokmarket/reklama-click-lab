#!/data/data/com.termux/files/usr/bin/bash
set -u

echo "========================================"
echo " CLOUDFLARED / DNS FIX"
echo "========================================"

echo
echo "[1/7] Termux mimarisi:"
uname -m

echo
echo "[2/7] DNS kontrolü:"
getent hosts github.com 2>/dev/null || true
getent hosts cloudflare.com 2>/dev/null || true

echo
echo "[3/7] İnternet kontrolü:"
curl -I --connect-timeout 10 --max-time 20 https://cloudflare.com 2>&1 | head -20 || true

echo
echo "[4/7] Paket deposu:"
pkg update -y

echo
echo "[5/7] cloudflared paket kontrolü:"
if pkg search cloudflared 2>/dev/null | grep -qi cloudflared; then
    echo "[OK] Termux deposunda cloudflared bulundu."
    pkg install -y cloudflared
else
    echo "[INFO] Termux deposunda cloudflared paketi bulunamadı."
fi

echo
echo "[6/7] Kurulum kontrolü:"
if command -v cloudflared >/dev/null 2>&1; then
    echo "[OK] cloudflared bulundu:"
    command -v cloudflared
    cloudflared --version || true
else
    echo "[WARN] cloudflared henüz kurulmadı."
fi

echo
echo "[7/7] Backend kontrolü:"
if [ -f privacy-analytics/.runtime/server.pid ]; then
    PID="$(cat privacy-analytics/.runtime/server.pid 2>/dev/null || true)"
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        echo "[OK] Backend çalışıyor. PID=$PID"
    else
        echo "[WARN] PID dosyası var fakat backend çalışmıyor."
    fi
else
    echo "[WARN] Backend PID dosyası bulunamadı."
fi

echo
echo "========================================"
echo " SONUÇ"
echo "========================================"
echo "Cloudflared kurulumu ayrı tutuldu."
echo "Backend dosyalarına dokunulmadı."
echo "MaxMind ayarları değiştirilmedi."
echo "========================================"
