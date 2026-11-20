# Container registry mirrors for Project PawPrint

This guide documents the Liara mirrors for image transfer and loading images into the local Kind cluster. It does not configure containerd or Docker, and it does not change Kubernetes manifests.

## Mirror mapping

| Liara mirror | Original registry | Example image |
|---|---|---|
| `docker-mirror.liara.ir` | Docker Hub (`docker.io`) | `postgres:18.6-trixie` |
| `quay-mirror.liara.ir` | Quay.io (`quay.io`) | `quay.io/example/image:tag` |
| `ghcr-mirror.liara.ir` | GitHub Container Registry (`ghcr.io`) | `ghcr.io/example/image:tag` |
| `k8s-mirror.liara.ir` | Kubernetes registry (`registry.k8s.io`) | `registry.k8s.io/pause:3.10` |
| `mcr-mirror.liara.ir` | Microsoft Container Registry (`mcr.microsoft.com`) | `mcr.microsoft.com/example/image:tag` |

Mirror availability, exact path rewriting, authentication, and current supported behavior are Liara service details; confirm against Liara's current documentation/account before relying on them. The examples below assume each mirror accepts the original repository path after the mirror host.

## Pull, retag, and load into Kind

Use a mirror-qualified temporary name for the pull. Then retag to the exact original image name referenced by the Kubernetes manifest. Kind nodes use their own containerd image stores, so a successful host pull alone does not make an image available in the cluster. `kind load docker-image` transfers a locally available Docker image into every node of the named Kind cluster.

### PostgreSQL example (Docker Hub)

The primary manifest currently references `postgres:18.6-trixie` with `imagePullPolicy: IfNotPresent`.

```bash
# Pull through Liara's Docker Hub mirror.
docker pull docker-mirror.liara.ir/library/postgres:18.6-trixie

# Restore the exact image name expected by the manifest.
docker tag docker-mirror.liara.ir/library/postgres:18.6-trixie postgres:18.6-trixie

# Load the image into every node in the pawprint Kind cluster.
kind load docker-image postgres:18.6-trixie --name pawprint
```

If Liara uses a different repository path convention, adjust only the mirror-qualified pull reference; retain the original tag when retagging. Never change or infer a manifest image name from a mirror URL without reviewing the deployment configuration.

### Other registry examples

```bash
# Quay.io
 docker pull quay-mirror.liara.ir/example/image:tag
 docker tag quay-mirror.liara.ir/example/image:tag quay.io/example/image:tag
 kind load docker-image quay.io/example/image:tag --name pawprint

# GitHub Container Registry
 docker pull ghcr-mirror.liara.ir/example/image:tag
 docker tag ghcr-mirror.liara.ir/example/image:tag ghcr.io/example/image:tag
 kind load docker-image ghcr.io/example/image:tag --name pawprint

# registry.k8s.io
 docker pull k8s-mirror.liara.ir/pause:3.10
 docker tag k8s-mirror.liara.ir/pause:3.10 registry.k8s.io/pause:3.10
 kind load docker-image registry.k8s.io/pause:3.10 --name pawprint

# Microsoft Container Registry
 docker pull mcr-mirror.liara.ir/example/image:tag
 docker tag mcr-mirror.liara.ir/example/image:tag mcr.microsoft.com/example/image:tag
 kind load docker-image mcr.microsoft.com/example/image:tag --name pawprint
```

Replace example repositories and tags with real images. For registries whose mirror requires a namespace prefix or authentication, use Liara's documented syntax and credentials. Do not place registry passwords in shell history or commit them.

## `imagePullPolicy: IfNotPresent`

Kubernetes checks the target node's local image store for the image reference. If that image is present, kubelet uses it without pulling; if absent, kubelet asks the node's container runtime to pull the image from the registry named in the image reference. Therefore, after retagging and loading, the manifest must still use the original reference (for example `postgres:18.6-trixie`) so its name matches the loaded tag. This policy does not trigger Liara mirror use by itself. Mirror use here happens on the host's `docker pull`; the subsequent `kind load` supplies the image to Kind nodes.

A tag can point to different content over time. Pin image digests for stronger reproducibility when the source's digest has been verified, and ensure every node receives the intended image. `IfNotPresent` does not refresh a locally cached tag automatically.

## Verify on all Kind nodes

After loading, inspect each node's containerd image list. Kind node containers have names such as `pawprint-control-plane`, `pawprint-worker`, and `pawprint-worker2`.

```bash
for node in pawprint-control-plane pawprint-worker pawprint-worker2; do
  echo "=== $node ==="
  docker exec "$node" crictl images | grep -F 'postgres'
done
```

Confirm the exact image and tag appears on all three nodes. `kind load docker-image` loads to all nodes by default. If a node is missing the image, repeat the load and check the exact tag/reference; do not alter the cluster runtime configuration.

Kubernetes-side checks after a workload is deployed (not part of this documentation task):

```bash
KUBECONFIG="$HOME/.kube/pawprint-config" kubectl get pods -n pawprint -o wide
KUBECONFIG="$HOME/.kube/pawprint-config" kubectl describe pod <pod-name> -n pawprint
```

An `ImagePullBackOff` or `ErrImageNeverPull` event can indicate an image name/tag mismatch, missing node-local image, or registry access problem. Inspect events before changing the pull policy.

## Current PostgreSQL manifest

`postgres/primary/statefulset.yaml` uses `image: postgres:18.6-trixie` and `imagePullPolicy: IfNotPresent`. This documentation task did not modify it. The recommended mirror workflow above pulls via `docker-mirror.liara.ir`, retags as `postgres:18.6-trixie`, and loads it into the `pawprint` cluster.
