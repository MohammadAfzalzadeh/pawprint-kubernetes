# Backup, restore and bootstrap acceptance

Validated on the existing PawPrint cluster on 2026-11-20 Tehran time. The historical Jobs and Pods were retained. Their timestamped logs and the current drill logs are in the local, Git-ignored `.pawprint/evidence/backup-repair/` directory.

## Root causes and corrections

| Observed failure | Root cause and correction |
| --- | --- |
| `petclinic-restore-test-c5c8r`, exit 1 | PostgreSQL listened on `/restore/.s.PGSQL.5432` while the client used `/restore/data/.s.PGSQL.5432`. The isolated server and all clients now share the private `/restore/socket` setting. |
| `petclinic-restore-test-4pzwq`, exit 1 | The 15,694-byte gzip custom archive contained `5; 2615 2200 SCHEMA - public pg_database_owner`. PostgreSQL's template already supplied `public`. The restore filters just that creation entry from its TOC and restores every other entry in one transaction. |
| `petclinic-schema-bootstrap-ncpqw`, exit 3 | The live Job spec contained `DO $$ BEGIN` inside an already quoted Bash heredoc. Kubernetes reduced `$$` to `$` during container argument expansion before Bash interpreted the command. The historical v2 Job used `$pawprint$`, exited zero and left one `petclinic-v1` marker. Current bootstrap SQL lives in a mounted file and runs using `psql -f`. [Kubernetes Pod API argument expansion](https://kubernetes.io/docs/reference/kubernetes-api/core/pod-v1/) |
| Historical successful Jobs provided limited proof | The manual backup listed the archive TOC. Restore checked only table presence and that owners existed. The new evidence compares the identical exported snapshot and verified archive with the restored data and catalog. Manual jobs share the CronJob template, and failed Jobs now fail the CLI with their logs and diagnostics. |

## Execution and evidence

These commands ran successfully against the dedicated context.

```bash
make deploy STAGES="backup bootstrap"
make backup
make restore BACKUP_ID=petclinic-20261119T205308Z-petclinic-backup-manual-20261119205307-01f8-hvlkv
make restore
make test-bootstrap
make verify
make test
make report
```

The live bootstrap stage printed `Bootstrap marker already present. Verifying the live catalog.` and never launched a live bootstrap Job. The negative command `make restore BACKUP_ID=petclinic-20000101T000000Z-missing-proof` intentionally failed. Job `petclinic-restore-test-79666` exited 1 and logged `Backup archive missing or empty`. The valid archive then restored successfully. The default-selection restore Job `petclinic-restore-test-brbl2` selected the same bundle and passed. The standalone bootstrap target also passed in Job `petclinic-bootstrap-test-t2txr`.

The verified backup Job was `petclinic-backup-manual-20261119205307-01f8`. Its container exited 0. The archive has 15,813 bytes on `petclinic-backups`, Bound to PV `pvc-97af1599-4adc-4525-8833-7ce4f5af0360` on `pawprint-worker`.

```text
/backup/petclinic-20261119T205308Z-petclinic-backup-manual-20261119205307-01f8-hvlkv.backup/petclinic.dump
SHA-256 626f8a25ab1e17fd041e5b70036854dfeeafe5ad24c60c5379ac74a98ff1c6ba
```

Final restore Job `petclinic-restore-test-xwh58` checked four bundle files and completed with matching PostgreSQL encoding and locale. The row fingerprints below matched on the source snapshot and the restored database. Prefixes are shown here. The logs contain full hashes.

| Table | Source rows | Restored rows | Matching SHA-256 prefix |
| --- | ---: | ---: | --- |
| owners | 17 | 17 | `7aa9b2e5b102` |
| pets | 13 | 13 | `6c7bc288b00a` |
| specialties | 3 | 3 | `5518e51fcdca` |
| types | 6 | 6 | `10243e08e21d` |
| vet_specialties | 5 | 5 | `0de5d02d8bda` |
| vets | 6 | 6 | `37f98b71a4c9` |
| visits | 4 | 4 | `864051d4a4b6` |

The schema comparison matched columns, 21 constraints including 5 validated foreign keys, 15 indexes, and 6 sequence definitions. All six sequence states matched the archive, and all six next values exceeded their tables' maximum restored IDs. The owners sequence returned 18 after restoring IDs through 17.

## Acceptance criteria

| Criterion | Status | Evidence |
| --- | --- | --- |
| Backup Job | PASS | `petclinic-backup-manual-20261119205307-01f8` completed with exit 0. |
| Backup archive | PASS | Nonempty custom archive, complete decode, seven table-data entries, validated bundle checksums. |
| Backup storage | PASS | Verified archive restored through the same Bound 3 GiB backup claim. |
| Restore Job | PASS | `petclinic-restore-test-xwh58` completed. |
| Restore database | PASS | Disposable socket-only PostgreSQL 18.6 database restored in one transaction. |
| Public schema conflict | PASS | Excluded one public-schema creation entry and restored the rest without an error. |
| DO block syntax | PASS | Mounted bootstrap and verification SQL executed in live disposable Jobs. |
| Data integrity | PASS | Seven table row fingerprints and counts matched. |
| Constraints | PASS | 21 constraints matched, including five validated FKs. |
| Indexes | PASS | 15 definitions and validity flags matched. |
| Sequences | PASS | Six definitions and archived positions matched, and next values worked. |
| Bootstrap | PASS | `petclinic-bootstrap-test-599fv` created and verified the seven seeded tables, bootstrap marker, reporting function and grants. |
| Bootstrap repeatability | PASS | Repeat preserved the sentinel, table and catalog fingerprints, and sequence states. The unmarked-populated case failed with exit 3 and rolled back. |
| PetClinic | PASS | Ingress returned HTTP 200. |
| PetClinic replicas | PASS | Deployment 2/2 Ready. |
| PostgreSQL Primary | PASS | StatefulSet 1/1 Ready, outside recovery, transaction read-only off. |
| PostgreSQL Replica | PASS | StatefulSet 1/1 Ready and in read-only recovery. |
| Streaming replication | PASS | Asynchronous sender and receiver streaming. Final sampled replay gap zero bytes. |
| Reporting | PASS | HTTP 200 and fresh aggregate and pet-type data matched direct Replica queries. |
| Reporting isolation | PASS | Reporting session on Replica only, Primary TCP blocked, zero-row UPDATE rejected with SQLSTATE 25006. |
| Regression tests | PASS | `make verify`, `make test`, and `make report` exited zero. The missing-archive test returned nonzero as expected. |

Live public table fingerprints, schema metadata, PostgreSQL Pod UIDs, and all three PVC UIDs and PV bindings matched before and after the work. Neither running database was restarted. The backup CronJob was updated and its template executed manually. A future time-triggered invocation was outside this run. Retention is operator-managed. The public-schema bundle does not supply role recreation, private metadata, or point-in-time recovery.

## Files changed

- Backup operations under `postgres/backup/` include `backup-cronjob.yaml`, `backup-job.yaml`, `restore-test-job.yaml`, `isolation.yaml`, `backup.sh`, `restore.sh`, `isolated-postgres.sh`, `snapshot.sql`, `verify-sequences.sql`, `verify-identity.sql`, and `README.md`.
- Bootstrap files are `postgres/bootstrap/job.yaml`, `bootstrap.sql`, `test-job.yaml`, `verify-bootstrap.sh`, and `verify.sql`.
- Operator integration includes `Makefile`, `scripts/common.sh`, `scripts/database-operations.sh`, `scripts/deploy.sh`, `scripts/backup.sh`, `scripts/restore-test.sh`, `scripts/test-bootstrap.sh`, `scripts/verify-database.sh`, and `scripts/verify-reporting-data.sh`.
- Documentation includes `README.md`, `postgres/primary/README.md`, and `docs/{acceptance-report,backup-bootstrap-evidence,backup-restore,database-architecture,database-testing,deployment-guide,postgres-primary-deployment}.md`.
