# Database security

| PostgreSQL identity | Scope |
| --- | --- |
| postgres | Peer-authenticated in-container administration and authenticated bootstrap on Primary |
| petclinic_owner | NOLOGIN owner of the database and application schema objects |
| petclinic_app | Primary login for app CRUD and sequences, no DDL or replication |
| replicator | SCRAM-authenticated physical replication login |
| reporting_user | Replica login with SELECT grants, read-only session default, statement and connection limits |

PawPrint uses SCRAM for TCP authentication. The primary's HBA accepts `petclinic_app`, bootstrap `postgres` and physical `replicator` connections on their intended paths. The Replica accepts `reporting_user` over TCP and restricts administrative access to its local socket. The pull of receiver health uses a narrow SQL function with a fixed search path. The function returns status and LSN-derived metrics and omits connection strings.

Kind ships NetworkPolicy support through kindnet. PawPrint verifies that actual connection behavior by testing both directions from Reporting. The DB ingress rules require workload labels, and Reporting egress allows only DNS and the Replica. A connection test reached Replica TCP/5432 and timed out reaching Primary TCP/5432. The PostgreSQL Services are internal. [Kind NetworkPolicy release notes](https://github.com/kubernetes-sigs/kind/releases/tag/v0.24.0)

## Secret access and encryption at rest

Create the Secret with `make secrets`. It reads four hidden inputs and uses temporary mode-restricted files in RAM, then unlinks them. The application Pods receive their assigned keys through `secretKeyRef` and set `automountServiceAccountToken: false`. On 2026-11-20, Kubernetes authorization checks returned `no` for `get`, `list` and `watch` on Secrets in `pawprint` as `system:serviceaccount:pawprint:default`.

The Kind API Server had no `--encryption-provider-config` argument. Kubernetes API-level encryption at rest for Secret resources in etcd is disabled in this lab. Base64 is the encoding used for the Secret `data` field in the API. RBAC governs API access, while encryption at rest protects stored API data. Host disk encryption was outside this check. PostgreSQL connections in this loopback lab use SCRAM without a configured database TLS certificate. [Kubernetes encryption at rest](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/)

Reproduce the checks from an operator context with impersonation permission. These commands show authorization and API Server configuration without displaying Secret values.

```bash
k() { kubectl --kubeconfig "$HOME/.kube/pawprint-config" --context kind-pawprint "$@"; }
for verb in get list watch; do
  k -n pawprint auth can-i "$verb" secrets --as=system:serviceaccount:pawprint:default
done
k -n kube-system get pod kube-apiserver-pawprint-control-plane \
  -o jsonpath='{range .spec.containers[*]}{range .command[*]}{.}{"\n"}{end}{range .args[*]}{.}{"\n"}{end}{end}' |
  grep -E '^--encryption-provider-config(=|$)'
```

Expect three `no` responses and no matching encryption-provider argument for this Kind configuration.
