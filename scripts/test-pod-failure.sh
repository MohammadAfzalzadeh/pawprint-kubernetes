#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "$0")/common.sh"
check_cluster
url=$(pawprint_http_url)
ns get pods -l app.kubernetes.io/name=petclinic -o wide
[[ "$(ns get deploy petclinic -o jsonpath='{.status.readyReplicas}')" == 2 ]]
pod=$(ns get pods -l app.kubernetes.io/name=petclinic -o jsonpath='{.items[0].metadata.name}')
sample=$(mktemp)
trap 'rm -f -- "$sample"' EXIT
(
  for _ in {1..40}; do
    printf '%s %s\n' "$(date -u +%T)" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$url/" || true)"
    sleep 0.5
  done
) >"$sample" &
sampler=$!
ns delete pod "$pod" --wait=true --timeout=90s
ns rollout status deployment/petclinic --timeout=180s
wait "$sampler"
cat "$sample"
awk '$2 != 200 {bad++} END {exit bad>0 || NR!=40}' "$sample"
[[ "$(ns get deploy petclinic -o jsonpath='{.status.readyReplicas}')" == 2 ]]
ns get pods -l app.kubernetes.io/name=petclinic -o wide
