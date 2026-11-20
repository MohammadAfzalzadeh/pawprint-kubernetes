# Kind cluster: pawprint

## Purpose and topology

Kind runs Kubernetes nodes as Docker containers, making it suitable for a local development and demonstration cluster without virtual machines. The planned cluster has one control-plane node and two workers, so workloads can be scheduled across workers and worker-node behavior can be demonstrated. Kind nodes share the host's CPU, memory, and disk; they do not add physical resources.

Configuration file: [`kind-pawprint.yaml`](../kind-pawprint.yaml)

- Kind CLI version: `v0.33.0`
- Kubernetes node image: `kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5`
- Topology: 1 control plane (`pawprint-control-plane`), 2 workers (`pawprint-worker`, `pawprint-worker2`)
- Networking: Kind default CNI remains enabled.
- Dedicated kubeconfig: `$HOME/.kube/pawprint-config`; the global kubeconfig and its existing `kind-dbaas` context are not used by these commands.

## Host port mapping

The control-plane container maps loopback host ports for a future Ingress NodePort Service:

| Host address | Control-plane container port | Protocol | Intended NodePort |
|---|---:|---|---:|
| `127.0.0.1:8080` | `30080` | TCP | HTTP |
| `127.0.0.1:8443` | `30443` | TCP | HTTPS |

No Ingress Controller or application is installed by this configuration. The eventual Ingress Service must use NodePorts `30080` and `30443` for these mappings to route traffic.

## Create from the real Ubuntu host terminal

These commands are for execution from the host terminal, not the restricted Codex execution environment. They create/use only the dedicated kubeconfig path and leave the global context untouched. Kind creates parent directories for the kubeconfig as needed; the explicit `mkdir` prepares it first.

```bash
mkdir -p "$HOME/.kube"
chmod 700 "$HOME/.kube"
touch "$HOME/.kube/pawprint-config"
chmod 600 "$HOME/.kube/pawprint-config"
KUBECONFIG="$HOME/.kube/pawprint-config" kind create cluster \
  --name pawprint \
  --config "$PWD/kind-pawprint.yaml" \
  --image kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5 \
  --wait 180s
```

Run from the project root so `$PWD/kind-pawprint.yaml` resolves correctly. Kind may add the cluster context to the dedicated kubeconfig only. The `chmod` commands apply appropriate owner-only access to the kubeconfig directory and file; review this if local organizational policy requires different modes.

## Verify

```bash
export KUBECONFIG="$HOME/.kube/pawprint-config"
kind get clusters
kubectl config get-contexts
kubectl config current-context
kubectl cluster-info
kubectl get nodes -o wide
kubectl get pods -A
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.nodeInfo.kubeletVersion}{"\n"}{end}'
```

Expected nodes are one control plane and two workers, all reporting Kubernetes `v1.37.0` and reaching `Ready`. Confirm CoreDNS and other system pods are Ready with `kubectl get pods -A`. To check host resource use, run `docker stats --no-stream`, `free -h`, `swapon --show`, and `df -h / /var` in the host terminal after startup.

## Safe deletion

First confirm the dedicated kubeconfig and target cluster:

```bash
export KUBECONFIG="$HOME/.kube/pawprint-config"
kind get clusters
kubectl config current-context
```

When intentionally removing this lab cluster, run:

```bash
KUBECONFIG="$HOME/.kube/pawprint-config" kind delete cluster --name pawprint
```

This removes the Kind node containers for `pawprint`. Do not use Docker prune commands. This does not request deletion of the global kubeconfig or the existing `kind-dbaas` context. Keep the dedicated kubeconfig unless you separately decide to remove it.

## Status

This document describes the planned configuration. No cluster was created and no kubeconfig was modified during preparation. Record actual node readiness and host resource measurements here after running the host commands.
