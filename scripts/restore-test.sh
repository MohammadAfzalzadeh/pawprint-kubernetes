#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "$0")/common.sh"
source scripts/database-operations.sh
check_cluster
ns get networkpolicy pawprint-disposable-database-isolation -o name >/dev/null
job=$(manifest postgres/backup/restore-test-job.yaml | ns set env --local -f - "BACKUP_ID=${1:-}" -o yaml | ns create -f - -o name)
wait_for_database_job "$job" 315
