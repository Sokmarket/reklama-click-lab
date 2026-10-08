#!/data/data/com.termux/files/usr/bin/bash

set -e

cd "$HOME/reklama-click-lab"

source "$HOME/.maxmind/config"

export MAXMIND_ACCOUNT_ID="$MM_ACCOUNT_ID"
export MAXMIND_LICENSE_KEY="$MM_LICENSE_KEY"

python maxmind-api/server.py &
PID=$!

trap 'kill "$PID" 2>/dev/null || true' EXIT

sleep 2

echo
echo "[*] Health test:"
curl -sS http://127.0.0.1:8787/health | jq .

echo
echo "[*] MaxMind test:"
curl -sS http://127.0.0.1:8787/api/maxmind | jq .
