#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "$0")/common.sh"
check_cluster
ns get pod,pvc,svc -o wide
ns exec -i "$(db_set primary)-0" -- gosu postgres psql -X -v ON_ERROR_STOP=1 -d petclinic <<'SQL'
SELECT version(), pg_is_in_recovery();
SHOW data_directory;
SHOW transaction_read_only;
SHOW wal_level;
SHOW max_wal_senders;
SHOW max_replication_slots;
SELECT rolname, rolcanlogin, rolsuper, rolreplication
FROM pg_roles WHERE rolname IN ('postgres','petclinic_app','replicator','reporting_user');
SELECT relname, has_table_privilege('petclinic_app',oid,'INSERT') AS app_insert,
       has_table_privilege('reporting_user',oid,'SELECT') AS reporting_select,
       has_table_privilege('reporting_user',oid,'INSERT,UPDATE,DELETE') AS reporting_write
FROM pg_class WHERE relnamespace = 'public'::regnamespace AND relkind='r' ORDER BY relname;
SELECT conrelid::regclass, conname FROM pg_constraint
WHERE connamespace='public'::regnamespace AND contype='f';
SELECT tablename, indexname FROM pg_indexes WHERE schemaname='public';
SELECT count(*) AS owners FROM owners;
DO $$ BEGIN
 IF pg_is_in_recovery() OR current_setting('transaction_read_only') <> 'off'
  OR (SELECT count(*) FROM pg_tables WHERE schemaname='public'
  AND tablename IN ('owners','pets','types','vets','specialties','vet_specialties','visits')) <> 7
  OR NOT has_table_privilege('petclinic_app','owners','INSERT')
  OR NOT has_sequence_privilege('petclinic_app',pg_get_serial_sequence('owners','id'),'USAGE')
  OR NOT has_table_privilege('reporting_user','owners','SELECT')
  OR has_table_privilege('reporting_user','owners','INSERT,UPDATE,DELETE')
  OR has_schema_privilege('reporting_user','public','CREATE')
  OR has_schema_privilege('petclinic_app','public','CREATE')
  OR EXISTS (SELECT FROM pg_roles WHERE rolname IN ('reporting_user','petclinic_app') AND (rolsuper OR rolreplication))
  OR (SELECT count(*) FROM owners) = 0
 THEN RAISE EXCEPTION 'PetClinic schema, seed data, or privileges failed verification';
 END IF;
END $$;
SQL
