# PostgreSQL recovery

For recovery from a verified logical backup, use the [live database restore runbook](live-recovery.md). For standby promotion, resolve the active PostgreSQL Pods through the stable Primary and Replica Services before applying the fencing procedure below.

Start with `bash scripts/test-primary-recovery.sh` and record database Pod placement and PVC affinity. If the old Primary is briefly unavailable, restore access to its original node and inspect the existing PVC before discussing promotion.

A manual promotion requires explicit operator approval and verified fencing. Quiesce writers and remove old write endpoints. For a confirmed reachable host, scaling the old Primary StatefulSet to zero and verifying the old Pod actually exited can contribute to fencing. A partitioned node requires infrastructure-level isolation. An empty endpoint list by itself cannot prove that an old Primary stopped.

Record Primary and Replica WAL positions where possible and measure possible asynchronous data loss. Once fencing and approval are established, run `SELECT pg_promote(wait => true, wait_seconds => 60)` against the standby via its local administrator socket. Confirm recovery is false. Before directing traffic, review its HBA and probes, which are intentionally standby-only, and the bootstrap guard, which intentionally rejects promoted PGDATA. Prepare appropriate Primary settings and a workload transition that preserves the promoted volume. Switch the write endpoint only after validating authenticated CRUD on the promoted instance. Keep reporting degraded until a confirmed standby is online.

Preserve the old Primary PVC. Rebuild a new standby from a base backup of the new Primary on separately provisioned storage. Confirm a single writer, streaming in the new direction, role and endpoint correctness, replicated rows and a new verified backup. Keep reconciliation paused until the deployment definitions match the new roles.
