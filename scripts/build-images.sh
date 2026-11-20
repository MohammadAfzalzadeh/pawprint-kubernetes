#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "$0")/common.sh"
app_tag=$(git -C spring-petclinic rev-parse --short=12 HEAD)
case "${1:-all}" in
  reporting)
    docker build -f docker/reporting/Dockerfile -t pawprint/reporting:1.0.0 .
    ;;
  petclinic)
    docker build -f docker/petclinic/Dockerfile -t "pawprint/petclinic:$app_tag" .
    ;;
  all)
    bash scripts/build-images.sh reporting
    bash scripts/build-images.sh petclinic
    ;;
  *) echo 'Usage: build-images.sh [all|petclinic|reporting]' >&2; exit 2 ;;
esac
