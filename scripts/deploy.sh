#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "$0")/common.sh"
source scripts/database-operations.sh
check_cluster
recovery_idle
k get storageclass standard
k apply -f k8s/namespace.yaml

apply() {
  k apply --dry-run=server --validate=strict "$@" >/dev/null
  k apply "$@"
}
rollout() { ns rollout status "$1" --timeout=300s; }
confirmed_image() {
  local node
  for node in $("$KIND_BIN" get nodes --name pawprint); do
    docker exec "$node" crictl inspecti "$1" >/dev/null
  done
}
secrets() {
  ns get secret postgres-primary-auth -o go-template='{{range $key, $ignored := .data}}{{println $key}}{{end}}' |
    python3 -c 'import sys; required={"app_user","postgres_password","app_password","replication_password","reporting_password"}; missing=required-set(sys.stdin.read().split()); sys.exit("Missing Secret keys: "+", ".join(sorted(missing)) if missing else 0)'
}
original_database() {
  local name=$1 active
  active=$(ns get svc "postgres-$name" --ignore-not-found \
    -o jsonpath='{.spec.selector.app\.kubernetes\.io/instance}')
  if [[ -n "$active" && "$active" != "postgres-$name" ]]; then
    echo "Active $name is $active after live recovery. See docs/live-recovery.md for database maintenance." >&2
    return 1
  fi
}
stage() {
  echo "Deploying $1"
  case "$1" in
    primary)
      original_database primary
      secrets
      confirmed_image postgres:18.6-trixie
      apply -f postgres/primary/configmap.yaml -f postgres/primary/service.yaml -f postgres/primary/statefulset.yaml
      rollout statefulset/postgres-primary
      ;;
    bootstrap)
      rollout "statefulset/$(db_set primary)"
      marker=$(bootstrap_marker)
      if [[ "$marker" == t ]]; then
        echo 'Bootstrap marker already present. Verifying the live catalog.'
      elif [[ "$marker" == f ]]; then
        create_bootstrap_configmap petclinic-schema
        apply -f postgres/bootstrap/job.yaml
        wait_for_database_job job/petclinic-schema-bootstrap-v3 190
      else
        echo "Unexpected bootstrap marker result: $marker" >&2
        return 1
      fi
      verify_bootstrap_objects
      bash scripts/verify-database.sh
      ;;
    replica)
      original_database replica
      verify_bootstrap_objects
      apply -f postgres/replica/configmap.yaml -f postgres/replica/service.yaml -f postgres/replica/statefulset.yaml
      rollout statefulset/postgres-replica
      bash scripts/verify-replication.sh
      ;;
    reporting)
      rollout "statefulset/$(db_set replica)"
      confirmed_image pawprint/reporting:1.0.0
      apply -f k8s/reporting
      rollout deployment/reporting
      ;;
    petclinic)
      verify_bootstrap_objects
      confirmed_image "pawprint/petclinic:$(git -C spring-petclinic rev-parse --short=12 HEAD)"
      apply -f k8s/petclinic -f k8s/policies/petclinic-pdb.yaml
      rollout deployment/petclinic
      ;;
    ingress)
      confirmed_image nginx/nginx-ingress:5.8.0
      helm --kubeconfig "$KUBECONFIG" --kube-context kind-pawprint upgrade --install \
        pawprint-nginx ./nginx-ingress-2.9.0.tgz --namespace pawprint \
        --skip-crds --wait --timeout 150s -f k8s/ingress/values.yaml
      apply -f k8s/ingress/ingress.yaml
      curl -fsS --retry 8 --retry-all-errors --retry-delay 2 --max-time 5 http://localhost:8080/ >/dev/null
      ;;
    network) apply -f k8s/network/database.yaml ;;
    backup)
      create_ops_configmap
      apply -f postgres/backup/backup-cronjob.yaml -f postgres/backup/isolation.yaml
      ;;
    *) echo "Unknown deployment stage: $1" >&2; return 2 ;;
  esac
}
if [[ $# == 0 ]]; then
  echo 'Choose one or more stages: primary bootstrap replica reporting petclinic ingress network backup' >&2
  exit 2
fi
for component in "$@"; do stage "$component"; done
