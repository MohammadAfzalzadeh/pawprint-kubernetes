# PostgreSQL backup Jobs

Run `make deploy STAGES=backup` to install the operations ConfigMap, update the CronJob, and apply the isolation policy. `make backup` creates a manual Job from the deployed CronJob. Use `make restore BACKUP_ID='<printed ID>'` to verify that exact bundle using a disposable PostgreSQL server.

The scripts in this directory run inside PostgreSQL 18.6 Jobs. See [the operator guide](../../docs/backup-restore.md) for archive format, validation, retention and storage boundaries.
