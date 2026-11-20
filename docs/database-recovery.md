# Database recovery and manual promotion

There is no automatic PostgreSQL failover. Streaming replication is asynchronous by default and can lag. Primary loss interrupts writes until an operator-led recovery; never promote while the old primary might still accept writes.

## Runbook outline

1. Confirm primary failure with pod/node/storage events and application connection errors. Rule out network-only interruption before promotion.
2. Fence the old primary: ensure its pod cannot restart or accept writes, and establish its authoritative storage/compute is isolated. If fencing cannot be proven, stop and escalate; do not promote.
3. Inspect standby `pg_is_in_recovery()`, `pg_stat_wal_receiver`, last receive/replay LSN and replay timestamp. Record possible asynchronous data loss.
4. With explicit operator approval, run `SELECT pg_promote(wait => true, wait_seconds => 60);` on the replica and verify `pg_is_in_recovery()` is false.
5. Switch the primary write Service selector to the promoted pod only after confirming role and fencing. Keep the former primary isolated.
6. Rebuild/reseed the former primary from the new primary using a reviewed base-backup workflow and its own clean/preserved PVC decision. Do not simply restart old primary data as writable.
7. Verify exactly one writable primary, new sender/receiver state, app connectivity, read-only reporting endpoint, backups, and data consistency. Document timelines and any lost writes.

This is a procedure outline, not an executed failover test. Endpoint switching and old-primary rejoin require a separately reviewed runbook and manifest mechanics.
