#!/usr/bin/env bash
set +x
set -euo pipefail
source "$(dirname -- "$0")/common.sh"
check_cluster
k apply -f k8s/namespace.yaml
if [[ -n "$(ns get secret postgres-primary-auth --ignore-not-found -o name)" ]]; then
  echo 'Existing postgres-primary-auth preserved. Credential rotation requires SQL changes.'
  exit 0
fi
umask 077
tmp=$(mktemp -d /dev/shm/pawprint-secret.XXXXXXXX)
keys=(postgres_password app_password replication_password reporting_password)
trap 'for key in "${keys[@]}"; do rm -f -- "$tmp/$key"; done; rmdir -- "$tmp"' EXIT
args=()
for key in "${keys[@]}"; do
  IFS= read -rsp "$key: " value </dev/tty
  printf '\n' >/dev/tty
  [[ -n "$value" ]] || { echo 'Password must be nonempty.' >&2; exit 1; }
  printf '%s' "$value" >"$tmp/$key"
  unset value
  args+=(--from-file="$key=$tmp/$key")
done
args+=(--from-literal=app_user=petclinic_app --from-literal=reporting_user=reporting_user)
ns create secret generic postgres-primary-auth "${args[@]}"
