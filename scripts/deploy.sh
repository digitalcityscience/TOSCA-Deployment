#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] || { echo "Missing .env (copy .env.example)" >&2; exit 1; }
docker compose pull
docker compose up -d --remove-orphans
docker compose ps
