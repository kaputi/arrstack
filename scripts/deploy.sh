#!/usr/bin/env bash
#
# deploy.sh
#
# Sync the repo's docker-compose.yaml + env.example to /srv/arrstack/stack/
# (the runtime location, owned by the arrstack user). Bootstraps the runtime
# directory on first run; idempotent on subsequent runs. Never touches .env
# in the runtime location — that's a one-time hand-edit.
#
# Workflow:
#   1. Edit ~/code/arrStack/docker-compose.yaml or env.example as eduardo.
#   2. bash scripts/deploy.sh
#   3. (First time only) Create /srv/arrstack/stack/.env from env.example.
#   4. Apply: sudo -iu arrstack docker compose -f /srv/arrstack/stack/docker-compose.yaml up -d
#
# Usage:
#   bash scripts/deploy.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_DIR=/srv/arrstack/stack
COMPOSE_SRC="$REPO_DIR/docker-compose.yaml"
ENVEX_SRC="$REPO_DIR/env.example"

# ---------- pre-flight -------------------------------------------------------

[ -f "$COMPOSE_SRC" ] || { echo "ERROR: $COMPOSE_SRC not found" >&2; exit 1; }
[ -f "$ENVEX_SRC" ]   || { echo "ERROR: $ENVEX_SRC not found"   >&2; exit 1; }

# ---------- bootstrap deploy dir (first run only) ---------------------------

if [ ! -d "$DEPLOY_DIR" ]; then
  echo "==> Bootstrapping $DEPLOY_DIR (first deploy)"
  sudo mkdir -p "$DEPLOY_DIR"
  sudo chown arrstack:arrstack /srv/arrstack "$DEPLOY_DIR"
  sudo chmod 2775 /srv/arrstack "$DEPLOY_DIR"
else
  echo "==> $DEPLOY_DIR exists; syncing"
fi

# ---------- sync compose + env.example --------------------------------------

echo "==> Syncing docker-compose.yaml + env.example"
sudo rsync -a --chown=arrstack:arrstack \
  "$COMPOSE_SRC" "$ENVEX_SRC" \
  "$DEPLOY_DIR/"

if [ -d "$REPO_DIR/caddy" ]; then
  # Caddy's Caddyfile + Dockerfile live in the deploy dir alongside the
  # compose file (so compose's `build: ./caddy` directive resolves correctly).
  # Caddy's runtime state (data/, config/ dirs with cert storage) lives on
  # drive 1 via the per-service config bind mounts in compose.
  echo "==> Syncing caddy/ (Caddyfile + Dockerfile) to deploy dir"
  sudo mkdir -p "$DEPLOY_DIR/caddy"
  sudo rsync -a --delete --chown=arrstack:arrstack \
    "$REPO_DIR/caddy/" \
    "$DEPLOY_DIR/caddy/"

  # Ensure the runtime state dirs exist on drive 1 (Caddy will write certs
  # there). Read ARR1_ROOT from runtime .env to find the right path.
  if [ -f "$DEPLOY_DIR/.env" ]; then
    ARR1_ROOT="$(sudo grep '^ARR1_ROOT=' "$DEPLOY_DIR/.env" | cut -d= -f2-)"
    if [ -n "$ARR1_ROOT" ]; then
      sudo mkdir -p "$ARR1_ROOT/config/caddy/data" "$ARR1_ROOT/config/caddy/config"
      sudo chown -R arrstack:arrstack "$ARR1_ROOT/config/caddy"
    fi
  fi
fi

# ---------- status -----------------------------------------------------------

echo
echo "==> Status"
ls -la "$DEPLOY_DIR"
echo

if [ -f "$DEPLOY_DIR/.env" ]; then
  echo "    .env: present"
  if sudo -u arrstack docker compose \
        -f "$DEPLOY_DIR/docker-compose.yaml" \
        --env-file "$DEPLOY_DIR/.env" \
        config >/dev/null 2>&1; then
    echo "    compose parse: OK"
  else
    echo "    compose parse: FAILED — run the following to see why:"
    echo "      sudo -u arrstack docker compose -f $DEPLOY_DIR/docker-compose.yaml --env-file $DEPLOY_DIR/.env config"
  fi
else
  echo "    .env: MISSING — create it before bringing up the stack:"
  echo
  echo "      sudo cp $DEPLOY_DIR/env.example $DEPLOY_DIR/.env"
  echo "      sudo chown arrstack:arrstack $DEPLOY_DIR/.env"
  echo "      sudo chmod 0640 $DEPLOY_DIR/.env"
  echo "      sudo \$EDITOR $DEPLOY_DIR/.env"
  echo
  echo "    Then re-run this script to validate."
fi

echo
echo "==> Done."
