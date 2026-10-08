# Playit-DDNS-with-Cloudflare

[![Tests](https://img.shields.io/badge/tests-passing-brightgreen.svg)]()
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: Debian%20LXC-Proxmox](https://img.shields.io/badge/Platform-Debian%2012%20LXC%20%7C%20Proxmox-orange.svg)]()

Idempotent Cloudflare DNS synchronization for **playit.gg** Minecraft Java tunnels running on Debian LXC containers in Proxmox VE.

Allows players to connect to your Minecraft server via your custom domain (e.g. `mc.prog-serv.shop`) without typing any port number, completely free, with no router port forwarding or VPN required.

---

## Architecture Overview

```
   [Minecraft Java Client]
              │
              ▼ (Connects to mc.prog-serv.shop)
    [Cloudflare DNS Server]
     ├── CNAME: mc.prog-serv.shop ──► fried-mg.tun.ply.gg (DNS-only)
     └── SRV:   _minecraft._tcp.mc.prog-serv.shop ──► Target: mc.prog-serv.shop, Port: 11769
              │
              ▼ (Resolves IP & Tunnel Port)
      [playit.gg Anycast Relay]
              │ (Encrypted UDP tunnel)
              ▼
   [Proxmox VE Hypervisor]
              │ (vnet0 bridge)
   [Debian 12 LXC Container (CT 105)]
     ├── playit agent (systemd: playit.service)
     │        │ (127.0.0.1:25565)
     │        ▼
     └── Minecraft Forge 1.20.1 (systemd: minecraft-server.service)
```

---

## Features

- **Zero Port Forwarding**: Uses `playit.gg` secure Anycast TCP/UDP tunnel.
- **Custom Domain & No Port Needed**: Updates Cloudflare DNS CNAME and SRV records automatically so players just enter `mc.yourdomain.com`.
- **Pure DNS-Only**: Bypasses Cloudflare HTTP proxying (`proxied: false`) so raw Minecraft TCP traffic flows directly without drops.
- **Idempotent Sync**: Detects configuration drift and updates Cloudflare only when records actually differ.
- **Debian LXC Optimized**: Designed for unprivileged Debian 12 LXC containers under Proxmox VE.
- **Systemd Integration**: Graceful stop signals (`SIGTERM`) for safe world saves and automatic startup.

---

## Migration from Proxmox VM to Debian LXC

### 1. Host Discovery & Preparation
- Target hypervisor: Proxmox VE
- Container specifications:
  - **Type**: Unprivileged Debian 12 (Bookworm)
  - **vCPU**: 4 cores
  - **RAM**: 12 GiB (JVM allocated 8 GiB heap: `-Xms4G -Xmx8G`)
  - **Storage**: Fast persistent storage (`local-lvm:25G`)
  - **Network**: `vnet0` (DHCP)

### 2. Minecraft Server Restoration
1. Stop old VM and verify shutdown:
   ```bash
   qm shutdown <VMID> --timeout 60
   qm set <VMID> --onboot 0
   ```
2. Create Debian 12 LXC container:
   ```bash
   pct create <CTID> local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst \
     --hostname minecraft \
     --cores 4 \
     --memory 12288 \
     --swap 2048 \
     --rootfs local-lvm:25 \
     --ostype debian \
     --unprivileged 1 \
     --features nesting=1 \
     --net0 name=eth0,bridge=vnet0,ip=dhcp,firewall=1 \
     --onboot 1 \
     --start 1
   ```
3. Install OpenJDK 17 and essentials:
   ```bash
   pct exec <CTID> -- apt-get update
   pct exec <CTID> -- apt-get install -y openjdk-17-jre-headless curl jq dnsutils gnupg sudo
   ```
4. Restore Minecraft installation to `/srv/minecraft` and ensure ownership:
   ```bash
   pct exec <CTID> -- useradd -r -m -d /srv/minecraft -s /bin/bash minecraft
   # extract backup into /srv/minecraft
   pct exec <CTID> -- chown -R minecraft:minecraft /srv/minecraft
   ```

---

## playit.gg Installation & Setup

1. Add official playit repository inside the LXC container:
   ```bash
   curl -SsL https://playit-cloud.github.io/ppa/key.gpg | gpg --dearmor -o /etc/apt/trusted.gpg.d/playit.gpg
   echo "deb [signed-by=/etc/apt/trusted.gpg.d/playit.gpg] https://playit-cloud.github.io/ppa/data ./" > /etc/apt/sources.list.d/playit.list
   apt-get update && apt-get install -y playit
   ```
2. Claim the agent via browser:
   ```bash
   playit setup
   ```
   Open the generated claim link in your browser:
   - Claim agent
   - Create tunnel: Type **Minecraft Java**
   - Local address: `127.0.0.1:25565`
3. Note your assigned playit hostname (e.g. `xxx.tun.ply.gg`) and port.

---

## Cloudflare DNS Sync Deployment

1. Run the automated installer:
   ```bash
   sudo ./deploy.sh
   ```
2. Configure credentials in `/etc/playit/cloudflare-sync.conf`:
   ```bash
   CF_API_TOKEN="your_scoped_api_token"
   CF_ZONE_ID="your_cloudflare_zone_id"
   CF_DOMAIN="mc.prog-serv.shop"
   PLAYIT_HOST="fried-mg.tun.ply.gg"
   PLAYIT_PORT="11769"
   ```
3. Trigger synchronization:
   ```bash
   /usr/local/bin/playit-sync-cloudflare.sh
   ```

---

## Systemd Units

### Minecraft Service (`/etc/systemd/system/minecraft-server.service`)
```ini
[Unit]
Description=Minecraft Server - Create Chronicles Bosses and Beyond
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=minecraft
Group=minecraft
WorkingDirectory=/srv/minecraft
ExecStart=/usr/bin/java @user_jvm_args.txt @libraries/net/minecraftforge/forge/1.20.1-47.2.20/unix_args.txt nogui
KillSignal=SIGTERM
TimeoutStopSec=90
TimeoutStartSec=300
Restart=on-failure
RestartSec=30
LimitNOFILE=65536
StandardInput=null
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

---

## Verification & Testing

- **TCP Reachability**:
  ```bash
  nc -zv fried-mg.tun.ply.gg 11769
  ```
- **DNS Resolution**:
  ```bash
  dig @1.1.1.1 mc.prog-serv.shop CNAME +short
  dig @1.1.1.1 _minecraft._tcp.mc.prog-serv.shop SRV +short
  ```
- **Automated Tests**:
  ```bash
  ./tests/test_sync.sh
  ```

---

## Rollback Procedure

If you ever need to roll back to the original Proxmox VM:
1. Stop the LXC container:
   ```bash
   pct stop 105
   pct set 105 --onboot 0
   ```
2. Re-enable and start the original VM (ID 103):
   ```bash
   qm set 103 --onboot 1
   qm start 103
   ```
3. Re-enable original services on the VM:
   ```bash
   systemctl enable --now minecraft-server.service
   systemctl enable --now minecraft-ngrok.service
   ```
4. Verify the rollback instance is active.
