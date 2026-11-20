#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "$0")/common.sh"
check_cluster
ns exec -i deploy/reporting -- python - <<'PY'
import socket
with socket.create_connection(("postgres-replica", 5432), timeout=3):
    print("Replica TCP 5432 reachable from Reporting")
try:
    with socket.create_connection(("postgres-primary", 5432), timeout=3):
        pass
except socket.timeout:
    print("Primary TCP 5432 blocked from Reporting")
else:
    raise SystemExit("Reporting unexpectedly reached Primary TCP 5432")
PY
