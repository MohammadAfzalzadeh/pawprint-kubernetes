.PHONY: preflight build load secrets ghcr-secret verify-ghcr-pulls deploy verify backup restore restore-live restore-live-preflight rollback-live report test test-bootstrap test-failures
preflight:
	bash scripts/preflight.sh
build:
	bash scripts/build-images.sh
load:
	bash scripts/load-images.sh
secrets:
	bash scripts/setup-secrets.sh
ghcr-secret:
	bash scripts/setup-ghcr-secret.sh
verify-ghcr-pulls:
	bash scripts/verify-ghcr-pulls.sh
deploy:
	bash scripts/deploy.sh $(STAGES)
verify:
	bash scripts/verify-cluster.sh
	bash scripts/verify-database.sh
	bash scripts/verify-replication.sh
	bash scripts/verify-reporting.sh
	bash scripts/verify-network.sh
	bash scripts/verify-reporting-data.sh
backup:
	bash scripts/backup.sh
restore:
	bash scripts/restore-test.sh "$(BACKUP_ID)"
restore-live restore-live-preflight: export RECOVERY_BACKUP_ID := $(value BACKUP_ID)
restore-live:
	python3 scripts/live-recovery.py run "$${RECOVERY_BACKUP_ID:-}"
restore-live-preflight:
	python3 scripts/live-recovery.py preflight "$${RECOVERY_BACKUP_ID:-}"
rollback-live: export RECOVERY_OPERATION_ID := $(value OPERATION_ID)
rollback-live:
	python3 scripts/live-recovery.py rollback "$${RECOVERY_OPERATION_ID:-}"
report:
	bash scripts/verify-reporting.sh
test: verify test-bootstrap

test-bootstrap:
	bash scripts/test-bootstrap.sh

test-failures:
	bash scripts/test-replication-data.sh
	bash scripts/test-pod-failure.sh
	bash scripts/test-replica-failure.sh
