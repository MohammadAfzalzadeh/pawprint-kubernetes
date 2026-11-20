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

Create the Secret with `make secrets`. It reads four hidden inputs and uses temporary mode-restricted files in RAM, then unlinks them. Avoid inspecting complete Secret objects in shared logs. Namespace RBAC and control-plane storage still determine access to Secrets. TCP in this loopback lab uses SCRAM without a configured database TLS certificate.
