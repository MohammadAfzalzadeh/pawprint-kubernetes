#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "$0")/common.sh"
check_cluster
[[ "$PAWPRINT_NAMESPACE" == pawprint ]]

credentials_file=.pawprint/monitoring-credentials.env
ingress_port=8080
hosts=(grafana.pawprint.local prometheus.pawprint.local alertmanager.pawprint.local)

create_secrets() {
  mkdir -p .pawprint
  chmod 700 .pawprint
  if [[ -f "$credentials_file" ]]; then
    # shellcheck disable=SC1090
    source "$credentials_file"
  else
    MONITORING_USERNAME=${MONITORING_USERNAME:-pawprint-admin}
    MONITORING_PASSWORD=${MONITORING_PASSWORD:-$(openssl rand -hex 18)}
    POSTGRES_MONITORING_PASSWORD=${POSTGRES_MONITORING_PASSWORD:-$(openssl rand -hex 18)}
    umask 077
    printf 'MONITORING_USERNAME=%q\nMONITORING_PASSWORD=%q\nPOSTGRES_MONITORING_PASSWORD=%q\n' \
      "$MONITORING_USERNAME" "$MONITORING_PASSWORD" "$POSTGRES_MONITORING_PASSWORD" >"$credentials_file"
  fi
  : "${MONITORING_USERNAME:?}" "${MONITORING_PASSWORD:?}" "${POSTGRES_MONITORING_PASSWORD:?}"
  local tmp
  tmp=$(mktemp -d /dev/shm/pawprint-monitoring.XXXXXXXX)
  trap 'rm -f -- "$tmp"/*; rmdir -- "$tmp"' RETURN
  printf '%s' "$MONITORING_USERNAME" >"$tmp/username"
  printf '%s' "$MONITORING_PASSWORD" >"$tmp/password"
  htpasswd -nbB "$MONITORING_USERNAME" "$MONITORING_PASSWORD" >"$tmp/htpasswd"
  printf 'postgresql://monitoring_user:%s@postgres-primary:5432/petclinic?sslmode=disable' "$POSTGRES_MONITORING_PASSWORD" >"$tmp/primary_dsn"
  printf 'postgresql://monitoring_user:%s@postgres-replica:5432/petclinic?sslmode=disable' "$POSTGRES_MONITORING_PASSWORD" >"$tmp/replica_dsn"
  ns create secret generic pawprint-grafana-admin --from-file=username="$tmp/username" --from-file=password="$tmp/password" \
    --dry-run=client -o yaml | k apply -f - >/dev/null
  ns create secret generic pawprint-monitoring-ingress-auth --from-file=htpasswd="$tmp/htpasswd" \
    --dry-run=client -o yaml | k apply -f - >/dev/null
  ns create secret generic pawprint-postgres-monitoring --from-file=primary_dsn="$tmp/primary_dsn" --from-file=replica_dsn="$tmp/replica_dsn" \
    --dry-run=client -o yaml | k apply -f - >/dev/null
  rm -f -- "$tmp"/*
  rmdir -- "$tmp"
  trap - RETURN
  echo "Monitoring credentials stored with mode 0600 in $credentials_file (git-ignored)."
}

prepare_database() {
  # shellcheck disable=SC1090
  source "$credentials_file"
  k apply -f postgres/primary/configmap.yaml -f postgres/replica/configmap.yaml >/dev/null
  if [[ "$(ns exec postgres-primary-0 -- gosu postgres psql -XAtq -U postgres -d postgres -c "SELECT count(*) FROM pg_roles WHERE rolname='monitoring_user'")" == 0 ]]; then
    printf "\\set password '%s'\nCREATE ROLE monitoring_user LOGIN CONNECTION LIMIT 4 PASSWORD :'password';\n" "$POSTGRES_MONITORING_PASSWORD" | \
      ns exec -i postgres-primary-0 -- gosu postgres psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null
  else
    printf "\\set password '%s'\nALTER ROLE monitoring_user PASSWORD :'password';\n" "$POSTGRES_MONITORING_PASSWORD" | \
      ns exec -i postgres-primary-0 -- gosu postgres psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null
  fi
  ns exec postgres-primary-0 -- gosu postgres psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres -c \
    'GRANT pg_monitor TO monitoring_user; GRANT CONNECT ON DATABASE petclinic TO monitoring_user;' >/dev/null
  if ! ns exec postgres-primary-0 -- grep -q monitoring_user /etc/postgresql/pg_hba.conf; then
    echo 'Refreshing PostgreSQL Pods so the subPath-mounted HBA receives the monitoring rule.'
    ns delete pod postgres-replica-0 --wait=false >/dev/null
    ns rollout status statefulset/postgres-replica --timeout=300s
    ns exec postgres-replica-0 -- gosu postgres psql -XAtq -U postgres -d postgres -c \
      "SELECT CASE WHEN pg_is_in_recovery() AND EXISTS (SELECT 1 FROM pg_stat_wal_receiver WHERE status='streaming') THEN 'ok' ELSE 'not-ok' END" | grep -qx ok
    ns delete pod postgres-primary-0 --wait=false >/dev/null
    ns rollout status statefulset/postgres-primary --timeout=300s
  fi
}

deploy() {
  create_secrets
  prepare_database
  k apply --dry-run=server --validate=strict -k k8s/monitoring >/dev/null
  k apply -k k8s/monitoring
  ns delete deployment pawprint-monitoring --ignore-not-found >/dev/null
  for deployment in pawprint-alertmanager pawprint-blackbox pawprint-grafana pawprint-kube-state-metrics pawprint-observer pawprint-postgres-primary-exporter pawprint-postgres-replica-exporter pawprint-prometheus; do
    ns rollout status "deployment/$deployment" --timeout=420s
  done
  ns rollout status daemonset/pawprint-node-exporter --timeout=420s
  ns rollout status daemonset/pawprint-pvc-usage --timeout=420s
  echo 'Deployment complete. Wait one scrape interval, then run make verify-monitoring.'
}

prom_query() {
  local query=$1
  curl --noproxy '*' -fsS --resolve "prometheus.pawprint.local:${ingress_port}:127.0.0.1" \
    -u "$MONITORING_USERNAME:$MONITORING_PASSWORD" --get --data-urlencode "query=$query" \
    "http://prometheus.pawprint.local:${ingress_port}/api/v1/query"
}

verify() {
  # shellcheck disable=SC1090
  source "$credentials_file"
  for claim in prometheus-data grafana-data alertmanager-data; do
    [[ "$(ns get pvc "$claim" -o jsonpath='{.status.phase}')" == Bound ]]
  done
  local endpoint
  for endpoint in pawprint-prometheus pawprint-grafana pawprint-alertmanager pawprint-blackbox pawprint-kube-state-metrics pawprint-node-exporter pawprint-observer pawprint-postgres-primary-exporter pawprint-postgres-replica-exporter pawprint-nginx-metrics; do
    [[ -n "$(ns get endpoints "$endpoint" -o jsonpath='{.subsets[*].addresses[*].ip}')" ]] || { echo "No endpoint: $endpoint" >&2; return 1; }
  done
  [[ "$(curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' --resolve "grafana.pawprint.local:${ingress_port}:127.0.0.1" "http://grafana.pawprint.local:${ingress_port}/login")" == 200 ]]
  [[ "$(curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' --resolve "prometheus.pawprint.local:${ingress_port}:127.0.0.1" "http://prometheus.pawprint.local:${ingress_port}/")" == 401 ]]
  [[ "$(curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' --resolve "alertmanager.pawprint.local:${ingress_port}:127.0.0.1" "http://alertmanager.pawprint.local:${ingress_port}/")" == 401 ]]
  [[ "$(curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' --resolve "prometheus.pawprint.local:${ingress_port}:127.0.0.1" -u "$MONITORING_USERNAME:$MONITORING_PASSWORD" "http://prometheus.pawprint.local:${ingress_port}/-/ready")" == 200 ]]
  [[ "$(curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' --resolve "alertmanager.pawprint.local:${ingress_port}:127.0.0.1" -u "$MONITORING_USERNAME:$MONITORING_PASSWORD" "http://alertmanager.pawprint.local:${ingress_port}/-/ready")" == 200 ]]
  curl --noproxy '*' -fsS --resolve "grafana.pawprint.local:${ingress_port}:127.0.0.1" -u "$MONITORING_USERNAME:$MONITORING_PASSWORD" \
    "http://grafana.pawprint.local:${ingress_port}/api/search?type=dash-db" | python3 -c '
import json,sys
expected={"pawprint-health","pawprint-overview","pawprint-kubernetes","pawprint-postgresql","pawprint-application","pawprint-ingress","pawprint-storage","pawprint-backup","pawprint-sre-slo","pawprint-postgresql-performance","pawprint-resource-efficiency","pawprint-alerts-incidents"}
actual={item["uid"] for item in json.load(sys.stdin)}
assert expected <= actual, f"Missing dashboards: {sorted(expected-actual)}"
print("Grafana dashboards provisioned:", len(expected))'
  prom_query 'max by(job,instance)(up)' | python3 -c '
import json,sys
rows=json.load(sys.stdin)["data"]["result"]
down=[r["metric"].get("job") for r in rows if float(r["value"][1]) != 1]
assert not down, f"DOWN targets: {down}"
print(f"Prometheus targets UP: {len(rows)}")'
  for query in \
    'count(kube_node_info) == 3' \
    'count(count by(instance)(node_uname_info)) == 3' \
    'count(container_cpu_usage_seconds_total{namespace="pawprint"}) > 0' \
    'pg_up{job="postgres-primary"} == 1' \
    'pg_up{job="postgres-replica"} == 1' \
    'pawprint_replication_streaming{job="postgres-replica"} == 1' \
    'probe_success{job="pawprint-http"} == 1' \
    'pawprint_backup_archive_integrity == 1'; do
    prom_query "$query" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["data"]["result"], sys.argv[1]' "$query"
  done
  prom_query 'count(pawprint_pvc_directory_used_bytes) == 6' | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["data"]["result"], "Expected actual usage for all six PVCs"'
  prom_query 'pawprint_restore_verification_timestamp_seconds > 0' | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["data"]["result"], "Missing restore verification timestamp"'
  [[ "$(curl --noproxy '*' -fsS -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/)" == 200 ]]
  local report
  report=$(curl --noproxy '*' -fsS http://127.0.0.1:8080/api/reports/status)
  python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["stale"] is False and d["degraded"] is False and d["replicaStatus"]=="streaming"' "$report"
  ns exec postgres-primary-0 -- gosu postgres psql -XAtq -U postgres -d postgres -c 'SELECT NOT pg_is_in_recovery()' | grep -qx t
  ns exec postgres-replica-0 -- gosu postgres psql -XAtq -U postgres -d postgres -c 'SELECT pg_is_in_recovery()' | grep -qx t
  echo 'Monitoring, ingress authentication, metrics and PawPrint regression checks passed.'
}

status() {
  ns get pods -l 'app.kubernetes.io/name in (pawprint-prometheus,pawprint-alertmanager,pawprint-grafana,pawprint-blackbox,pawprint-kube-state-metrics,pawprint-node-exporter,pawprint-postgres-exporter,pawprint-observer)' -o wide
  ns get pvc prometheus-data grafana-data alertmanager-data
  ns get ingress pawprint-grafana pawprint-monitoring
  ns get daemonset pawprint-node-exporter pawprint-pvc-usage
}

ui() {
  printf '%s\n' \
    "Grafana:      http://grafana.pawprint.local:${ingress_port}/" \
    "Prometheus:   http://prometheus.pawprint.local:${ingress_port}/" \
    "Alertmanager: http://alertmanager.pawprint.local:${ingress_port}/" \
    '' 'Add this once to /etc/hosts if your resolver does not resolve the names:' \
    '127.0.0.1 grafana.pawprint.local prometheus.pawprint.local alertmanager.pawprint.local' \
    '' "Credentials: $credentials_file (mode 0600). No port-forward is started."
}

case "${1:-}" in
  deploy) deploy ;;
  verify) verify ;;
  status) status ;;
  ui) ui ;;
  secrets) create_secrets ;;
  *) echo 'Usage: monitoring.sh {deploy|verify|status|ui|secrets}' >&2; exit 2 ;;
esac
