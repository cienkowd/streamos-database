-- StreamOS - czyszczenie bazy przed ponownym utworzeniem
-- uruchamiac jako streamos_admin (Alt+X)
-- usuwa uzytkownikow testowych (te, ktore istnieja) i caly schemat streamos

DO $$
DECLARE r text;
BEGIN
  FOR r IN SELECT rolname FROM pg_roles
           WHERE rolname IN ('reklamodawca_01', 'reklamodawca_02', 'reklamodawca_03',
                             'partner_alfa', 'partner_beta',
                             'rola_reklamodawca', 'rola_partner')
  LOOP
    EXECUTE format('DROP OWNED BY %I', r);   -- zabiera wszystkie nadane uprawnienia
    EXECUTE format('DROP ROLE %I', r);
  END LOOP;
END $$;

DROP SCHEMA IF EXISTS streamos CASCADE;

-- kontrola: oba wyniki powinny byc puste
SELECT rolname FROM pg_roles WHERE rolname LIKE 'reklamodawca%' OR rolname LIKE 'partner%' OR rolname LIKE 'rola%';
SELECT schema_name FROM information_schema.schemata WHERE schema_name = 'streamos';
