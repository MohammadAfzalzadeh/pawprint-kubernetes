# Controlled failure tests

Record start/end time, Pod placement, PVC/PV affinity, HTTP responses and recovery for each exercise. See [acceptance evidence](acceptance-report.md) for the actual outcomes.

| Script | Operation | Expected evidence |
| --- | --- | --- |
| test-pod-failure.sh | Delete one PetClinic Pod after confirming two Ready | Repeated HTTP 200 and two Ready replicas again |
| test-replica-failure.sh | Scale Replica to zero, then restore it with the same PVC | Report HTTP 503 with stale flag, PetClinic HTTP 200, streaming and reporting recover |
| test-worker-failure.sh | Cordon the approved worker and evict its PetClinic Pod via the eviction API | Remaining worker hosts both PetClinic Pods, HTTP remains available, original worker uncordons |
| test-persistence.sh | Restart one DB Pod and check its claim and test data | Claim UID and PV unchanged, marker retained |
| test-primary-recovery.sh | Read-only replication and fencing precheck | Recorded stream and LSN state for use in the recovery runbook |

The worker exercise tests application evacuation with DB Pods left running on their existing volumes. An actual worker shutdown can take a local database volume out of service. A preferable replica placement is a scheduling hint. Only use the worker script after explicit operator approval. It takes a fresh backup before cordoning. Uncordoning restores scheduling eligibility. Kubernetes may keep both healthy replicas on the surviving worker until a subsequent reschedule. Perform primary promotion separately under the [recovery runbook](recovery-guide.md).

Deleting a Pod lets its ReplicaSet replace it. Deleting the Deployment removes the controller that maintains the replica count. The Service selects Pod labels and receives readiness-filtered endpoints. During rollouts, readiness gates new traffic while the previous ready Pod can continue serving. Worker failure additionally affects scheduler placement, eviction timing and node-bound volumes.

The 2026-11-19 Pod deletion test returned HTTP 200 for all 40 samples. The standby outage test produced a controlled 503 for reports and recovered to 200 after restoring streaming. The worker evacuation awaits operator approval.

Run the [PetClinic image rollout and rollback exercise](petclinic-image-rollout.md) separately to test a change between two real application releases and record readiness and HTTP responses.

## Worker evacuation status

**Pending.** No worker evacuation or shutdown has been executed for this acceptance test. The planned exercise limits eviction to PetClinic and leaves the database Pods running. Collect node and Pod placement, HTTP results for PetClinic and Reporting through the full replacement window, and the final Ready count. Compare PostgreSQL Pod and PVC UIDs and PV bindings before and after. Record when the worker becomes schedulable again.

The script samples both HTTP routes independently before eviction, throughout replacement and after both PetClinic Pods are Ready on the surviving worker. It expects HTTP 200 on both routes. It also compares the database Pod UIDs, node placement, restart counts and mounted PVC UIDs and PV bindings. The script attempts to uncordon the target on exit, including after a failure. Review the timeline and evidence under `.pawprint/evidence/worker-evacuation.*`. Use those results to report application evacuation. The worker itself remains running throughout this exercise.

After approval and a fresh placement check, run from the repository root with `approved_worker` set to the chosen node name.

```bash
bash scripts/test-worker-failure.sh "$approved_worker" --operator-approved
```
