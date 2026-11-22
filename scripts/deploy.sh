#!/usr/bin/env bash
# deploy.sh - zero-downtime rolling update of the RickshawGo containers on the VM
#
# Usage (on the VM, from the repository clone in /opt/rickshawgo):
#   sudo ./scripts/deploy.sh TAG          TAG = an image tag built by CI, e.g. sha-1a2b3c4 (or latest)
#   sudo SKIP_PULL=1 ./scripts/deploy.sh TAG   use an image that only exists on this machine (testing)
#
# What it does:
#   1. pulls ghcr.io/mazkar-224/rickshawgo-docker:TAG   (if this fails, nothing has changed)
#   2. replaces api-1 and waits until Docker reports it healthy (its HEALTHCHECK passes),
#      then waits SETTLE seconds so Nginx puts it back into the rotation
#   3. does the same for api-2. One container is always serving, so users see no errors.
#   If a new container doesn't become healthy, it is rolled back to the previous tag and the
#   script stops with an error (the other container never left the old version).

set -Eeuo pipefail

TAG="${1:-}"
[ -n "$TAG" ] || { echo "Usage: $0 TAG   (e.g. sha-1a2b3c4)" >&2; exit 2; }

cd "$(dirname "$0")/.."
export IMAGE="${IMAGE:-ghcr.io/mazkar-224/rickshawgo-docker}"
STATE_DIR=/var/lib/rickshawgo
STATE="$STATE_DIR/current-tag"
SETTLE="${SETTLE:-3}"          # > Nginx fail_timeout (2 s)
WAIT_TIMEOUT="${WAIT_TIMEOUT:-60}"
DOMAIN="${DOMAIN:-rickshawgo.azkar.test}"
CA_CERT="${CA_CERT:-ssl/azkar-lab-root-ca.crt}"

say()  { echo "==> $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "run me with sudo (Docker needs root)"
mkdir -p "$STATE_DIR"
PREV="$(cat "$STATE" 2>/dev/null || true)"
say "Live tag now: ${PREV:-none}   ->   deploying: $TAG"

if [ "${SKIP_PULL:-0}" = 1 ]; then
    # for testing an image built on this machine (it is never in the registry)
    docker image inspect "$IMAGE:$TAG" >/dev/null 2>&1 || fail "SKIP_PULL=1 but $IMAGE:$TAG is not on this machine"
    say "Using the local image $IMAGE:$TAG (SKIP_PULL=1)"
else
    say "Pulling $IMAGE:$TAG"
    docker pull --quiet "$IMAGE:$TAG" >/dev/null || fail "could not pull $IMAGE:$TAG: nothing was changed"
fi

for svc in api-1 api-2; do
    say "Updating $svc"
    if ! TAG="$TAG" docker compose up -d --no-deps --pull never --wait --wait-timeout "$WAIT_TIMEOUT" "$svc"; then
        echo "ERROR: $svc did not become healthy on $TAG" >&2
        docker compose logs --tail 20 "$svc" >&2 || true
        if [ -n "$PREV" ]; then
            echo "ERROR: rolling $svc back to $PREV" >&2
            TAG="$PREV" docker compose up -d --no-deps --pull never --wait --wait-timeout "$WAIT_TIMEOUT" "$svc" || true
        fi
        fail "deployment of $TAG stopped; the other container is still on ${PREV:-the old version}"
    fi
    say "$svc is healthy on $TAG; waiting ${SETTLE}s so Nginx uses it again"
    sleep "$SETTLE"
done

echo "$TAG" > "$STATE"
say "Running containers:"
docker compose ps --format 'table {{.Service}}\t{{.Image}}\t{{.Status}}'

# old images: remove the ones no container uses any more (keeps the disk from filling up)
docker image prune -f >/dev/null

if [ -f "$CA_CERT" ]; then
    say "Through Nginx + TLS: $(curl -s -m 5 --cacert "$CA_CERT" --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/api/health")"
fi
say "Deployed $TAG"
