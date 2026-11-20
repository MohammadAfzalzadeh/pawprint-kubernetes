#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "$0")/common.sh"
check_cluster
[[ "$PAWPRINT_NAMESPACE" == pawprint ]]
node=${1:-}
[[ "$node" == pawprint-worker || "$node" == pawprint-worker2 ]] || {
  echo 'Usage: test-worker-failure.sh pawprint-worker[2] --operator-approved' >&2
  exit 2
}
[[ "${2:-}" == --operator-approved ]] || exit 2
[[ -z "$(k get node "$node" -o jsonpath='{.spec.unschedulable}')" ]]
ns get pods,pvc -o wide
k get pv -o json | python3 -c 'import json,sys; node=sys.argv[1]; vols=json.load(sys.stdin)["items"]; print("Local PVs referencing target:",[v["metadata"]["name"] for v in vols if node in json.dumps(v["spec"].get("nodeAffinity",{}))])' "$node"
[[ "$(ns get deploy petclinic -o jsonpath='{.status.readyReplicas}')" == 2 ]]
[[ "$(ns get pods -l app.kubernetes.io/name=petclinic -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u | wc -l)" == 2 ]]
pod=$(ns get pods -l app.kubernetes.io/name=petclinic --field-selector "spec.nodeName=$node" -o jsonpath='{.items[0].metadata.name}')
[[ -n "$pod" ]]
bash scripts/backup.sh
url=$(pawprint_http_url)
sample=$(mktemp)
trap 'k uncordon "$node"; rm -f -- "$sample"' EXIT
k cordon "$node"
(
  for _ in {1..40}; do
    printf '%s %s\n' "$(date -u +%T)" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$url/" || true)"
    sleep 0.5
  done
) >"$sample" &
sampler=$!
printf '{"apiVersion":"policy/v1","kind":"Eviction","metadata":{"name":"%s","namespace":"pawprint"}}\n' "$pod" |
  k create --raw "/api/v1/namespaces/pawprint/pods/$pod/eviction" -f -
ns wait --for=delete "pod/$pod" --timeout=90s
ns rollout status deployment/petclinic --timeout=180s
wait "$sampler"
cat "$sample"
awk '$2 != 200 {bad++} END {exit bad>0 || NR!=40}' "$sample"
[[ "$(ns get deploy petclinic -o jsonpath='{.status.readyReplicas}')" == 2 ]]
ns get pods -l app.kubernetes.io/name=petclinic -o wide
echo 'Application-only worker evacuation verified. Local PostgreSQL volumes stayed on their original nodes.'
