#!/data/data/com.termux/files/usr/bin/bash

set -e

cd "$HOME/reklama-click-lab"

source "$HOME/.maxmind/config"

export MAXMIND_ACCOUNT_ID="$MM_ACCOUNT_ID"
export MAXMIND_LICENSE_KEY="$MM_LICENSE_KEY"

echo "========================================"
echo " MAXMIND VISITOR API"
echo "========================================"
echo "Account ID: $MAXMIND_ACCOUNT_ID"
echo "License Key: [GİZLİ]"
echo

python maxmind-api/server.py
