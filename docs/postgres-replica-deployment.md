# PostgreSQL Replica deployment

```bash
make deploy STAGES=replica
bash scripts/verify-replication.sh
```

`postgres-replica-0` became Ready on `pawprint-worker2` with a separate `standard` claim. The first live query showed sender `replicator` in `streaming` state and `sync_state=async`, with sent and replayed positions both `0/3000060`. The matching WAL receiver and recovery query succeeded. See the [replication guide](replication-guide.md).
