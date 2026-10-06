# TOSCA production deployment

This repository is the single production orchestration authority. It sits next
to (rather than embeds) the application repositories:

```text
/opt/NGCN/TOSCA-Backend     Django application and backend Dockerfile
/opt/NGCN/TOSCA-2           Vue/Vite application and frontend Dockerfile
/opt/NGCN/TOSCA-Deployment  production compose, deploy scripts and state
```

They are deliberately not Git submodules: each application has its own normal
release history, while this repository only describes how known sibling commits
are built and run on this server.

## Configuration

Create server-local files (both are ignored by Git):

```bash
cp /opt/NGCN/TOSCA-Deployment/env/backend.env.example /opt/NGCN/TOSCA-Backend/.env.prod
cp /opt/NGCN/TOSCA-Deployment/env/frontend.env.example /opt/NGCN/TOSCA-2/.env.production
```

`TOSCA-2/.env.production` is Vite build-time configuration. Every `VITE_*`
value is embedded in the browser bundle, so it must never contain a private
credential. `TOSCA-Backend/.env.prod` is runtime container configuration and
may contain secrets; it is injected with `env_file` and is not baked into the
backend image.

## First-time setup

1. Clone all three repositories under `/opt/NGCN` and create the two files
   above with server-specific values.
2. Install Docker Engine plus the Compose plugin; ensure the runner user can
   run `docker` without interactive privilege escalation.
3. If the retained GeoServer image is private, authenticate that host to GHCR.
4. Install a GitHub self-hosted runner on this trusted host with labels
   `self-hosted`, `ngcn`, and `production`.
5. Restrict that runner to the main-branch deployment workflows. Do not run
   fork or pull-request code on it.
6. Run `./deploy.sh` once from this directory.

GitHub is only a trigger: a push to `main` runs the small self-hosted workflow,
which invokes this script locally. No application image is built or pushed to
GHCR and no production Vite or Django setting is stored in GitHub.

## Operation

```bash
cd /opt/NGCN/TOSCA-Deployment
./deploy.sh                 # deploy changed components
./deploy.sh --dry-run       # report changes without modifying state
./deploy.sh --status        # same safe state report
```

The script locks with `flock`, refuses tracked edits in either application
checkout, fetches `origin/main`, then resets only clean trees to that commit.
Ignored server configuration is never removed and the script never uses
`git clean`, deletes volumes, or prunes images.

Frontend is rebuilt when its `origin/main` SHA or the SHA-256 of
`.env.production` changes. Backend is rebuilt only when its `origin/main` SHA
changes. A backend environment hash change recreates the backend and runs
migrations, but does not rebuild its image. Migrations run against the target
SHA image before compose reconciliation; the container entrypoint defaults
automatic migrations off to avoid running them twice.

After success, `deploy-state.json` records application SHAs, environment hashes
and timestamp. It is intentionally ignored and is left unchanged on every
failure. Health checks require public nginx `/healthz`, Django `/readyz`, and
the frontend `/healthz` (default host port `8080`); URLs and retry settings are
environment-overridable.

## Rollback

Local images are retained under immutable SHA tags. To roll application images
back manually, set the previous `BACKEND_IMAGE_TAG` and `FRONTEND_IMAGE_TAG`
when invoking Compose with the same backend env file, then run `docker compose
up -d`. Application rollback does **not** reverse database migrations. Confirm
database compatibility before using an older application image; automatic
reverse migrations are intentionally not attempted.
