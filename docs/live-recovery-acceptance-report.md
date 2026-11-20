# PawPrint live database recovery acceptance

Validation ran on 2026-11-20 Tehran time. The destructive exercise targeted `pawprint-recovery-test-restore`, a labeled disposable namespace with separate Secrets, deployments, ingress and local-path PVCs on the three-node Kind cluster. HTTP checks went through its F5 NGINX ingress via a local port-forward. The first full cutover used one PetClinic replica because initial checkout provisioning encountered memory pressure. The serving `pawprint` namespace was used for read-only preflight and verification. Raw evidence is under `.pawprint/evidence/live-recovery/` in the local workspace.

The serving Primary and Replica kept their original Pod UIDs, PVC bindings and Service selectors. PetClinic and Reporting in `pawprint` both returned HTTP 200 after the disposable cutover. See `original-preflight.log`, `original-verify.log`, and `original-final.log`.

The final sandbox checks after rollback returned a streaming pair, `RESTORE_BASELINE` on both databases, and HTTP 200 on both routes. The sandbox workloads were then scaled down to release memory while retaining every claim and the recovery journals. See `sandbox-final.log` and `sandbox-retained-claims.log`.

## Recovery architecture

The preparation Job restored to a new Primary PVC with external networking disabled. PostgreSQL provisioned the project roles, applied the existing reporting function and bootstrap metadata, restored archive contents as `petclinic_owner`, and verified the backup fingerprints and sequence state. Cutover stopped application connections and backups, fenced both original database controllers, and started a new Primary with the verified PVC. The unchanged Service names then routed to the new generation. A fresh standby claim received a physical base backup from that Primary and streamed its WAL. The journal held all changes until the required health gates completed.

## Verified cutover

- Backup ID `petclinic-20261119T225135Z-petclinic-backup-manual-20261119225057-4486-9nddh`. Archive SHA-256 `03a8cb468d1eeb4087ff0d66ccbd0304f7425d8b7fafcb02fadd61b21a044d5d`; checksum manifest SHA-256 `14eade7102dc9b3f9bd222f094ff4b0aa5322bc5131fa597af29be992fa94dd1`.
- Success journal `rd9e2392793d6`. The original Primary and Replica system ID was `7710015529258418226`. The recovered pair shared the new system ID `7710020299266404397`.
- Old and new Primary Pod UIDs were `8f10e3d0-a4c2-4e07-a1c4-3c7fded0fbe5` and `0a4381d6-cc03-48d7-8709-6b358331db0f`. Old and new Replica Pod UIDs were `699693df-f997-4f5a-b3e0-6a32e6005cad` and `15fdb0a1-d390-4755-a6e2-cc51ad781181`.
- The new Primary claim was `data-postgres-primary-rd9e2392793d6-0`, bound to PV `pvc-8cf5d2b3-96a4-4b7f-96e7-213e78212119`. The new Replica claim was `data-postgres-replica-rd9e2392793d6-0`, bound to PV `pvc-548e339e-d3c5-47f3-bc15-d65ae0436e43`. Both original claim UIDs and PV bindings still matched preflight.
- Owner `id=1` was `RESTORE_BASELINE` when the backup ran and `RESTORE_MODIFIED` on both original servers before cutover. After the Service switch, both recovered servers returned `RESTORE_BASELINE` for that owner. The HTTP Reporting API exposes aggregate counts rather than names, so the test checked the exact surname on the Replica and compared HTTP results with direct Replica queries.
- Both HTTP endpoints returned 200. PetClinic then wrote owner `11` through the real HTTP form. The Replica query matched after 801 ms, including polling. Reporting published owner `11` as `latestOwnerId` and an owner count of 11 after 23.15 s. PostgreSQL showed one asynchronous streaming sender, one standby receiver, zero sampled replay lag at `0/304FC48`, and zero Reporting sessions on Primary.

The original fingerprints before and after persistent preparation were equal, including the deliberately modified owner. The recovered Primary and standby matched the archived state before reopening PetClinic. The table below shows SHA-256 prefixes. Full values are in `success-journal.json`.

| Table | Rows before and after | Original at preflight | Backup and recovered before writes |
| --- | ---: | --- | --- |
| owners | 10 | `2473a65e3018` | `8dda86f43327` |
| pets | 13 | `6c7bc288b00a` | `6c7bc288b00a` |
| specialties | 3 | `5518e51fcdca` | `5518e51fcdca` |
| types | 6 | `10243e08e21d` | `10243e08e21d` |
| vet_specialties | 5 | `0de5d02d8bda` | `0de5d02d8bda` |
| vets | 6 | `37f98b71a4c9` | `37f98b71a4c9` |
| visits | 4 | `864051d4a4b6` | `864051d4a4b6` |

The isolated and persistent restore Jobs matched the seven tables, 21 constraints including five validated foreign keys, 15 indexes and six sequences. The serving Primary's sequence state matched the archive before creating the test owner.

## Acceptance checks

| Criterion | Status | Evidence |
| --- | --- | --- |
| Valid preflight | PASS | Existing PawPrint archive verified in an isolated Job. Sandbox archive verified on each successful start. |
| Invalid ID | PASS | Path-like input rejected before contacting the API. |
| Missing bundle | PASS | Job `restore-check-rdfd21a307092` reported a missing archive, and Make returned nonzero. |
| Corrupted checksum | PASS | Job `restore-check-r3b0ab35a76a0` rejected a damaged copy of `snapshot.tsv`. |
| Wrong current context | PASS | A disposable kubectl fixture returned `kind-unrelated`; the command aborted before cluster reads. |
| Recovery already running | PASS | A second preflight rejected the journal while the first runner was in CUTOVER. An unresolved FAILED journal also blocked it. |
| Storage preflight | PASS | The three original claims were Bound to their recorded PVs. The restore Job measured the backing filesystem before provisioning and the final database pair used two separate Bound 5 GiB claims. |
| Persistent restore and ownership | PASS | Job `restore-prepare-rd9e2392793d6` restored to a dedicated PVC, verified ownership and privileges, compared fingerprints and stopped its offline PostgreSQL server cleanly. |
| Original protected before cutover | PASS | Pod UIDs, PVC/PV bindings and actual table fingerprints matched before and after preparation. |
| Cutover and fences | PASS | Old Pod termination preceded candidate launch. An accidental sandbox scale-up of the old Primary started only the blocking init container. |
| New standby | PASS | New Pod and PVC, same system ID as recovered Primary, recovery mode on with asynchronous streaming and zero final sampled pending bytes. |
| Reporting restrictions | PASS | Actual Reporting used only the standby. TCP to Primary was blocked. SQL probes denied UPDATE, INSERT, DELETE and DDL on both servers. |
| Application recovery | PASS | PetClinic and Reporting HTTP 200, baseline surname confirmed on both DBs and an HTTP-created owner observed by Replica and Reporting. |
| Original and recovered PVCs | PASS | Original Primary, original Replica, backup, recovered Primary and recovered Replica claims remained Bound. |
| Existing regression targets | PASS | After cutover the disposable deployment scaled to two PetClinic replicas and passed `make verify`, `make test`, `make test-bootstrap`, `make test-failures`, `make backup`, and isolated `make restore BACKUP_ID=<id>`. The final backup, isolated restore and bootstrap also passed after refreshing their scripts. |
| Shell checks and Python syntax | PASS | ShellCheck at warning severity, Bash syntax checks, Python byte compilation and six recovery fault-boundary tests passed. |
| Kubernetes resource validation | PASS | The Job, claims and generated recovery controllers were accepted by Kubernetes. The coordinator's server-side dry-run validated the generated Services, StatefulSets and policies before the fault-injection cutovers. |
| Recovery against serving `pawprint` data | NOT TESTED | Destructive steps were confined to the separately provisioned namespace. |
| Host failure, unreachable-node fencing and continuous-WAL PITR | NOT TESTED | The exercise used reachable Kind nodes and a logical PostgreSQL archive. |

## Failure handling

The first terminal-confirmation attempt caught an implementation error opening the terminal in update mode. It had passed preflight and made no cutover changes. Splitting terminal reads and writes fixed it. The first confirmed attempt `r48a23e155fbc` caught an omitted `POSTGRES_USER` in the preparation Job. It stopped with `FAILED` during RESTORING, preserved its partial PVC and kept both original database controllers running without replacing their Pods. Application writers stayed stopped until `make rollback-live` completed. The provisioning variable was fixed and the full workflow reran.

The six automated safety tests in `tests/test_live_recovery.py` passed. Their fault cases assert that the coordinator stops writers and preserves fencing when initialization, archive restoration, fingerprint comparison, fencing, routing, standby rebuild or application recovery fails. The job-level archive and fingerprint cases also ran with real PostgreSQL in the sandbox:

| Fault | Status | Evidence |
| --- | --- | --- |
| Backup validation | PASS | Corrupted copy failed the real SHA-256 check. |
| Recovery initialization | PASS | Omitted provisioning variable failed a real persistent Job before cutover, and explicit rollback returned traffic. |
| Archive restoration | PASS | A copy with recomputed SHA-256 checksums contained invalid archive bytes and was rejected by real `pg_restore`. |
| Fingerprint validation | PASS | A checksum-valid bundle with a wrong owner fingerprint restored in isolation, failed the real comparison and left the running databases on their current generation. |
| Primary fencing | PASS | A denied StatefulSet patch stopped operation `recbd124a924b` before any recovered database controller started. Both applications stopped and the existing Primary remained the sole writer. Explicit rollback restored traffic. |
| Primary Service switch | PASS | The sandbox shim denied the stable Primary Service patch in operation `r92b76e5f0895`. The prior pair stayed fenced and the recovered Primary was the only writable database while both applications were stopped. Explicit rollback restored the preceding generation. |
| Replica rebuild | PASS | In operation `r1ff223e32656`, the sandbox standby received an invalid source hostname and real `pg_basebackup` failed at DNS resolution. The workflow recorded `ROLLBACK_REQUIRED` with one writer and no application Pods. Explicit rollback restored a streaming pair. |
| Application restart | PASS | For operation `r1e759294093d`, the sandbox kubectl shim rejected PetClinic rollout after the database and Reporting gates. Both application Deployments returned to zero, exactly one PostgreSQL process remained writable and explicit rollback restored the previous pair and HTTP service. |

## Timing

The backup timestamp is 22:51:35 UTC and the journal's outage clock starts at 22:56:35 UTC. The **approximate recovery point gap was five minutes**. The test deliberately committed a known edit within that gap. Reporting returned fresh data at about 22:57:58 UTC. The test observed PetClinic serving and committing the test owner at about 22:58:35 UTC. **Fully verified RTO was 2 min 25 s**, ending at 22:59:00 UTC. These are one-off local lab measurements. The rollback data and logical backup define different recovery points.

## Files

- Added `scripts/live-recovery.py`, `postgres/recovery/recover-metadata.sql`, `postgres/recovery/check-reporting-denials.sql`, and `tests/test_live_recovery.py`.
- Updated `Makefile`, shared context and database helpers, deployment and backup entry points, and the existing verification and failure-test scripts to resolve the serving generation via the stable Services.
- Updated `postgres/backup/restore.sh` and `isolated-postgres.sh` to share archive verification between disposable and persistent restoration.
- Addressed shell lint findings in the backup cleanup, bootstrap credential setup, and the host setup script.
- Updated Reporting's default host to the same-namespace Replica Service, with an optional explicit environment host.
- Added the live recovery and acceptance guides and linked them from `README.md`, `docs/deployment-guide.md`, `docs/backup-restore.md`, and `docs/recovery-guide.md`.
