-- Idempotent self-host repair; runtime cron URLs/keys are registered by schedule-cron.sh.
-- The self-hosted image provisions pg_cron/pg_net itself. Re-running
-- CREATE EXTENSION can execute its after-create hook and fail with
-- "dependent privileges exist" even when the extension is installed.
-- schedule-cron.sh verifies the extensions separately before adding jobs.
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS referral_code text;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS referred_by uuid;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS referral_earnings numeric NOT NULL DEFAULT 0;
CREATE INDEX IF NOT EXISTS idx_profiles_referral_code_upper ON public.profiles ((upper(referral_code))) WHERE referral_code IS NOT NULL;

-- Some hosted histories granted this RPC before its CREATE reached the VPS.
-- Recreate the canonical, authenticated-user-only implementation first.
CREATE OR REPLACE FUNCTION public.set_referrer_by_code(p_code text) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_referrer_id uuid;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF coalesce(btrim(p_code), '') = '' THEN RAISE EXCEPTION 'Referral code required'; END IF;

  SELECT user_id INTO v_referrer_id
    FROM public.profiles
   WHERE upper(referral_code) = upper(btrim(p_code))
   LIMIT 1;
  IF v_referrer_id IS NULL THEN RAISE EXCEPTION 'Invalid referral code'; END IF;
  IF v_referrer_id = v_user_id THEN RAISE EXCEPTION 'You cannot refer yourself'; END IF;

  UPDATE public.profiles
     SET referred_by = v_referrer_id, updated_at = now()
   WHERE user_id = v_user_id AND referred_by IS NULL;
  IF NOT FOUND THEN
    RETURN json_build_object('success', false, 'already_set', true);
  END IF;
  RETURN json_build_object('success', true, 'referrer_id', v_referrer_id);
END $$;
REVOKE EXECUTE ON FUNCTION public.set_referrer_by_code(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_referrer_by_code(text) TO authenticated;

-- Repair services.provider_id FK prerequisites before failed historical migrations retry.
INSERT INTO public.providers(id,name,api_url,api_key,is_active)
SELECT DISTINCT s.provider_id,coalesce(pa.name,s.provider_id),coalesce(nullif(pa.api_url,''),'http://invalid.local'),
 coalesce(pa.api_key,''),coalesce(pa.is_active,false)
FROM public.services s LEFT JOIN public.provider_accounts pa ON pa.provider_id=s.provider_id
WHERE s.provider_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.providers p WHERE p.id=s.provider_id)
ON CONFLICT(id) DO NOTHING;
-- Historical seed 20260703075454 references this provider before any tracked
-- migration creates it. Keep it inactive until a real account is configured.
-- Provider codes that historical seed migrations reference before any tracked
-- migration creates them. Kept inactive until a real account is configured.
INSERT INTO public.providers(id,name,api_url,api_key,is_active)
SELECT v.id, v.id || ' (configuration required)','http://invalid.local','',false
FROM (VALUES ('chpst'),('smmfollows'),('justanotherpanel'),('smmkings'),('peakerr'))
  AS v(id)
ON CONFLICT(id) DO NOTHING;
-- Any provider code referenced by an account/mapping but missing from providers.
INSERT INTO public.providers(id,name,api_url,api_key,is_active)
SELECT DISTINCT pa.provider_id, coalesce(pa.name,pa.provider_id),
  coalesce(nullif(pa.api_url,''),'http://invalid.local'), coalesce(pa.api_key,''), false
FROM public.provider_accounts pa
WHERE pa.provider_id IS NOT NULL
  AND NOT EXISTS(SELECT 1 FROM public.providers p WHERE p.id=pa.provider_id)
ON CONFLICT(id) DO NOTHING;

-- A unique Razorpay idempotency index cannot be created over historical
-- duplicate references. Preserve every transaction but quarantine duplicate
-- references with a stable suffix before the canonical migration adds UNIQUE.
WITH ranked AS (
  SELECT id, payment_reference,
         row_number() OVER (PARTITION BY payment_reference ORDER BY created_at, id) AS rn
    FROM public.transactions
   WHERE payment_method='razorpay_auto' AND payment_reference IS NOT NULL
)
UPDATE public.transactions t
   SET payment_reference = t.payment_reference || '-duplicate-' || t.id::text
  FROM ranked r
 WHERE t.id=r.id AND r.rn>1;

-- Migration 20260627023321 locks this RPC down but some partially imported
-- databases never received its CREATE statement. Install the canonical
-- service-role-only implementation before that migration reaches REVOKE.
CREATE OR REPLACE FUNCTION public.apply_referral_bonus(
  p_referee uuid,
  p_deposit_usd numeric
) RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_referrer uuid;
  v_prev_deposits numeric;
  v_bonus numeric;
  v_balance numeric;
  v_new_balance numeric;
BEGIN
  IF p_referee IS NULL OR p_deposit_usd IS NULL OR p_deposit_usd <= 0 THEN
    RETURN json_build_object('success', false, 'reason', 'invalid_input');
  END IF;

  SELECT referred_by INTO v_referrer
    FROM public.profiles
   WHERE user_id = p_referee;
  IF v_referrer IS NULL THEN
    RETURN json_build_object('success', false, 'reason', 'no_referrer');
  END IF;

  SELECT COALESCE(SUM(amount), 0) INTO v_prev_deposits
    FROM public.transactions
   WHERE user_id = p_referee
     AND type = 'deposit'
     AND status = 'completed'
     AND payment_method <> 'promo';
  IF v_prev_deposits > p_deposit_usd THEN
    RETURN json_build_object('success', false, 'reason', 'not_first_deposit');
  END IF;

  v_bonus := trunc(p_deposit_usd * 0.10, 4);
  IF v_bonus <= 0 THEN
    RETURN json_build_object('success', false, 'reason', 'zero_bonus');
  END IF;

  INSERT INTO public.wallets(user_id,balance,total_deposited,total_spent)
  VALUES(v_referrer,0,0,0) ON CONFLICT(user_id) DO NOTHING;
  SELECT balance INTO v_balance FROM public.wallets
   WHERE user_id=v_referrer FOR UPDATE;
  v_new_balance := trunc(COALESCE(v_balance,0)+v_bonus,4);
  UPDATE public.wallets SET balance=v_new_balance WHERE user_id=v_referrer;
  UPDATE public.profiles
     SET referral_earnings=COALESCE(referral_earnings,0)+v_bonus
   WHERE user_id=v_referrer;
  INSERT INTO public.transactions(
    user_id,type,amount,balance_after,status,payment_method,description
  ) VALUES (
    v_referrer,'deposit',v_bonus,v_new_balance,'completed','referral',
    'Referral bonus (10%) from new user deposit'
  );
  RETURN json_build_object('success',true,'bonus_usd',v_bonus,'referrer',v_referrer);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.apply_referral_bonus(uuid,numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.apply_referral_bonus(uuid,numeric) TO service_role;

CREATE TABLE IF NOT EXISTS public.zapupi_deposits (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id uuid NOT NULL, order_id text NOT NULL UNIQUE,
 amount_inr numeric NOT NULL, amount_usd numeric, status text NOT NULL DEFAULT 'pending',
 credited boolean NOT NULL DEFAULT false, txn_id text, utr text, payment_url text, raw_response jsonb,
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());
GRANT SELECT ON public.zapupi_deposits TO authenticated;
GRANT ALL ON public.zapupi_deposits TO service_role;
ALTER TABLE public.zapupi_deposits ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Users view own zapupi deposits" ON public.zapupi_deposits;
CREATE POLICY "Users view own zapupi deposits" ON public.zapupi_deposits FOR SELECT TO authenticated USING (auth.uid()=user_id);

DROP POLICY IF EXISTS "Admins can view poll state" ON public.instagram_poll_state;
CREATE POLICY "Admins can view poll state" ON public.instagram_poll_state FOR SELECT TO authenticated USING (public.has_role(auth.uid(),'admin'));
DROP POLICY IF EXISTS "Admins can manage poll state" ON public.instagram_poll_state;
CREATE POLICY "Admins can manage poll state" ON public.instagram_poll_state FOR ALL TO authenticated
 USING (public.has_role(auth.uid(),'admin')) WITH CHECK (public.has_role(auth.uid(),'admin'));

DO $$ BEGIN
 PERFORM cron.unschedule(jobid) FROM cron.job WHERE command LIKE '%supabase.co%';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'legacy cron cleanup skipped: %', SQLERRM; END $$;

CREATE OR REPLACE FUNCTION public.redeem_promo_code(p_code text,p_deposit_usd numeric) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE u uuid:=auth.uid(); c record; bonus numeric; bal numeric; new_bal numeric;
BEGIN
 IF u IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
 IF p_deposit_usd IS NULL OR p_deposit_usd<=0 THEN RAISE EXCEPTION 'Invalid deposit amount'; END IF;
 SELECT * INTO c FROM public.promo_codes WHERE upper(code)=upper(p_code) AND is_active FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Invalid promo code'; END IF;
 IF c.expires_at IS NOT NULL AND c.expires_at<now() THEN RAISE EXCEPTION 'Promo code expired'; END IF;
 IF c.max_uses IS NOT NULL AND c.used_count>=c.max_uses THEN RAISE EXCEPTION 'Promo code limit reached'; END IF;
 IF p_deposit_usd<c.min_deposit_usd THEN RAISE EXCEPTION 'Minimum deposit required'; END IF;
 IF EXISTS(SELECT 1 FROM public.promo_redemptions WHERE promo_code_id=c.id AND user_id=u) THEN RAISE EXCEPTION 'You already used this code'; END IF;
 bonus:=trunc(CASE WHEN c.bonus_type='percent' THEN p_deposit_usd*c.bonus_value/100 ELSE c.bonus_value END,4);
 IF bonus<=0 THEN RAISE EXCEPTION 'Bonus calculation failed'; END IF;
 INSERT INTO public.wallets(user_id,balance,total_deposited,total_spent) VALUES(u,0,0,0) ON CONFLICT(user_id) DO NOTHING;
 SELECT balance INTO bal FROM public.wallets WHERE user_id=u FOR UPDATE; new_bal:=trunc(coalesce(bal,0)+bonus,4);
 UPDATE public.wallets SET balance=new_bal WHERE user_id=u;
 INSERT INTO public.promo_redemptions(promo_code_id,user_id,bonus_amount_usd,deposit_amount_usd) VALUES(c.id,u,bonus,p_deposit_usd);
 UPDATE public.promo_codes SET used_count=used_count+1 WHERE id=c.id;
 INSERT INTO public.transactions(user_id,type,amount,balance_after,status,payment_method,description) VALUES(u,'deposit',bonus,new_bal,'completed','promo','Promo code: '||c.code);
 RETURN json_build_object('success',true,'bonus_usd',bonus,'new_balance',new_bal,'code',c.code);
END $$;
REVOKE EXECUTE ON FUNCTION public.redeem_promo_code(text,numeric) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.redeem_promo_code(text,numeric) TO authenticated;
-- ==== Missing helper functions (needed by 20260614013712 grant migration) ====
CREATE OR REPLACE FUNCTION public.get_user_tier(_user_id uuid) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $$
  SELECT CASE
    WHEN COALESCE((SELECT total_deposited FROM public.wallets WHERE user_id = _user_id), 0) >= 2000 THEN 'diamond'
    WHEN COALESCE((SELECT total_deposited FROM public.wallets WHERE user_id = _user_id), 0) >= 500 THEN 'gold'
    WHEN COALESCE((SELECT total_deposited FROM public.wallets WHERE user_id = _user_id), 0) >= 100 THEN 'silver'
    ELSE 'bronze'
  END
$$;

CREATE OR REPLACE FUNCTION public.get_public_markup() RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $$
  SELECT COALESCE((SELECT global_markup_percent FROM public.platform_settings LIMIT 1), 0)::numeric
$$;

CREATE OR REPLACE FUNCTION public.is_maintenance_mode() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $$
  SELECT COALESCE((SELECT maintenance_mode FROM public.platform_settings LIMIT 1), false)
$$;

DO $$ BEGIN
  BEGIN GRANT EXECUTE ON FUNCTION public.get_user_tier(uuid) TO authenticated; EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN GRANT EXECUTE ON FUNCTION public.get_public_markup() TO authenticated; EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN GRANT EXECUTE ON FUNCTION public.is_maintenance_mode() TO authenticated, anon; EXCEPTION WHEN OTHERS THEN NULL; END;
END $$;

-- ============ Subscriptions repair (dedupe + unique + admin policies) ============
DO $$ BEGIN
  -- keep newest row per user, drop duplicates
  DELETE FROM public.subscriptions s
  USING public.subscriptions d
  WHERE s.user_id = d.user_id
    AND s.ctid < d.ctid;

  BEGIN
    CREATE UNIQUE INDEX IF NOT EXISTS subscriptions_user_id_key ON public.subscriptions(user_id);
  EXCEPTION WHEN OTHERS THEN NULL; END;

  BEGIN
    CREATE POLICY "Admins can manage all subscriptions" ON public.subscriptions
      FOR ALL TO authenticated
      USING (public.has_role(auth.uid(), 'admin'))
      WITH CHECK (public.has_role(auth.uid(), 'admin'));
  EXCEPTION WHEN OTHERS THEN NULL; END;

  BEGIN
    CREATE POLICY "Admins can manage all subscription requests" ON public.subscription_requests
      FOR ALL TO authenticated
      USING (public.has_role(auth.uid(), 'admin'))
      WITH CHECK (public.has_role(auth.uid(), 'admin'));
  EXCEPTION WHEN OTHERS THEN NULL; END;
END $$;

-- ============ Dedupe user-scoped tables + unique indexes (upsert needs them) ============
DO $$ BEGIN
  DELETE FROM public.wallets a USING public.wallets b WHERE a.user_id = b.user_id AND a.ctid < b.ctid;
  BEGIN CREATE UNIQUE INDEX IF NOT EXISTS wallets_user_id_key ON public.wallets(user_id); EXCEPTION WHEN OTHERS THEN NULL; END;

  DELETE FROM public.profiles a USING public.profiles b WHERE a.user_id = b.user_id AND a.ctid < b.ctid;
  BEGIN CREATE UNIQUE INDEX IF NOT EXISTS profiles_user_id_key ON public.profiles(user_id); EXCEPTION WHEN OTHERS THEN NULL; END;

  DELETE FROM public.user_roles a USING public.user_roles b WHERE a.user_id = b.user_id AND a.role = b.role AND a.ctid < b.ctid;
  BEGIN CREATE UNIQUE INDEX IF NOT EXISTS user_roles_user_role_key ON public.user_roles(user_id, role); EXCEPTION WHEN OTHERS THEN NULL; END;
END $$;
