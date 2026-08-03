#!/usr/bin/env bash
# ============================================================================
# PHASE 4b — (re)schedule the pg_cron jobs on the self-hosted stack.
# Idempotent: unschedules an existing job with the same name first.
#   bash deploy/schedule-cron.sh
# ============================================================================
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/supabase}"
cd "$INSTALL_DIR" || { echo "[error] stack not found at $INSTALL_DIR" >&2; exit 1; }

ENVF="$INSTALL_DIR/.env"
KONG_PORT="$(grep -E '^KONG_HTTP_PORT=' "$ENVF" | cut -d= -f2- | tr -d '"')"
SRK="$(grep -E '^SERVICE_ROLE_KEY=' "$ENVF" | cut -d= -f2- | tr -d '"')"
BASE="http://kong:8000"   # inside the docker network

psql_run() { docker compose exec -T db psql -U postgres -d postgres "$@"; }

echo "==> Scheduling cron jobs (base=$BASE)"
# pg_cron/pg_net may already exist; creating them again can fail on the
# extension after-create script ("dependent privileges exist"). Only create
# when actually missing, and tolerate failures.
psql_run -c "DO \$do\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname='pg_cron') THEN CREATE EXTENSION pg_cron; END IF; EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'pg_cron: %', SQLERRM; END \$do\$;" || true
psql_run -c "DO \$do\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname='pg_net') THEN CREATE EXTENSION pg_net; END IF; EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'pg_net: %', SQLERRM; END \$do\$;" || true

psql_run -v ON_ERROR_STOP=1 <<SQL

DO \$\$
DECLARE
  jobs text[][] := ARRAY[
    ARRAY['organic-runs-minutely',            '* * * * *',    'execute-all-runs'],
    ARRAY['check-order-status-every-2-min',   '*/2 * * * *',  'check-order-status'],
    ARRAY['auto-refill-check-every-15-min',   '*/15 * * * *', 'auto-refill-check'],
    ARRAY['drip-feed-tick-every-5-min',       '*/5 * * * *',  'drip-feed-tick'],
    ARRAY['instagram-poll-every-10-min',      '*/10 * * * *', 'instagram-poll'],
    ARRAY['snapshot-health-hourly',           '0 * * * *',    'snapshot-engagement-health'],
    ARRAY['provider-balance-hourly',          '5 * * * *',    'check-provider-balance'],
    ARRAY['subscription-expiry-daily',        '0 3 * * *',    'check-subscription-expiry'],
    ARRAY['sync-service-prices-every-12-hours','0 */12 * * *','sync-service-prices']
  ];
  j text[];
BEGIN
  FOREACH j SLICE 1 IN ARRAY jobs LOOP
    BEGIN
      PERFORM cron.unschedule(j[1]);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    PERFORM cron.schedule(j[1], j[2], format(
      \$q\$SELECT net.http_post(
            url := '$BASE/functions/v1/%s',
            headers := '{"Content-Type":"application/json","Authorization":"Bearer $SRK"}'::jsonb,
            body := '{}'::jsonb
          );\$q\$, j[3]));
  END LOOP;
END \$\$;
SQL

echo "==> Active jobs"
psql_run -c "SELECT jobname, schedule, active FROM cron.job ORDER BY jobname;"
echo "[done] cron scheduled. Recent runs: SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 10;"
