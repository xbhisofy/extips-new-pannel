-- ============================================================================
-- Data API grants for every base table in public.
-- authenticated + service_role always; anon SELECT only where a permissive
-- (non auth.uid()-scoped) SELECT policy exists.
-- ============================================================================
DO $$
DECLARE t record; has boolean;
BEGIN
  FOR t IN SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
            WHERE c.relkind='r' AND n.nspname='public'
  LOOP
    SELECT EXISTS(SELECT 1 FROM information_schema.role_table_grants
      WHERE grantee='authenticated' AND table_schema='public' AND table_name=t.relname
        AND privilege_type IN ('SELECT','INSERT','UPDATE','DELETE')) INTO has;
    IF NOT has THEN
      EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON public.%I TO authenticated', t.relname);
    END IF;

    SELECT EXISTS(SELECT 1 FROM information_schema.role_table_grants
      WHERE grantee='service_role' AND table_schema='public' AND table_name=t.relname
        AND privilege_type IN ('SELECT','INSERT','UPDATE','DELETE')) INTO has;
    IF NOT has THEN
      EXECUTE format('GRANT ALL ON public.%I TO service_role', t.relname);
    END IF;

    -- anon read only when a public-read policy already allows it.
    SELECT EXISTS(
      SELECT 1 FROM pg_policies p
       WHERE p.schemaname='public' AND p.tablename=t.relname
         AND p.cmd IN ('SELECT','ALL')
         AND ('anon'=ANY(p.roles) OR 'public'=ANY(p.roles))
         AND coalesce(p.qual,'true') NOT LIKE '%auth.uid()%'
    ) INTO has;
    IF has THEN
      EXECUTE format('GRANT SELECT ON public.%I TO anon', t.relname);
    END IF;
  END LOOP;
END $$;

GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
