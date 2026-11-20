#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "$0")/common.sh"
source scripts/ghcr.sh
check_cluster
check_ghcr_release
nodes=$("$KIND_BIN" get nodes --name pawprint)
probe=
cleanup() {
  if [[ -n "$probe" ]]; then
    ns delete "$probe" --ignore-not-found --wait=false >/dev/null
  fi
}
trap cleanup EXIT
worker_count=0
while IFS= read -r node; do
  [[ "$node" =~ ^pawprint-worker[0-9]*$ ]] || continue
  (( worker_count += 1 ))
  hostname=$(k get node "$node" -o jsonpath='{.metadata.labels.kubernetes\.io/hostname}')
  [[ -n "$hostname" ]]
  for component in petclinic reporting; do
    probe=$(python3 scripts/ghcr_release.py probe "$GHCR_RELEASE" "${GHCR_PULL_SECRET:-}" "$component" "$hostname" |
      ns create -f - -o name)
    echo "Checking $component on $node ($probe)"
    if ! ns wait --for=jsonpath='{.status.phase}'=Succeeded "$probe" --timeout=260s; then
      ns describe "$probe"
      exit 1
    fi
    read -r actual_node uid image image_id < <(ns get "$probe" -o jsonpath='{.spec.nodeName}{"\t"}{.metadata.uid}{"\t"}{.spec.containers[0].image}{"\t"}{.status.containerStatuses[0].imageID}{"\n"}')
    [[ "$actual_node" == "$node" && -n "$image_id" ]]
    for _ in {1..5}; do
      events=$(ns get events --field-selector "involvedObject.uid=$uid,reason=Pulled" -o jsonpath='{range .items[*]}{.message}{"\n"}{end}')
      [[ "$events" == *"Successfully pulled image"* ]] && break
      sleep 1
    done
    [[ "$events" == *"Successfully pulled image"* ]] || {
      printf 'No successful registry pull event for %s\n%s\n' "$probe" "$events" >&2
      exit 1
    }
    printf '%s\n' "$events"
    printf 'node=%s image=%s imageID=%s\n' "$actual_node" "$image" "$image_id"
    cleanup
    probe=
  done
done <<< "$nodes"
(( worker_count > 0 )) || { echo 'No PawPrint workers found.' >&2; exit 1; }
