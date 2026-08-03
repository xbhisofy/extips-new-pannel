#!/usr/bin/env bash
# ============================================================================
# PHASE 4 — Deploy all repo edge functions to the self-hosted Edge Runtime and
# load secrets from /etc/smmpanel.secrets (chmod 600, template auto-created).
#   bash deploy/deploy-edge-functions.sh
# Idempotent.
# ============================================================================
set -euo pipefail

REPO_DIR="${REPO_DIR:-/opt/smmpanel}"
SUPA_DIR="${SUPA_DIR:-/opt/supabase}"
SRC="$REPO_DIR/supabase/functions"
DST="$SUPA_DIR/volumes/functions"
SECRETS_FILE="${SECRETS_FILE:-/etc/smmpanel.secrets}"
ENVF="$SUPA_DIR/.env"

log()  { echo -e "\n\033[1;32m==>\033[0m $*"; }
warn() { echo -e "\033[1;33m[warn]\033[0m $*"; }
die()  { echo -e "\033[1;31m[error]\033[0m $*" >&2; exit 1; }

[ -d "$SRC" ] || die "$SRC not found"
[ -f "$SUPA_DIR/docker-compose.yml" ] || die "Supabase stack not found at $SUPA_DIR"

log "1/5 Secrets template"
if [ ! -f "$SECRETS_FILE" ]; then
  cat > "$SECRETS_FILE" <<'EOF'
# Fill these in, then rerun deploy/deploy-edge-functions.sh
OXAPAY_MERCHANT_API_KEY=
ZAPUPI_ZAP_KEY=
RAZORPAY_KEY_ID=
RAZORPAY_KEY_SECRET=
RAZORPAY_WEBHOOK_SECRET=
TELEGRAM_BOT_TOKEN=
TELEGRAM_BOT_USERNAME=
TELEGRAM_CHAT_ID=
TELEGRAM_API_KEY=
APIFY_API_TOKEN=
LOVABLE_API_KEY=
RESEND_API_KEY=
PROVIDER_CURRENCY=USD
EOF
  chmod 600 "$SECRETS_FILE"
  warn "created template $SECRETS_FILE — fill it in and rerun this script"
fi

log "2/5 Copying $(find "$SRC" -mindepth 1 -maxdepth 1 -type d ! -name _shared | wc -l) functions -> $DST"
mkdir -p "$DST"
find "$DST" -mindepth 1 -maxdepth 1 ! -name main -exec rm -rf {} +
cp -r "$SRC"/. "$DST"/
# temporary migration helpers must never run on the new stack
rm -rf "$DST/export-cloud-data" "$DST/export-auth-hashes"

log "3/5 Merging secrets into $ENVF"
set_env() {
  local k="$1" v="$2"
  [ -n "$v" ] || return 0
  if grep -qE "^${k}=" "$ENVF"; then sed -i "s|^${k}=.*|${k}=${v}|" "$ENVF"; else printf '%s=%s\n' "$k" "$v" >> "$ENVF"; fi
}
MISSING=""
while IFS='=' read -r k v; do
  [ -z "${k// }" ] && continue
  case "$k" in \#*) continue;; esac
  if [ -z "$v" ]; then MISSING="$MISSING $k"; else set_env "$k" "$v"; fi
done < "$SECRETS_FILE"
[ -n "${MISSING// /}" ] && warn "empty secrets (features using them will fail):$MISSING"

log "4/5 Restarting edge runtime"
cd "$SUPA_DIR"
docker compose up -d functions >/dev/null 2>&1 || docker compose up -d edge-functions >/dev/null 2>&1 || true
docker compose restart functions >/dev/null 2>&1 || docker compose restart edge-functions >/dev/null 2>&1 || true

log "5/5 Health check + webhook URLs"
KONG_PORT="$(grep -E '^KONG_HTTP_PORT=' "$ENVF" | cut -d= -f2- | tr -d '"')"
API_URL="$(grep -E '^API_EXTERNAL_URL=' "$ENVF" | cut -d= -f2- | tr -d '"')"
ANON="$(grep -E '^ANON_KEY=' "$ENVF" | cut -d= -f2- | tr -d '"')"
sleep 6
CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${KONG_PORT:-8000}/functions/v1/cron-status" -H "apikey: $ANON" || true)
echo "   GET /functions/v1/cron-status -> HTTP $CODE"
[ "$CODE" = "000" ] && warn "edge runtime unreachable: docker compose logs functions --tail=50"

cat <<EOF

Point provider webhooks here:
  OxaPay    -> $API_URL/functions/v1/oxapay-webhook
  ZapUPI    -> $API_URL/functions/v1/zapupi-webhook
  Razorpay  -> $API_URL/functions/v1/razorpay-webhook
  Telegram  -> $API_URL/functions/v1/telegram-webhook
  (Telegram can be registered by calling: $API_URL/functions/v1/telegram-set-webhook)
EOF
echo "[done] edge functions deployed."
