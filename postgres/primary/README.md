# PostgreSQL Primary

One PostgreSQL 18.6 StatefulSet provides the writable `petclinic` database. `postgres-primary` is its internal client Service and `postgres-primary-peer` is its headless StatefulSet Service. The 5 GiB claim is retained on scale-down and StatefulSet deletion.

```bash
make secrets
bash scripts/load-images.sh postgres
make deploy STAGES="primary bootstrap"
bash scripts/verify-database.sh
```

The image entrypoint initializes `/var/lib/postgresql/18/docker` on the first start. The PVC mounts at `/var/lib/postgresql`. The executable ConfigMap script initializes roles and grants. `petclinic_owner` owns the database and schema objects. `petclinic_app` gets CRUD and sequence rights. `replicator` gets a separate SCRAM identity scoped to physical replication. `reporting_user` gets table SELECT and can authenticate to the Replica.

The deployment generates the SQL ConfigMap directly from the nested checkout and uses a transactional, advisory-locked bootstrap Job for a new database. Existing version markers trigger read-only catalog verification. The init script only runs on a fresh PGDATA. Changes to credentials or roles on an existing database require a planned SQL change. See [deployment evidence](../../docs/postgres-primary-deployment.md).
