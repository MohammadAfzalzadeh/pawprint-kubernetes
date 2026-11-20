# Database testing

```bash
make verify
make report
make test
make backup
make restore BACKUP_ID='<value printed by make backup>'
```

`make verify` checks the live service, schema, grants, writable Primary, Replica recovery and WAL stream. It compares HTTP reporting with queries authenticated as `reporting_user` on Replica, checks that a zero-row UPDATE is rejected, and verifies network isolation from Primary.

`make test` adds the disposable bootstrap suite to live verification. Use `make test-bootstrap` to run only that suite. The Job mounts the same bootstrap SQL and primary role initialization code, then runs a fresh instance and repeats bootstrap after inserting a sentinel. It compares row hashes, schema metadata and sequence states before and after the repeat. A second disposable database tests the unmarked-populated guard and confirms rollback. `make test-failures` runs the earlier live write, Pod deletion and standby outage exercises separately. See [failure testing](failure-testing.md) before running those disruptive exercises.

`make deploy STAGES=bootstrap` checks the live `petclinic-v1` marker and verifies existing catalog objects if present. On a new database it creates the versioned bootstrap Job. The SQL uses an advisory transaction lock, one transaction and a marker. An unmarked database with public objects requires operator review. PetClinic startup keeps automatic SQL initialization disabled.

See the [backup and bootstrap evidence](backup-bootstrap-evidence.md) and [acceptance report](acceptance-report.md).
