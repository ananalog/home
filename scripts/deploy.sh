#!/usr/bin/env bash
# Deploys the server release to the home server over SSH (or locally) with health check and rollback.
#   scripts/deploy.sh <user@host | local> [archive.tar.gz]
# Without an archive the newest server/dist/home-*-linux-x64.tar.gz is used (built if missing).
set -euo pipefail
cd "$(dirname "$0")/.."
TARGET=${1:?usage: deploy.sh <user@host|local> [archive]}
ARCHIVE=${2:-$(ls -t server/dist/home-*-linux-x64.tar.gz 2>/dev/null | head -1 || true)}
if [ -z "$ARCHIVE" ]; then
    echo "no release archive — building one"
    server/scripts/publish.sh
    ARCHIVE=$(ls -t server/dist/home-*-linux-x64.tar.gz | head -1)
fi
[ -f "$ARCHIVE.sha256" ] && (cd "$(dirname "$ARCHIVE")" && sha256sum -c "$(basename "$ARCHIVE").sha256" >/dev/null) && echo "checksum ok"
echo "deploying $(basename "$ARCHIVE") → $TARGET"

if [ "$TARGET" = local ]; then
    sudo bash scripts/remote-install.sh "$ARCHIVE"
else
    scp -q "$ARCHIVE" scripts/remote-install.sh "$TARGET:/tmp/"
    ssh -t "$TARGET" "sudo bash /tmp/remote-install.sh /tmp/$(basename "$ARCHIVE") && rm -f /tmp/$(basename "$ARCHIVE") /tmp/remote-install.sh"
fi
