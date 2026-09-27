#!/usr/bin/env bash
# Prepares a clean Debian/Ubuntu x86_64 server for Home. Safe to run again.
#
#   sudo scripts/server-bootstrap.sh --domain myhome --duckdns-token <token> \
#        --bot-token <telegram-bot-token> --admin <your-telegram-id> [--firewall] [--lan 192.168.1.0/24]
#
#   --domain X          DuckDNS name (X.duckdns.org); enables DuckDNS updates and Caddy HTTPS
#   --duckdns-token T   DuckDNS token (or --duckdns-token-file F)
#   --bot-token T       Telegram bot token from @BotFather (or --bot-token-file F)
#   --admin ID          Telegram id of the first admin (write /id to the bot to learn it)
#   --firewall          install nftables rules (SSH stays open; devices/API only from the LAN)
#   --lan CIDR          home network (default: detected from the default route)
#   --https-port N      external HTTPS port (default 443). If 443 is used by another application,
#                       take e.g. 8443: the certificate is then obtained through DuckDNS DNS
#                       (no need for ports 80/443), the Mini App address becomes https://X.duckdns.org:N
#   --no-caddy          skip Caddy (e.g. you terminate HTTPS elsewhere)
set -euo pipefail
cd "$(dirname "$0")/.."

DOMAIN="" DUCK_TOKEN="" BOT_TOKEN="" ADMIN="" FIREWALL=0 LAN="" CADDY=1 HTTPS_PORT=443
while [ $# -gt 0 ]; do
    case "$1" in
        --domain) DOMAIN=${2%.duckdns.org}; shift ;;
        --duckdns-token) DUCK_TOKEN=$2; shift ;;
        --duckdns-token-file) DUCK_TOKEN=$(cat "$2"); shift ;;
        --bot-token) BOT_TOKEN=$2; shift ;;
        --bot-token-file) BOT_TOKEN=$(cat "$2"); shift ;;
        --admin) ADMIN=$2; shift ;;
        --firewall) FIREWALL=1 ;;
        --lan) LAN=$2; shift ;;
        --https-port) HTTPS_PORT=$2; shift ;;
        --no-caddy) CADDY=0 ;;
        -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
        *) echo "unknown option $1" >&2; exit 2 ;;
    esac
    shift
done

[ "$(id -u)" = 0 ] || { echo "run as root (sudo)" >&2; exit 1; }
[[ "$HTTPS_PORT" =~ ^[0-9]+$ ]] || { echo "--https-port must be a number" >&2; exit 2; }
if [ "$HTTPS_PORT" != 443 ] && [ "$CADDY" = 1 ] && [ -z "$DUCK_TOKEN" ] && [ ! -f /etc/home/duckdns.env ]; then
    echo "--https-port $HTTPS_PORT needs --duckdns-token (the certificate is obtained through DuckDNS DNS)" >&2
    exit 2
fi
PORT_SUFFIX=""
[ "$HTTPS_PORT" != 443 ] && PORT_SUFFIX=":$HTTPS_PORT"
command -v apt-get >/dev/null || { echo "Debian/Ubuntu expected (apt-get)" >&2; exit 1; }
case "$(uname -m)" in x86_64) ;; *) echo "warning: built and tested for x86_64, this is $(uname -m)" >&2 ;; esac
say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

say "packages"
export DEBIAN_FRONTEND=noninteractive
if [ -z "${SKIP_APT:-}" ]; then
apt-get update -q
apt-get install -y -q ca-certificates curl sqlite3 nftables chrony gnupg debian-keyring debian-archive-keyring apt-transport-https >/dev/null
if [ "$CADDY" = 1 ] && ! command -v caddy >/dev/null; then
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
    apt-get update -q && apt-get install -y -q caddy >/dev/null
fi
if [ "$CADDY" = 1 ] && [ "$HTTPS_PORT" != 443 ] && ! caddy list-modules 2>/dev/null | grep -q '^dns.providers.duckdns'; then
    # DNS challenge through DuckDNS: Caddy with the caddy-dns/duckdns module (held so apt does not replace it).
    caddy add-package github.com/caddy-dns/duckdns >/dev/null
    apt-mark hold caddy >/dev/null
    echo "Caddy: duckdns DNS module installed (apt upgrades of caddy are held; to update: caddy upgrade)"
fi
fi

say "user and directories"
id home >/dev/null 2>&1 || useradd --system --home-dir /var/lib/home --shell /usr/sbin/nologin home
install -d -o root -g root -m 0755 /opt/home /opt/home/releases /opt/home/bin
install -d -o root -g home -m 0750 /etc/home /etc/home/secrets
install -d -o home -g home -m 0750 /var/lib/home
install -d -o root -g root -m 0700 /var/backups/home
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
    usermod -aG home "$SUDO_USER"
    echo "$SUDO_USER added to group 'home' (homectl on this server works without a token; re-login to apply)"
fi

say "secrets and config"
if [ -n "$BOT_TOKEN" ]; then
    printf '%s\n' "$BOT_TOKEN" > /etc/home/secrets/bot_token
    chown root:home /etc/home/secrets/bot_token && chmod 0640 /etc/home/secrets/bot_token
fi
if [ ! -f /etc/home/home.json ]; then
    PUBLIC=null
    [ -n "$DOMAIN" ] && PUBLIC="\"https://$DOMAIN.duckdns.org$PORT_SUFFIX\""
    cat > /etc/home/home.json <<JSON
{
  "Home": {
    "DataDir": "/var/lib/home",
    "HttpUrls": [ "http://127.0.0.1:8080" ],
    "UnixSocket": "/run/home/api.sock",
    "DevicePort": 7700,
    "DiscoveryPort": 7701,
    "PublicUrl": $PUBLIC,
    "Telegram": { "BotTokenFile": "/etc/home/secrets/bot_token" },
    "BootstrapAdmin": ${ADMIN:-null},
    "OfflineAlertMinutes": 10,
    "RawHistoryDays": 7
  }
}
JSON
    chown root:home /etc/home/home.json && chmod 0640 /etc/home/home.json
    echo "wrote /etc/home/home.json"
else
    echo "/etc/home/home.json exists, not touched"
fi

say "systemd units"
install -m 0644 deploy/home.service deploy/home-backup.service deploy/home-backup.timer /etc/systemd/system/
install -m 0755 scripts/backup.sh /opt/home/bin/home-backup
systemctl daemon-reload
systemctl enable --now home-backup.timer >/dev/null
systemctl enable home.service >/dev/null
if [ -e /opt/home/current/home-server ]; then systemctl restart home.service; else echo "home.service enabled; it starts after the first deploy (scripts/deploy.sh)"; fi

if [ -n "$DOMAIN" ]; then
    say "DuckDNS $DOMAIN.duckdns.org"
    if [ -n "$DUCK_TOKEN" ]; then
        printf 'DUCKDNS_DOMAIN=%s\nDUCKDNS_TOKEN=%s\n' "$DOMAIN" "$DUCK_TOKEN" > /etc/home/duckdns.env
        chmod 0600 /etc/home/duckdns.env
    fi
    if [ -f /etc/home/duckdns.env ]; then
        install -m 0644 deploy/duckdns.service deploy/duckdns.timer /etc/systemd/system/
        systemctl daemon-reload
        systemctl enable --now duckdns.timer >/dev/null
        systemctl start duckdns.service && echo "DuckDNS updated" || echo "DuckDNS update failed: journalctl -u duckdns"
    else
        echo "no DuckDNS token: pass --duckdns-token"
    fi
    if [ "$CADDY" = 1 ]; then
        install -d /etc/caddy
        if [ "$HTTPS_PORT" = 443 ]; then
            cat > /etc/caddy/Caddyfile <<CADDY
$DOMAIN.duckdns.org {
	encode zstd gzip
	reverse_proxy 127.0.0.1:8080
}
CADDY
        else
            # Port 443 belongs to another application: listen on $HTTPS_PORT only, never touch 80/443,
            # get the certificate with a DNS record through the DuckDNS API.
            cat > /etc/caddy/Caddyfile <<CADDY
{
	auto_https disable_redirects
}

$DOMAIN.duckdns.org:$HTTPS_PORT {
	tls {
		dns duckdns {env.DUCKDNS_TOKEN}
	}
	encode zstd gzip
	reverse_proxy 127.0.0.1:8080
}
CADDY
            install -d /etc/systemd/system/caddy.service.d
            printf '[Service]\nEnvironmentFile=/etc/home/duckdns.env\n' > /etc/systemd/system/caddy.service.d/home-duckdns.conf
            systemctl daemon-reload
        fi
        systemctl enable caddy >/dev/null
        systemctl reload caddy 2>/dev/null || systemctl restart caddy
        if [ "$HTTPS_PORT" = 443 ]; then echo "Caddy serves https://$DOMAIN.duckdns.org (certificate appears once ports 80/443 are forwarded)"
        else echo "Caddy serves https://$DOMAIN.duckdns.org:$HTTPS_PORT (forward TCP $HTTPS_PORT on the router; ports 80/443 are not used)"; fi
    fi
fi

if [ "$FIREWALL" = 1 ]; then
    say "firewall"
    if [ -z "$LAN" ]; then
        DEV=$(ip route show default | awk '{print $5; exit}')
        LAN=$(ip -4 route show dev "$DEV" scope link | awk '{print $1; exit}')
    fi
    [ -n "$LAN" ] || { echo "cannot detect the LAN, pass --lan" >&2; exit 1; }
    PUBLIC_PORTS="80, 443"
    [ "$HTTPS_PORT" != 443 ] && PUBLIC_PORTS="$HTTPS_PORT"
    sed -e "s|define LAN = .*|define LAN = $LAN|" -e "s|tcp dport { 80, 443 } accept|tcp dport { $PUBLIC_PORTS } accept|" \
        deploy/nftables.conf.example > /etc/nftables.d-home.conf
    grep -q 'nftables.d-home.conf' /etc/nftables.conf 2>/dev/null || echo 'include "/etc/nftables.d-home.conf"' >> /etc/nftables.conf
    nft -c -f /etc/nftables.conf && systemctl enable --now nftables >/dev/null && systemctl restart nftables
    echo "firewall on: 22, $PUBLIC_PORTS open; 7700/8080 tcp and 5353/7701 udp only from $LAN"
fi

say "done"
IP=$(hostname -I | awk '{print $1}')
URL="https://${DOMAIN:-<name>}.duckdns.org$PORT_SUFFIX"
FORWARD="TCP 443 and 80"
[ "$HTTPS_PORT" != 443 ] && FORWARD="TCP $HTTPS_PORT (external) → $IP:$HTTPS_PORT"
cat <<TXT
Next steps:
 1. Deploy the server from your computer:   scripts/deploy.sh <user>@$IP
 2. Router: DHCP reservation for $IP; forward $FORWARD.
 3. @BotFather: /newbot → token (--bot-token); Bot Settings → Menu Button → $URL
 4. First admin: --admin <telegram id> (the bot answers /id), or on this server: homectl users add <id> --role admin
 5. Check: curl -s $URL/healthz  → ok
TXT
