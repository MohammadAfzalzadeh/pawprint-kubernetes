#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "$0")/common.sh"
check_cluster
component=${1:-primary}
[[ "$component" == primary || "$component" == replica ]]
bash scripts/verify-replication.sh
marker="persist-$(date -u +%s)-$RANDOM"
db="$(db_set "$component")"
ns exec "$(db_set primary)-0" -- gosu postgres psql -X -v ON_ERROR_STOP=1 -d petclinic \
  -c "INSERT INTO owners(first_name,last_name,address,city,telephone) VALUES('PawPrint','$marker','Test St','Test City','5551234567')"
sql="SELECT count(*) FROM owners WHERE last_name='$marker'"
read_marker() { ns exec "$db-0" -- gosu postgres psql -XAt -v ON_ERROR_STOP=1 -d petclinic -c "$sql"; }
deadline=$((SECONDS + 30))
until [[ "$(read_marker)" == 1 ]]; do
  (( SECONDS < deadline )) || exit 1
  sleep 1
done
claim="data-$db-0"
before=$(ns get pvc "$claim" -o jsonpath='{.metadata.uid}:{.spec.volumeName}')
ns delete pod "$db-0" --wait=true --timeout=90s
ns rollout status "sts/$db" --timeout=200s
[[ "$(ns get pvc "$claim" -o jsonpath='{.metadata.uid}:{.spec.volumeName}')" == "$before" ]]
[[ "$(read_marker)" == 1 ]]
echo "Persistence verified on $component. Same claim/PV $before and retained marker $marker."
