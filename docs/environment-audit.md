# Environment audit

Audit date: 2026-11-19 (local machine, Ubuntu)

## Machine

- OS: Ubuntu 24.04.4 LTS (Noble), x86_64; kernel `6.17.0-40-generic`.
- CPU: 8 logical CPUs, amd64.
- RAM: 11 GiB total, 3.2 GiB available at audit time; swap 3.7 GiB total, 187 MiB free.
- `/home`: 49 GiB filesystem, 6.4 GiB available (87% used).
- `/var`: 169 GiB filesystem, 32 GiB available (81% used).

## Runtime and tools

- Docker CLI/Engine client: 29.5.2, installed. Daemon status and server details could not be read: access to `/var/run/docker.sock` is denied for current user `jesus` (socket owned by `nobody:nogroup`, mode `srw-rw----`). `docker info`, `docker system df`, `docker ps -a`, and `docker volume ls` all fail for this same reason. Storage root and usage therefore remain unverified; `/var/lib/docker` is on `/var` with 32 GiB free, but that is not a substitute for `docker info`.
- kubectl: client v1.33.1, installed. Existing current context is `kind-dbaas`; cluster connectivity was not queried because Docker access is denied and this may be a pre-existing cluster.
- Kind: v0.27.0, installed. `kind get clusters` fails because it invokes Docker and cannot access the socket. No assumption is made about whether clusters exist.
- Helm: v4.2.0, installed.
- Git: 2.43.0.
- Java: OpenJDK 17.0.21.1.
- Maven: Apache Maven 3.8.7.

No system dependency installation was performed.

## Repository state

- Parent repository branch: `master`. `git status --short --branch` reports untracked `PartOne/` and `spring-petclinic/`; no remotes were listed for the parent repository.
- PetClinic is a nested Git repository, branch `main`, commit `500158f732419217507c7656904b8e6aa1bcc0d6`, remote `https://github.com/spring-projects/spring-petclinic.git`; its working tree is clean and branch reports `main...origin/main`.
- Only existing `.gitignore` found: `spring-petclinic/.gitignore`. No root `.gitignore` existed at audit time; none was added so as not to mask or stage the nested repository.
- `PartOne/init.bash` was inspected and not executed. It runs apt update, searches for and installs OpenJDK 17, installs Maven and Git, prints versions, clones Spring PetClinic, changes into it, and prints revision/log/branch/status. It then greps Java requirements, lists resource configuration, and searches PostgreSQL config references. The script contains privileged package installation and network clone operations; it is not safe to treat as a read-only audit script.

## Assignment requirements and scoring

The PDF requires a reproducible Kubernetes deployment of Spring PetClinic, Docker image, PostgreSQL primary and streaming hot-standby replica, two app replicas, Service and NGINX Ingress, self-healing, worker failure test, reporting against the replica, security and documentation. It specifies at least three Kubernetes nodes (one control plane, two workers); its suggested minimum is 2–4 CPUs/4 GiB per control plane and 2 CPUs/4 GiB per worker, while allowing justified alternatives and stating single-node is only suitable for initial learning.

Scoring: application 10, PostgreSQL primary 10, Docker image 10, cluster/workload 15, two replicas/scheduling 10, Service/NGINX Ingress 10, HA/failure tests 10, streaming replication 15, reporting 5, security/docs 5 (100 total). Up to 20 bonus points for monitoring, CI/CD, low-downtime rollout, and better PostgreSQL HA.

PetClinic commit inspected in the existing checkout requires Java 17. PostgreSQL properties use `POSTGRES_URL`, `POSTGRES_USER`, and `POSTGRES_PASS` defaults in `application-postgres.properties`; credentials should be injected, not committed.

## Resource decision and blockers

Do not create the three-node Kind cluster yet. Available RAM is 3.2 GiB, below the requested 4 GiB guideline, and `/home` has 6.4 GiB free, below the 10 GiB guideline. Docker's actual storage location/usage and cluster inventory also cannot be confirmed due to socket permission denial. The proposed layout puts Kind configuration in the workspace on `/home`, so free space on `/var` does not remove the workspace-filesystem constraint. Kind nodes share laptop CPU/RAM and do not add physical resources.

To resume safely: free at least 3.6 GiB on `/home` (preferably more), regain at least 4 GiB available RAM, and have the Docker socket permissions fixed by the machine administrator or Docker configuration owner. Then rerun Docker info/df/list commands and inspect the existing `kind-dbaas` context before creating anything. Do not change socket ownership or membership blindly: the socket is unexpectedly owned by `nobody:nogroup`, and privileged host changes require explicit review.
