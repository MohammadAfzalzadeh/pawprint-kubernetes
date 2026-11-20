#!/usr/bin/env bash
set -Eeuo pipefail
source /operations/isolated-postgres.sh
start_isolated_postgres

export POSTGRES_USER=postgres
PETCLINIC_APP_PASSWORD=$(openssl rand -hex 24)
REPLICATION_PASSWORD=$(openssl rand -hex 24)
REPORTING_PASSWORD=$(openssl rand -hex 24)
export PETCLINIC_APP_PASSWORD REPLICATION_PASSWORD REPORTING_PASSWORD
gosu postgres bash /primary-init/10-create-roles.sh
unset PETCLINIC_APP_PASSWORD REPLICATION_PASSWORD REPORTING_PASSWORD

db() { gosu postgres psql -X -v ON_ERROR_STOP=1 -d petclinic "$@"; }
snapshot() { db -qAt -F $'\t' --single-transaction -f /operations/snapshot.sql; }
sequences() { db -qAt --single-transaction -f /operations/verify-sequences.sql | sort; }

db --single-transaction -f /sql/bootstrap.sql
db -f /sql/verify.sql
db --single-transaction -c "SET ROLE petclinic_app; INSERT INTO owners(first_name,last_name) VALUES ('PawPrint','BootstrapSentinel');"
snapshot >/restore/before.tsv
sequences >/restore/before-sequences.sql
db --single-transaction -f /sql/bootstrap.sql
db -f /sql/verify.sql
snapshot >/restore/after.tsv
sequences >/restore/after-sequences.sql
diff -u /restore/before.tsv /restore/after.tsv
diff -u /restore/before-sequences.sql /restore/after-sequences.sql
[[ "$(db -qAt -c "SELECT count(*) FROM owners WHERE last_name='BootstrapSentinel'")" == 1 ]]
echo 'Bootstrap repeat preserved existing row, all public data and schema, and sequence state.'

gosu postgres createdb --owner=petclinic_owner petclinic_guard
gosu postgres psql -X -v ON_ERROR_STOP=1 -d petclinic_guard \
  -c 'SET ROLE petclinic_owner; CREATE TABLE public.preexisting (id integer); INSERT INTO public.preexisting VALUES (42);'
if gosu postgres psql -X --single-transaction -v ON_ERROR_STOP=1 -d petclinic_guard -f /sql/bootstrap.sql >/restore/guard.log 2>&1; then
  echo 'Unmarked existing database unexpectedly accepted' >&2
  exit 1
else
  status=$?
fi
cat /restore/guard.log
[[ "$status" == 3 ]]
grep -F 'Existing public objects require operator review before bootstrap' /restore/guard.log
[[ "$(gosu postgres psql -XqAt -v ON_ERROR_STOP=1 -d petclinic_guard -c "SELECT id=42 AND to_regnamespace('pawprint_meta') IS NULL FROM public.preexisting")" == t ]]
echo 'Unmarked database guard returned exit 3 and rolled back all bootstrap changes.'
