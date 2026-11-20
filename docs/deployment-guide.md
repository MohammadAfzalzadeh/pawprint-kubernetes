# Deploy and test PawPrint from scratch

## Prepare the Ubuntu host

Use an amd64 Ubuntu host with Docker and BuildKit, Kind v0.33.0, kubectl v1.37.x, Helm, Git, GNU Make, Bash, Python 3, and curl. Your user needs access to the Docker daemon. Run the following commands from the PawPrint project root. Use the full project checkout, including `nginx-ingress-2.9.0.tgz`, and download Spring PetClinic separately if `spring-petclinic/` is absent. The pinned source revision matches the image tag in the Kubernetes Deployment.

```bash
docker info --format 'Docker {{.ServerVersion}}'
kind version
kubectl version --client
helm version --short
free -h
swapon --show
df -h / /home /var
ss -ltn '( sport = :8080 or sport = :8443 )'

if [ ! -d spring-petclinic ]; then
  git clone https://github.com/spring-projects/spring-petclinic.git spring-petclinic
  git -C spring-petclinic checkout --detach 500158f732419217507c7656904b8e6aa1bcc0d6
fi
git -C spring-petclinic rev-parse HEAD
```

Check that `8080` and `8443` are free and that the source revision is `500158f732419217507c7656904b8e6aa1bcc0d6` before continuing. Use a clean PetClinic checkout for a reproducible build. A cold build needs access to the pinned Kind node image, Liara's Docker Hub mirror for workload images, Maven Central for PetClinic, and the Python package index for Reporting. See [image builds](docker-guide.md) and [registry mirrors](image-registry-mirrors.md) for registry troubleshooting.

## Create the Kind cluster

If `kind get clusters` already lists `pawprint`, verify that cluster with `make preflight` and skip creation. Otherwise, create one control plane and two workers using the pinned images and port mappings in `kind-pawprint.yaml`.

```bash
mkdir -p -m 700 "$HOME/.kube"
kind create cluster --name pawprint --config ./kind-pawprint.yaml \
  --kubeconfig "$HOME/.kube/pawprint-config" --wait 180s
make preflight
```

`make preflight` requires a running cluster. Expect all three nodes to be `Ready` and the `standard` StorageClass to exist. PawPrint uses the dedicated kubeconfig and context `kind-pawprint`. See [Kind setup](kind-cluster.md) for the pinned image and host ports. The Ansible mirror configuration is optional for this run because the image loader imports the workload images on each node.

## Build, load, and deploy

To deploy the published PetClinic and Reporting images, follow the [GHCR deployment guide](ghcr-deployment.md) after the `primary bootstrap replica` stages. The Docker build and Kind load commands for those two applications are for local images.

Run these commands in order and stop at the first failure. `make secrets` prompts for four database passwords and preserves an existing Secret. It creates `pawprint/postgres-primary-auth` on a fresh cluster. The [placeholder Secret](../k8s/secret.example.yaml) records the six keys and uses a separate example name. On a host under memory pressure, use the staged commands below to build and roll out one component at a time.

```bash
make secrets
bash scripts/load-images.sh postgres
make deploy STAGES="primary bootstrap replica"
bash scripts/build-images.sh reporting
bash scripts/load-images.sh reporting
make deploy STAGES=reporting
bash scripts/build-images.sh petclinic
bash scripts/load-images.sh petclinic
make deploy STAGES=petclinic
bash scripts/load-images.sh ingress
make deploy STAGES=ingress
make deploy STAGES="network backup"
```

Pause between stages to inspect `free -h`, `swapon --show`, `cat /proc/pressure/memory` and node conditions. At steady state, the workloads request about 1.25 GiB of memory and have combined limits of about 1.75 GiB, excluding cluster overhead and transient backup and restore Jobs. The nodes share one physical memory pool. Reclaimable host cache and swap use can vary during builds.

Expected database Services are ClusterIP and expected PVCs are `data-postgres-primary-0`, `data-postgres-replica-0` and `petclinic-backups` after its first consumer. Replica and PetClinic deployment verify the bootstrap marker and catalog. The bootstrap stage seeds a new database once and verifies a previously marked database. A failed initial Job needs log inspection and a reviewed retry. Existing claims and Secrets survive repeated deployment.

```bash
export KUBECONFIG="$HOME/.kube/pawprint-config"
kubectl --context kind-pawprint -n pawprint get pods,svc,pvc,job,ingress -o wide
curl -fsS http://localhost:8080/
curl -fsS http://localhost:8080/api/reports/summary
```

HTTP is the local demo path. The 8443 mapping reserves HTTPS access. A TLS Secret and explicit certificate configuration are required to serve trusted HTTPS.

## PetClinic resource sizing

On 2026-11-20 from 19:23:49 to 19:25:49 Tehran time, the two Ready PetClinic Pods ran `pawprint/petclinic:500158f73241`, one on each worker. The baseline lasted 48 seconds without synthetic traffic. The next 72 seconds alternated GET requests to `/`, `/owners?lastName=` and `/vets.html` through NGINX at about four requests per second across both replicas. All 286 requests returned HTTP 200. Both Pod identities and restart counts stayed the same during sampling.

Metrics Server was absent, so the samples came from the [kubelet Summary API](https://kubernetes.io/docs/reference/instrumentation/node-metrics/) for the `petclinic` container in each Pod. The collector polled every 12 seconds and counted unique kubelet timestamps. Average CPU uses the change in cumulative CPU time divided by elapsed kubelet sample time. Peak CPU is the largest reported sample. Memory is the sampled working set.

| Worker | Pod | Phase | CPU average / peak | Memory median / peak | Unique samples |
| --- | --- | --- | --- | --- | ---: |
| `pawprint-worker` | `petclinic-6cf5cbfddf-lcjwk` | Baseline | 2.05m / 3.32m | 267.26 / 268.25 MiB | 4 |
| `pawprint-worker` | `petclinic-6cf5cbfddf-lcjwk` | Light GET traffic | 53.59m / 104.79m | 288.58 / 291.91 MiB | 7 |
| `pawprint-worker2` | `petclinic-6cf5cbfddf-hskx6` | Baseline | 2.48m / 3.33m | 303.85 / 304.52 MiB | 4 |
| `pawprint-worker2` | `petclinic-6cf5cbfddf-hskx6` | Light GET traffic | 36.07m / 42.52m | 305.46 / 308.01 MiB | 5 |

The Deployment uses the following per-container budget. Requests guide placement, and CPU and memory limits constrain container use. This sizing reflects a warm, light-traffic run on one Kind host. Recheck usage and latency for a different workload or sustained peak traffic. [Kubernetes resource management](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/)

| Setting | Value | Rationale |
| --- | ---: | --- |
| CPU request | `100m` | Covers both measured averages with margin. One brief sample reached `104.79m`. A CPU request allows bursts above that amount when capacity is available. |
| CPU limit | `750m` | Bounds a replica's CPU use on the shared Kind host and leaves room for startup and traffic bursts above its `100m` request. |
| Memory request | `336Mi` | Both warm replicas already exceeded the former `256Mi` request. The new request is about `28Mi` above the largest working set and about `19Mi` above the largest sampled total memory usage (`316.80Mi`). |
| Memory limit | `384Mi` | Leaves about `67Mi` above the largest sampled total memory usage while capping one replica's impact. The container image configures the JVM with `MaxRAMPercentage=55` to leave room for memory beyond the Java heap. |

If `ScheduleAnyway` places both replicas on one worker, their combined requests are `200m` CPU and `672Mi` memory, plus the requests of the worker's other workloads. [PetClinic Pod placement](architecture.md#petclinic-pod-placement)

After the memory request changed to `336Mi`, the same image rolled out successfully with both replicas Ready on separate workers. The rollout then used `maxUnavailable: 1` and `maxSurge: 0`. During that rollout, 78 of 79 homepage samples returned HTTP 200. One client request timed out after NGINX tried to connect to the old Pod at `10.244.2.5:8080` during termination. After the rollout, all 30 follow-up samples returned HTTP 200, `make verify` passed, and the PostgreSQL Pod UIDs matched their pre-rollout values. [Current rolling update settings and release validation](petclinic-image-rollout.md)

Inspect the source measurements on either worker with the dedicated kubeconfig. The app's `usageNanoCores`, `usageCoreNanoSeconds`, `workingSetBytes` and `usageBytes` fields are under its container entry. The full local measurement record is in `.pawprint/evidence/petclinic-resources/`.

```bash
kubectl --kubeconfig "$HOME/.kube/pawprint-config" --context kind-pawprint \
  get --raw /api/v1/nodes/pawprint-worker/proxy/stats/summary |
  python3 -c 'import json,sys; data=json.load(sys.stdin); [print(p["podRef"]["name"], c["cpu"], c["memory"]) for p in data["pods"] if p["podRef"]["namespace"]=="pawprint" for c in p["containers"] if c["name"]=="petclinic"]'
```

## Run acceptance tests

```bash
make test
make backup
make restore
```

| Command | Passing result |
| --- | --- |
| `make test` | Two PetClinic replicas are Ready, ingress returns HTTP 200, PostgreSQL streams WAL, Reporting matches the read-only Replica, the NetworkPolicy blocks Reporting from Primary, and isolated bootstrap passes. |
| `make backup` | The Job publishes a verified backup bundle and prints its backup ID. |
| `make restore` | The latest verified bundle restores into an isolated PostgreSQL instance. The test compares table data, schema objects and sequence state against the backup. |

Use `make restore BACKUP_ID='<ID printed by make backup>'` to test the exact manual backup if the scheduled backup also ran. To verify scheduled execution, inspect `kubectl --kubeconfig "$HOME/.kube/pawprint-config" --context kind-pawprint -n pawprint get cronjob,job` after a scheduled run. See [backup and restore](backup-restore.md) for the schedule and evidence to collect.

Use `make restore-live-preflight BACKUP_ID=<id>` to evaluate that backup for a live cutover. The separate `make restore-live BACKUP_ID=<id>` command requires a maintenance window and explicit confirmation. See [live recovery and rollback](live-recovery.md).

## Exercise failures on the lab cluster

Run these after the baseline, backup, and restore pass. These tests write sample records and cause temporary workload disruption. The Primary persistence test can briefly interrupt PetClinic, and the Replica outage and persistence tests can briefly degrade Reporting. The scripts keep their sample records for inspection.

```bash
make test-failures
bash scripts/test-persistence.sh primary
bash scripts/test-persistence.sh replica
bash scripts/test-primary-recovery.sh
make test
```

`make test-failures` creates an owner through PetClinic, checks WAL replay and Reporting, deletes one PetClinic Pod, and exercises a Replica outage and recovery. The persistence scripts restart one PostgreSQL Pod at a time and check its claim and sample record. The Primary recovery script checks replication and WAL position as a read-only precheck.

For application-only worker evacuation, first verify PetClinic has one Ready Pod per worker and review the database volume placement. Run the worker script only after approving the target, using the [failure-test procedure](failure-testing.md). A full node shutdown can make its local PostgreSQL volume unavailable. Actual standby promotion is a separate operator-approved exercise that requires fencing the old Primary. See the [recovery runbook](recovery-guide.md).
