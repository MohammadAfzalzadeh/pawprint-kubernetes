# Reporting API

The Python service uses one psycopg connection only to `postgres-replica.pawprint.svc.cluster.local:5432/petclinic` with the `reporting_user` role. Each refresh uses a read-only transaction with a three-second statement timeout. The background refresh runs every 30 seconds. HTTP handlers consume one cached snapshot.

| Path under /api/reports | Contents |
| --- | --- |
| summary | Owners, pets, vets, visits, pet-type counts and latest owner ID |
| owners, pets, vets, visits | Individual counts |
| pet-types | Counts grouped by the actual PetClinic types table |
| status | Refresh and stream metadata |

`generatedAt` is the query snapshot time. `dataFreshnessAt` is the last replayed transaction timestamp and may remain unchanged during an idle period. `lastWalMessageAt` measures receiver contact. `replayPendingBytes` measures the Replica's receive-to-replay gap. After a refresh observes a failure or detects an outdated stream, reports return HTTP 503 with `stale` and `degraded` set. Liveness stays independent of database availability.

```bash
make report
bash scripts/test-replication-data.sh
bash scripts/test-replica-failure.sh
```

Verification compares `pg_stat_activity` on both nodes and checks the owner ID observed by the report after WAL replay.
