#!/usr/bin/env bash
set -Eeuo pipefail

PUBLIC_HEALTH_URL=${PUBLIC_HEALTH_URL:-http://localhost/healthz}
DJANGO_HEALTH_URL=${DJANGO_HEALTH_URL:-http://localhost:8000/readyz}
FRONTEND_HEALTH_URL=${FRONTEND_HEALTH_URL:-http://localhost:8080/healthz}
HEALTHCHECK_RETRIES=${HEALTHCHECK_RETRIES:-12}
HEALTHCHECK_DELAY=${HEALTHCHECK_DELAY:-5}

check() {
  local name=$1 url=$2 attempt
  for ((attempt = 1; attempt <= HEALTHCHECK_RETRIES; attempt++)); do
    if curl --fail --silent --show-error --max-time 10 "$url" >/dev/null; then
      echo "$name healthy: $url"
      return 0
    fi
    sleep "$HEALTHCHECK_DELAY"
  done
  echo "$name unhealthy after ${HEALTHCHECK_RETRIES} attempts: $url" >&2
  return 1
}

check public-nginx "$PUBLIC_HEALTH_URL"
check django "$DJANGO_HEALTH_URL"
check frontend "$FRONTEND_HEALTH_URL"
