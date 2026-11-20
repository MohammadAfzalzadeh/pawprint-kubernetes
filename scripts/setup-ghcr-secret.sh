#!/usr/bin/env bash
set +x
set -euo pipefail
source "$(dirname -- "$0")/common.sh"
check_cluster
k get namespace "$PAWPRINT_NAMESPACE" -o name >/dev/null

IFS= read -rp 'GitHub username: ' username </dev/tty
IFS= read -rsp 'GitHub classic PAT (read:packages): ' token </dev/tty
printf '\n' >/dev/tty
[[ -n "$username" && -n "$token" ]] || { echo 'Both GitHub credentials are required.' >&2; exit 1; }

umask 077
config=$(mktemp /dev/shm/pawprint-ghcr.XXXXXXXX)
trap 'rm -f -- "$config"' EXIT
printf '%s\n' "$username" "$token" | python3 -c '
import base64
import json
import sys

username, token = sys.stdin.read().splitlines()
auth = base64.b64encode(f"{username}:{token}".encode()).decode()
print(json.dumps({"auths": {"ghcr.io": {"auth": auth}}}))
' > "$config"
unset token
ns create secret generic pawprint-ghcr --type=kubernetes.io/dockerconfigjson \
  --from-file=".dockerconfigjson=$config" --dry-run=client -o json |
  ns apply --server-side --field-manager=pawprint-ghcr-secret -f -
