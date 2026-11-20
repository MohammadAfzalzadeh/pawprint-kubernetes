#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "$0")/common.sh"
source scripts/database-operations.sh
check_cluster
ns get networkpolicy pawprint-disposable-database-isolation -o name >/dev/null
create_bootstrap_configmap pawprint-bootstrap-test
job=$(manifest postgres/bootstrap/test-job.yaml | ns create -f - -o name)
wait_for_database_job "$job" 165
