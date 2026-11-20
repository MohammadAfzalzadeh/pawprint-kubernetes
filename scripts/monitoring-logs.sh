#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "$0")/common.sh"
check_cluster
since=${SINCE:-15m}
tail_lines=${TAIL_LINES:-200}

show() {
  local title=$1 selector=$2
  printf '\n===== %s (since %s) =====\n' "$title" "$since"
  ns logs -l "$selector" --all-containers --prefix --timestamps --since="$since" --tail="$tail_lines" || true
}

show PetClinic 'app.kubernetes.io/name=petclinic'
show Reporting 'app.kubernetes.io/name=reporting'
show PostgreSQL 'app.kubernetes.io/name=postgresql'
show 'NGINX Ingress' 'app.kubernetes.io/name=nginx-ingress'
show Monitoring 'app.kubernetes.io/name in (pawprint-prometheus,pawprint-grafana,pawprint-alertmanager,pawprint-observer)'

printf '\nThis is a lightweight, on-demand alternative while Loki is intentionally not deployed.\n'
