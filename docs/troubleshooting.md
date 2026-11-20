# Troubleshooting

| Symptom | Check and response |
| --- | --- |
| kubectl tries localhost:8080 for the API | Inspect the dedicated file with `kubectl --kubeconfig "$HOME/.kube/pawprint-config" config get-contexts`. An earlier empty file caused this fallback. Confirm the existing cluster has its own context. |
| Missing image on a node | Use `bash scripts/load-images.sh COMPONENT` and check `crictl inspecti` against the original tag via docker exec. Confirm registry, tag, digest and AMD64 availability if a mirror stalls. |
| PVC Pending | Inspect `kubectl describe pvc` and Pod scheduling. `WaitForFirstConsumer` allows local provisioning only after a node is chosen. |
| Primary fails on a new volume | Inspect startup and previous container logs. Check Secret key names, permissions and role bootstrap. A partially initialized PGDATA requires investigation before any restart or retry. |
| Replica setup fails | Inspect the base-backup init logs and HBA. The staged data is preserved. Check PGDATA, `standby.signal`, passfile permissions and WAL availability. |
| Reporting returns 503 | Inspect the reporting log, receiver state and `pg_stat_activity`. Confirm last WAL message time and replay state. |
| HTTP works in cluster but not on host | Inspect `docker port pawprint-control-plane`, controller NodePorts and Ingress events. The correct mapping is 8080 to 30080. |
| Host memory pressure | Observe `free -h`, `vmstat` and memory PSI. Start components sequentially and wait for stable measurements. |

The loopback demo Ingress disables its default HTTPS redirect. PetClinic uses relative redirects so port 8080 remains in the browser's origin. The management listener uses port 8081 and the Ingress Service routes only to 8080.
