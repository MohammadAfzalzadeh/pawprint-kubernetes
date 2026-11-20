# PostgreSQL backup and isolated restore

```bash
make deploy STAGES=backup
make backup
make restore BACKUP_ID='<value printed by make backup>'
```

`make restore` without an ID selects the most recent published bundle by its UTC timestamp and name. Use the printed ID to prove a specific archive or to avoid selecting a backup created concurrently. A missing or damaged bundle fails the Job and the Make target. The isolated database is discarded with the test Pod.

To recover the database serving PetClinic, use the separate [live recovery and rollback runbook](live-recovery.md). Its preflight verifies the chosen bundle, and its explicitly confirmed cutover switches the application to a recovered database on a new PVC. Both commands use logical snapshot backups. Point-in-time recovery requires continuous WAL archiving and a physical base backup.

## Backup bundles

The deployed CronJob runs every six hours in UTC, at 03:30, 09:30, 15:30 and 21:30 in Tehran. Manual Jobs use that same CronJob template. The PostgreSQL 18.6 client exports a read-only repeatable-read snapshot. `pg_dump` and the verification SQL import that snapshot while its transaction is held open. This keeps the data and schema comparison consistent when application writes occur during a backup. Sequence state comes from the archive because PostgreSQL sequence values are outside MVCC. [PostgreSQL 18 pg_dump](https://www.postgresql.org/docs/18/app-pgdump.html)

The Job mounts `petclinic-backups` at `/backup` and publishes a uniquely named `<BACKUP_ID>.backup` directory by rename on the same volume. A published bundle contains the compressed custom-format archive, its TOC, the source snapshot fingerprints and catalog definitions, the archive's sequence state, and SHA-256 checksums. Before publication the Job verifies nonzero size, lists and decodes the archive, and confirms the expected table-data and sequence entries. A failed run leaves its hidden staging directory outside restore selection.

Backups are retained until an operator archives or expires them. Automatic deletion of existing dumps was removed from both scheduled and manual execution. CronJob history limits apply to Job objects. The 3 GiB local-path claim shares the node filesystem and provides a local recovery point. Monitor free space, keep off-host copies of complete bundles, and manage retention after verifying the copies. This logical dump covers the PetClinic public schema. Restore drills omit live ownership and ACLs. Cluster roles, grants, private bootstrap/reporting metadata, physical WAL history and point-in-time recovery are separate recovery concerns.

## Restore checks

The restore Job uses a read-only PVC mount, private peer-authenticated Unix socket, temporary data volume, and ingress and egress isolation. PostgreSQL starts with TCP disabled and no production Secret. The fresh database uses the live PawPrint database's UTF-8 and `en_US.utf8` settings. The filter excludes exactly the archive's `SCHEMA - public` creation entry because the template already supplies that schema. All other TOC entries are restored in one transaction with errors treated as fatal. [PostgreSQL 18 pg_restore](https://www.postgresql.org/docs/18/app-pgrestore.html)

Pass requires matching row counts and SHA-256 row fingerprints for every public table, matching columns, constraints, indexes and sequence definitions, and exact agreement with the archive's six sequence states before checking their next usable values. The verifier uses bounded data appropriate to the PawPrint lab and aggregates hashes inside PostgreSQL. See [live evidence and historical failures](backup-bootstrap-evidence.md).
