#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "$0")/common.sh"
check_cluster
k get nodes -o wide
ns get deploy,sts,pods,svc,pvc,ingress -o wide
k get pv -o wide
ns rollout status deployment/petclinic --timeout=60s
[[ "$(ns get deploy petclinic -o jsonpath='{.status.readyReplicas}')" == 2 ]]
url=$(pawprint_http_url)
status=$(curl -fsS --max-time 5 -o /dev/null -w '%{http_code}' "$url/")
[[ "$status" == 200 ]]
printf 'PetClinic ingress returned HTTP %s\n' "$status"
