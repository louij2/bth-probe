#!/bin/bash
# Build, publish and redeploy bth-probe on TOWER, from this repo (tower path:
# /mnt/user/appdata/claude-code/workspace/repos/bth-probe/deploy.sh).
#
# The container comes from its Unraid template
# (/boot/config/plugins/dockerMan/templates-user/my-bth-probe.xml), never from
# compose. The image goes to Docker Hub (public, nothing private baked in) first, so tower never
# holds the only copy. The WireGuard private key lives in the template's --env-file (0600).
set -euo pipefail
cd "$(dirname "$0")"
IMG=louij2/bth-probe
TAG=$(date +%Y%m%d-%H%M)
C=bth-probe
RECREATE=/mnt/user/appdata/compose-to-templates/tpl-recreate.sh

docker build -t "$IMG:latest" -t "$IMG:$TAG" .
docker push "$IMG:$TAG"
docker push "$IMG:latest"

if ! docker inspect "$C" >/dev/null 2>&1; then
  echo "no $C container yet: create it from the template (README, First install)" >&2
  exit 1
fi
"$RECREATE" "$C"
for _ in $(seq 20); do
  [ "$(docker inspect -f '{{.State.Health.Status}}' "$C")" = healthy ] && break
  sleep 15
done
if [ "$(docker inspect -f '{{.State.Health.Status}}' "$C")" = healthy ]; then
  "$RECREATE" --commit "$C"
  echo "deployed $IMG:$TAG"
else
  echo "NOT healthy. Roll back: docker rm -f $C; docker rename $C-old $C; docker start $C" >&2
  exit 1
fi
