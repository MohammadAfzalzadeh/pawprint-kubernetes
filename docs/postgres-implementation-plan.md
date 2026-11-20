# PostgreSQL implementation plan

Analysis only: no manifests are created here. All commands below are proposed for later host-terminal execution with the dedicated PawPrint kubeconfig. Replace namespace and resource names only through reviewed manifests. Estimate assumes a small local lab and excludes troubleshooting delays.

## Shared assumptions and safety

- Namespace: `pawprint` (planned).
- Existing Kind `local-path` StorageClass; verify its exact name and behavior before PVC creation.
- Internal ClusterIP Services only for PostgreSQL. No host port or public database exposure.
- PostgreSQL credentials enter through Kubernetes Secrets created outside Git. Do not commit populated Secret manifests or literal passwords in shell history.
- Use a pinned PostgreSQL image and confirm its major version, data directory, startup behavior, and replication instructions before creating PVCs.
- Use distinct app, replication, and reporting users. PetClinic profile uses `SPRING_PROFILES_ACTIVE=postgres`, `POSTGRES_URL`, `POSTGRES_USER`, and `POSTGRES_PASS`.
- Do not run any failure test until persistence, replication, and recovery steps are understood.

## Milestones

### 1. Deploy Primary (estimated 2–3 hours)

- **Files:** `postgres/primary/statefulset.yaml`, `service.yaml`, `configmap.yaml`, PVC template in StatefulSet, plus non-secret Secret creation instructions (no populated secret file).
- **Commands:** inspect `kubectl get storageclass`; apply namespace and reviewed primary resources with `kubectl --kubeconfig "$HOME/.kube/pawprint-config" apply -f ...`; inspect `kubectl get pods,pvc,svc -n pawprint` and `kubectl describe pod`.
- **Expected:** one primary pod Ready; PVC Bound; internal ClusterIP Service resolves to the pod.
- **Verify:** `pg_isready` in pod; connect internally; `SELECT version()`; confirm service endpoints and no external DB Service.
- **Common errors:** wrong image architecture/tag, Secret key mismatch, PVC Pending/StorageClass mismatch, insufficient node resources, probe too aggressive, data-directory ownership mismatch.

### 2. Verify initialization and persistence (estimated 1–2 hours)

- **Files:** primary initialization SQL/config if needed, `postgres/primary/README.md` documenting initialization and PVC policy.
- **Commands:** inspect logs and schema; insert a uniquely identifiable test row; restart the primary pod through a controlled StatefulSet pod deletion only after verifying the PVC is retained; reconnect and query the row.
- **Expected:** schema/roles exist; data survives pod restart on the same node/PVC.
- **Verify:** `\dt`, role/privilege queries, `SELECT` for test row, PVC remains Bound.
- **Common errors:** initialization scripts only run on empty data directories, app SQL scripts rerun concurrently, sequence state mismatch, PVC not retained or local node unavailable. Keep PetClinic's `spring.sql.init.mode=always` behavior under review before app deployment.

### 3. Deploy Replica (estimated 2–3 hours)

- **Files:** `postgres/replica/statefulset.yaml`, `service.yaml`, Secret instructions, readiness configuration; replica PVC.
- **Commands:** apply replica StatefulSet and internal Service; inspect pod/PVC/events. Do not accept a freshly initialized standalone database as a replica.
- **Expected:** replica PVC Bound and instance prepared to follow primary; replica endpoint internal only.
- **Verify:** `pg_isready`, pod role/recovery state, and service endpoints.
- **Common errors:** replica starts with unrelated initialized data, wrong PostgreSQL major version, node-local volume placement, insufficient disk/resources.

### 4. Configure Streaming Replication (estimated 2–4 hours)

- **Files:** reviewed primary/replica config (ConfigMaps), Secret creation instructions for replication credential, restricted `pg_hba.conf` rule; bootstrap procedure (base backup/entrypoint or controlled init Job to be decided).
- **Commands:** create replication role on primary; set WAL/sender settings; authorize replica source only; bootstrap standby from primary; start standby with correct `primary_conninfo`/`standby.signal` semantics for chosen image/version.
- **Expected:** standby enters recovery and connects to primary; no manual SQL writes on standby.
- **Verify:** primary `pg_stat_replication`; replica `pg_stat_wal_receiver`, `pg_is_in_recovery() = true`; inspect logs and WAL positions.
- **Common errors:** credentials/hostname mismatch, `pg_hba.conf` mismatch, missing WAL settings, wrong base backup ownership/permissions, incompatible major versions, WAL removed before reconnect. Replication slots can prevent WAL loss but can fill disk if abandoned.

### 5. Verify Primary/Replica synchronization (estimated 1 hour)

- **Files:** `scripts/verify-replication.sh` (later, without embedded credentials) and evidence section in docs.
- **Commands:** insert a unique owner/pet or dedicated test record on primary; poll a replica query until visible; record timestamps and WAL lag.
- **Expected:** record becomes visible on replica after replay; replica remains read-only.
- **Verify:** compare same record on both, inspect replication views and relevant database role identity.
- **Common errors:** replication disconnected, lag, querying a wrong Service, expecting immediate synchronous visibility. Default streaming is asynchronous.

### 6. Test database connectivity (estimated 1–2 hours)

- **Files:** later PetClinic Deployment config and Secret wiring; a temporary diagnostic Pod manifest may be created for the test and removed only with explicit review.
- **Commands:** run a short-lived PostgreSQL client inside the namespace; verify primary endpoint and app role; separately verify read-only reporting role on replica. Then connect PetClinic via `POSTGRES_URL` in a later app phase.
- **Expected:** app role can use the required application database operations on primary; reporting role can select on replica and cannot write.
- **Verify:** `current_database()`, `current_user`, `inet_server_addr()`, `pg_is_in_recovery()` and role privilege checks.
- **Common errors:** using localhost in a pod, service DNS/namespace typo, secret key/environment mismatch, auth rule, missing grants, connection limit.

### 7. Test restart and persistence behavior (estimated 1–2 hours)

- **Files:** persistence/recovery runbook and recorded PVC topology.
- **Commands:** controlled pod restart for each instance; verify PVC and data. Do not delete PVCs or simulate node/disk loss without a separately reviewed recovery plan.
- **Expected:** pod restart with its volume preserves database state. This does not prove node-loss recovery with local-path storage.
- **Verify:** same rows before/after, pod node/PVC binding and volume events.
- **Common errors:** PVC bound to failed worker, pod cannot mount volume on another node, insufficient free space, permissions mismatch.

### 8. Test assignment failure scenarios (estimated 2–4 hours)

- **Files:** `docs/failure-tests.md` with action, expected/actual output, recovery and evidence; primary promotion/rejoin runbook before any database failover experiment.
- **Commands:** first test reporting replica unavailable while PetClinic remains available (after app exists); separately test primary outage only with a reviewed manual-promotion plan and explicit confirmation. Worker failure must follow the assignment's controlled procedure and be restored promptly.
- **Expected:** replica outage degrades reporting while ordinary app remains available. Primary outage interrupts writes until operator-driven promotion and endpoint switch. Worker outage can strand local-path data and reduce scheduling capacity.
- **Verify:** node/pod placement, DB role and recovery state, Services/endpoints, application HTTP checks, report response, and post-recovery replication/data checks.
- **Common errors:** split brain, promotion before fencing old primary, stale Service endpoints, replica not caught up, node-local volume unavailable, insufficient spare capacity. Stop if recovery state is ambiguous.

## Overall estimate and boundaries

Estimated implementation time: approximately 12–20 focused hours across milestones, excluding cluster/resource remediation and the separate PetClinic/Ingress work. Estimates are planning ranges, not commitments. This plan does not implement automatic failover; the assignment's mandatory scope is streaming replication and reporting via replica, while advanced PostgreSQL HA is bonus/investigation scope.
