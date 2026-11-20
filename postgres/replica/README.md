# PostgreSQL Replica

The standby uses PostgreSQL 18.6 with a 5 GiB local PVC and prefers a distinct worker. Its base-backup init container creates `standby.signal` and `primary_conninfo` using `pg_basebackup -R`. The password is available through a mode-0600 passfile in a shared memory volume. The password does not need to be embedded in the connection string or data volume.

```bash
make deploy STAGES=replica
bash scripts/verify-replication.sh
```

The init container stages a new backup on the Replica PVC and moves it into PGDATA only after completion. An existing valid standby is reused on restarts. An interrupted attempt leaves its staging path for operator review. Keep both database claims during recovery. See [replication](../../docs/replication-guide.md) and [manual recovery](../../docs/recovery-guide.md).
