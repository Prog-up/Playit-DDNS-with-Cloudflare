#!/usr/bin/env bash
# =============================================================================
#  deploy.sh
#  Idempotent installer for playit-sync-cloudflare and systemd integration.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Deploying Playit Cloudflare DNS Sync ==="

if [[ $EUID -ne 0 ]]; then
   echo "[!] This script must be run as root." >&2
   exit 1
fi

# 1. Install dependencies
echo "[*] Ensuring dependencies (curl, jq, dnsutils) are installed..."
if command -v apt-get &>/dev/null; then
    apt-get update -qq
    apt-get install -y -qq curl jq dnsutils
fi

# 2. Install sync script
echo "[*] Installing /usr/local/bin/playit-sync-cloudflare.sh..."
install -m 0755 "${SCRIPT_DIR}/playit-sync-cloudflare.sh" /usr/local/bin/playit-sync-cloudflare.sh

# 3. Install config if not present
mkdir -p /etc/playit
if [[ ! -f /etc/playit/cloudflare-sync.conf ]]; then
    echo "[*] Creating /etc/playit/cloudflare-sync.conf from template..."
    install -m 0600 "${SCRIPT_DIR}/cloudflare-sync.conf.example" /etc/playit/cloudflare-sync.conf
    echo "[!] Please edit /etc/playit/cloudflare-sync.conf with your API token and domain."
fi

# 4. Install systemd service
echo "[*] Installing systemd unit..."
install -m 0644 "${SCRIPT_DIR}/playit-sync-cloudflare.service" /etc/systemd/system/playit-sync-cloudflare.service
systemctl daemon-reload

echo "[+] Deployment complete! Run: /usr/local/bin/playit-sync-cloudflare.sh to synchronize DNS."
