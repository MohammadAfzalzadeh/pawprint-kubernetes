#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "$0")/common.sh"
node=${1:-}
if [[ $# != 2 || "${2:-}" != --operator-approved || ! "$node" =~ ^pawprint-worker2?$ ]]; then
  echo 'Usage: test-worker-failure.sh pawprint-worker[2] --operator-approved' >&2
  exit 2
fi
check_cluster
[[ "$PAWPRINT_NAMESPACE" == pawprint ]]
recovery_idle
survivor=pawprint-worker
[[ "$node" != "$survivor" ]] || survivor=pawprint-worker2
node_schedulable() {
  local unschedulable
  unschedulable=$(k --request-timeout=10s get node "$1" -o jsonpath='{.spec.unschedulable}') &&
    [[ "$unschedulable" != true ]]
}
node_schedulable "$node"
node_schedulable "$survivor"
k wait node "$node" "$survivor" --for=condition=Ready --timeout=10s
primary=$(db_set primary)
replica=$(db_set replica)
url=$(pawprint_http_url)
mkdir -p .pawprint/evidence
evidence=$(mktemp -d .pawprint/evidence/worker-evacuation.XXXXXXXX)
echo "Evidence directory: $evidence"

placement() {
  ns get pods -l app.kubernetes.io/name=petclinic -o json | python3 -c '
import json, sys
pods = json.load(sys.stdin)["items"]
if len(pods) != 2:
    sys.exit("Expected exactly two PetClinic Pods")
for pod in pods:
    metadata, status = pod["metadata"], pod["status"]
    name = metadata["name"]
    if metadata.get("deletionTimestamp") or not any(
        c["type"] == "Ready" and c["status"] == "True" for c in status.get("conditions", [])
    ):
        sys.exit(f"PetClinic Pod {name} is not Ready")
    print(pod["spec"]["nodeName"], name, metadata["uid"], sep="\t")
' | sort
}

database_snapshot() {
  ns --request-timeout=15s get pods,pvc -o json | python3 -c '
import json, sys
resources = json.load(sys.stdin)["items"]
pods = {o["metadata"]["name"]: o for o in resources if o["kind"] == "Pod"}
claims = {o["metadata"]["name"]: o for o in resources if o["kind"] == "PersistentVolumeClaim"}
snapshot = {}
for name in sys.argv[1:]:
    pod = pods[name]
    if pod["metadata"].get("deletionTimestamp") or not any(
        c["type"] == "Ready" and c["status"] == "True" for c in pod["status"].get("conditions", [])
    ):
        sys.exit(f"Database Pod {name} is not Ready")
    mounted = [v["persistentVolumeClaim"]["claimName"] for v in pod["spec"]["volumes"] if "persistentVolumeClaim" in v]
    if not mounted or any(claims[c]["status"]["phase"] != "Bound" for c in mounted):
        sys.exit(f"Expected bound persistent storage for {name}")
    snapshot[name] = {
        "uid": pod["metadata"]["uid"], "node": pod["spec"]["nodeName"],
        "restarts": {c["name"]: c["restartCount"] for c in pod["status"]["containerStatuses"]},
        "claims": {c: {"uid": claims[c]["metadata"]["uid"], "pv": claims[c]["spec"]["volumeName"]} for c in mounted},
    }
print(json.dumps(snapshot, indent=2, sort_keys=True))
' "$primary-0" "$replica-0"
}

sample() {
  local route=$1 stamp status
  stamp=$(date -u +%FT%T.%3NZ)
  status=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 2 "$url$route") || status=000
  printf '%s\t%s\n' "$stamp" "$status"
}

sample_loop() {
  while [[ ! -e "$evidence/stop-sampling" ]]; do
    sample "$1"
    sleep 0.5
  done
}

samplers=()
cordon_attempted=false
cleanup() {
  local result=$?
  trap - EXIT
  if "$cordon_attempted"; then
    if k --request-timeout=15s uncordon "$node" && node_schedulable "$node"; then
      echo "$(date -u +%FT%TZ) $node schedulable again" | tee -a "$evidence/timeline.log"
    else
      echo "Could not verify that $node is schedulable. Check it before continuing." >&2
      result=1
    fi
  fi
  touch "$evidence/stop-sampling"
  for pid in "${samplers[@]}"; do wait "$pid" || result=1; done
  if [[ -s "$evidence/database-before.json" ]]; then
    if ! database_snapshot >"$evidence/database-after.json" ||
       ! diff -u "$evidence/database-before.json" "$evidence/database-after.json"; then
      echo 'Database identity or readiness check failed.' >&2
      result=1
    else
      echo 'Database Pod identities, restart counts and PVC bindings matched.'
    fi
  fi
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

bash scripts/backup.sh | tee "$evidence/backup.log"
k get nodes -o wide >"$evidence/nodes-before.txt"
ns get pods,pvc,pdb -o wide >"$evidence/workloads-before.txt"
k get pv -o wide >"$evidence/volumes-before.txt"
placement >"$evidence/placement-before.tsv"
read -r _ pod uid < <(awk -v node="$node" '$1 == node' "$evidence/placement-before.tsv")
[[ "$(awk -v node="$survivor" '$1 == node {n++} END {print n+0}' "$evidence/placement-before.tsv")" == 1 ]]
database_snapshot >"$evidence/database-before.json"
sample / >"$evidence/petclinic-http.tsv"
sample /api/reports/summary >"$evidence/reporting-http.tsv"
awk '$2 != 200 {exit 1}' "$evidence/"*-http.tsv
recovery_idle
node_schedulable "$node"
node_schedulable "$survivor"

sample_loop / >>"$evidence/petclinic-http.tsv" &
samplers+=("$!")
sample_loop /api/reports/summary >>"$evidence/reporting-http.tsv" &
samplers+=("$!")
cordon_attempted=true
k --request-timeout=15s cordon "$node"
echo "$(date -u +%FT%TZ) requesting eviction of $pod on $node" | tee "$evidence/timeline.log"
printf '{"apiVersion":"policy/v1","kind":"Eviction","metadata":{"name":"%s","namespace":"pawprint"},"deleteOptions":{"preconditions":{"uid":"%s"}}}\n' "$pod" "$uid" |
  k --request-timeout=15s create --raw "/api/v1/namespaces/pawprint/pods/$pod/eviction" -f -
ns wait --for=delete "pod/$pod" --timeout=90s
ns rollout status deployment/petclinic --timeout=180s | tee "$evidence/rollout.log"
placement | tee "$evidence/placement-after.tsv"
awk -v node="$survivor" '$1 != node {exit 1}' "$evidence/placement-after.tsv"
echo "$(date -u +%FT%TZ) both PetClinic Pods Ready on $survivor" | tee -a "$evidence/timeline.log"
touch "$evidence/stop-sampling"
for pid in "${samplers[@]}"; do wait "$pid"; done
samplers=()
sample / >>"$evidence/petclinic-http.tsv"
sample /api/reports/summary >>"$evidence/reporting-http.tsv"
ns get pods,pvc,pdb -o wide >"$evidence/workloads-after.txt"
awk '$2 != 200 {print FILENAME, $0; bad=1} END {exit bad}' "$evidence/"*-http.tsv
echo 'PetClinic placement and HTTP checks passed.'
