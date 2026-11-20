#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "$0")/common.sh"
source scripts/database-operations.sh
check_cluster
recovery_idle
if [[ "$(ns get cronjob petclinic-backup -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].command[1]}')" != /operations/backup.sh ]]; then
  echo 'The backup CronJob has an outdated template. Deploy the backup stage first.' >&2
  exit 1
fi
job_name="petclinic-backup-manual-$(date -u +%Y%m%d%H%M%S)-$(printf '%04x' "$RANDOM")"
job=$(ns create job "$job_name" --from=cronjob/petclinic-backup -o name)
wait_for_database_job "$job" 315
