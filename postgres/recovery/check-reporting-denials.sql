-- Run on the primary with argument recovery=false and on the standby with recovery=true.
-- SET ROLE tests the ACLs even when network policy denies the login on the primary.
BEGIN;
\if :recovery
SET TRANSACTION READ ONLY;
\else
SET TRANSACTION READ WRITE;
\endif
SET LOCAL ROLE reporting_user;
DO $verify$
DECLARE
  statement text;
  denied text;
  required text := CASE WHEN pg_is_in_recovery() THEN '25006' ELSE '42501' END;
BEGIN
  FOREACH statement IN ARRAY ARRAY[
    'UPDATE public.owners SET last_name=last_name WHERE false',
    'INSERT INTO public.owners (id) SELECT id FROM public.owners WHERE false',
    'DELETE FROM public.owners WHERE false',
    'CREATE TABLE public.pawprint_recovery_privilege_probe (id int)'
  ] LOOP
    BEGIN
      EXECUTE statement;
      RAISE EXCEPTION 'Reporting write unexpectedly allowed: %', statement;
    EXCEPTION WHEN read_only_sql_transaction OR insufficient_privilege THEN
      GET STACKED DIAGNOSTICS denied = RETURNED_SQLSTATE;
      IF denied <> required AND denied <> '42501' THEN RAISE; END IF;
      RAISE NOTICE 'Denied [%]: %', denied, statement;
    END;
  END LOOP;
END
$verify$;
ROLLBACK;
