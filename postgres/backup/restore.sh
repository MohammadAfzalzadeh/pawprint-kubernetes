#!/usr/bin/env bash
set -Eeuo pipefail
source /operations/isolated-postgres.sh
export LC_ALL=C
work=$(mktemp -d /restore/verify.XXXXXXXX)

if [[ -n "${BACKUP_ID:-}" ]]; then
  [[ "$BACKUP_ID" =~ ^petclinic-[0-9]{8}T[0-9]{6}Z-[a-z0-9-]+$ ]]
  backup="/backup/$BACKUP_ID.backup"
else
  shopt -s nullglob
  candidates=(/backup/petclinic-*.backup)
  (( ${#candidates[@]} > 0 )) || { echo 'No verified backup bundle available' >&2; exit 1; }
  backup=${candidates[-1]}
fi

if [[ ! -s "$backup/petclinic.dump" ]]; then
  printf 'Backup archive missing or empty: %s/petclinic.dump\n' "$backup" >&2
  exit 1
fi
(
  cd "$backup"
  if [[ "$(sed -nE 's/^[0-9a-f]{64}  (petclinic\.dump|toc\.txt|snapshot\.tsv|sequences\.sql)$/\1/p' SHA256SUMS | sort)" \
    != $'petclinic.dump\nsequences.sql\nsnapshot.tsv\ntoc.txt' || "$(wc -l < SHA256SUMS)" != 4 ]]; then
    echo 'Invalid SHA256SUMS: expected exactly the four PawPrint bundle files' >&2
    exit 1
  fi
  sha256sum --check --strict SHA256SUMS
)
manifest_hash=$(sha256sum < "$backup/SHA256SUMS" | cut -d ' ' -f 1)
printf 'BACKUP_MANIFEST_SHA256=%s\n' "$manifest_hash"
if [[ -n "${EXPECTED_BACKUP_MANIFEST:-}" ]]; then
  [[ "$manifest_hash" == "$EXPECTED_BACKUP_MANIFEST" ]] || { echo 'Backup changed since preflight' >&2; exit 1; }
fi
archive="$backup/petclinic.dump"
pg_restore --list "$archive" >"$work/toc.txt"
pg_restore --exit-on-error --file=/dev/null "$archive"
if [[ -n "${RECOVERY_MIN_FREE_BYTES:-}" ]]; then
  grep -Eq '^;[[:space:]]+Dumped from database version: 18\.' "$work/toc.txt"
  disk_path=${RECOVERY_PGDATA:-}
  disk_path=${disk_path%/18/docker}
  [[ -n "$disk_path" ]] || disk_path=/restore
  available=$(df -PB1 "$disk_path" | awk 'NR==2 {print $4}')
  printf 'RECOVERY_FILESYSTEM_FREE_BYTES=%s\n' "$available"
  (( available >= RECOVERY_MIN_FREE_BYTES )) || { echo 'Insufficient actual backing filesystem space' >&2; exit 1; }
fi
# The fresh database already has public. Preserve its other TOC entries.
awk '
  $4=="SCHEMA" && $5=="-" && $6=="public" { print ";" $0; n++; next }
  { print }
  END { if (n != 1) exit 1 }
' "$work/toc.txt" >"$work/restore.toc"

database=petclinic_restore
owner=()
identity="${RECOVERY_PGDATA:-}"
if [[ -n "$identity" ]]; then
  printf 'PERSISTENT_RESTORE_PHASE=INITIALIZING\n'
  start_isolated_postgres "$identity"
  POSTGRES_USER=postgres gosu postgres bash /provision/10-create-roles.sh
  database=petclinic
  owner=(--role=petclinic_owner)
else
  start_isolated_postgres
  gosu postgres createdb --template=template0 "$database"
fi
gosu postgres psql -XAt -v ON_ERROR_STOP=1 -d "$database" \
  -c "SELECT format('Restore database encoding=%s collation=%s ctype=%s provider=%s', pg_encoding_to_char(encoding), datcollate, datctype, datlocprovider) FROM pg_database WHERE datname=current_database()"
install -o postgres -g postgres -m 0600 "$work/restore.toc" "$PGHOST/restore.toc"
printf 'PERSISTENT_RESTORE_PHASE=RESTORING\n'
gosu postgres pg_restore --exit-on-error --single-transaction --no-owner --no-acl "${owner[@]}" \
  --use-list="$PGHOST/restore.toc" --dbname="$database" <"$archive"
if [[ -n "$identity" ]]; then
  gosu postgres psql -Xq -v ON_ERROR_STOP=1 --single-transaction -d "$database" -f /operations/recover-metadata.sql
  gosu postgres psql -Xq -v ON_ERROR_STOP=1 --single-transaction -d "$database" -f /operations/verify.sql
fi
printf 'PERSISTENT_RESTORE_PHASE=VALIDATING\n'
gosu postgres psql -XqAt -F $'\t' -v ON_ERROR_STOP=1 --single-transaction \
  -d "$database" -f /operations/snapshot.sql >"$work/restored.tsv"
diff -u "$backup/snapshot.tsv" "$work/restored.tsv"
gosu postgres psql -XqAt -v ON_ERROR_STOP=1 --single-transaction \
  -d "$database" -f /operations/verify-sequences.sql | sort >"$work/restored-sequences.sql"
diff -u "$backup/sequences.sql" "$work/restored-sequences.sql"
gosu postgres psql -X -v ON_ERROR_STOP=1 --single-transaction \
  -d "$database" -f /operations/verify-identity.sql
if [[ -n "$identity" ]]; then
  # nextval is nontransactional. Restore the previously checksum-verified archive values.
  gosu postgres psql -Xq -v ON_ERROR_STOP=1 --single-transaction -d "$database" <"$backup/sequences.sql" >/dev/null
  gosu postgres psql -XqAt -v ON_ERROR_STOP=1 --single-transaction \
    -d "$database" -f /operations/verify-sequences.sql | sort >"$work/final-sequences.sql"
  diff -u "$backup/sequences.sql" "$work/final-sequences.sql"
  printf 'RECOVERY_SEQUENCE_SHA256=%s\n' "$(sha256sum < "$work/final-sequences.sql" | cut -d ' ' -f 1)"
  gosu postgres psql -XAtq -v ON_ERROR_STOP=1 -d "$database" \
    -c "SELECT 'RECOVERY_SYSTEM_ID=' || system_identifier FROM pg_control_system()"
fi
awk -F '\t' '
 $1=="TABLE" { printf "restored table=%s rows=%s sha256=%s\n", $2,$3,$4; tables++ }
 $1=="CONSTRAINT" { constraints++; if($4=="f") fks++ }
 $1=="INDEX" { indexes++ }
 $1=="SEQUENCE" { sequences++ }
 END { printf "matched tables=%d constraints=%d foreign_keys=%d indexes=%d sequences=%d\n", tables,constraints,fks,indexes,sequences }
' "$work/restored.tsv"
printf 'RESTORE_VERIFIED=%s\n' "${backup##*/}"
