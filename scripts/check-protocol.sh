#!/usr/bin/env bash
# All components must use the same home-protocol commit (or at least the same major version).
set -euo pipefail
cd "$(dirname "$0")/.."
ref=$(git -C protocol rev-parse HEAD 2>/dev/null || echo missing)
major() { grep -A2 '^version:' "$1/schema.yaml" | awk '/major:/ {print $2}'; }
ref_major=$(major protocol)
status=0
for c in server firmware android; do
    p=$c/external/home-protocol
    h=$(git -C "$p" rev-parse HEAD 2>/dev/null || echo missing)
    if [ "$h" = "$ref" ]; then
        echo "ok      $c → ${h:0:7}"
    elif [ "$(major "$p")" = "$ref_major" ]; then
        echo "differs $c → ${h:0:7} (protocol/ is ${ref:0:7}), same major v$ref_major"
    else
        echo "ERROR   $c → ${h:0:7}: protocol major $(major "$p") ≠ $ref_major" >&2
        status=1
    fi
done
exit $status
