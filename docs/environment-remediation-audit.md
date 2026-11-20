# Environment remediation audit (read-only)

Date: 2026-11-19. Commands were run from the Codex workspace environment. No installation, cleanup, permission change, service action, context switch, or cluster operation was performed.

## 1–3. Docker access and cluster inventory

Docker CLI is present (previous audit: 29.5.2). Current identity: `jesus`, primary group `jesus`, supplementary `nogroup`; `getent group docker` returns `docker:x:984:jesus`. Despite this host group record, the process's active groups do not include `docker`. `/var/run/docker.sock` is a Unix socket mode `0660`, owned by `nobody:nogroup` (UID/GID 65534). Therefore the current process cannot connect. This is a socket ownership/credential mismatch, but it is not possible to conclude whether the daemon itself is running: `systemctl` cannot connect to system bus in this environment.

Requested `sudo -n docker ...` reads could not run. Sudo reports `/etc/sudo.conf` owned by UID 65534 and that the `no new privileges` flag prevents privilege escalation. Consequently Docker root directory, storage consumption, containers, volumes, container labels, and daemon status remain unverified. Do not infer these facts from `/var` free space.

Kubernetes config shows current context `kind-dbaas`, cluster and user also named `kind-dbaas`, API server `https://127.0.0.1:38801`. Config credentials are present. The endpoint in kubeconfig alone does not establish a live cluster. `kubectl get nodes` was not used; even if queried, API reachability would only establish API availability, not Kind container inventory. Docker inventory could not be inspected, so existence/running state/node count of `dbaas` and existence of `pawprint` are unknown. Current context was not changed.

Docker group membership grants effective root-equivalent control of the host: a group member can typically mount host paths into containers and modify host files. Do not add a user to that group without understanding this security consequence. Possible remedies for administrator review: restore normal Docker service/socket ownership and group configuration, run Docker through a properly authorized rootless setup, or use a deliberately authorized administrative workflow. Do not `chmod` the socket ad hoc.

## 4. Memory and swap

Measured during this snapshot: 11.4 GiB RAM (`MemTotal` 11,934,736 kB), `MemAvailable` 3.02 GiB, `MemFree` 356 MiB. Swap is 3.63 GiB used of 3.73 GiB (about 97.5%); 180 MiB free. These values fluctuate.

The requested `ps` output shows only the isolated workspace's `codex` process (~19 MiB RSS) and command utilities, not the full host process table. `systemctl --type=service --state=running` failed because system bus access is prohibited. Thus no defensible attribution to Docker or development services can be made from this environment. Safest memory recovery is to inspect the full host's process/desktop workload and close user-selected, nonessential applications normally, save work first, and then remeasure. Do not kill unknown processes or disable/swapoff swap.

## 5. Storage

`df -h` in this execution environment reports `/home` 6.4 GiB free, `/var` 32 GiB free, and `/` 148 MiB free (100% used). This differs from an unrestricted host view because workspace paths are sandboxed/mounted. Inodes are not constrained (home 28%, var 6%, root 22%). Project path is under `/home`, so its relevant measured headroom is 6.4 GiB. This is below the 10 GiB planning threshold. Maven outputs and docs are usually modest, but Docker build context and downloaded layers/node images are the major variable costs; current space is insufficient for a comfortable, reproducible multi-node lab. Root at 100% is an additional concern in this reported namespace. Docker's actual data-root filesystem remains unknown because Docker inspection was blocked. If confirmed on `/var/lib/docker`, `/var` has 32 GiB free, but that alone does not solve the workspace or RAM constraints. No files, caches, images, or volumes were removed.

## 6. Git repositories

Parent repository: branch `master`, latest commit `6ce7ac4 add project requirement`, no remotes reported. Working tree has untracked `PartOne/`, `docs/`, and `spring-petclinic/`. Nested PetClinic repo is clean at `500158f732419217507c7656904b8e6aa1bcc0d6`, remote `origin` points to the upstream Spring PetClinic GitHub repository.

Keep PetClinic independent by retaining it as a separate clone outside the parent repository (or configure the parent repo to exclude the nested directory locally); avoid adding it as ordinary files. If reproducibility in the parent is desired, later decide explicitly whether to use a documented clone step or a submodule. Do not stage its contents accidentally. No Git changes were made in this diagnostic phase.

## 7. Resource feasibility (estimates, not measurements)

Measured resource availability is 3.02 GiB RAM and 6.4 GiB on the project filesystem at this snapshot. Estimated steady-state/working budgets below vary by image, Java heap, PostgreSQL settings, load, and cache; they are planning ranges, not benchmark results. They exclude the Ubuntu desktop and other host workloads, which already leave little headroom.

| Component | Estimated memory | Estimated disk | Priority |
|---|---:|---:|---|
| Kind control plane | 0.7–1.2 GiB | 1–2 GiB | Required |
| Each Kind worker (2) | 0.4–0.8 GiB | 0.5–1.5 GiB each | Required |
| PetClinic (2 replicas) | 0.4–0.8 GiB each | 0.3–0.8 GiB image shared by layers | Required |
| PostgreSQL primary | 0.25–0.6 GiB | 1–3+ GiB persistent data/WAL | Required |
| PostgreSQL replica | 0.25–0.6 GiB | 1–3+ GiB data/WAL | Required |
| Reporting API | 0.1–0.3 GiB | 0.1–0.4 GiB | Required by target |
| Ingress controller | 0.1–0.3 GiB | 0.1–0.3 GiB | Required |
| Images/build cache/logs | n/a | 5–12+ GiB | Required working space |

The combined Kubernetes/system and workload estimate is roughly 3.0–6.0 GiB before host desktop overhead and transient builds. This 3-node topology plus both DB instances is not safely feasible at the observed 3.02 GiB available RAM, near-full swap, and 6.4 GiB project-filesystem headroom. The requested 4 GiB available-RAM and 10 GiB disk gates are unmet. Do not create the cluster yet. Even after freeing memory/disk, monitor usage during staged deployment and use explicit requests/limits and conservative PostgreSQL buffers; requests do not create physical capacity.

## 8. Recommended remediation (not performed)

1. In a normal host terminal, have the administrator verify Docker daemon/socket service status and restore a supported access model. First inspect service/socket ownership and policy; avoid ad hoc `chmod`. Docker group membership is root-equivalent.
2. Run Docker inventory and storage commands from an authorized host session; record Docker root directory, usage, and all existing containers/volumes before any project work.
3. Inspect the `kind-dbaas` API and correlate it with Docker Kind labels. Treat it as potentially live until proved otherwise. Do not overwrite it or change context.
4. Free space only by reviewing files interactively and choosing user-owned data to move/remove; target >=10 GiB available on `/home` and keep ample headroom on Docker's actual data filesystem. No automated cleanup.
5. Review host applications interactively and close only selected, nonessential programs normally; remeasure RAM. Aim for >=4 GiB available RAM before creating Kind.
6. Keep PetClinic in its own repository and establish an intentional parent-repo strategy before staging.
7. Re-run the audit in a host environment where systemd and Docker state are visible. Only after all checks pass, prepare the pinned Kind config and ask before cluster creation if topology/resources remain marginal.

## Exact read-only commands for an authorized host terminal

These are diagnostics only; they have not been executed with privilege here:

```sh
id; groups; getent group docker
stat /var/run/docker.sock; ls -l /var/run/docker.sock
systemctl is-active docker
systemctl status docker --no-pager
systemctl status docker.socket --no-pager
sudo docker info
sudo docker info --format '{{.DockerRootDir}}'
sudo docker system df -v
sudo docker ps -a
sudo docker volume ls
sudo docker ps -a --filter label=io.x-k8s.kind.cluster --format 'table {{.Names}}\t{{.Status}}\t{{.Labels}}'
sudo docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Labels}}'
kubectl config get-contexts
kubectl config current-context
kubectl get nodes -o wide
free -h; swapon --show; ps -eo pid,ppid,comm,rss,%mem --sort=-rss | head -20
systemctl --type=service --state=running
df -h; df -ih
git status --short; git remote -v; git log -1 --oneline
git -C spring-petclinic status --short
git -C spring-petclinic rev-parse HEAD
git -C spring-petclinic remote -v
```

No remediation commands are included here; this report does not authorize system changes.
