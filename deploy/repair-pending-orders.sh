#!/usr/bin/env bash
# Force-dispatch overdue organic runs on the self-hosted backend and show a
# useful result instead of silently relying on the next cron tick.
set -euo pipefail

SUPA_DIR="${SUPA_DIR:-/opt/supabase}"
ENVF="$SUPA_DIR/.env"

fail() { echo "[error] $*" >&2; exit 1; }
[ -f "$ENVF" ] || fail "backend env missing at $ENVF"
cd "$SUPA_DIR" || fail "backend stack missing at $SUPA_DIR"

env_value() {
  grep -E "^$1=" "$ENVF" | head -1 | cut -d= -f2- | tr -d '"\r'
}

PORT="$(env_value KONG_HTTP_PORT || true)"
SERVICE_KEY="$(env_value SERVICE_ROLE_KEY || true)"
[ -n "$SERVICE_KEY" ] || fail "SERVICE_ROLE_KEY is missing"

pending_count() {
  docker compose exec -T db psql -U postgres -d postgres -tAc \
    "SELECT count(*) FROM public.organic_run_schedule WHERE status='pending' AND scheduled_at <= now();" 2>/dev/null \
    | tr -d '[:space:]'
}

BEFORE="$(pending_count || echo unknown)"
echo "   overdue runs before: $BEFORE"

# Ensure the runtime has loaded the freshly copied function before invoking it.
for _ in $(seq 1 20); do
  CODE="$(curl -sS --max-time 5 -o /tmp/order-executor-ready.json -w '%{http_code}' \
    "http://127.0.0.1:${PORT:-8000}/functions/v1/execute-all-runs" \
    -H "Authorization: Bearer $SERVICE_KEY" -H "apikey: $SERVICE_KEY" \
    -H 'Content-Type: application/json' --data '{}' || true)"
  [ "$CODE" != "000" ] && break
  sleep 2
done

CODE="$(curl -sS --max-time 300 -o /tmp/order-executor-result.json -w '%{http_code}' \
  "http://127.0.0.1:${PORT:-8000}/functions/v1/execute-all-runs" \
  -H "Authorization: Bearer $SERVICE_KEY" -H "apikey: $SERVICE_KEY" \
  -H 'Content-Type: application/json' --data '{"instant":true}' || true)"

if [ "$CODE" != "200" ]; then
  echo "[error] order executor HTTP ${CODE:-000}: $(head -c 500 /tmp/order-executor-result.json 2>/dev/null || true)" >&2
  docker compose logs functions --tail=40 2>/dev/null || docker compose logs edge-functions --tail=40 2>/dev/null || true
  exit 1
fi

AFTER="$(pending_count || echo unknown)"
echo "   order executor -> HTTP 200"
echo "   overdue runs after: $AFTER"
echo "   response: $(head -c 500 /tmp/order-executor-result.json)"