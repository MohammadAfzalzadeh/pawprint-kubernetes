#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "$0")/common.sh"
check_cluster
bash scripts/verify-replication.sh
ns get pod,pvc,svc -o wide
ns exec "$(db_set primary)-0" -- gosu postgres psql -XAt -d postgres \
  -c "SELECT pg_current_wal_lsn(), replay_lsn, pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) FROM pg_stat_replication WHERE state='streaming'"
echo 'Read-only recovery precheck finished. Follow docs/recovery-guide.md after operator approval and fencing.'
