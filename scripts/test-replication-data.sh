#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "$0")/common.sh"
check_cluster
url=$(pawprint_http_url)
marker="WAL-$(date -u +%s)-$RANDOM"
primary_pod="$(db_set primary)-0"
replica_pod="$(db_set replica)-0"
primary() { ns exec "$primary_pod" -- gosu postgres psql -XAt -v ON_ERROR_STOP=1 -d petclinic -c "$1"; }
replica() { ns exec "$replica_pod" -- gosu postgres psql -XAt -v ON_ERROR_STOP=1 -d petclinic -c "$1"; }
before=$(primary 'SELECT pg_current_wal_lsn()')
start=$(date +%s%3N)
response=$(curl -fsS --max-time 8 -o /dev/null -w '%{http_code} %{redirect_url}' \
  --data-urlencode "firstName=PawPrint" --data-urlencode "lastName=$marker" \
  --data-urlencode 'address=Test Street' --data-urlencode 'city=Test City' --data-urlencode 'telephone=5551234567' \
  "$url/owners/new")
if [[ ! "$response" =~ ^30[12378]\ .*/owners/[0-9]+$ ]]; then
  printf 'Unexpected owner creation redirect: %s\n' "${response%%;*}" >&2
  exit 1
fi
redirect=${response#* }
[[ "$redirect" == "$url/owners/"* ]] || { echo 'Owner redirect left the ingress origin.' >&2; exit 1; }
[[ "$(curl -fsS --max-time 5 -o /dev/null -w '%{http_code}' "$redirect")" == 200 ]]
id=${response##*/}
query="SELECT id,last_name FROM owners WHERE id=$id"
[[ "$(primary "$query")" == "$id|$marker" ]]
deadline=$((SECONDS + 30))
until [[ "$(replica "$query")" == "$id|$marker" ]]; do
  (( SECONDS < deadline )) || exit 1
  sleep 1
done
printf 'PetClinic wrote owner %s; Replica matched within %sms (includes polling).\n' "$id" "$(( $(date +%s%3N) - start ))"
[[ "$(replica "SELECT pg_last_wal_replay_lsn() > '$before'::pg_lsn")" == t ]]
deadline=$((SECONDS + 70))
until curl -fsS --max-time 5 "$url/api/reports/summary" |
  python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(1) if d["stale"] or d["data"]["latestOwnerId"] != int(sys.argv[1]) else print(d["generatedAt"], d["data"])' "$id"; do
  (( SECONDS < deadline )) || exit 1
  sleep 2
done
printf 'Reporting observed the same owner after %sms. Test record retained.\n' "$(( $(date +%s%3N) - start ))"
bash scripts/verify-reporting.sh
