#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BACKEND_DIR="$ROOT_DIR/../TOSCA-Backend"
FRONTEND_DIR="$ROOT_DIR/../TOSCA-2"
BACKEND_ENV="$BACKEND_DIR/.env.prod"
FRONTEND_ENV="$FRONTEND_DIR/.env.production"
STATE_FILE="$ROOT_DIR/deploy-state.json"
LOCK_FILE="$ROOT_DIR/deploy.lock"
MODE=deploy

case "${1:-}" in
  --dry-run|--status) MODE="$1" ;;
  --component|--component=*) shift 2 2>/dev/null || true ;; # state detection remains authoritative
  "") ;;
  *) echo "Usage: $0 [--dry-run|--status|--component backend|frontend|all]" >&2; exit 2 ;;
esac

exec 9>"$LOCK_FILE"
flock -n 9 || { echo "Another deployment is already running." >&2; exit 1; }

die() { echo "ERROR: $*" >&2; exit 1; }
require_file() {
  [[ -f "$1" ]] && return
  die "Missing $1\nCopy: $ROOT_DIR/env/$2\nTo: $1\nand fill the required values."
}
tracked_clean() {
  git -C "$1" diff --quiet && git -C "$1" diff --cached --quiet ||
    die "Tracked local changes in $1; deployment refuses to overwrite them. Commit, stash, or revert those changes first."
}
hash_file() { sha256sum "$1" | awk '{print $1}'; }
# State is written by this script with fixed SHA/hash/timestamp fields. Keep the
# reader dependency-free because a production runner may not have jq installed.
state_value() { [[ -f "$STATE_FILE" ]] && sed -n -E "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/p" "$STATE_FILE" | head -n 1 || true; }
validate_frontend_env() {
  local key value
  for key in VITE_BASE_URL VITE_BACKEND_ROOT_URL VITE_GEONODE_REST_URL VITE_MAPTILER_API_KEY VITE_INHOUSE_MAP_BASE_URL VITE_MAP_START_LNG VITE_MAP_START_LAT VITE_MAP_START_ZOOM; do
    value=$(awk -F= -v key="$key" '$0 !~ /^[[:space:]]*#/ && $1 == key {sub(/^[^=]*=/, ""); print; exit}' "$FRONTEND_ENV")
    [[ -n "$value" ]] || die "Frontend production config has no non-empty $key: $FRONTEND_ENV"
  done
}

require_file "$BACKEND_ENV" backend.env.example
require_file "$FRONTEND_ENV" frontend.env.example
[[ -f "$ROOT_DIR/repos.yml" ]] || die "Missing $ROOT_DIR/repos.yml"
[[ -f "$ROOT_DIR/compose.yaml" ]] || die "Missing $ROOT_DIR/compose.yaml"
command -v docker >/dev/null || die "docker is required"
validate_frontend_env

tracked_clean "$BACKEND_DIR"
tracked_clean "$FRONTEND_DIR"
git -C "$BACKEND_DIR" fetch origin main
git -C "$FRONTEND_DIR" fetch origin main

BACKEND_LOCAL_SHA=$(git -C "$BACKEND_DIR" rev-parse HEAD)
FRONTEND_LOCAL_SHA=$(git -C "$FRONTEND_DIR" rev-parse HEAD)
BACKEND_SHA=$(git -C "$BACKEND_DIR" rev-parse origin/main)
FRONTEND_SHA=$(git -C "$FRONTEND_DIR" rev-parse origin/main)
BACKEND_ENV_HASH=$(hash_file "$BACKEND_ENV")
FRONTEND_ENV_HASH=$(hash_file "$FRONTEND_ENV")
DEPLOYED_BACKEND_SHA=$(state_value backend_sha)
DEPLOYED_FRONTEND_SHA=$(state_value frontend_sha)
DEPLOYED_BACKEND_ENV_HASH=$(state_value backend_env_hash)
DEPLOYED_FRONTEND_ENV_HASH=$(state_value frontend_env_hash)

BUILD_BACKEND=false; BUILD_FRONTEND=false; MIGRATE=false; RECREATE_BACKEND=false
[[ "$BACKEND_SHA" != "$DEPLOYED_BACKEND_SHA" ]] && BUILD_BACKEND=true
[[ "$FRONTEND_SHA" != "$DEPLOYED_FRONTEND_SHA" || "$FRONTEND_ENV_HASH" != "$DEPLOYED_FRONTEND_ENV_HASH" ]] && BUILD_FRONTEND=true
[[ "$BACKEND_SHA" != "$DEPLOYED_BACKEND_SHA" || "$BACKEND_ENV_HASH" != "$DEPLOYED_BACKEND_ENV_HASH" ]] && MIGRATE=true && RECREATE_BACKEND=true

report() {
  printf 'backend local SHA: %s\nbackend remote SHA: %s\nbackend deployed SHA: %s\n' "$BACKEND_LOCAL_SHA" "$BACKEND_SHA" "${DEPLOYED_BACKEND_SHA:-<none>}"
  printf 'frontend local SHA: %s\nfrontend remote SHA: %s\nfrontend deployed SHA: %s\n' "$FRONTEND_LOCAL_SHA" "$FRONTEND_SHA" "${DEPLOYED_FRONTEND_SHA:-<none>}"
  printf 'backend env changed: %s\nfrontend env changed: %s\n' "$([[ "$BACKEND_ENV_HASH" != "$DEPLOYED_BACKEND_ENV_HASH" ]] && echo yes || echo no)" "$([[ "$FRONTEND_ENV_HASH" != "$DEPLOYED_FRONTEND_ENV_HASH" ]] && echo yes || echo no)"
  printf 'would build backend: %s\nwould build frontend: %s\nwould migrate: %s\nwould recreate backend: %s\n' "$BUILD_BACKEND" "$BUILD_FRONTEND" "$MIGRATE" "$RECREATE_BACKEND"
}
report
[[ "$MODE" == --status || "$MODE" == --dry-run ]] && exit 0

git -C "$BACKEND_DIR" reset --hard origin/main
git -C "$FRONTEND_DIR" reset --hard origin/main
export BACKEND_IMAGE_TAG="$BACKEND_SHA" FRONTEND_IMAGE_TAG="$FRONTEND_SHA"
compose=(docker compose --env-file "$BACKEND_ENV" -f "$ROOT_DIR/compose.yaml")

if [[ "$BUILD_BACKEND" == true ]]; then "${compose[@]}" build django; fi
if [[ "$BUILD_FRONTEND" == true ]]; then "${compose[@]}" build web; fi

# Ensure migration dependencies exist before invoking the target SHA image.
if [[ "$MIGRATE" == true ]]; then
  "${compose[@]}" up -d db geoserver
  "${compose[@]}" run --rm --no-deps \
    -e RUN_MIGRATIONS_ON_STARTUP=false \
    -e RUN_COLLECTSTATIC_ON_STARTUP=false \
    -e RUN_SETUP_DEFAULT_ENGINE=false \
    -e RUN_DEFAULT_GEODATA_PROVIDER_SYNC_ON_STARTUP=false \
    django /venv/bin/python manage.py migrate --noinput
fi

"${compose[@]}" up -d --no-build
BACKEND_IMAGE_TAG="$BACKEND_SHA" FRONTEND_IMAGE_TAG="$FRONTEND_SHA" "$ROOT_DIR/healthcheck.sh"

tmp_state=$(mktemp "$ROOT_DIR/.deploy-state.XXXXXX")
trap 'rm -f "$tmp_state"' EXIT
printf '{\n  "backend_sha": "%s",\n  "frontend_sha": "%s",\n  "backend_env_hash": "%s",\n  "frontend_env_hash": "%s",\n  "deployed_at": "%s"\n}\n' \
  "$BACKEND_SHA" "$FRONTEND_SHA" "$BACKEND_ENV_HASH" "$FRONTEND_ENV_HASH" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$tmp_state"
mv "$tmp_state" "$STATE_FILE"
trap - EXIT
echo "Deployment successful: backend ${BACKEND_SHA:0:12}, frontend ${FRONTEND_SHA:0:12}"
