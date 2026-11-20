#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "$0")/common.sh"
check_cluster
primary_pod="$(db_set primary)-0"
replica_pod="$(db_set replica)-0"
primary() { ns exec "$primary_pod" -- gosu postgres psql -XAt -v ON_ERROR_STOP=1 -d petclinic "$@"; }
replica() { ns exec "$replica_pod" -- gosu postgres psql -XAt -v ON_ERROR_STOP=1 -d petclinic "$@"; }
primary -c "SELECT application_name,usename,state,sync_state,sent_lsn,replay_lsn,pg_wal_lsn_diff(pg_current_wal_lsn(),replay_lsn) FROM pg_stat_replication"
replica -c "SELECT status,sender_host,flushed_lsn,pg_last_wal_replay_lsn() FROM pg_stat_wal_receiver"
[[ "$(primary -c "SELECT EXISTS(SELECT FROM pg_stat_replication WHERE usename='replicator' AND state='streaming' AND sync_state='async')")" == t ]]
[[ "$(replica -c "SELECT pg_is_in_recovery() AND current_setting('transaction_read_only')='on' AND EXISTS(SELECT FROM pg_stat_wal_receiver WHERE status='streaming')")" == t ]]
