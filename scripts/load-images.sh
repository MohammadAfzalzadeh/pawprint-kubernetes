#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "$0")/common.sh"
check_cluster
load() {
  local image=$1 node
  docker image inspect "$image" --format '{{.Id}} {{.Os}}/{{.Architecture}} {{json .RepoDigests}}'
  "$KIND_BIN" load docker-image "$image" --name pawprint
  for node in $("$KIND_BIN" get nodes --name pawprint); do
    printf '%s ' "$node"
    docker exec "$node" crictl inspecti "$image" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"]["id"])'
  done
}
mirror() {
  local original=$1 expected_id=$2 mirrored="docker-mirror.liara.ir/$1"
  if ! docker image inspect "$mirrored" >/dev/null 2>&1; then
    docker pull "$mirrored"
  fi
  if [[ "$(docker image inspect "$mirrored" --format '{{.Id}} {{.Os}}/{{.Architecture}}')" != "$expected_id linux/amd64" ]]; then
    echo "Unexpected image ID or architecture for $mirrored" >&2
    return 1
  fi
  docker tag "$mirrored" "$original"
  load "$original"
}
case "${1:-all}" in
  postgres) mirror postgres:18.6-trixie sha256:8bca9649e52d948114ccc8164b55b7ab26b64e729893e420114bb5c87bf7c7cc ;;
  ingress) mirror nginx/nginx-ingress:5.8.0 sha256:8da42de2ec1499b61412852bdfc4dc1cc4bfd5db0313891cae5b4d305cd3511e ;;
  petclinic) load "pawprint/petclinic:$(git -C spring-petclinic rev-parse --short=12 HEAD)" ;;
  reporting) load pawprint/reporting:1.0.0 ;;
  all)
    for component in postgres reporting petclinic ingress; do bash scripts/load-images.sh "$component"; done
    ;;
  *) echo 'Usage: load-images.sh [all|postgres|reporting|petclinic|ingress]' >&2; exit 2 ;;
esac
