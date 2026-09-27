#!/usr/bin/env bash
# Runs ON the server (called by deploy.sh): installs a release archive with rollback.
#   sudo bash remote-install.sh /tmp/home-<version>-linux-x64.tar.gz
set -euo pipefail
ARCHIVE=${1:?archive}
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
NAME=$(basename "$ARCHIVE" .tar.gz)
DEST=/opt/home/releases/$NAME
PREV=$(readlink -f /opt/home/current 2>/dev/null || true)
TS=$(date +%Y%m%d-%H%M%S)

rm -rf "$DEST" && mkdir -p "$DEST"
tar -xzf "$ARCHIVE" -C "$DEST" --strip-components=1
chmod 0755 "$DEST"/home-server "$DEST"/homectl "$DEST"/home-sim 2>/dev/null || true

DB=/var/lib/home/home.db
if [ -f "$DB" ]; then
    sqlite3 "$DB" ".backup '/var/backups/home/pre-deploy-$TS.db'"
    echo "database backed up: /var/backups/home/pre-deploy-$TS.db"
fi

ln -sfn "$DEST" /opt/home/current
ln -sf /opt/home/current/homectl /usr/local/bin/homectl
ln -sf /opt/home/current/home-sim /usr/local/bin/home-sim
systemctl restart home.service

ok=0
for _ in $(seq 1 60); do
    if curl -fsS --max-time 2 http://127.0.0.1:8080/healthz >/dev/null 2>&1; then ok=1; break; fi
    sleep 1
done

if [ "$ok" != 1 ]; then
    echo "new release did not become healthy — rolling back" >&2
    journalctl -u home.service -n 30 --no-pager >&2 || true
    if [ -n "$PREV" ] && [ -d "$PREV" ]; then
        systemctl stop home.service
        [ -f "/var/backups/home/pre-deploy-$TS.db" ] && install -o home -g home -m 0640 "/var/backups/home/pre-deploy-$TS.db" "$DB" && rm -f "$DB-wal" "$DB-shm"
        ln -sfn "$PREV" /opt/home/current
        systemctl start home.service
        echo "rolled back to $(basename "$PREV")" >&2
    fi
    exit 1
fi

# Keep the 5 newest releases.
ls -1dt /opt/home/releases/*/ | tail -n +6 | while read -r old; do [ "$(readlink -f /opt/home/current)/" = "$old" ] || rm -rf "$old"; done
echo "deployed $NAME"
/opt/home/current/homectl --server unix:/run/home/api.sock system status || true
