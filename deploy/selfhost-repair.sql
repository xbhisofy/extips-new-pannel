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

-- Policies from historically partially-applied migrations. Dropping only the
-- named policy lets the original migration recreate the intended definition.
DROP POLICY IF EXISTS "Restrict user_roles mutations to admins" ON public.user_roles;
DROP POLICY IF EXISTS "Restrict providers to admins" ON public.providers;
DROP POLICY IF EXISTS "Restrict provider_accounts to admins" ON public.provider_accounts;
DROP POLICY IF EXISTS "Users manage own drip campaigns" ON public.drip_feed_campaigns;
DROP POLICY IF EXISTS "Admins manage all drip campaigns" ON public.drip_feed_campaigns;
DROP POLICY IF EXISTS "Users view own engagement health history" ON public.engagement_health_history;
DROP POLICY IF EXISTS "Users insert own engagement health history" ON public.engagement_health_history;
DROP POLICY IF EXISTS "Admins manage engagement health history" ON public.engagement_health_history;
DROP POLICY IF EXISTS "Deny anonymous access to engagement_health_history" ON public.engagement_health_history;
DROP POLICY IF EXISTS "Users manage their own batches" ON public.mass_order_batches;
DROP POLICY IF EXISTS "Users manage their own batch items" ON public.mass_order_batch_items;
DROP POLICY IF EXISTS "Users view own link events" ON public.instagram_link_events;
DROP POLICY IF EXISTS "Admins view all link events" ON public.instagram_link_events;
DROP POLICY IF EXISTS "oxapay_deposits_select_own_or_admin" ON public.oxapay_deposits;
DROP POLICY IF EXISTS "oxapay_deposits_insert_own" ON public.oxapay_deposits;
DROP POLICY IF EXISTS "oxapay_deposits_admin_update" ON public.oxapay_deposits;

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