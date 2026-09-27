#!/usr/bin/env bash
# Consistent backup of the Home database and firmware images (installed as /opt/home/bin/home-backup).
#   home-backup [target-dir]    (default /var/backups/home, keeps 14 copies)
set -euo pipefail
DIR=${1:-/var/backups/home}
DATA=${HOME_DATA:-/var/lib/home}
TS=$(date +%Y%m%d-%H%M)
mkdir -p "$DIR"
if [ -f "$DATA/home.db" ]; then
    sqlite3 "$DATA/home.db" ".backup '$DIR/home-$TS.db'"
    gzip -f "$DIR/home-$TS.db"
fi
[ -d "$DATA/firmware" ] && tar -czf "$DIR/firmware-$TS.tar.gz" -C "$DATA" firmware
ls -1t "$DIR"/home-*.db.gz 2>/dev/null | tail -n +15 | xargs -r rm -f
ls -1t "$DIR"/firmware-*.tar.gz 2>/dev/null | tail -n +15 | xargs -r rm -f
echo "backup: $DIR/home-$TS.db.gz"
# Restore: systemctl stop home; gunzip -c home-<ts>.db.gz > /var/lib/home/home.db; rm -f /var/lib/home/home.db-{wal,shm};
#          chown home:home /var/lib/home/home.db; systemctl start home
