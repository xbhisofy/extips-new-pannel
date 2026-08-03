#!/usr/bin/env bash
# Create (or reset password for) a user directly in the self-hosted auth DB
# and give them the admin role.
#
# Usage:
#   bash deploy/create-admin-user.sh                 # prompts for email/password
#   EMAIL=x@y.com PASSWORD=secret bash deploy/create-admin-user.sh
set -euo pipefail

SUPA_DIR="${SUPA_DIR:-/opt/supabase}"

EMAIL="${EMAIL:-}"
PASSWORD="${PASSWORD:-}"
[ -z "$EMAIL" ] && read -rp "Email: " EMAIL
if [ -z "$PASSWORD" ]; then
  read -rsp "Password (min 6 chars): " PASSWORD; echo
fi

if [ ${#PASSWORD} -lt 6 ]; then
  echo "!! Password must be at least 6 characters" >&2
  exit 1
fi

EMAIL_LC="$(printf '%s' "$EMAIL" | tr '[:upper:]' '[:lower:]')"

cd "$SUPA_DIR"

psql_run() {
  docker compose exec -T db psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"
}

echo "== ensuring pgcrypto =="
psql_run -c "CREATE EXTENSION IF NOT EXISTS pgcrypto;" >/dev/null

echo "== creating / updating auth user: $EMAIL_LC =="
docker compose exec -T db psql -U postgres -d postgres -v ON_ERROR_STOP=1 <<SQL
DO \$\$
DECLARE
  v_email text := '${EMAIL_LC}';
  v_pass  text := '${PASSWORD}';
  v_id    uuid;
BEGIN
  SELECT id INTO v_id FROM auth.users WHERE lower(email) = v_email LIMIT 1;

  IF v_id IS NULL THEN
    v_id := gen_random_uuid();
    INSERT INTO auth.users (
      id, instance_id, aud, role, email, encrypted_password,
      email_confirmed_at, created_at, updated_at,
      raw_app_meta_data, raw_user_meta_data, is_super_admin
    ) VALUES (
      v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
      v_email, crypt(v_pass, gen_salt('bf')),
      now(), now(), now(),
      '{"provider":"email","providers":["email"]}'::jsonb,
      jsonb_build_object('email', v_email, 'email_verified', true),
      false
    );
    RAISE NOTICE 'created new user %', v_id;
  ELSE
    UPDATE auth.users
       SET encrypted_password = crypt(v_pass, gen_salt('bf')),
           email_confirmed_at = COALESCE(email_confirmed_at, now()),
           banned_until = NULL,
           updated_at = now()
     WHERE id = v_id;
    RAISE NOTICE 'password reset for existing user %', v_id;
  END IF;

  -- identity row (needed by some GoTrue versions for email login)
  IF NOT EXISTS (
    SELECT 1 FROM auth.identities WHERE user_id = v_id AND provider = 'email'
  ) THEN
    BEGIN
      INSERT INTO auth.identities (id, user_id, provider_id, provider, identity_data, created_at, updated_at, last_sign_in_at)
      VALUES (gen_random_uuid(), v_id, v_id::text, 'email',
              jsonb_build_object('sub', v_id::text, 'email', v_email, 'email_verified', true),
              now(), now(), now());
    EXCEPTION WHEN others THEN
      -- older schema without provider_id / id defaults
      INSERT INTO auth.identities (user_id, provider, identity_data, created_at, updated_at, last_sign_in_at)
      VALUES (v_id, 'email',
              jsonb_build_object('sub', v_id::text, 'email', v_email, 'email_verified', true),
              now(), now(), now());
    END;
  END IF;

  -- profile
  BEGIN
    INSERT INTO public.profiles (id, email)
    VALUES (v_id, v_email)
    ON CONFLICT (id) DO UPDATE SET email = EXCLUDED.email;
  EXCEPTION WHEN others THEN
    RAISE NOTICE 'profiles insert skipped: %', SQLERRM;
  END;

  -- wallet (if table exists)
  BEGIN
    INSERT INTO public.wallets (user_id) VALUES (v_id) ON CONFLICT DO NOTHING;
  EXCEPTION WHEN others THEN NULL;
  END;

  -- admin role
  BEGIN
    INSERT INTO public.user_roles (user_id, role)
    VALUES (v_id, 'admin') ON CONFLICT DO NOTHING;
  EXCEPTION WHEN others THEN
    RAISE NOTICE 'user_roles insert skipped: %', SQLERRM;
  END;
END
\$\$;
SQL

echo
echo "== result =="
psql_run -c "SELECT u.id, u.email, u.email_confirmed_at IS NOT NULL AS confirmed,
                    (SELECT count(*) FROM auth.identities i WHERE i.user_id=u.id) AS identities,
                    (SELECT string_agg(r.role::text, ',') FROM public.user_roles r WHERE r.user_id=u.id) AS roles
             FROM auth.users u WHERE lower(u.email)='${EMAIL_LC}';"

echo
echo "== live login test through Kong =="
ANON_KEY="$(grep -E '^ANON_KEY=' "$SUPA_DIR/.env" | cut -d= -f2- | tr -d '"')"
HTTP="$(curl -s -o /tmp/login-test.json -w '%{http_code}' \
  -X POST "http://localhost:8000/auth/v1/token?grant_type=password" \
  -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  --data "$(printf '{"email":"%s","password":"%s"}' "$EMAIL_LC" "$PASSWORD")" || true)"
echo "HTTP $HTTP"
if [ "$HTTP" = "200" ]; then
  echo "LOGIN OK -> website pe isi email/password se sign in karo"
else
  echo "LOGIN FAILED response:"; cat /tmp/login-test.json; echo
fi
rm -f /tmp/login-test.json
