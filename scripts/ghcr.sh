#!/usr/bin/env bash
# Shared by deployment and worker image pull checks after common.sh is sourced.
check_ghcr_release() {
  local pull_secret=${GHCR_PULL_SECRET:-}
  [[ -n "${GHCR_RELEASE:-}" ]] || {
    echo 'Set GHCR_RELEASE to the release.json from GitHub Actions.' >&2
    return 1
  }
  python3 scripts/ghcr_release.py check "$GHCR_RELEASE" "$pull_secret" || return
  check_ghcr_pull_secret
}

check_ghcr_pull_secret() {
  local pull_secret=${GHCR_PULL_SECRET:-}
  if [[ -n "$pull_secret" ]]; then
    [[ "$(ns get "secret/$pull_secret" -o jsonpath='{.type}')" == kubernetes.io/dockerconfigjson ]] || {
      echo "Expected a dockerconfigjson Secret named $pull_secret in $PAWPRINT_NAMESPACE." >&2
      return 1
    }
  fi
}
