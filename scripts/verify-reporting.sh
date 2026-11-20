#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "$0")/common.sh"
check_cluster
url=$(pawprint_http_url)
for endpoint in summary owners pets vets visits pet-types status; do
  report=$(curl -fsS --max-time 5 "$url/api/reports/$endpoint") || exit 1
  python3 -c 'import json,sys; d=json.load(sys.stdin); assert not d["stale"] and d["replicaStatus"]=="streaming" and d["refreshSeconds"]==30; print(json.dumps(d))' <<<"$report"
done
db() {
  ns exec "$1" -- gosu postgres psql -XAt -v ON_ERROR_STOP=1 -d petclinic -c "$2"
}
query="SELECT count(*) FROM pg_stat_activity WHERE usename='reporting_user' AND application_name='pawprint-reporting'"
[[ "$(db "$(db_set primary)-0" "$query")" == 0 ]]
[[ "$(db "$(db_set replica)-0" "$query")" -ge 1 ]]
echo 'pg_stat_activity shows the Reporting API on Replica and zero reporting sessions on Primary.'
