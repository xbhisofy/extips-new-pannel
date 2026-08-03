#!/usr/bin/env bash
# Strict self-hosted migration reconciliation. No migration failure is skipped.
set -Eeuo pipefail

REPO_DIR="${REPO_DIR:-/opt/smmpanel}"
SUPA_DIR="${SUPA_DIR:-/opt/supabase}"
BACKUP_DIR="${BACKUP_DIR:-/opt/backups/smmpanel}"
DB_USER="${DB_USER:-postgres}"
DB_NAME="${DB_NAME:-postgres}"

log() { printf '\n==> %s\n' "$*"; }
die() { printf '\n[FAIL] %s\n' "$*" >&2; exit 1; }
trap 'die "line $LINENO failed: $BASH_COMMAND"' ERR

[ "$(id -u)" -eq 0 ] || die "run as root"
[ -d "$REPO_DIR/supabase/migrations" ] || die "migrations missing in $REPO_DIR"
[ -f "$SUPA_DIR/docker-compose.yml" ] || die "backend stack missing in $SUPA_DIR"
cd "$SUPA_DIR"
psql_db() { docker compose exec -T db psql -X -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 "$@"; }
scalar() { psql_db -tAc "$1" | tr -d '[:space:]'; }

log "1/7 Database readiness + required extensions"
docker compose exec -T db pg_isready -U "$DB_USER" -d "$DB_NAME" >/dev/null
for ext in pg_cron pg_net pgcrypto; do
  [ "$(scalar "SELECT EXISTS(SELECT 1 FROM pg_extension WHERE extname='$ext');")" = "t" ] \
    || die "required extension $ext is absent; do not rerun its vendor after-create script"
done
echo "extensions: pg_cron pg_net pgcrypto"

log "2/7 Compressed pre-repair backup"
install -d -m 700 "$BACKUP_DIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="$BACKUP_DIR/postgres-before-migration-repair-$STAMP.sql.gz"
docker compose exec -T db pg_dump -U "$DB_USER" -d "$DB_NAME" --no-owner --no-privileges | gzip -9 > "$BACKUP"
gzip -t "$BACKUP"
[ -s "$BACKUP" ] || die "backup is empty"
chmod 600 "$BACKUP"
echo "backup: $BACKUP ($(du -h "$BACKUP" | awk '{print $1}'))"

log "3/7 Idempotent prerequisite repair"
psql_db -f - < "$REPO_DIR/deploy/fix-missing-tables.sql"
psql_db -f - < "$REPO_DIR/deploy/selfhost-repair.sql"

log "4/7 Migration ledger reconciliation"
psql_db <<'SQL'
CREATE TABLE IF NOT EXISTS public._applied_migrations (
  name text PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public._migration_reconciliation (
  name text PRIMARY KEY,
  disposition text NOT NULL CHECK (disposition IN ('reconciled','quarantined')),
  reason text NOT NULL,
  reconciled_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public._applied_migrations, public._migration_reconciliation TO service_role;
SQL

# Hosted cron migrations contain obsolete hosted URLs/keys. Runtime cron is
# registered only by schedule-cron.sh. The Razorpay row is customer-specific
# money mutation and must never be replayed on a fresh VPS.
declare -A SPECIAL=(
  [20260327000000_fix_cron_jobs.sql]="reconciled|obsolete hosted cron replaced by local runtime registration"
  [20260405030811_5997936f-10d5-4ba7-b221-5a2e5313f67e.sql]="reconciled|non-idempotent legacy schema snapshot already represented by repaired live schema"
  [20260612095016_667f5de3-67bc-41e2-a1a8-5be47caa06c2.sql]="reconciled|hosted cron section replaced by local runtime registration; schema/data prerequisites repaired"
  [20260609105116_c185e5e7-e9f5-43b7-a7fe-2723d229cc0e.sql]="quarantined|customer-specific Razorpay fee adjustment is not portable and was not executed"
)
for name in "${!SPECIAL[@]}"; do
  IFS='|' read -r disposition reason <<< "${SPECIAL[$name]}"
  psql_db -v n="$name" -v d="$disposition" -v r="$reason" <<'SQL'
INSERT INTO public._migration_reconciliation(name, disposition, reason)
VALUES (:'n', :'d', :'r')
ON CONFLICT (name) DO UPDATE SET disposition=excluded.disposition, reason=excluded.reason, reconciled_at=now();
INSERT INTO public._applied_migrations(name) VALUES (:'n') ON CONFLICT DO NOTHING;
SQL
done

log "5/7 Apply every unresolved migration strictly"
mapfile -t FILES < <(printf '%s\n' "$REPO_DIR"/supabase/migrations/*.sql | sort)
for file in "${FILES[@]}"; do
  name="$(basename "$file")"
  [ "$(scalar "SELECT EXISTS(SELECT 1 FROM public._applied_migrations WHERE name='${name//\'/\'\'}');")" = "t" ] && continue
  echo "apply: $name"
  # One transaction means a failed migration cannot leave another partial state.
  if [ "$name" = "20260420072911_720ac022-4005-425b-9d45-d315761b5ed5.sql" ]; then
    # On the self-hosted image pg_cron/pg_net are preinstalled and guarded by
    # a vendor event trigger. Even CREATE EXTENSION IF NOT EXISTS invokes that
    # trigger's after-create script, which fails while re-granting cron objects.
    # Keep this migration's cleanup function and local cron job, but remove only
    # the two redundant extension statements after step 1 verified both exist.
    sed -E '/^[[:space:]]*CREATE EXTENSION IF NOT EXISTS (pg_cron|pg_net)([[:space:]]*;|[[:space:]]+WITH[[:space:]]+SCHEMA.*;)[[:space:]]*$/Id' \
      "$file" | psql_db --single-transaction -f -
  elif [ "$name" = "20260627023321_b39ea7be-1a3e-410e-b31a-d6338d4744f5.sql" ]; then
    # This tracked migration predates idempotency guards. Normalize only its
    # DDL wrappers at runtime; its functions/grants still execute unchanged.
    sed -e 's/^CREATE TABLE public\.zapupi_deposits/CREATE TABLE IF NOT EXISTS public.zapupi_deposits/' \
        -e '/^CREATE POLICY "Users view own zapupi deposits"/i DROP POLICY IF EXISTS "Users view own zapupi deposits" ON public.zapupi_deposits;' \
        -e '/^CREATE TRIGGER update_zapupi_deposits_updated_at/i DROP TRIGGER IF EXISTS update_zapupi_deposits_updated_at ON public.zapupi_deposits;' \
        -e 's/^CREATE INDEX zapupi_deposits_/CREATE INDEX IF NOT EXISTS zapupi_deposits_/' \
        "$file" | psql_db --single-transaction -f -
  else
    psql_db --single-transaction -f - < "$file"
  fi
  psql_db -v n="$name" -c "INSERT INTO public._applied_migrations(name) VALUES (:'n') ON CONFLICT DO NOTHING;" >/dev/null
done

log "6/7 Register local cron and deploy functions"
bash "$REPO_DIR/deploy/deploy-edge-functions.sh"
bash "$REPO_DIR/deploy/schedule-cron.sh"

log "7/7 Strict verification"
EXPECTED="$(find "$REPO_DIR/supabase/migrations" -maxdepth 1 -type f -name '*.sql' | wc -l | tr -d ' ')"
APPLIED="$(scalar 'SELECT count(*) FROM public._applied_migrations;')"
[ "$APPLIED" -ge "$EXPECTED" ] || die "migration ledger incomplete: files=$EXPECTED ledger=$APPLIED"

MISSING_TABLES="$(scalar "SELECT count(*) FROM (VALUES ('profiles'),('wallets'),('services'),('provider_accounts'),('service_provider_mapping'),('engagement_orders'),('engagement_order_items'),('organic_run_schedule'),('zapupi_deposits')) v(n) WHERE to_regclass('public.'||n) IS NULL;")"
[ "$MISSING_TABLES" = "0" ] || die "$MISSING_TABLES required tables are missing"
[ "$(scalar "SELECT to_regprocedure('public.set_referrer_by_code(text)') IS NOT NULL;")" = "t" ] || die "set_referrer_by_code(text) missing"
[ "$(scalar "SELECT to_regprocedure('public.credit_wallet_razorpay(uuid,text,numeric,numeric)') IS NOT NULL;")" = "t" ] || die "credit_wallet_razorpay missing"

BAD_FK="$(scalar "SELECT count(*) FROM public.services s LEFT JOIN public.providers p ON p.id=s.provider_id WHERE s.provider_id IS NOT NULL AND p.id IS NULL;")"
[ "$BAD_FK" = "0" ] || die "$BAD_FK services have missing providers"
HOSTED_JOBS="$(scalar "SELECT count(*) FROM cron.job WHERE command LIKE '%supabase.co%';")"
[ "$HOSTED_JOBS" = "0" ] || die "$HOSTED_JOBS cron jobs still target hosted backend"
BAD_JOBS="$(scalar "WITH expected(name) AS (VALUES ('execute-organic-runs-every-minute'),('execute-all-runs-every-minute'),('check-order-status-every-5-min'),('auto-refill-check-every-15-min'),('drip-feed-tick-every-5-min'),('snapshot-health-hourly'),('subscription-expiry-daily')) SELECT count(*) FROM expected e LEFT JOIN cron.job j ON j.jobname=e.name AND j.active WHERE j.jobid IS NULL;")"
[ "$BAD_JOBS" = "0" ] || die "$BAD_JOBS required cron jobs are missing/inactive"

echo
echo "PASS: strict migration repair complete"
echo "migration_files=$EXPECTED ledger_rows=$APPLIED missing_tables=$MISSING_TABLES bad_provider_fks=$BAD_FK hosted_cron=$HOSTED_JOBS inactive_cron=$BAD_JOBS"
psql_db -P pager=off -c "SELECT jobname,schedule,active FROM cron.job ORDER BY jobname;"
psql_db -P pager=off -c "SELECT name,disposition,reason FROM public._migration_reconciliation ORDER BY name;"
echo "backup=$BACKUP"