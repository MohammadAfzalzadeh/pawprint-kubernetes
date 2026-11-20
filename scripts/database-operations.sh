# Shared helpers for the PostgreSQL Jobs.
create_ops_configmap() {
  ns create configmap pawprint-backup-tools \
    --from-file=postgres/backup/backup.sh \
    --from-file=postgres/backup/restore.sh \
    --from-file=postgres/backup/isolated-postgres.sh \
    --from-file=postgres/backup/snapshot.sql \
    --from-file=postgres/backup/verify-sequences.sql \
    --from-file=postgres/backup/verify-identity.sql \
    --dry-run=client -o yaml | ns apply -f -
}

wait_for_database_job() {
  local job=$1 timeout=$2 deadline=$((SECONDS + $2)) conditions
  printf 'Watching %s\n' "$job"
  while (( SECONDS < deadline )); do
    conditions=$(ns get "$job" -o jsonpath='{range .status.conditions[?(@.status=="True")]}{.type}{" "}{end}')
    if [[ "$conditions" == *Failed* ]]; then
      if ! ns logs "$job" --all-containers --prefix --timestamps; then
        printf 'Container logs unavailable for %s\n' "$job" >&2
      fi
      ns describe "$job"
      return 1
    fi
    if [[ "$conditions" == *Complete* ]]; then
      ns logs "$job" --all-containers
      return 0
    fi
    sleep 2
  done
  printf 'Timed out waiting for %s after %s seconds\n' "$job" "$timeout" >&2
  ns describe "$job"
  return 1
}

create_bootstrap_configmap() {
  ns create configmap "$1" \
    --from-file=schema.sql=spring-petclinic/src/main/resources/db/postgres/schema.sql \
    --from-file=data.sql=spring-petclinic/src/main/resources/db/postgres/data.sql \
    --from-file=postgres/bootstrap/bootstrap.sql \
    --from-file=postgres/bootstrap/reporting.sql \
    --from-file=postgres/bootstrap/verify.sql \
    --from-file=postgres/bootstrap/verify-bootstrap.sh \
    --dry-run=client -o yaml | ns apply -f -
}

bootstrap_marker() {
  ns exec -i "$(db_set primary)-0" -- gosu postgres psql -XqAt -v ON_ERROR_STOP=1 -d petclinic <<'SQL'
BEGIN READ ONLY;
SELECT to_regclass('pawprint_meta.bootstrap') IS NOT NULL AS marker_table \gset
\if :marker_table
SELECT EXISTS(SELECT FROM pawprint_meta.bootstrap WHERE version='petclinic-v1');
\else
SELECT false;
\endif
COMMIT;
SQL
}

verify_bootstrap_objects() {
  ns exec -i "$(db_set primary)-0" -- gosu postgres psql -X -v ON_ERROR_STOP=1 \
    --single-transaction -d petclinic -f - < postgres/bootstrap/verify.sql
}
