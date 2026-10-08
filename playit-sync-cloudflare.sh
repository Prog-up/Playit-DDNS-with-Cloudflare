#!/usr/bin/env bash
# =============================================================================
#  playit-sync-cloudflare.sh
#  Discovers the playit.gg tunnel endpoint (or accepts it via CLI/env),
#  and idempotently configures Cloudflare DNS:
#    - CNAME <CF_DOMAIN> -> <PLAYIT_HOST> (DNS-only / proxied: false)
#    - SRV   _minecraft._tcp.<CF_DOMAIN> -> target <CF_DOMAIN>, port <PLAYIT_PORT>
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# CONFIGURATION / ENVIRONMENT VARIABLES
# -----------------------------------------------------------------------------
CF_API_TOKEN="${CF_API_TOKEN:-}"
CF_ZONE_ID="${CF_ZONE_ID:-}"
CF_DOMAIN="${CF_DOMAIN:-mc.example.com}"

PLAYIT_HOST="${PLAYIT_HOST:-}"
PLAYIT_PORT="${PLAYIT_PORT:-}"
CONFIG_FILE="${CONFIG_FILE:-/etc/playit/cloudflare-sync.conf}"

# Load config file if present
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

usage() {
    cat << EOF
Usage: $(basename "$0") [options]

Idempotent Cloudflare DNS synchronizer for playit.gg Minecraft tunnels.

Options:
  -t, --token <token>       Cloudflare API Token (Zone:DNS:Edit)
  -z, --zone-id <id>        Cloudflare Zone ID
  -d, --domain <domain>     Custom Minecraft domain (e.g. mc.example.com)
  -H, --host <playit_host>  Playit tunnel hostname (e.g. xxx.tun.ply.gg)
  -p, --port <playit_port>  Playit tunnel port (e.g. 11769)
  -c, --config <file>       Path to config file (default: /etc/playit/cloudflare-sync.conf)
  -h, --help                Show this help message

Environment variables supported:
  CF_API_TOKEN, CF_ZONE_ID, CF_DOMAIN, PLAYIT_HOST, PLAYIT_PORT, CONFIG_FILE
EOF
    exit 0
}

# Parse CLI arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--token) CF_API_TOKEN="$2"; shift 2 ;;
        -z|--zone-id) CF_ZONE_ID="$2"; shift 2 ;;
        -d|--domain) CF_DOMAIN="$2"; shift 2 ;;
        -H|--host) PLAYIT_HOST="$2"; shift 2 ;;
        -p|--port) PLAYIT_PORT="$2"; shift 2 ;;
        -c|--config)
            CONFIG_FILE="$2"
            if [[ -f "$CONFIG_FILE" ]]; then
                # shellcheck disable=SC1090
                source "$CONFIG_FILE"
            fi
            shift 2
            ;;
        -h|--help) usage ;;
        *) echo "[!] Unknown option: $1" >&2; exit 1 ;;
    esac
done

# -----------------------------------------------------------------------------
# DEPENDENCY CHECK
# -----------------------------------------------------------------------------
check_deps() {
    local missing=()
    for cmd in curl jq; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if ! command -v dig &>/dev/null && ! command -v python3 &>/dev/null; then
        missing+=("dig (or python3)")
    fi
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "[!] Missing required dependencies: ${missing[*]}" >&2
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# DISCOVER PLAYIT ENDPOINT (IF NOT EXPLICITLY PROVIDED)
# -----------------------------------------------------------------------------
discover_playit_endpoint() {
    if [[ -n "$PLAYIT_HOST" && -n "$PLAYIT_PORT" ]]; then
        return 0
    fi

    echo "[*] Discovering playit.gg tunnel endpoint..." >&2

    # Check if playit status or logs have the tunnel domain
    local log_file="/var/log/playit/playit.log"
    if [[ -z "$PLAYIT_HOST" && -f "$log_file" ]]; then
        PLAYIT_HOST=$(grep -oE '[a-zA-Z0-9-]+\.tun\.ply\.gg' "$log_file" | tail -n1 || true)
    fi

    if [[ -z "$PLAYIT_HOST" ]]; then
        echo "[!] Could not automatically discover PLAYIT_HOST." >&2
        echo "    Please specify with --host <hostname> or set PLAYIT_HOST in config." >&2
        exit 1
    fi

    if [[ -z "$PLAYIT_PORT" ]]; then
        echo "[*] Resolving SRV/port for ${PLAYIT_HOST} via DNS..." >&2
        if command -v dig &>/dev/null; then
            local srv_result
            srv_result=$(dig "${PLAYIT_HOST}" any +short | grep -E '^[0-9]+ [0-9]+ [0-9]+' | head -n1 || true)
            if [[ -n "$srv_result" ]]; then
                PLAYIT_PORT=$(echo "$srv_result" | awk '{print $3}')
            fi
        elif command -v python3 &>/dev/null; then
            PLAYIT_PORT=$(python3 -c "import socket; print(socket.getaddrinfo('${PLAYIT_HOST}', 0)[0][4][1])" 2>/dev/null || true)
        fi
    fi

    if [[ -z "$PLAYIT_PORT" ]]; then
        echo "[!] Could not resolve port for ${PLAYIT_HOST}. Please specify --port <port>." >&2
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# CLOUDFLARE API HELPERS
# -----------------------------------------------------------------------------
cf_api() {
    local method="$1"
    local endpoint="$2"
    shift 2

    local response
    response=$(curl -sf -X "$method" \
        "https://api.cloudflare.com/client/v4${endpoint}" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        "$@")

    local success
    success=$(echo "$response" | jq -r '.success')
    if [[ "$success" != "true" ]]; then
        local errors
        errors=$(echo "$response" | jq -c '.errors')
        echo "[!] Cloudflare API error on ${method} ${endpoint}: ${errors}" >&2
        return 1
    fi

    echo "$response"
}

get_record() {
    local type="$1"
    local name="$2"
    cf_api GET "/zones/${CF_ZONE_ID}/dns_records?type=${type}&name=${name}" \
        | jq -r '.result[0] // empty'
}

sync_cname() {
    local record
    record=$(get_record "CNAME" "$CF_DOMAIN")

    local existing_id existing_content existing_proxied
    existing_id=$(echo "$record" | jq -r '.id // empty')
    existing_content=$(echo "$record" | jq -r '.content // empty')
    existing_proxied=$(echo "$record" | jq -r '.proxied // empty')

    if [[ -n "$existing_id" ]]; then
        if [[ "$existing_content" == "$PLAYIT_HOST" && "$existing_proxied" == "false" ]]; then
            echo "[=] CNAME record for ${CF_DOMAIN} already points to ${PLAYIT_HOST} (DNS-only). No update needed."
            return 0
        fi
        echo "[*] Updating CNAME record for ${CF_DOMAIN}: ${existing_content} -> ${PLAYIT_HOST} (proxied: false)..."
        local payload
        payload=$(jq -n --arg name "$CF_DOMAIN" --arg content "$PLAYIT_HOST" \
            '{type:"CNAME", name:$name, content:$content, ttl:1, proxied:false}')
        cf_api PUT "/zones/${CF_ZONE_ID}/dns_records/${existing_id}" --data "$payload" > /dev/null
        echo "[+] CNAME record updated successfully."
    else
        echo "[*] Creating new CNAME record for ${CF_DOMAIN} -> ${PLAYIT_HOST}..."
        local payload
        payload=$(jq -n --arg name "$CF_DOMAIN" --arg content "$PLAYIT_HOST" \
            '{type:"CNAME", name:$name, content:$content, ttl:1, proxied:false}')
        cf_api POST "/zones/${CF_ZONE_ID}/dns_records" --data "$payload" > /dev/null
        echo "[+] CNAME record created successfully."
    fi
}

sync_srv() {
    local srv_name="_minecraft._tcp.${CF_DOMAIN}"
    local record
    record=$(get_record "SRV" "$srv_name")

    local existing_id existing_port existing_target
    existing_id=$(echo "$record" | jq -r '.id // empty')
    existing_port=$(echo "$record" | jq -r '.data.port // empty')
    existing_target=$(echo "$record" | jq -r '.data.target // empty')

    if [[ -n "$existing_id" ]]; then
        if [[ "$existing_port" == "$PLAYIT_PORT" && "$existing_target" == "$CF_DOMAIN" ]]; then
            echo "[=] SRV record for ${srv_name} already points to ${CF_DOMAIN}:${PLAYIT_PORT}. No update needed."
            return 0
        fi
        echo "[*] Updating SRV record for ${srv_name} -> target: ${CF_DOMAIN}, port: ${PLAYIT_PORT}..."
        local payload
        payload=$(jq -n \
            --arg name "$srv_name" \
            --arg target "$CF_DOMAIN" \
            --argjson port "$PLAYIT_PORT" \
            '{
                type: "SRV",
                name: $name,
                ttl: 1,
                data: {
                    service: "_minecraft",
                    proto: "_tcp",
                    name: $name,
                    priority: 0,
                    weight: 5,
                    port: $port,
                    target: $target
                }
            }')
        cf_api PUT "/zones/${CF_ZONE_ID}/dns_records/${existing_id}" --data "$payload" > /dev/null
        echo "[+] SRV record updated successfully."
    else
        echo "[*] Creating new SRV record for ${srv_name} -> target: ${CF_DOMAIN}, port: ${PLAYIT_PORT}..."
        local payload
        payload=$(jq -n \
            --arg name "$srv_name" \
            --arg target "$CF_DOMAIN" \
            --argjson port "$PLAYIT_PORT" \
            '{
                type: "SRV",
                name: $name,
                ttl: 1,
                data: {
                    service: "_minecraft",
                    proto: "_tcp",
                    name: $name,
                    priority: 0,
                    weight: 5,
                    port: $port,
                    target: $target
                }
            }')
        cf_api POST "/zones/${CF_ZONE_ID}/dns_records" --data "$payload" > /dev/null
        echo "[+] SRV record created successfully."
    fi
}

main() {
    check_deps

    if [[ -z "$CF_API_TOKEN" || -z "$CF_ZONE_ID" || -z "$CF_DOMAIN" ]]; then
        echo "[!] CF_API_TOKEN, CF_ZONE_ID, and CF_DOMAIN must be set." >&2
        exit 1
    fi

    discover_playit_endpoint

    echo "============================================================"
    echo "  Playit.gg -> Cloudflare DNS Synchronization"
    echo "  Domain:      ${CF_DOMAIN}"
    echo "  Playit Host: ${PLAYIT_HOST}"
    echo "  Playit Port: ${PLAYIT_PORT}"
    echo "============================================================"

    sync_cname
    sync_srv

    echo ""
    echo "============================================================"
    echo "  DNS Sync complete!"
    echo "  Players connect to: ${CF_DOMAIN} (no port needed)"
    echo "============================================================"
}

main "$@"
