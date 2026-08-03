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
# git reset restores the repository's development .env. Always regenerate the
# production frontend configuration from the local backend before every build,
# otherwise browser orders can silently go to the old cloud database while VPS
# cron/repair checks an empty local database.
[ -f "$SUPA_DIR/.env" ] || die "backend env missing at $SUPA_DIR/.env"
API_URL="$(grep -E '^API_EXTERNAL_URL=' "$SUPA_DIR/.env" | head -1 | cut -d= -f2- | tr -d '"\r')"
ANON="$(grep -E '^ANON_KEY=' "$SUPA_DIR/.env" | head -1 | cut -d= -f2- | tr -d '"\r')"
[ -n "$API_URL" ] && [ -n "$ANON" ] || die "API_EXTERNAL_URL / ANON_KEY missing in backend env"
case "$API_URL" in
  http://127.0.0.1:*|http://localhost:*) die "API_EXTERNAL_URL must be browser-accessible, got $API_URL" ;;
esac
printf 'VITE_SUPABASE_URL=%s\nVITE_SUPABASE_PUBLISHABLE_KEY=%s\nVITE_SUPABASE_PROJECT_ID=selfhosted\n' \
  "$API_URL" "$ANON" > "$REPO_DIR/.env"
echo "   frontend backend -> $API_URL"
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
  if [ -f "$REPO_DIR/deploy/fix-missing-tables.sql" ]; then
    echo "   -> VPS missing-table repair"
    docker compose exec -T db psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f - \
      < "$REPO_DIR/deploy/fix-missing-tables.sql" || die "VPS missing-table repair failed"
  fi
  if [ -f "$REPO_DIR/deploy/selfhost-repair.sql" ]; then
    echo "   -> self-host idempotent migration repair"
    docker compose exec -T db psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f - \
      < "$REPO_DIR/deploy/selfhost-repair.sql" || die "self-host migration repair failed"
  fi
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
