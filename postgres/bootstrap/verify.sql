DO $check$
BEGIN
  IF (SELECT count(*) FROM pg_tables WHERE schemaname='public'
         AND tablename IN ('owners','pets','specialties','types','vets','vet_specialties','visits')) <> 7
     OR (SELECT count(*) FROM pg_constraint WHERE connamespace='public'::regnamespace AND contype='f' AND convalidated) < 5
     OR (SELECT count(*) FROM pg_indexes WHERE schemaname='public') < 15
     OR (SELECT count(*) FROM pg_sequences WHERE schemaname='public') < 6
     OR NOT EXISTS (SELECT FROM public.owners)
     OR NOT EXISTS (SELECT FROM pawprint_meta.bootstrap WHERE version='petclinic-v1')
     OR to_regprocedure('pawprint_meta.replica_health()') IS NULL
     OR NOT has_function_privilege('reporting_user','pawprint_meta.replica_health()','EXECUTE')
     OR NOT has_table_privilege('petclinic_app','public.owners','INSERT')
     OR NOT has_sequence_privilege('petclinic_app','public.owners_id_seq','USAGE')
     OR has_schema_privilege('petclinic_app','public','CREATE')
     OR NOT has_table_privilege('reporting_user','public.owners','SELECT')
     OR has_table_privilege('reporting_user','public.owners','INSERT,UPDATE,DELETE')
     OR has_schema_privilege('reporting_user','public','CREATE')
  THEN RAISE EXCEPTION 'Bootstrap objects or privileges failed verification';
  END IF;
END
$check$;
SELECT count(*) AS owners FROM public.owners;
SELECT count(*) AS foreign_keys FROM pg_constraint WHERE connamespace='public'::regnamespace AND contype='f' AND convalidated;
SELECT count(*) AS indexes FROM pg_indexes WHERE schemaname='public';
SELECT count(*) AS sequences FROM pg_sequences WHERE schemaname='public';
