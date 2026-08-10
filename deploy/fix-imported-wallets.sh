#!/usr/bin/env bash
# ============================================================================
# FIX: imported users ka wallet balance 0 dikh raha hai.
#
# Kyu hua: merge ke time auth.users bante hi trigger ne wallet row (balance 0)
# bana di, isliye source ki asli wallet row "ON CONFLICT DO NOTHING" se skip
# ho gayi. Ye script source ke asli balance / total_deposited / total_spent
# wapas laga deti hai.
#
# Safe: sirf un users ko touch karta hai jo merge me IMPORT hue the
# (merge_stage.accepted). Purane/existing users ke paise chhoote nahi.
# Balance sirf badhta hai (GREATEST), kabhi kam nahi hota.
#
# Usage (VPS):
#   cd /opt/smmpanel && bash deploy/fix-imported-wallets.sh
#   DRY_RUN=1 bash deploy/fix-imported-wallets.sh     # sirf report
# ============================================================================
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/supabase}"
CONF="${CONF:-/etc/smmpanel.merge}"
WORK="${WORK:-/root/merge-src}"
DRY_RUN="${DRY_RUN:-0}"
PAGE="${PAGE:-1000}"

log()  { echo -e "\n\033[1;32m==>\033[0m $*"; }
warn() { echo -e "\033[1;33m[warn]\033[0m $*"; }
die()  { echo -e "\033[1;31m[error]\033[0m $*" >&2; exit 1; }

[ -f "$CONF" ] && . "$CONF" || true
[ -d "$INSTALL_DIR" ] || die "Supabase stack not found at $INSTALL_DIR"
cd "$INSTALL_DIR"
command -v jq >/dev/null || { apt-get update -qq && apt-get install -y -qq jq; }

psql_run() { docker compose exec -T db psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
psql_q()   { docker compose exec -T db psql -U postgres -d postgres -At -c "$1"; }

docker compose exec -T db pg_isready -U postgres >/dev/null 2>&1 || die "Postgres not running"

HAVE_STAGE=$(psql_q "SELECT to_regclass('merge_stage.raw') IS NOT NULL AND EXISTS(SELECT 1 FROM merge_stage.raw WHERE tbl='wallets')" || echo f)

# ---------------------------------------------------------------------------
# 1. agar staging gayab hai -> source se wallets/transactions dobara le aao
# ---------------------------------------------------------------------------
if [ "$HAVE_STAGE" != "t" ]; then
  log "1/4 merge_stage khali hai -> source se wallets fetch kar raha hu"
  : "${SRC_URL:?SRC_URL required (put it in $CONF)}"
  : "${SRC_SERVICE_KEY:?SRC_SERVICE_KEY required (put it in $CONF)}"
  SRC_URL="${SRC_URL%/}"
  mkdir -p "$WORK"

  fetch() { # $1=table
    local t="$1" from=0 out="$WORK/$t.ndjson" body n
    : > "$out"
    while :; do
      body=$(curl -sS --max-time 300 \
        -H "apikey: $SRC_SERVICE_KEY" -H "Authorization: Bearer $SRC_SERVICE_KEY" \
        -H "Range-Unit: items" -H "Range: ${from}-$((from+PAGE-1))" \
        "$SRC_URL/rest/v1/$t?select=*") || return 1
      echo "$body" | jq -e 'type=="array"' >/dev/null 2>&1 || { warn "$t: $(echo "$body" | head -c 160)"; return 1; }
      n=$(echo "$body" | jq 'length'); [ "$n" -eq 0 ] && break
      echo "$body" | jq -c '.[]' >> "$out"
      [ "$n" -lt "$PAGE" ] && break
      from=$((from+PAGE))
    done
    wc -l < "$out"
  }

  echo "   wallets rows: $(fetch wallets)"
  echo "   transactions rows: $(fetch transactions || echo 0)"

  psql_run <<'SQL' >/dev/null
CREATE SCHEMA IF NOT EXISTS merge_stage;
CREATE TABLE IF NOT EXISTS merge_stage.raw (tbl text, j jsonb);
DELETE FROM merge_stage.raw WHERE tbl IN ('wallets','transactions');
CREATE TABLE IF NOT EXISTS merge_stage.accepted (user_id uuid PRIMARY KEY);
SQL

  # base64-safe staging (JSON quoting issues se bachne ke liye)
  for t in wallets transactions; do
    [ -s "$WORK/$t.ndjson" ] || continue
    base64 -w0 < "$WORK/$t.ndjson" > "$WORK/$t.b64"
    docker compose exec -T db psql -U postgres -d postgres -q \
      -c "CREATE TEMP TABLE _b (d text); \copy _b FROM PROGRAM 'cat' ;" </dev/null >/dev/null 2>&1 || true
    # simple, reliable path: stream ndjson via COPY into a text table
    docker compose exec -T db psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q <<SQL
CREATE TEMP TABLE _l (line text);
\copy _l FROM STDIN
$(cat "$WORK/$t.ndjson")
\.
INSERT INTO merge_stage.raw (tbl, j)
SELECT '$t', line::jsonb FROM _l WHERE btrim(line) <> '';
SQL
  done

  # accepted = jo users source me the aur yahan bhi hain
  psql_run >/dev/null <<'SQL'
INSERT INTO merge_stage.accepted (user_id)
SELECT DISTINCT (j->>'user_id')::uuid
FROM merge_stage.raw
WHERE tbl='wallets' AND j->>'user_id' IS NOT NULL
  AND EXISTS (SELECT 1 FROM auth.users u WHERE u.id = (j->>'user_id')::uuid)
ON CONFLICT DO NOTHING;
SQL
else
  log "1/4 merge_stage mil gaya — usi data se restore karunga"
fi

# ---------------------------------------------------------------------------
# 2. report (pehle)
# ---------------------------------------------------------------------------
log "2/4 Before"
psql_run -c "
WITH src AS (
  SELECT (j->>'user_id')::uuid AS user_id,
         COALESCE((j->>'balance')::numeric,0)         AS balance,
         COALESCE((j->>'total_deposited')::numeric,0) AS total_deposited,
         COALESCE((j->>'total_spent')::numeric,0)     AS total_spent
  FROM merge_stage.raw WHERE tbl='wallets'
)
SELECT count(*) FILTER (WHERE s.balance > COALESCE(w.balance,0)) AS wallets_to_restore,
       ROUND(SUM(GREATEST(s.balance - COALESCE(w.balance,0),0)),2) AS money_to_restore,
       ROUND((SELECT SUM(balance) FROM public.wallets),2) AS current_total
FROM src s LEFT JOIN public.wallets w ON w.user_id = s.user_id
WHERE s.user_id IN (SELECT user_id FROM merge_stage.accepted);"

if [ "$DRY_RUN" = "1" ]; then
  echo; echo "[dry-run] kuch change nahi kiya. Chalane ke liye: bash deploy/fix-imported-wallets.sh"
  exit 0
fi

# ---------------------------------------------------------------------------
# 3. restore
# ---------------------------------------------------------------------------
log "3/4 Wallet balances restore kar raha hu"
psql_run <<'SQL'
BEGIN;

CREATE TEMP TABLE _src_wallets AS
SELECT DISTINCT ON ((j->>'user_id')::uuid)
       (j->>'user_id')::uuid                        AS user_id,
       COALESCE((j->>'balance')::numeric,0)         AS balance,
       COALESCE((j->>'total_deposited')::numeric,0) AS total_deposited,
       COALESCE((j->>'total_spent')::numeric,0)     AS total_spent
FROM merge_stage.raw
WHERE tbl='wallets' AND j->>'user_id' IS NOT NULL
ORDER BY (j->>'user_id')::uuid, COALESCE((j->>'balance')::numeric,0) DESC;

-- missing wallet rows
INSERT INTO public.wallets (user_id, balance, total_deposited, total_spent)
SELECT s.user_id, s.balance, s.total_deposited, s.total_spent
FROM _src_wallets s
WHERE s.user_id IN (SELECT user_id FROM merge_stage.accepted)
  AND NOT EXISTS (SELECT 1 FROM public.wallets w WHERE w.user_id = s.user_id);

-- existing (0 wali) rows upgrade — sirf badhta hai, ghatta nahi
UPDATE public.wallets w
   SET balance         = GREATEST(COALESCE(w.balance,0), s.balance),
       total_deposited = GREATEST(COALESCE(w.total_deposited,0), s.total_deposited),
       total_spent     = GREATEST(COALESCE(w.total_spent,0), s.total_spent),
       updated_at      = now()
FROM _src_wallets s
WHERE w.user_id = s.user_id
  AND s.user_id IN (SELECT user_id FROM merge_stage.accepted)
  AND (s.balance > COALESCE(w.balance,0)
    OR s.total_deposited > COALESCE(w.total_deposited,0)
    OR s.total_spent > COALESCE(w.total_spent,0));

-- purani transaction history bhi (jo miss hui ho)
INSERT INTO public.transactions
SELECT r.* FROM (
  SELECT j FROM merge_stage.raw
  WHERE tbl='transactions'
    AND (j->>'user_id')::uuid IN (SELECT user_id FROM merge_stage.accepted)
) z, LATERAL jsonb_populate_record(NULL::public.transactions, z.j) r
ON CONFLICT DO NOTHING;

COMMIT;
SQL

# ---------------------------------------------------------------------------
# 4. report (baad me)
# ---------------------------------------------------------------------------
log "4/4 After"
psql_run -c "
SELECT count(*)                                   AS wallets,
       count(*) FILTER (WHERE balance > 0)         AS funded_wallets,
       ROUND(SUM(balance),2)                       AS total_balance,
       ROUND(SUM(total_deposited),2)               AS total_deposited,
       (SELECT count(*) FROM public.transactions)  AS transactions
FROM public.wallets;"

psql_run -c "
SELECT p.email, ROUND(w.balance,2) AS balance, ROUND(w.total_deposited,2) AS deposited
FROM public.wallets w JOIN public.profiles p ON p.user_id = w.user_id
WHERE w.balance > 0
ORDER BY w.balance DESC LIMIT 25;"

echo
echo "[done] Imported users ke paise wapas lag gaye. Kuch bhi delete nahi hua."
