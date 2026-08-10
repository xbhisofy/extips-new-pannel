#!/usr/bin/env bash
# ============================================================================
# RESTORE order history (purane panel se aaye orders wapas laao)
#
# Kya karta hai:
#   1. Report: source (merge staging / external Supabase) me kitne orders the
#      vs yahan kitne hain.
#   2. Source user ko email se current user UUID par map karke missing orders,
#      engagement orders, items aur run schedule import karta hai.
#      Kuch bhi delete nahi hota (ON CONFLICT DO NOTHING).
#   3. order_number ki sequence theek karta hai.
#
# Usage (VPS):
#   cd /opt/smmpanel && DRY_RUN=1 bash deploy/restore-order-history.sh   # report
#   cd /opt/smmpanel && bash deploy/restore-order-history.sh             # asli run
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

ORDER_TABLES=( orders engagement_orders engagement_order_items organic_run_schedule engagement_health_history )

# ---------------------------------------------------------------------------
# 0. staging ready karo (agar khali hai to source se dobara fetch)
# ---------------------------------------------------------------------------
need_fetch=0
for t in "${ORDER_TABLES[@]}"; do
  have=$(psql_q "SELECT to_regclass('merge_stage.raw') IS NOT NULL AND EXISTS(SELECT 1 FROM merge_stage.raw WHERE tbl='$t')" 2>/dev/null || echo f)
  [ "$have" = "t" ] || need_fetch=1
done

if [ "$need_fetch" = "1" ]; then
  log "0/4 staging adhura hai -> source se orders fetch kar raha hu"
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

  psql_run >/dev/null <<'SQL'
CREATE SCHEMA IF NOT EXISTS merge_stage;
CREATE TABLE IF NOT EXISTS merge_stage.raw (tbl text, j jsonb);
CREATE TABLE IF NOT EXISTS merge_stage.accepted (user_id uuid PRIMARY KEY);
CREATE TABLE IF NOT EXISTS merge_stage.user_map (
  source_user_id uuid PRIMARY KEY,
  target_user_id uuid NOT NULL
);
SQL

  for t in "${ORDER_TABLES[@]}"; do
    rows=$(fetch "$t" 2>/dev/null || echo 0)
    echo "   $t: ${rows:-0} rows"
    [ "${rows:-0}" -gt 0 ] || continue
    psql_run -c "DELETE FROM merge_stage.raw WHERE tbl='$t';" >/dev/null
    {
      echo "CREATE TEMP TABLE _l (line text);"
      printf '\\copy _l FROM STDIN WITH (FORMAT csv, DELIMITER E%s\\x02%s, QUOTE E%s\\x01%s)\n' "'" "'" "'" "'"
      cat "$WORK/$t.ndjson"
      echo '\.'
      echo "INSERT INTO merge_stage.raw (tbl, j) SELECT '$t', line::jsonb FROM _l WHERE btrim(line) <> '';"
    } | docker compose exec -T db psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q
  done

  # accepted = jo bhi user yahan maujood hai (orders unke liye laane hain)
  psql_run >/dev/null <<'SQL'
INSERT INTO merge_stage.accepted (user_id)
SELECT DISTINCT (j->>'user_id')::uuid
FROM merge_stage.raw
WHERE j->>'user_id' IS NOT NULL
  AND EXISTS (SELECT 1 FROM auth.users u WHERE u.id = (j->>'user_id')::uuid)
ON CONFLICT DO NOTHING;
SQL
fi

# Purane merge me same email wale 48 accounts jaan-bujhkar skip hue the. Unke
# orders source UUID par hain, jabki login current UUID se hota hai. Source auth
# staging available ho to email se map banao; same UUID users bhi include karo.
psql_run >/dev/null <<'SQL'
CREATE TABLE IF NOT EXISTS merge_stage.user_map (
  source_user_id uuid PRIMARY KEY,
  target_user_id uuid NOT NULL
);

INSERT INTO merge_stage.user_map (source_user_id, target_user_id)
SELECT u.id, u.id FROM auth.users u
ON CONFLICT (source_user_id) DO UPDATE SET target_user_id=EXCLUDED.target_user_id;

INSERT INTO merge_stage.user_map (source_user_id, target_user_id)
SELECT (s.j->>'user_id')::uuid, a.id
FROM merge_stage.users s
JOIN auth.users a ON lower(a.email)=lower(s.j->>'email')
WHERE s.j->>'user_id' IS NOT NULL AND s.j->>'email' IS NOT NULL
ON CONFLICT (source_user_id) DO UPDATE SET target_user_id=EXCLUDED.target_user_id;

INSERT INTO merge_stage.accepted (user_id)
SELECT source_user_id FROM merge_stage.user_map
ON CONFLICT DO NOTHING;
SQL

# ---------------------------------------------------------------------------
# 1. report
# ---------------------------------------------------------------------------
log "1/4 Before (source vs yahan)"
for t in "${ORDER_TABLES[@]}"; do
  src=$(psql_q "SELECT count(*) FROM merge_stage.raw WHERE tbl='$t'")
  cur=$(psql_q "SELECT count(*) FROM public.$t" 2>/dev/null || echo "-")
  miss=$(psql_q "SELECT count(*) FROM merge_stage.raw s WHERE s.tbl='$t' AND NOT EXISTS (SELECT 1 FROM public.$t x WHERE x.id = (s.j->>'id')::uuid)" 2>/dev/null || echo "-")
  printf '  %-28s source=%-7s here=%-7s missing=%s\n' "$t" "$src" "$cur" "$miss"
done

if [ "$DRY_RUN" = "1" ]; then
  echo; echo "[dry-run] kuch change nahi hua. Asli run: bash deploy/restore-order-history.sh"
  exit 0
fi

# ---------------------------------------------------------------------------
# 2. import (parents pehle, FK/trigger off)
# ---------------------------------------------------------------------------
log "2/4 Missing order history import kar raha hu"

for t in "${ORDER_TABLES[@]}"; do
  psql_q "SELECT to_regclass('public.$t') IS NOT NULL" | grep -q t || { warn "$t target me nahi — skip"; continue; }
  has_user=$(psql_q "SELECT EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='$t' AND column_name='user_id')")
  filter="TRUE"
  [ "$has_user" = "t" ] && filter="(s.j->>'user_id')::uuid IN (SELECT source_user_id FROM merge_stage.user_map)"
  jexpr="s.j"
  [ "$has_user" = "t" ] && jexpr="jsonb_set(s.j, '{user_id}', to_jsonb((SELECT target_user_id FROM merge_stage.user_map WHERE source_user_id=(s.j->>'user_id')::uuid)))"
  before=$(psql_q "SELECT count(*) FROM public.$t")
  # SET aur INSERT ek hi DB session me hone chahiye. Purana script alag session
  # me SET karta tha, isliye child rows FK par fail hoke silently skip ho rahi thi.
  docker compose exec -T db psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q -c "
    SET session_replication_role='replica';
    INSERT INTO public.$t
    SELECT r.* FROM (
      SELECT $jexpr AS j FROM merge_stage.raw s
      WHERE s.tbl='$t' AND $filter
        AND NOT EXISTS (SELECT 1 FROM public.$t x WHERE x.id = (s.j->>'id')::uuid)
    ) z, LATERAL jsonb_populate_record(NULL::public.$t, z.j) r
    ON CONFLICT DO NOTHING;
    SET session_replication_role='origin';" >/dev/null || warn "$t: kuch rows fail hui (upar DB error dekhein)"
  after=$(psql_q "SELECT count(*) FROM public.$t")
  printf '  -> %-28s +%s rows (now %s)\n' "$t" "$((after-before))" "$after"
done

# Existing imported rows ko bhi correct current login UUID do. Sirf wahi rows
# touch hoti hain jinka source owner mapping me exact match hai.
psql_run >/dev/null <<'SQL'
UPDATE public.engagement_orders eo
SET user_id=m.target_user_id
FROM merge_stage.user_map m
WHERE eo.user_id=m.source_user_id AND eo.user_id<>m.target_user_id;

UPDATE public.orders o
SET user_id=m.target_user_id
FROM merge_stage.user_map m
WHERE o.user_id=m.source_user_id AND o.user_id<>m.target_user_id;
SQL

# ---------------------------------------------------------------------------
# 3. sequences theek karo (nayi order numbering purane se aage se shuru ho)
# ---------------------------------------------------------------------------
log "3/4 Sequences sync"
psql_run >/dev/null <<'SQL'
DO $$
DECLARE r record; maxv bigint;
BEGIN
  FOR r IN
    SELECT c.oid::regclass::text AS tbl, a.attname AS col,
           pg_get_serial_sequence(c.oid::regclass::text, a.attname) AS seq
    FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    JOIN pg_attribute a ON a.attrelid=c.oid AND a.attnum>0
    WHERE n.nspname='public' AND c.relkind='r'
      AND pg_get_serial_sequence(c.oid::regclass::text, a.attname) IS NOT NULL
  LOOP
    EXECUTE format('SELECT COALESCE(MAX(%I),0) FROM %s', r.col, r.tbl) INTO maxv;
    EXECUTE format('SELECT setval(%L, GREATEST(%s,1))', r.seq, maxv);
  END LOOP;
END $$;
SQL

# ---------------------------------------------------------------------------
# 4. after report
# ---------------------------------------------------------------------------
log "4/4 After"
psql_run -c "
SELECT (SELECT count(*) FROM public.orders)                   AS orders,
       (SELECT count(*) FROM public.engagement_orders)         AS engagement_orders,
       (SELECT count(*) FROM public.engagement_order_items)    AS items,
       (SELECT count(*) FROM public.organic_run_schedule)      AS runs,
       (SELECT count(*) FROM public.transactions)              AS transactions;"

psql_run -c "
SELECT count(*) AS engagement_orders_without_items
FROM public.engagement_orders eo
WHERE NOT EXISTS (
  SELECT 1 FROM public.engagement_order_items i
  WHERE i.engagement_order_id=eo.id
);"

psql_run -c "
SELECT p.email,
       (SELECT count(*) FROM public.engagement_orders eo WHERE eo.user_id=p.user_id) AS eng_orders,
       (SELECT count(*) FROM public.orders o WHERE o.user_id=p.user_id)              AS orders
FROM public.profiles p
WHERE (SELECT count(*) FROM public.engagement_orders eo WHERE eo.user_id=p.user_id) > 0
   OR (SELECT count(*) FROM public.orders o WHERE o.user_id=p.user_id) > 0
ORDER BY 2 DESC, 3 DESC LIMIT 25;"

echo
echo "[done] Order history wapas import ho gayi. Kuch bhi delete nahi hua."
