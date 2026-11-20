#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "$0")/common.sh"
check_cluster
url=$(pawprint_http_url)
bash scripts/verify-reporting.sh
replica_set=$(db_set replica)
[[ "$(ns get sts "$replica_set" -o jsonpath='{.spec.replicas}')" == 1 ]]
restore() { ns scale "sts/$replica_set" --current-replicas=0 --replicas=1; }
trap 'restore || true' EXIT
ns scale "sts/$replica_set" --current-replicas=1 --replicas=0
ns wait --for=delete "pod/$replica_set-0" --timeout=90s
deadline=$((SECONDS + 68))
while true; do
  curl -fsS --max-time 5 "$url/" >/dev/null
  report_file=$(mktemp)
  code=$(curl -sS --max-time 5 -o "$report_file" -w '%{http_code}' "$url/api/reports/summary")
  if [[ "$code" == 503 ]]; then
    python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["stale"] and d["degraded"]; print(d)' <"$report_file"
    rm -f -- "$report_file"
    break
  fi
  rm -f -- "$report_file"
  (( SECONDS < deadline )) || exit 1
  sleep 2
done
ns exec "$(db_set primary)-0" -- gosu postgres psql -XAt -d petclinic -c "SELECT count(*) FROM pg_stat_activity WHERE usename='reporting_user'" | grep -qx 0
restore
trap - EXIT
ns rollout status "sts/$replica_set" --timeout=200s
deadline=$((SECONDS + 75))
until bash scripts/verify-replication.sh && bash scripts/verify-reporting.sh; do
  (( SECONDS < deadline )) || exit 1
  sleep 4
done
