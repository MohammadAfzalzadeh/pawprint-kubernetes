#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
export LC_ALL=C PGPASSWORD="$APP_PASSWORD" PGCONNECT_TIMEOUT=5
export PGHOST=postgres-primary PGUSER=petclinic_app PGDATABASE=petclinic
[[ "$(pg_dump --version | awk '{print $3}')" == 18.6 ]]
backup_id="petclinic-$(date -u +%Y%m%dT%H%M%SZ)-$HOSTNAME"
staging=$(mktemp -d "/backup/.$backup_id.XXXXXXXX")
final="/backup/$backup_id.backup"
exporter_pid=
cleanup() {
  if [[ -n "$exporter_pid" ]]; then
    printf '\\q\n' 1>&"$control" 2>/dev/null
    wait "$exporter_pid"
  fi
}
trap cleanup EXIT

# Keep the exporting transaction open until both consumers finish.
coproc EXPORTER { exec psql -XqAt -v ON_ERROR_STOP=1; }
exporter_pid=$EXPORTER_PID
exec {control}>&"${EXPORTER[1]}"
exec {output}<&"${EXPORTER[0]}"
printf '%s\n' 'BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;' 'SELECT pg_export_snapshot();' >&"$control"
IFS= read -r -t 20 snapshot <&"$output"
[[ "$snapshot" =~ ^[0-9A-F-]+$ ]]
pg_dump -Fc -Z6 --no-owner --no-acl --schema=public --snapshot="$snapshot" --file="$staging/petclinic.dump"
psql -XqAt -F $'\t' -v ON_ERROR_STOP=1 -v snapshot="$snapshot" >"$staging/snapshot.tsv" <<'SQL'
BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET TRANSACTION SNAPSHOT :'snapshot';
\i /operations/snapshot.sql
COMMIT;
SQL
printf '%s\n' 'COMMIT;' '\q' >&"$control"
wait "$exporter_pid"
exporter_pid=

archive="$staging/petclinic.dump"
test -s "$archive"
pg_restore --list "$archive" >"$staging/toc.txt"
# Decode archive payload as well as reading its table of contents.
pg_restore --exit-on-error --file=/dev/null "$archive"
for table in owners pets specialties types vets vet_specialties visits; do
  awk -F '\t' -v table="$table" '$1=="TABLE" && $2==table { found=1 } END { exit !found }' "$staging/snapshot.tsv"
  awk -v table="$table" '$4=="TABLE" && $5=="DATA" && $6=="public" && $7==table { found=1 } END { exit !found }' "$staging/toc.txt"
done
awk '$4=="SEQUENCE" && $5=="SET" && $6=="public"' "$staging/toc.txt" >"$staging/sequence.toc"
pg_restore --exit-on-error --use-list="$staging/sequence.toc" --file=- "$archive" |
  awk '/^SELECT pg_catalog.setval\(/' | sort >"$staging/sequences.sql"
[[ "$(wc -l <"$staging/sequences.sql")" == "$(wc -l <"$staging/sequence.toc")" ]]
[[ "$(wc -l <"$staging/sequences.sql")" -ge 6 ]]
(
  cd "$staging"
  sha256sum petclinic.dump toc.txt snapshot.tsv sequences.sql > SHA256SUMS
)
[[ ! -e "$final" ]]
mv -T -- "$staging" "$final"
# The read-only monitoring collector runs as GID 10001. Keep archives private
# from other users while allowing that group to verify checksums and size.
chgrp -R 10001 "$final"
find "$final" -type d -exec chmod 0750 {} +
find "$final" -type f -exec chmod 0640 {} +
printf 'BACKUP_ID=%s\n' "$backup_id"
stat --format='archive=%n bytes=%s' "$final/petclinic.dump"
cat "$final/SHA256SUMS"
awk -F '\t' '$1=="TABLE" { printf "snapshot table=%s rows=%s sha256=%s\n", $2,$3,$4 }' "$final/snapshot.tsv"
