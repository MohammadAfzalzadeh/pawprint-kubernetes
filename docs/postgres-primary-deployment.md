# PostgreSQL Primary deployment

The PawPrint API was reachable using the dedicated kubeconfig. All three nodes reported Ready. The `standard` StorageClass uses `rancher.io/local-path`, `WaitForFirstConsumer` and reclaim policy `Delete`. The primary claim binds to `pawprint-worker`. The StatefulSet retains the claim when scaled or deleted. PVC deletion can reclaim local data.

The existing PostgreSQL 18.6 Trixie image was loaded through Liara on all three nodes. PostgreSQL reported `18.6 (Debian 18.6-1.pgdg13+2)`. The primary used `/var/lib/postgresql/18/docker`, WAL level `replica`, five WAL senders and five slots. Credentials were set via the hidden prompts. The bootstrap Job checked the seven expected tables, five foreign keys, 15 indexes and 10 seeded owners. It verified that the app role can insert and use the identity sequence, and that the reporting login can select and lacks write or schema creation grants.

```bash
make secrets
bash scripts/load-images.sh postgres
make deploy STAGES="primary bootstrap"
bash scripts/verify-database.sh
bash scripts/test-persistence.sh primary
```

The first schema Job failed because Kubernetes translated the unescaped double-dollar SQL delimiter before invoking Bash. The retry uses a named dollar quote. The transaction rolled back the first attempt, and `petclinic-schema-bootstrap-v2` loaded the original SQL successfully. See [acceptance evidence](acceptance-report.md) for current verification.

The current deployment stage verifies the marker and catalog on initialized clusters. It uses the mounted SQL and v3 Job only for fresh provisioning. The SQL carries the schema guard, seed files, reporting function and version marker in one transaction. `make test-bootstrap` exercises creation, repeat and rejection on isolated databases.
