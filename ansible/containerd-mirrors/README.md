# Ansible: Kind containerd registry mirrors

This playbook writes containerd `hosts.toml` files inside all node containers of a Kind cluster. Kubernetes manifests can continue using original registry image names. The mirror is tried first; `server` is the upstream fallback. See [Kind registry guidance](https://kind.sigs.k8s.io/docs/user/private-registries) and [containerd hosts configuration](https://github.com/containerd/containerd/blob/main/docs/hosts.md).

The playbook uses local `kind` and `docker` commands; it does not use sudo, edit Docker daemon configuration, alter Kubernetes resources/kubeconfig, or restart Docker/containerd. Run it on the Ubuntu host with access to the Kind node containers.

## Requirements and check

Install Ansible on the host if needed. Verify the CLIs and cluster:

```bash
ansible-playbook --version
kind get nodes --name pawprint
docker ps --filter label=io.x-k8s.kind.cluster=pawprint
```

## Configure mirrors

Edit `vars.yml`. Each item defines the original registry, upstream server, and ordered mirror endpoints:

| Original registry | Upstream fallback | Default mirror |
|---|---|---|
| `docker.io` | `https://registry-1.docker.io` | `https://docker-mirror.liara.ir` |
| `quay.io` | `https://quay.io` | `https://quay-mirror.liara.ir` |
| `ghcr.io` | `https://ghcr.io` | `https://ghcr-mirror.liara.ir` |
| `registry.k8s.io` | `https://registry.k8s.io` | `https://k8s-mirror.liara.ir` |
| `mcr.microsoft.com` | `https://mcr.microsoft.com` | `https://mcr-mirror.liara.ir` |

Replace a URL in `mirrors` to change it. Add more mirror URLs in preferred order to define a chain. Keep `server` set to the original registry for fallback. Remove a registry entry to leave it unconfigured. The playbook assumes HTTPS endpoints preserving repository paths; confirm Liara's path and authentication requirements.

Example:

```yaml
- registry: docker.io
  server: https://registry-1.docker.io
  mirrors:
    - https://first-mirror.example
    - https://second-mirror.example
```

## Run

From the project root on the Ubuntu host:

```bash
ansible-playbook \
  -i ansible/containerd-mirrors/inventory.ini \
  ansible/containerd-mirrors/site.yml
```

The playbook discovers nodes with `kind get nodes --name pawprint`; the cluster name is configurable in `vars.yml`. It writes every configured registry file to each discovered node. Re-run it after changing variables or recreating a node. It overwrites matching `hosts.toml` files; inspect and save existing contents first.

## Verify

```bash
for node in $(kind get nodes --name pawprint); do
  echo "=== $node ==="
  docker exec "$node" sh -c \
    'for f in /etc/containerd/certs.d/*/hosts.toml; do echo "--- $f"; cat "$f"; done'
done
```

Test CRI pulls on every node:

```bash
for node in $(kind get nodes --name pawprint); do
  echo "=== $node ==="
  docker exec "$node" crictl pull docker.io/library/postgres:18.6-trixie
done
```

A successful pull proves the node can retrieve the image through its configured registry path, but does not identify whether the mirror or fallback served it. With `imagePullPolicy: IfNotPresent`, kubelet uses an image cached under the manifest's exact image reference on that node; otherwise containerd pulls using the mirror/fallback configuration. Keep manifest image references unchanged.

## Rollback

Restore previous contents of affected `hosts.toml` files on every node, or remove only the individual registry file if it did not exist before. Do not remove the full `certs.d` directory. The playbook deploys no Kubernetes resources.
