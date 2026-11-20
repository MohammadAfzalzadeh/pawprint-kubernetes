#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "$0")/common.sh"
check_cluster
docker info --format 'Docker {{.ServerVersion}} at {{.DockerRootDir}}'
docker ps -a
"$KIND_BIN" get clusters
k get nodes -o wide
k wait node --all --for=condition=Ready --timeout=10s
k get pods -A
k get namespaces
k get storageclass standard
k get pv,pvc -A
free -h
swapon --show
df -h / /home /var
docker system df
cat /proc/pressure/memory
