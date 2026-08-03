#!/usr/bin/env bash
# ============================================================================
# Safe update: git pull -> install -> ATOMIC build -> migrations -> restart
# -> health check -> automatic rollback on failure. Idempotent.
#   bash deploy/update.sh
# ============================================================================
set -euo pipefail

REPO_DIR="${REPO_DIR:-/opt/smmpanel}"
SUPA_DIR="${SUPA_DIR:-/opt/supabase}"
APP_PORT="${APP_PORT:-3000}"

log()  { echo -e "\n\033[1;32m==>\033[0m $*"; }
warn() { echo -e "\033[1;33m[warn]\033[0m $*"; }
die()  { echo -e "\033[1;31m[error]\033[0m $*" >&2; exit 1; }

cd "$REPO_DIR" || die "repo not found at $REPO_DIR"

log "1/6 git pull"
PREV_SHA="$(git rev-parse HEAD)"
git fetch --all --prune
git reset --hard origin/main
echo "   $PREV_SHA -> $(git rev-parse HEAD)"

log "2/6 pnpm install"
pnpm install --no-frozen-lockfile

log "3/6 Atomic build (dist-new -> dist)"
rm -rf dist-new
if ! pnpm run build --outDir dist-new; then
  rm -rf dist-new
  git reset --hard "$PREV_SHA"
  die "build failed — repo rolled back to $PREV_SHA, live dist untouched"
fi
[ -d dist-new ] && [ -n "$(ls -A dist-new)" ] || { rm -rf dist-new; git reset --hard "$PREV_SHA"; die "empty build output"; }
rm -rf dist-prev
[ -d dist ] && cp -a dist dist-prev
rm -rf dist && mv dist-new dist

log "4/6 Migrations"
if [ -d "$SUPA_DIR" ] && [ -d supabase/migrations ]; then
  cd "$SUPA_DIR"
  docker compose exec -T db psql -U postgres -d postgres -c \
    "CREATE TABLE IF NOT EXISTS public._applied_migrations(name text PRIMARY KEY, applied_at timestamptz DEFAULT now());" >/dev/null
  for f in $(ls "$REPO_DIR"/supabase/migrations/*.sql | sort); do
    name="$(basename "$f")"
    already="$(docker compose exec -T db psql -U postgres -d postgres -tAc \
      "SELECT 1 FROM public._applied_migrations WHERE name='$name'" || true)"
    [ "$already" = "1" ] && continue
    echo "   -> $name"
    if docker compose exec -T db psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f - < "$f" >/tmp/upd-mig.log 2>&1; then
      docker compose exec -T db psql -U postgres -d postgres -c \
        "INSERT INTO public._applied_migrations(name) VALUES ('$name') ON CONFLICT DO NOTHING" >/dev/null
    else
      warn "migration failed: $name"; tail -n 6 /tmp/upd-mig.log
    fi
  done
  cd "$REPO_DIR"
fi

log "5/6 Edge functions + restart"
bash "$REPO_DIR/deploy/deploy-edge-functions.sh" >/dev/null 2>&1 || warn "edge deploy step reported issues"
bash "$REPO_DIR/deploy/schedule-cron.sh" >/dev/null 2>&1 || warn "cron scheduling step reported issues"

if ! bash "$REPO_DIR/deploy/repair-pending-orders.sh"; then
  warn "pending-order repair failed; diagnostic output is shown above"
fi
systemctl restart smmpanel

log "6/6 Health check"
OK=0
for _ in $(seq 1 15); do
  CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$APP_PORT/" || true)
  [ "$CODE" = "200" ] && OK=1 && break
  sleep 2
done
if [ "$OK" = "1" ]; then
  rm -rf dist-prev
  echo "   HTTP 200 — update live at $(git rev-parse --short HEAD)"
else
  warn "health check failed — rolling back"
  if [ -d dist-prev ]; then rm -rf dist && mv dist-prev dist; fi
  git reset --hard "$PREV_SHA"
  systemctl restart smmpanel
  die "rolled back to $PREV_SHA"
fi
