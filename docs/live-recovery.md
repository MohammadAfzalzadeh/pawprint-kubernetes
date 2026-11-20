# Recover the live PawPrint database from a backup

| Command | Result |
| --- | --- |
| `make restore BACKUP_ID=<id>` | Restores the archive in a temporary, isolated PostgreSQL instance and verifies it. |
| `make restore-live-preflight BACKUP_ID=<id>` | Checks the active database, storage and application identities and runs an isolated restore of the selected bundle. Creates validation Job resources only. |
| `make restore-live BACKUP_ID=<id>` | Restores into a new persistent database and switches the application's database Services after fencing the old database pair. |
| `make rollback-live OPERATION_ID=<operation-id>` | Fences the recovered pair and returns traffic to the preserved original pair. |

The live procedure restores the snapshot in one logical backup. Writes committed after that snapshot disappear from the database serving traffic. The original volumes retain their contents. Rollback can similarly remove post-cutover writes from service. Schedule downtime, stop external writer traffic, and retain an off-host copy of the backup. PawPrint has no continuous WAL archive or timestamp-based point-in-time recovery.

## Run the recovery

Run from an interactive terminal on the Kind host. The recovery script requires Python 3.9 or newer, kubectl, the dedicated `$HOME/.kube/pawprint-config`, the current context `kind-pawprint` and namespace `pawprint`. Both PostgreSQL 18 servers must start healthy and streaming. Make sure the backup tooling, NetworkPolicies, Services, and workloads have already been deployed. Recovery also needs room for a fresh Primary and standby and for transient restore Jobs. Kind local-path claims share backing disk capacity. The script checks actual available bytes on the backing filesystem as well as Kubernetes claim status.

The operator needs read access to nodes, namespaced workloads, EndpointSlices, StorageClasses, PVCs and PVs. The operator also needs `pods/exec` and Job log access, permission to create Jobs, PVCs, Services, StatefulSets, ConfigMaps and NetworkPolicies, and permission to replace the recovery ConfigMap, scale Deployments, and patch the CronJob, Services and StatefulSets. Recovery mounts the existing Secret through Kubernetes Secret references. It does not print passwords or require direct `get secret` access.

```bash
make restore-live-preflight BACKUP_ID='<exact ID printed by make backup>'
make restore-live BACKUP_ID='<exact ID printed by make backup>'
```

Read the reported Primary and Replica identities, deployment image versions, and selected backup ID. At the prompt type `RESTORE <exact backup ID>`. The command repeats preflight on every invocation. The backup stays mounted read-only, and its checksum manifest digest must match again during persistent preparation.

### Architecture and states

1. **PREFLIGHT** checks the current context, namespace, cluster state, effective Service endpoints, database and volume identities, versions, data fingerprints, WAL positions, available disk, and application replica counts and images. A scoped Job checks the four SHA-256 digests, decodes the archive, and proves an isolated restore. A failed preflight leaves application traffic and database controllers as they were.
2. **PREPARING**, **RESTORING**, and **VALIDATING** create a fresh PVC and run a socket-only PostgreSQL Job with TCP disabled. The Job provisions PawPrint's known roles with existing credentials and restores the public schema as `petclinic_owner`. It reinstates the private reporting function and bootstrap marker from the checked-in SQL without seeding over the archive. It verifies all seven table fingerprints and schema objects, checks the six sequences and reinstates their backed-up state after the `nextval` probes. The original Primary's Pod and PVC identities are checked again before cutover. Concurrent application writes may still change its fingerprints at this stage.
3. **CUTOVER** scales PetClinic and Reporting to zero, waits for their Pods to terminate, and suspends and drains scheduled backups. It records the original selectors and writes a persistent fence on each old StatefulSet. The fence sets replicas to zero and adds a blocking init container so an accidental scale-up cannot start PostgreSQL. It waits for old Pods to disappear on Ready nodes before starting the restored Primary. The existing Primary Service switches to exactly one Ready endpoint on the new generation. No direct data copy targets either original PVC.
4. **REPLICATION_RECOVERY** creates a new standby StatefulSet and claim. Its existing `pg_basebackup` init path copies the new Primary. The standby must report recovery mode, streaming, and the same new PostgreSQL system ID. The Replica Service then targets the new standby. Converged catalog and table fingerprints must match the backup, and the serving Primary must match the archived sequence state. Reporting's four write operations must fail on each database. [PostgreSQL base backup documentation](https://www.postgresql.org/docs/18/app-pgbasebackup.html)
5. **APPLICATION_RECOVERY** starts Reporting first and checks HTTP data and network isolation. PetClinic resumes at its original replica count after these gates pass. A test owner created through PetClinic must appear on both databases and in Reporting's aggregates. The successful test row is retained. Recovery then verifies all previous and new PVCs, confirms that the old StatefulSets remain fenced, restores the original CronJob suspension setting, and marks **VERIFIED**.

The namespace ConfigMap `pawprint-live-recovery` is the recovery journal. Its resource version serializes cutovers. It records operation and backup IDs, selectors, old and new Pod/system identities, claim bindings, fingerprints, failure phase and timestamps. A later operation archives the previous terminal journal as `pawprint-recovery-<operation-id>`. Keep the existing Services as the database connection endpoints. `make deploy` refuses to reapply the original Primary or Replica manifests while their Services use a recovered generation.

## Failures and rollback

On a confirmed run failure the command stops PetClinic and Reporting, suspends backups, and records **FAILED** before cutover or **ROLLBACK_REQUIRED** after cutover starts. It preserves both generations and leaves fence changes in place. An unreachable API can prevent it from recording the failure or verifying that application Pods stopped. Recover API access and inspect the journal and controllers before acting. Do not force-delete a database Pod on an unreachable node or start a second Primary.

```bash
kc="$HOME/.kube/pawprint-config"
kubectl --kubeconfig "$kc" --context kind-pawprint -n pawprint \
  get configmap pawprint-live-recovery -o jsonpath='{.data.record\.json}' | python3 -m json.tool
kubectl --kubeconfig "$kc" --context kind-pawprint -n pawprint \
  get sts,pods,pvc,svc,endpointslice,job -o wide
```

Review `failed_phase`, Pod and claim identities, and `app_writes_may_have_occurred`. If you decide to return traffic to the pre-cutover database, run the command below and type `ROLLBACK <operation-id>`. Rollback first stops application traffic and waits for any preparation Job to terminate. It then fences the recovered pair and verifies termination before removing the fences from the old StatefulSets. It checks streaming and HTTP after restoring the original routes. The script accepts only the current failed or verified operation so older journals cannot activate stale databases.

```bash
make rollback-live OPERATION_ID='<operation from the current journal>'
```

If the runner was killed and the journal never reached a failure or terminal state, keep writers stopped while investigating. After independently confirming the runner has exited, all nodes with database Pods are reachable, and no other administrator is acting on the namespace, an operator with ConfigMap write access can mark the interrupted operation for rollback by preserving its record and resource version. This changes journal state only. Run rollback afterward to enforce database fencing.

```bash
kubectl --kubeconfig "$kc" --context kind-pawprint -n pawprint \
  scale deployment/petclinic deployment/reporting --replicas=0
kubectl --kubeconfig "$kc" --context kind-pawprint -n pawprint \
  patch cronjob petclinic-backup --type merge -p '{"spec":{"suspend":true}}'
kubectl --kubeconfig "$kc" --context kind-pawprint -n pawprint get cm pawprint-live-recovery -o json |
  python3 -c '
import json, sys
obj = json.load(sys.stdin)
record = json.loads(obj["data"]["record.json"])
if record["phase"] in {"VERIFIED", "ROLLED_BACK"}:
    sys.exit("This journal already reached a terminal state")
record.update(failed_phase=record["phase"], phase="ROLLBACK_REQUIRED")
obj["metadata"]["annotations"]["pawprint.io/phase"] = "ROLLBACK_REQUIRED"
obj["data"]["record.json"] = json.dumps(record)
print(json.dumps(obj))
' | kubectl --kubeconfig "$kc" --context kind-pawprint -n pawprint replace -f -
```

The workloads use StatefulSet claim retention and keep the claims Bound when scaling down. Kind's local-path StorageClass has reclaim policy `Delete`. Deleting a claim or losing its node can destroy the corresponding local data. Keep the old PVCs, their nodes and a separate backup copy during the rollback window. [StatefulSet claim retention](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/#persistentvolumeclaim-retention)

## RPO, RTO and limits

- Measure **RPO** from the backup snapshot acquisition time to the incident or write freeze. The bundle ID timestamp is a lower-precision proxy generated just before snapshot acquisition. The WAL positions in the journal characterize the serving pair and replica lag. They cannot replay changes newer than the logical backup.
- Measure **RTO** from `outage_started_at` to `verified_at` for fully verified service. Use `petclinic_http_at` and `reporting_verified_at` to measure time to their respective readiness gates. Preflight and persistent preparation run before the outage timer. Report elapsed incident time separately if recovery began long after the incident.
- This procedure requires the PawPrint topology, seven-table public schema, compatible PostgreSQL 18 images and the checked-in initialization metadata. Other roles, grants, custom schemas and external database writers require separate recovery planning. Multiple operators or GitOps must not concurrently edit or scale recovery-managed resources. The fence guards ordinary controller scale-up, while a privileged administrator can remove it.
- Reporting exposes counts and latest owner ID. It does not expose surnames. Verify field-level state on the standby and compare the API aggregates to standby queries.
- Local-path storage on Kind shares one physical host. The recovery workflow does not provide high availability across host failures.

See [live recovery acceptance evidence](live-recovery-acceptance-report.md) for the exercised cases and results.
