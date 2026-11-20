# PostgreSQL physical replication

Both nodes use PostgreSQL 18.6. The standby uses `pg_basebackup --write-recovery-conf --wal-method=stream` and a shared in-memory passfile. The init container stages each base backup in a unique directory on the Replica PVC and moves it into PGDATA only after backup succeeds. A complete standby with `standby.signal` is reused. Partial staging directories remain available for inspection. An unexpected final PGDATA blocks startup.

```bash
bash scripts/verify-replication.sh
bash scripts/test-replication-data.sh
bash scripts/test-persistence.sh replica
```

The first script checks sender and receiver states, the replication role, async mode and recovery status. The HTTP data test creates a unique owner through PetClinic and measures time to observing it in the Replica and the next Reporting API snapshot. These are upper bounds influenced by polling and HTTP time. The persistence script checks PVC UID, PV identity and a database record across Pod replacement.

The Primary retains 256 MiB of WAL as a buffer. No persistent physical slot is configured. A long disconnect can exhaust retained WAL and require a fresh reviewed seed. Asynchronous replication may lose acknowledged writes after an unrecoverable Primary outage.
