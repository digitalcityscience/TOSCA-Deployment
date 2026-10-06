# TOSCA-Deployment
## Usage

1. `cp .env.example .env` and edit values for your environment.
2. `./scripts/deploy.sh` pulls images and starts the stack (app behind an nginx reverse proxy).

CI validates the compose file and deploy script on every push.
