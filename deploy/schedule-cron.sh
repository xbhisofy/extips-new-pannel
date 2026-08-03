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
SRK="$(grep -E '^SERVICE_ROLE_KEY=' "$ENVF" | cut -d= -f2- | tr -d '"')"
BASE="http://kong:8000"   # inside the docker network
[ -n "$SRK" ] || { echo "[error] SERVICE_ROLE_KEY missing in $ENVF" >&2; exit 1; }

psql_run() { docker compose exec -T db psql -U postgres -d postgres "$@"; }

echo "==> Scheduling cron jobs (base=$BASE)"
# pg_cron/pg_net may already exist; creating them again can fail on the
# extension after-create script ("dependent privileges exist"). Only create
# when actually missing, and tolerate failures.
psql_run -c "DO \$do\$ BEGIN CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA extensions; EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'pg_cron: %', SQLERRM; END \$do\$;"
psql_run -c "DO \$do\$ BEGIN CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions; EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'pg_net: %', SQLERRM; END \$do\$;"

psql_run -v ON_ERROR_STOP=1 <<SQL

DO \$\$
DECLARE
  jobs text[][] := ARRAY[
    ARRAY['execute-organic-runs-every-minute','* * * * *',    'execute-organic-runs'],
    ARRAY['execute-all-runs-every-minute',    '* * * * *',    'execute-all-runs'],
    ARRAY['check-order-status-every-5-min',   '*/5 * * * *',  'check-order-status'],
    ARRAY['auto-refill-check-every-15-min',   '*/15 * * * *', 'auto-refill-check'],
    ARRAY['drip-feed-tick-every-5-min',       '*/5 * * * *',  'drip-feed-tick'],
    ARRAY['snapshot-health-hourly',           '0 * * * *',    'snapshot-engagement-health'],
    ARRAY['subscription-expiry-daily',        '0 3 * * *',    'check-subscription-expiry']
  ];
  j text[];
BEGIN
  -- Remove every historical job that still targets a hosted project. This is
  -- command-based so renamed legacy jobs cannot survive the repair.
  BEGIN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE command LIKE '%supabase.co%';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'legacy hosted cron cleanup skipped: %', SQLERRM;
  END;
  FOREACH j SLICE 1 IN ARRAY jobs LOOP
    BEGIN
      PERFORM cron.unschedule(j[1]);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    PERFORM cron.schedule(j[1], j[2], format(
      \$q\$SELECT net.http_post(
            url := '$BASE/functions/v1/%s',
            headers := '{"Content-Type":"application/json","Authorization":"Bearer $SRK","apikey":"$SRK"}'::jsonb,
            body := CASE WHEN %L = 'execute-all-runs' THEN '{"instant":true}'::jsonb ELSE '{}'::jsonb END
          );\$q\$, j[3], j[3]));
  END LOOP;
END \$\$;
SQL

echo "==> Active jobs"
psql_run -c "SELECT jobname, schedule, active FROM cron.job ORDER BY jobname;"
echo "[done] cron scheduled. Recent runs: SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 10;"
