#!/usr/bin/env bash
export KUBECONFIG="$HOME/.kube/pawprint-config"
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || return 1
KIND_BIN=${KIND_BIN:-kind}
k() { "${KUBECTL_BIN:-kubectl}" --kubeconfig "$KUBECONFIG" --context kind-pawprint "$@"; }
PAWPRINT_NAMESPACE=${PAWPRINT_NAMESPACE:-pawprint}
ns() { k -n "$PAWPRINT_NAMESPACE" "$@"; }
# The namespace override is reserved for purpose-built recovery test namespaces.
manifest() {
  sed -e "s/namespace: pawprint$/namespace: $PAWPRINT_NAMESPACE/" \
    -e "s/\.pawprint\.svc\.cluster\.local/.$PAWPRINT_NAMESPACE.svc.cluster.local/g" "$1"
}
db_set() {
  local role=$1 instance
  instance=$(ns get svc "postgres-$role" -o jsonpath='{.spec.selector.app\.kubernetes\.io/instance}') || return
  [[ "$instance" == "postgres-$role" || "$instance" =~ ^postgres-$role-r[0-9a-f]{12}$ ]] || {
    echo "Unexpected selector for postgres-$role: $instance" >&2
    return 1
  }
  printf '%s\n' "$instance"
}
pawprint_http_url() {
  local url=${PAWPRINT_URL:-http://localhost:8080}
  if [[ "$PAWPRINT_NAMESPACE" != pawprint ]]; then
    [[ "$url" =~ ^http://(localhost|127\.0\.0\.1):[1-9][0-9]{0,4}$ && "${url##*:}" != 8080 ]] || {
      echo 'Disposable recovery tests require a separate loopback HTTP port' >&2
      return 1
    }
  fi
  printf '%s\n' "$url"
}
recovery_idle() {
  local state
  state=$(ns get configmap pawprint-live-recovery --ignore-not-found \
    -o jsonpath='{.metadata.annotations.pawprint\.io/phase}') || return
  case "$state" in
    ''|VERIFIED|ROLLED_BACK) return 0 ;;
    *) echo "Database recovery is in $state. Review docs/live-recovery.md." >&2; return 1 ;;
  esac
}
check_cluster() {
  [[ -s "$KUBECONFIG" && "$("${KUBECTL_BIN:-kubectl}" --kubeconfig "$KUBECONFIG" config current-context)" == kind-pawprint ]] || {
    echo 'Expected kind-pawprint in the dedicated kubeconfig' >&2
    return 1
  }
  k --request-timeout=10s get --raw=/readyz >/dev/null || return
  if [[ "$PAWPRINT_NAMESPACE" != pawprint ]]; then
    [[ "$PAWPRINT_NAMESPACE" =~ ^pawprint-recovery-test-[a-z0-9-]{1,20}$ &&
       "$(k get ns "$PAWPRINT_NAMESPACE" -o jsonpath='{.metadata.labels.pawprint\.io/disposable-restore-test}')" == true ]] || {
      echo 'Namespace override requires a labeled disposable recovery test namespace' >&2
      return 1
    }
  fi
}
