# PawPrint acceptance report

The backup and restore rows were refreshed on 2026-11-20. The [backup, restore and bootstrap evidence](backup-bootstrap-evidence.md) records checksum verification, data and catalog comparisons, negative tests and unchanged live database and PVC identities.

Verified against the existing `kind-pawprint` context on 2026-11-19. All three nodes reported Ready on Kubernetes v1.37.0. F5 NGINX Ingress Controller 5.8.0 served both paths from the existing loopback mapping `8080 → 30080`. PetClinic ran one Pod per worker. PostgreSQL Primary and Replica ran on different workers and Reporting was Ready.

## Application

| Criterion | Status | Evidence |
| --- | --- | --- |
| PetClinic image builds | PASS | Maven Wrapper 3.9.16 ended with BUILD SUCCESS and packaged the Spring Boot 4.1.0 JAR with Java 17. |
| PetClinic runs directly on the host | PASS | On 2026-11-20, Java 17 ran the Maven-built JAR with H2 on `127.0.0.1:18081`. The homepage rendered and returned HTTP 200. [Host run evidence](standalone-petclinic.md#build-with-maven-and-run-on-the-host) |
| Image loaded into all Kind nodes | PASS | All three CRI stores reported image ID prefix `f6666d2c35bc3`. |
| Two PetClinic replicas Ready | PASS | Deployment 2/2; Pods on `pawprint-worker` and `pawprint-worker2`. |
| PetClinic resources measured per Pod | PASS | On 2026-11-20, both replicas were sampled at baseline and during 286 successful GET requests. The measured working set peaked at `308.01Mi`, informing the `336Mi` request. [Measurements and rollout evidence](deployment-guide.md#petclinic-resource-sizing) |
| Service routes traffic | PASS | EndpointSlice lists both Pods on TCP 8080. Homepage, vet list and owner details returned 200 through the Service. |
| Health probes work | PASS | Both Pods reached 1/1 with startup, readiness and liveness checks. Management uses port 8081 and the ingress returned 404 for `/actuator`. |
| Ingress works | PASS | NGINX accepted the Ingress. Home and reports returned HTTP 200 at localhost:8080. The owner create redirect stayed on the same origin. |
| Uses PostgreSQL Primary | PASS | Hibernate reported PostgreSQL 18.6 and the Primary JDBC URL. Primary showed four `petclinic_app` sessions. |
| Survives Pod deletion | PASS | Deleted one PetClinic Pod. The 40 HTTP samples returned 200 and a replacement brought the Deployment back to 2/2. |
| Rolls out a new PetClinic image | PASS | Changed from source tag `0d064b04958d` to `500158f73241`. During rollout, at least two PetClinic Pods were Ready at every sample and all 196 homepage requests returned HTTP 200. [Release evidence](petclinic-image-rollout.md#observed-upgrade-and-rollback) |
| Rolls back to the previous image | PASS | `rollout undo` restored the previous source tag and its pagination behavior. All 195 homepage samples during rollback returned HTTP 200. [Rollback evidence](petclinic-image-rollout.md#observed-upgrade-and-rollback) |
| Separate Docker-only app run | PASS | On 2026-11-20, `pawprint/petclinic:500158f73241` ran with H2 and returned HTTP 200 on `127.0.0.1:18082`. Its image ID matched both Kind workers. [Standalone Docker evidence](standalone-petclinic.md#run-the-kubernetes-image-with-docker) |

## Database

| Criterion | Status | Evidence |
| --- | --- | --- |
| Primary Ready | PASS | `postgres-primary-0` 1/1; PostgreSQL 18.6 accepts connections. |
| Primary PVC Bound | PASS | 5 GiB RWO `data-postgres-primary-0` on `pawprint-worker`. |
| Initializes petclinic | PASS | Bootstrap Job v2 completed. Original SQL seeded 10 owners, 13 pets, 6 vets and 4 visits. |
| Expected schema exists | PASS | Seven expected tables, five foreign keys and 15 indexes verified on Primary. |
| App role least privileged | PASS | Verified table INSERT and sequence USAGE, no schema CREATE, superuser or replication rights. PetClinic inserted owner 15. |
| Replica Ready | PASS | `postgres-replica-0` 1/1; successful recovery-mode readiness. |
| Replica PVC Bound | PASS | 5 GiB RWO `data-postgres-replica-0` on `pawprint-worker2`. |
| Replica in recovery | PASS | `pg_is_in_recovery()` true and `transaction_read_only` on. |
| Streaming connected | PASS | `replicator / streaming / async`. Final observed Primary WAL LSN and replay LSN were both `0/3060038` with zero bytes of lag. |
| Replication data test | PASS | Created owner 15 via PetClinic HTTP. Primary and Replica matched its ID and marker within 2.236 s, including HTTP and polling. WAL replay advanced. |
| Persistence | PASS | Wrote distinct test records and replaced each PostgreSQL Pod separately. Both tests verified the same claim UID, PV and retained record. |

## Reporting

| Criterion | Status | Evidence |
| --- | --- | --- |
| Separate Reporting API deployed | PASS | Reporting Deployment 1/1 and ClusterIP route returned 200. |
| Replica only | PASS | `pg_stat_activity` showed `reporting_user / pawprint-reporting` on Replica and zero on Primary. TCP from Reporting reached Replica and timed out on Primary. |
| Read-only login | PASS | Authenticated SELECT passed. UPDATE and CREATE TABLE returned SQLSTATE 25006. Role privileges also exclude writes and schema creation. |
| Owner report | PASS | 15 owners after retained test data. The report observed owner 15 after 8.871 s, including polling. |
| Pet report | PASS | 13 pets. |
| Veterinarian report | PASS | 6 vets. |
| Visit report | PASS | 4 visits. |
| Pet-type report | PASS | Bird 2, cat 4, dog 4, hamster 1, lizard 1, snake 1. |
| 30-second refresh | PASS | Two successive snapshots at 19:53:17.470682Z and 19:53:47.441514Z were 29.971 s apart. |
| Replica outage handled | PASS | Scaled standby down to zero. Reporting returned 503 with `stale=true` and `degraded=true`. Standby, streaming and HTTP 200 reports recovered. |
| Website available during reporting outage | PASS | PetClinic returned HTTP 200 at each sampled request while waiting for degraded Reporting. No reporting session appeared on Primary. |

## Operations

| Criterion | Status | Evidence |
| --- | --- | --- |
| Backup | PASS | `petclinic-backup-manual-20261119205307-01f8` produced a 15,813-byte custom archive and verified its TOC and payload. The six-hour CronJob uses the same template. |
| Isolated restore | PASS | `petclinic-restore-test-xwh58` restored into a disposable PostgreSQL 18.6 instance. Seven table hashes, 21 constraints, 15 indexes and six sequences matched. |
| Bootstrap repeat and rollback guard | PASS | `petclinic-bootstrap-test-599fv` verified new provisioning, preservation on repeat and rejection of unmarked pre-existing data. |
| Application Pod failure | PASS | ReplicaSet replaced the selected Pod and all 40 sampled requests returned 200. |
| Worker failure | BLOCKED | Application-only evacuation procedure prepared. Requires explicit approval for the selected worker test. Local database volumes remain on their original nodes. |
| Replica failure | PASS | Reporting degraded while PetClinic stayed up and recovered after scale-up with the existing claim. |
| Recovery documented | PASS | Read-only recovery precheck passed. Manual fencing and promotion are documented. |
| Live Primary promotion | NOT TESTED | Requires separate approval and verified fencing. |
| No credentials committed | PASS | Secret created through hidden prompts with independent random values. No populated Secret manifests or commits. Nested checkout is clean. |
| Documentation and reproducible files | PASS | Deployment, backup, reporting, testing, known failures and operations are documented. |

## Image inventory

All four workload images were verified on the control plane and both workers as linux/amd64.

| Image | Image ID or registry index |
| --- | --- |
| `pawprint/petclinic:500158f73241` | `sha256:f6666d2c35bc3e1afb4b4cc5ab585c44ddcad9b24a8b9b8bccc53c583a98706b` |
| `pawprint/reporting:1.0.0` | `sha256:3421f4b4668f960252b39a4e633a3b2656de5b30262a4dae1494bc226f5bbc76` |
| `postgres:18.6-trixie` | Mirror index `sha256:e3d24f6906d0760bf4da0dae872415391ededefad23fd471c47dc53b0ddf3c42`; CRI ID prefix `8bca9649e52d9` |
| `nginx/nginx-ingress:5.8.0` | Mirror and upstream index `sha256:57705208dfa8ffb13be2bd8fca234b8a5dd49502eb37d44be57de54c6fec37aa`; CRI ID prefix `8da42de2ec149` |

The deployed PetClinic build used the installed Ubuntu OpenJDK 17.0.21.1 in a temporary Trixie build stage after the mirror JDK pull stalled. Its final runtime came from the pinned Temurin JRE index. The checked-in Dockerfile pins the mirror Temurin JDK and JRE indexes for direct rebuilds. The Reporting build used the official Python base whose index matched Liara. An initial Jammy fallback build stage rejected Ubuntu's JDK because that JDK needs GLIBC 2.38. The Trixie fallback compiled successfully.

## Resource and storage evidence

The final observed node-container memory was 666 MiB for the control plane, 470 MiB for one worker and 469 MiB for the other, about 1.57 GiB in total. Host available RAM was 774 MiB and 3.7 GiB of swap was occupied. Free space was 8.1 GiB on root, 6.3 GiB on home and 20 GiB on the Docker storage filesystem at /var. Primary PGDATA occupied about 80 MiB and Replica PGDATA occupied about 64 MiB. Each database requests 5 GiB. Backup requests 3 GiB and bound on `pawprint-worker`. The `standard` class uses local-path, WaitForFirstConsumer and Delete reclaim. Claim capacity reports the request and local-path shares backing filesystem capacity.

## Failures diagnosed

- The first bootstrap Job logged `syntax error at or near "$"`. It rolled back. The named SQL delimiter in the replacement Job solved the Kubernetes argument expansion.
- The first isolated restore attempt used a mismatched socket path. A second attempt encountered an already existing default public schema. The passing Job used the socket inside the temporary data directory and removed only the empty default schema in its fresh isolated database before restoring.
- The hostless ingress initially redirected HTTP to HTTPS. The route disables that redirect for the loopback demo. NGINX's forwarded service port also caused owner creation redirects to lose :8080. Relative redirects and cookie-only session tracking fixed the live owner form.
- The first Replica tally after restart showed a negative receive/replay byte difference because replay may have advanced through locally available WAL before current network receive catches up. The SQL health function floors the reported backlog at zero and leaves unknown positions null.

## Files delivered

- Root files `README.md`, `Makefile` and `.gitignore`.
- `docker/petclinic/` and `docker/reporting/` each contain a Dockerfile and both ignore file variants.
- `reporting/` contains `source/server.py`, `requirements.txt`, `README.md` and `configuration/README.md`.
- `k8s/` contains `namespace.yaml`, `petclinic/{configmap,deployment,service}.yaml`, `reporting/{configmap,deployment,service}.yaml`, `ingress/{ingress,values}.yaml`, `network/{database.yaml,README.md}` and `policies/petclinic-pdb.yaml`. The prior standalone PetClinic ConfigMap file moved into its component directory.
- `postgres/` updates the Primary and Replica ConfigMaps, StatefulSets and READMEs. Bootstrap uses `job.yaml`, `reporting.sql` and an informational ConfigMap file. Backup provides `backup-job.yaml`, `backup-cronjob.yaml`, `restore-test-job.yaml` and a README. The former fixed-name manual manifest points to the reusable Job.
- `scripts/` adds `common.sh`, `preflight.sh`, `setup-secrets.sh`, `build-images.sh`, `load-images.sh`, `deploy.sh`, `verify-cluster.sh`, `verify-database.sh`, `verify-reporting.sh`, `verify-network.sh`, `verify-refresh.sh`, `backup.sh`, `restore-test.sh`, `test-persistence.sh`, `test-replication-data.sh`, and the four component failure scripts. It updates `verify-replication.sh`.
- `docs/` adds the deployment, Docker, replication, reporting, backup, failure, recovery, troubleshooting and acceptance guides. It updates architecture, database architecture/security/testing and the earlier PostgreSQL deployment and backup notes.
