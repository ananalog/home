#!/usr/bin/env bash
# Uploads the newest firmware build(s) to the server, ready for OTA from the Mini App or homectl.
#   scripts/fw-publish.sh <user@host> [device...]        (over SSH; the user must be in group 'home')
#   HOME_TOKEN=<token> scripts/fw-publish.sh https://myhome.duckdns.org [device...]   (over the API)
set -euo pipefail
cd "$(dirname "$0")/.."
TARGET=${1:?usage: fw-publish.sh <user@host|https://url> [device...]}
shift
DEVICES=("$@")
[ ${#DEVICES[@]} -gt 0 ] || mapfile -t DEVICES < <(ls firmware/dist 2>/dev/null | grep -v board-probe)
[ ${#DEVICES[@]} -gt 0 ] || { echo "nothing built: firmware/scripts/fw-build.sh <device>" >&2; exit 1; }

for dev in "${DEVICES[@]}"; do
    ver=$(ls -t "firmware/dist/$dev" | head -1)
    bin="firmware/dist/$dev/$ver/$dev-$ver.bin"
    [ -f "$bin" ] || { echo "no $bin" >&2; exit 1; }
    echo "== $dev $ver"
    if [[ "$TARGET" == http* ]]; then
        homectl --server "$TARGET" --token "${HOME_TOKEN:?set HOME_TOKEN}" fw upload "$bin"
    else
        scp -q "$bin" "$TARGET:/tmp/"
        ssh "$TARGET" "homectl fw upload /tmp/$(basename "$bin") && rm -f /tmp/$(basename "$bin")"
    fi
done
echo "flash: homectl fw flash --model <model> --all --canary   (or in the Mini App → Прошивки)"
