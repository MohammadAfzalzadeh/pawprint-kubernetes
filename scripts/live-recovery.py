#!/usr/bin/env python3
"""Orchestrate a fenced, generation-based PawPrint PostgreSQL recovery."""

import copy
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time
import uuid
from urllib.error import HTTPError, URLError
from urllib.request import urlopen


ROOT = Path(__file__).resolve().parents[1]
BACKUP_ID = re.compile(r"petclinic-[0-9]{8}T[0-9]{6}Z-[a-z0-9-]{1,112}", re.ASCII)
GENERATION = re.compile(r"r[0-9a-f]{12}", re.ASCII)
TEST_NAMESPACE = re.compile(r"pawprint-recovery-test-[a-z0-9-]{1,20}", re.ASCII)
ROLES = ("primary", "replica")
APPS = ("petclinic", "reporting")
INSTANCE = "app.kubernetes.io/instance"
PHASE = "pawprint.io/phase"
FENCE = "pawprint.io/fenced-by"
STATE = "pawprint-live-recovery"
BACKUP_PVC = "petclinic-backups"
CRONJOB = "petclinic-backup"
PGDATA = "/var/lib/postgresql/18/docker"
MAX_WAIT = 360
IMAGE_MAJOR = 18
URL = os.environ.get("PAWPRINT_URL", "http://localhost:8080")
TERMINAL = {"VERIFIED", "ROLLED_BACK"}
FAILED = {"FAILED", "ROLLBACK_REQUIRED"}


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def utc_now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def emit(message):
    print(message, flush=True)


def poll(predicate, message, timeout=MAX_WAIT):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(2)
    raise RuntimeError(message)


def swap_labels(value, replacements):
    if isinstance(value, dict):
        return {key: swap_labels(item, replacements) for key, item in value.items()}
    if isinstance(value, list):
        return [swap_labels(item, replacements) for item in value]
    if isinstance(value, str):
        return replacements.get(value, value)
    return value


def reports_fresh():
    try:
        with urlopen(f"{URL}/api/reports/summary", timeout=5) as response:
            payload = json.load(response)
        return not payload["stale"] and payload["replicaStatus"] == "streaming"
    except (HTTPError, URLError, TimeoutError, ValueError):
        return False


def petclinic_available():
    try:
        with urlopen(URL + "/", timeout=5) as response:
            return response.status == 200
    except (HTTPError, URLError, TimeoutError):
        return False


class Cluster:
    def __init__(self):
        self.kubeconfig = str(Path.home() / ".kube/pawprint-config")
        self.namespace = os.environ.get("PAWPRINT_NAMESPACE", "pawprint")
        self.base = [os.environ.get("KUBECTL_BIN", "kubectl"), "--kubeconfig", self.kubeconfig]

    def run(self, *args, stdin=None, timeout=30, scope=True):
        command = self.base + ["--context", "kind-pawprint"]
        if scope:
            command += ["--namespace", self.namespace]
        result = subprocess.run(
            command + list(args), input=stdin, text=True, capture_output=True, timeout=timeout,
        )
        if result.returncode:
            raise RuntimeError(f"kubectl {args[0]} {args[1] if len(args) > 1 else ''} failed: {result.stderr.strip()}")
        return result.stdout.rstrip("\n")

    def check(self):
        require(Path(self.kubeconfig).is_file(), "Dedicated PawPrint kubeconfig is missing")
        context = subprocess.check_output(self.base + ["config", "current-context"], text=True).strip()
        require(context == "kind-pawprint", f"Expected current context kind-pawprint, got {context!r}")
        require(self.namespace == "pawprint" or TEST_NAMESPACE.fullmatch(self.namespace), "Unexpected namespace")
        self.run("--request-timeout=10s", "get", "--raw=/readyz", scope=False)
        namespace = self.get("namespace", self.namespace)
        require(namespace["status"]["phase"] == "Active", "Namespace is not Active")
        if self.namespace != "pawprint":
            require(namespace["metadata"].get("labels", {}).get("pawprint.io/disposable-restore-test") == "true",
                    "Namespace override requires the disposable recovery test label")
        return namespace["metadata"]["uid"]

    def get(self, kind, name=None, *, optional=False, selector=None):
        args = ["get", kind]
        if name:
            args.append(name)
        if optional:
            args.append("--ignore-not-found")
        if selector:
            args += ["-l", selector]
        output = self.run(*args, "-o", "json")
        return json.loads(output) if output else None

    def send(self, verb, obj, *, dry_run=False):
        flags = ["--dry-run=server", "--validate=strict"] if dry_run else []
        return json.loads(self.run(verb, *flags, "-f", "-", "-o", "json", stdin=json.dumps(obj)))

    def patch(self, kind, name, body, patch_type="merge"):
        return json.loads(self.run("patch", kind, name, "--type", patch_type, "-p", json.dumps(body), "-o", "json"))

    def manifest(self, path):
        template = (ROOT / path).read_text().replace("namespace: pawprint\n", f"namespace: {self.namespace}\n")
        return json.loads(self.run("create", "--dry-run=client", "--validate=false", "-f", "-", "-o", "json", stdin=template))

    def sql(self, pod, sql, *args):
        return self.run("exec", "-i", pod, "--", "gosu", "postgres", "psql", "-XqAt",
                        "-F", "\t", "-v", "ON_ERROR_STOP=1", "-d", "petclinic", *args, "-f", "-", stdin=sql, timeout=90)

    def wait_job(self, name, phase_callback=None):
        def terminal_job():
            job = self.get("job", name)
            if phase_callback and job.get("status", {}).get("active"):
                output = self.run("logs", f"job/{name}", timeout=10) if self.job_running(name) else ""
                phase_callback(output)
            for condition in job.get("status", {}).get("conditions", []):
                if condition["status"] == "True" and condition["type"] in ("Complete", "Failed"):
                    return condition["type"]
            return None

        result = poll(terminal_job, f"Job {name} did not finish. Inspect its Pods and events.", timeout=330)
        logs = self.run("logs", f"job/{name}", timeout=30)
        emit(logs)
        require(result == "Complete", f"Job {name} failed")
        return logs

    def job_running(self, name):
        return any(pod.get("status", {}).get("phase") == "Running"
                   for pod in self.get("pods", selector=f"batch.kubernetes.io/job-name={name}")["items"])

    def scale(self, kind, name, count):
        self.run("scale", f"{kind}/{name}", f"--replicas={count}")

    def rollout(self, kind, name):
        self.run("rollout", "status", f"{kind}/{name}", "--timeout=300s", timeout=315)

    def endpoints(self, alias):
        objects = self.get("endpointslices", selector=f"kubernetes.io/service-name={alias}")["items"]
        return [ep["targetRef"]["uid"] for obj in objects for ep in obj["endpoints"]
                if ep.get("conditions", {}).get("ready") and ep.get("targetRef", {}).get("kind") == "Pod"]

    def run_script(self, script, timeout=110):
        subprocess.run(["bash", f"scripts/{script}.sh"], cwd=ROOT, check=True, timeout=timeout)


def record_of(cm):
    return json.loads(cm["data"]["record.json"]) if cm else None


def plain_resource(obj, name):
    return {"apiVersion": obj["apiVersion"], "kind": obj["kind"], "metadata": {"name": name},
            "spec": copy.deepcopy(obj["spec"])}


class Recovery:
    def __init__(self, cluster, generation=None):
        self.k = cluster
        self.id = generation or f"r{uuid.uuid4().hex[:12]}"
        self.state = None
        self.journal = None
        self.phase = "PREFLIGHT"
        self.backup_job = f"restore-check-{self.id}"
        self.prep_job = f"restore-prepare-{self.id}"
        self.tools = f"restore-tools-{self.id}"

    @property
    def candidates(self):
        return {role: f"postgres-{role}-{self.id}" for role in ROLES}

    def assert_idle(self):
        previous = record_of(self.k.get("cm", STATE, optional=True))
        require(not previous or previous["phase"] in TERMINAL,
                f"Recovery {previous and previous['operation']} is active or requires review: {previous and previous['phase']}")

    def write_state(self, phase, **extra):
        self.phase = phase
        self.state.update(extra, phase=phase, updated_at=utc_now())
        self.state.setdefault("timeline", {}).setdefault(phase, utc_now())
        self.state.setdefault("history", []).append({"phase": phase, "at": utc_now()})
        cm = {"apiVersion": "v1", "kind": "ConfigMap",
              "metadata": {"name": STATE, "annotations": {PHASE: phase}},
              "data": {"record.json": json.dumps(self.state, sort_keys=True)}}
        if self.journal:
            cm["metadata"]["resourceVersion"] = self.journal["metadata"]["resourceVersion"]
        self.journal = self.k.send("replace" if self.journal else "create", cm)
        emit(f"{utc_now()} state={phase} operation={self.id}")

    def lock(self, state):
        previous = self.k.get("cm", STATE, optional=True)
        previous_state = record_of(previous)
        require(not previous_state or previous_state["phase"] in TERMINAL, "Another recovery holds the journal")
        if previous_state:
            archive = f"pawprint-recovery-{previous_state['operation']}"
            if not self.k.get("cm", archive, optional=True):
                self.k.send("create", {"apiVersion": "v1", "kind": "ConfigMap", "immutable": True,
                                      "metadata": {"name": archive}, "data": previous["data"]})
        self.journal = previous
        self.state = state
        self.write_state("PREFLIGHT")

    def claim_info(self, name):
        claim = self.k.get("pvc", name)
        spec = claim["spec"]
        require(claim["status"]["phase"] == "Bound" and spec.get("volumeName"), f"PVC {name} is not Bound")
        volume = self.k.get("pv", spec["volumeName"])
        require(volume["status"]["phase"] == "Bound" and volume["spec"]["claimRef"]["uid"] == claim["metadata"]["uid"],
                f"Unexpected PV binding for {name}")
        return {"uid": claim["metadata"]["uid"], "pv": spec["volumeName"], "capacity": claim["status"]["capacity"]["storage"],
                "storage_class": spec["storageClassName"]}

    def database(self, role):
        service = self.k.get("service", f"postgres-{role}")
        selector = service["spec"]["selector"]
        name = selector[INSTANCE]
        require(name == f"postgres-{role}" or re.fullmatch(rf"postgres-{role}-r[0-9a-f]{{12}}", name),
                f"Unexpected {role} Service selector: {name}")
        statefulset = self.k.get("sts", name)
        pod = self.k.get("pod", f"{name}-0")
        uid = pod["metadata"]["uid"]
        require(any(ref.get("controller") and ref["uid"] == statefulset["metadata"]["uid"]
                    for ref in pod["metadata"]["ownerReferences"]), f"Pod {name}-0 has unexpected owner")
        require(statefulset["spec"]["replicas"] == 1 and statefulset["status"].get("readyReplicas") == 1
                and statefulset["spec"].get("persistentVolumeClaimRetentionPolicy") == {"whenDeleted": "Retain", "whenScaled": "Retain"}
                and not statefulset["metadata"].get("annotations", {}).get(FENCE),
                f"Unexpected serving StatefulSet state: {name}")
        require(self.k.endpoints(f"postgres-{role}") == [uid], f"Service postgres-{role} must route to exactly its active Pod")
        node = pod["spec"]["nodeName"]
        self.node_ready(node)
        claim = next(item["persistentVolumeClaim"]["claimName"] for item in pod["spec"]["volumes"] if item["name"] == "data")
        require(claim == f"data-{name}-0", f"Unexpected database volume {claim}")
        return {"set": name, "set_uid": statefulset["metadata"]["uid"], "pod": f"{name}-0", "pod_uid": uid, "node": node,
                "claim": claim, "binding": self.claim_info(claim), "selector": selector,
                "image_id": pod["status"]["containerStatuses"][0]["imageID"]}

    def node_ready(self, node):
        conditions = self.k.get("node", node)["status"]["conditions"]
        require(any(c["type"] == "Ready" and c["status"] == "True" for c in conditions),
                f"Cannot verify clean database shutdown: node {node} is not Ready")

    def db_health(self, primary, replica):
        first = self.k.sql(primary, """
            SELECT current_setting('server_version_num'), system_identifier,
                   pg_is_in_recovery(), current_setting('transaction_read_only'), pg_current_wal_lsn(),
                   (SELECT count(*) FROM pg_stat_replication WHERE usename='replicator'
                    AND application_name='pawprint-replica' AND state='streaming' AND sync_state='async'),
                   (SELECT coalesce(max(replay_lsn), '0/0') FROM pg_stat_replication)
            FROM pg_control_system();
        """).split("\t")
        second = self.k.sql(replica, """
            SELECT current_setting('server_version_num'), system_identifier,
                   pg_is_in_recovery(), current_setting('transaction_read_only'),
                   pg_last_wal_receive_lsn(),pg_last_wal_replay_lsn(),
                   (SELECT status FROM pg_stat_wal_receiver)
            FROM pg_control_system();
        """).split("\t")
        require(len(first) == len(second) == 7 and first[1] == second[1], "Primary and Replica have different PostgreSQL system IDs")
        require(first[0] == second[0] and int(first[0]) // 10000 == IMAGE_MAJOR
                and first[2:4] == ["f", "off"] and first[5] == "1"
                and second[2:4] == ["t", "on"] and second[6] == "streaming",
                "Expected writable PostgreSQL 18 Primary and read-only streaming Replica")
        emit(f"Primary version={first[0]} system_id={first[1]} wal={first[4]} replay={first[6]}")
        emit(f"Replica system_id={second[1]} receive={second[4]} replay={second[5]} status={second[6]}")
        return {"version": first[0], "system_id": first[1], "primary_lsn": first[4], "replica_lsn": second[5]}

    def fingerprint(self, pod):
        return self.k.sql(pod, "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;\n"
                          + (ROOT / "postgres/backup/snapshot.sql").read_text() + "\nCOMMIT;")

    def capture(self, backup):
        namespace_uid = self.k.check()
        self.assert_idle()
        sources = {role: self.database(role) for role in ROLES}
        claims = {item["claim"]: item["binding"] for item in sources.values()}
        claims[BACKUP_PVC] = self.claim_info(BACKUP_PVC)
        for name, binding in claims.items():
            storage_class = self.k.get("storageclass", binding["storage_class"])
            require(storage_class["provisioner"] == "rancher.io/local-path"
                    and storage_class.get("volumeBindingMode") == "WaitForFirstConsumer",
                    f"PVC {name} uses an untested storage provisioner or binding mode")
        require(self.k.get("networkpolicy", "pawprint-disposable-database-isolation"),
                "Missing disposable database isolation policy")
        for name in ("postgres-primary-ingress", "postgres-replica-ingress", "reporting-egress"):
            self.k.get("networkpolicy", name)
        cron = self.k.get("cronjob", CRONJOB)
        apps = {}
        autoscaled = {obj["spec"]["scaleTargetRef"]["name"] for obj in self.k.get("hpa")["items"]}
        for app in APPS:
            deploy = self.k.get("deployment", app)
            count = deploy["spec"]["replicas"]
            require(count > 0 and deploy["status"].get("readyReplicas") == count and app not in autoscaled,
                    f"{app} must be Ready and must not have an HPA")
            app_pods = self.k.get("pods", selector=f"app.kubernetes.io/name={app}")["items"]
            apps[app] = {"count": count, "images": [c["image"] for c in deploy["spec"]["template"]["spec"]["containers"]],
                         "image_ids": sorted({c["imageID"] for p in app_pods for c in p.get("status", {}).get("containerStatuses", [])})}
            emit(f"{app}: {apps[app]}")
        primary, replica = (sources[role]["pod"] for role in ROLES)
        for role, item in sources.items():
            emit(f"{role}: {item['pod']} uid={item['pod_uid']} volume={item['binding']}")
        health = self.db_health(primary, replica)
        source_snapshot = self.fingerprint(primary)
        tables = [line for line in source_snapshot.splitlines() if line.startswith("TABLE\t")]
        require(len(tables) == 7, "Expected seven public PetClinic tables")
        emit("\n".join(tables))
        disks = [self.k.run("exec", sources[role]["pod"], "--", "bash", "-ec",
                            'du -sb "$PGDATA" | cut -f1; df -PB1 "$PGDATA" | awk \'NR==2 {print $4}\'')
                 .splitlines() for role in ROLES]
        required = 2 * max(256 * 1024**2, *(int(disk[0]) for disk in disks)) + 512 * 1024**2
        require(all(int(disk[1]) >= required for disk in disks), f"Local-path filesystem needs {required} free bytes")
        return {"operation": self.id, "backup": backup, "namespace": self.k.namespace, "namespace_uid": namespace_uid,
                "old": sources, "claims": claims, "apps": apps, "old_health": health, "source_tables": tables,
                "cron_was_suspended": cron["spec"].get("suspend", False), "required_free": required,
                "candidates": self.candidates, "prep_job": self.prep_job, "tools_configmap": self.tools,
                "cutover_started": False, "app_writes_may_have_occurred": False}

    def stage_tools(self):
        files = [
            "postgres/backup/restore.sh", "postgres/backup/isolated-postgres.sh", "postgres/backup/snapshot.sql",
            "postgres/backup/verify-sequences.sql", "postgres/backup/verify-identity.sql",
            "postgres/bootstrap/reporting.sql", "postgres/bootstrap/verify.sql", "postgres/recovery/recover-metadata.sql",
        ]
        self.k.send("create", {"apiVersion": "v1", "kind": "ConfigMap", "immutable": True,
                              "metadata": {"name": self.tools},
                              "data": {Path(path).name: (ROOT / path).read_text() for path in files}})

    def restore_job(self, state, persistent=False):
        job = self.k.manifest("postgres/backup/restore-test-job.yaml")
        job["metadata"] = {"name": self.prep_job if persistent else self.backup_job}
        pod = job["spec"]["template"]["spec"]
        container = pod["containers"][0]
        volumes = {volume["name"]: volume for volume in pod["volumes"]}
        volumes["operations"]["configMap"]["name"] = self.tools
        container["env"] = [{"name": "BACKUP_ID", "value": state["backup"]},
                            {"name": "RECOVERY_MIN_FREE_BYTES", "value": str(state["required_free"])}]
        if persistent:
            claim = f"data-{self.candidates['primary']}-0"
            pod["volumes"] += [{"name": "data", "persistentVolumeClaim": {"claimName": claim}},
                               {"name": "provision", "configMap": {"name": "postgres-primary-config"}}]
            container["volumeMounts"] += [{"name": "data", "mountPath": "/var/lib/postgresql"},
                                          {"name": "provision", "mountPath": "/provision", "readOnly": True}]
            container["env"] += [{"name": "RECOVERY_PGDATA", "value": PGDATA},
                                 {"name": "EXPECTED_BACKUP_MANIFEST", "value": state["manifest_sha256"]}]
            source = self.k.get("sts", state["old"]["primary"]["set"])["spec"]["template"]["spec"]["containers"][0]
            container["env"] += [env for env in source["env"] if "secretKeyRef" in env.get("valueFrom", {})]
            container["resources"] = copy.deepcopy(source["resources"])
            container["image"] = source["image"]
        return job

    def preflight(self, backup):
        emit(f"{utc_now()} state=PREFLIGHT backup={backup} context=kind-pawprint namespace={self.k.namespace}")
        state = self.capture(backup)
        self.stage_tools()
        self.k.send("create", self.restore_job(state))
        logs = self.k.wait_job(self.backup_job)
        match = re.search(r"^BACKUP_MANIFEST_SHA256=([0-9a-f]{64})$", logs, re.M)
        require(match and f"RESTORE_VERIFIED={backup}.backup" in logs, "Missing successful archive verification")
        state["manifest_sha256"] = match[1]
        state["backup_tables"] = [line for line in logs.splitlines() if line.startswith("restored table=")]
        require(len(state["backup_tables"]) == 7, "Backup verification did not report all seven tables")
        emit(f"PREFLIGHT_PASSED backup={backup} manifest_sha256={match[1]}")
        return state

    def same_sources(self):
        for role, item in self.state["old"].items():
            observed = self.database(role)
            require(observed == item, f"{role} identity or storage changed since preflight. Re-run preflight")
        for name, original in self.state["claims"].items():
            require(self.claim_info(name) == original, f"Claim {name} changed since preflight")
        for app, original in self.state["apps"].items():
            workload = self.k.get("deployment", app)
            require(workload["spec"]["replicas"] == original["count"] and
                    [c["image"] for c in workload["spec"]["template"]["spec"]["containers"]] == original["images"],
                    f"{app} replicas or images changed since preflight")

    def prepare(self):
        self.write_state("PREPARING")
        self.same_sources()
        original = self.k.get("pvc", self.state["old"]["primary"]["claim"])
        spec = copy.deepcopy(original["spec"])
        spec.pop("volumeName")
        claim = f"data-{self.candidates['primary']}-0"
        self.k.send("create", {"apiVersion": "v1", "kind": "PersistentVolumeClaim",
                              "metadata": {"name": claim, "labels": {"pawprint.io/recovery-operation": self.id}}, "spec": spec})
        self.write_state("RESTORING", new_primary_claim=claim)
        self.k.send("create", self.restore_job(self.state, persistent=True))

        def show_validation(logs):
            if "PERSISTENT_RESTORE_PHASE=VALIDATING" in logs and self.phase != "VALIDATING":
                self.write_state("VALIDATING")
        logs = self.k.wait_job(self.prep_job, show_validation)
        if self.phase != "VALIDATING":
            self.write_state("VALIDATING")
        restored = [line for line in logs.splitlines() if line.startswith("restored table=")]
        match = re.search(r"^RECOVERY_SYSTEM_ID=([0-9]+)$", logs, re.M)
        sequences = re.search(r"^RECOVERY_SEQUENCE_SHA256=([0-9a-f]{64})$", logs, re.M)
        require(restored == self.state["backup_tables"] and match and sequences, "Persistent restore does not match preflight")
        require(f"RESTORE_VERIFIED={self.state['backup']}.backup" in logs, "Persistent restore missing verified marker")
        self.same_sources()
        fresh_tables = [line for line in self.fingerprint(self.state["old"]["primary"]["pod"]).splitlines() if line.startswith("TABLE\t")]
        emit("Original databases kept their Pod and PVC identities through preparation.")
        self.write_state("VALIDATING", recovered_system_id=match[1], prepared_tables=restored, sequence_sha256=sequences[1],
                         original_tables_after_preparation=fresh_tables, new_primary_binding=self.claim_info(claim))
        candidates = list(self.policy_resources())
        for role in ROLES:
            candidates.extend(self.database_resources(role))
        for obj in candidates:
            self.k.send("create", obj, dry_run=True)
        emit("Server-side validation passed for recovery Services, StatefulSets, and NetworkPolicies.")

    def stop_apps(self):
        for name in APPS:
            self.k.scale("deployment", name, 0)
        for name in APPS:
            poll(lambda: not self.k.get("pods", selector=f"app.kubernetes.io/name={name}")["items"],
                 f"{name} Pods did not terminate. Do not proceed with cutover.")

    def backup_quiet(self):
        self.k.patch("cronjob", CRONJOB, {"spec": {"suspend": True}})
        def no_backups():
            return not any(j["spec"]["template"]["metadata"].get("labels", {}).get("app.kubernetes.io/name") == "petclinic-backup"
                           and not any(c["type"] in ("Complete", "Failed") and c["status"] == "True"
                                       for c in j.get("status", {}).get("conditions", []))
                           for j in self.k.get("jobs")["items"])
        poll(no_backups, "Scheduled or manually started backup Jobs did not finish")

    def fence(self, name, expected=None):
        sts = self.k.get("sts", name, optional=True)
        if not sts:
            require(not expected and not self.k.get("pod", f"{name}-0", optional=True), f"Missing controller {name}")
            return
        metadata, spec = sts["metadata"], sts["spec"]
        if expected:
            require(metadata["uid"] == expected["set_uid"], f"Unexpected UID for {name}")
        pod = self.k.get("pod", f"{name}-0", optional=True)
        if pod:
            node = pod["spec"].get("nodeName")
            if node:
                self.node_ready(node)
        else:
            node = expected["node"] if expected else None
        original_fence = metadata.get("annotations", {}).get(FENCE)
        require(original_fence in (None, self.id), f"{name} is fenced by a different operation")
        template = spec["template"]["spec"]
        init = template.get("initContainers", [])
        if not original_fence:
            require(all(c["name"] != "recovery-fence" for c in init), f"Unrecognized fence on {name}")
            blocker = {"name": "recovery-fence", "image": template["containers"][0]["image"], "imagePullPolicy": "IfNotPresent",
                       "command": ["sleep", "infinity"], "resources": {"requests": {"cpu": "1m", "memory": "4Mi"},
                                                                       "limits": {"cpu": "50m", "memory": "16Mi"}}}
            init = [blocker, *init]
        self.k.patch("sts", name, {"metadata": {"resourceVersion": metadata["resourceVersion"], "annotations": {FENCE: self.id}},
                                  "spec": {"replicas": 0, "template": {"spec": {"initContainers": init}}}})
        poll(lambda: not self.k.get("pod", f"{name}-0", optional=True), f"Timed out waiting for clean shutdown of {name}")
        if node:
            self.node_ready(node)
        self.assert_fenced(name)
        if expected:
            require(self.claim_info(expected["claim"]) == expected["binding"], f"Original claim changed for {name}")
        emit(f"FENCED={name} replicas=0 pod=absent fence_init=present")

    def assert_fenced(self, name):
        sts = self.k.get("sts", name)
        require(sts["metadata"].get("annotations", {}).get(FENCE) == self.id
                and sts["spec"]["replicas"] == 0
                and sts["spec"]["template"]["spec"].get("initContainers", [{}])[0].get("name") == "recovery-fence"
                and not self.k.get("pod", f"{name}-0", optional=True), f"{name} is not safely fenced")

    def policy_resources(self):
        replacements = {f"postgres-{role}": self.candidates[role] for role in ROLES}
        for name in ("postgres-primary-ingress", "postgres-replica-ingress", "reporting-egress"):
            policy = self.k.get("networkpolicy", name)
            obj = plain_resource(policy, f"{name}-{self.id}")
            obj["spec"] = swap_labels(obj["spec"], replacements)
            yield obj

    def database_resources(self, role):
        old = self.state["old"][role]["set"]
        candidate = self.candidates[role]
        source = self.k.get("sts", old)
        obj = plain_resource(source, candidate)
        spec = obj["spec"]
        spec["replicas"] = 1
        for claim in spec["volumeClaimTemplates"]:
            claim["metadata"].pop("creationTimestamp", None)
            if "labels" in claim["metadata"]:
                claim["metadata"]["labels"] = swap_labels(claim["metadata"]["labels"], {old: candidate})
            claim.pop("status", None)
        spec["selector"]["matchLabels"][INSTANCE] = candidate
        template = spec["template"]
        template["metadata"].get("annotations", {}).pop("kubectl.kubernetes.io/restartedAt", None)
        template["metadata"]["labels"][INSTANCE] = candidate
        pod = template["spec"]
        init = [part for part in pod.get("initContainers", []) if part["name"] != "recovery-fence"]
        pod["initContainers"] = init
        if "affinity" in pod:
            pod["affinity"] = swap_labels(pod["affinity"], {self.state["old"]["primary"]["set"]: self.candidates["primary"]})
        peer = plain_resource(self.k.get("service", spec["serviceName"]), f"{candidate}-peer")
        peer["spec"]["selector"][INSTANCE] = candidate
        spec["serviceName"] = f"{candidate}-peer"
        if role == "primary":
            postgres = pod["containers"][0]
            postgres["startupProbe"] = {"exec": {"command": ["gosu", "postgres", "pg_isready", "-d", "postgres"]},
                                        "periodSeconds": 5, "timeoutSeconds": 3, "failureThreshold": 36}
            ready_sql = "SELECT NOT pg_is_in_recovery() AND current_setting('transaction_read_only')='off'"
            postgres["readinessProbe"] = {"exec": {"command": ["bash", "-ec",
                f'[[ "$(gosu postgres psql -XqAt -d postgres -c "{ready_sql}")" == t ]]']},
                "periodSeconds": 5, "timeoutSeconds": 3, "failureThreshold": 3}
            # Always require initialized, cleanly stopped restore data before launching PostgreSQL.
            pod["initContainers"] = [{"name": "require-recovered-data", "image": postgres["image"], "imagePullPolicy": "IfNotPresent",
                                      "command": ["bash", "-ec", f"test -s {PGDATA}/PG_VERSION && test ! -e {PGDATA}/standby.signal"],
                                      "resources": {"requests": {"cpu": "5m", "memory": "8Mi"},
                                                    "limits": {"cpu": "50m", "memory": "32Mi"}},
                                      "volumeMounts": [{"name": "data", "mountPath": "/var/lib/postgresql", "readOnly": True}]}]
        return peer, obj

    def create_policy(self):
        for obj in self.policy_resources():
            self.k.send("create", obj)

    def create_database(self, role):
        for obj in self.database_resources(role):
            self.k.send("create", obj)
        self.k.rollout("sts", self.candidates[role])

    def route(self, role, destination):
        alias = f"postgres-{role}"
        service = self.k.get("service", alias)
        current = service["spec"]["selector"]
        original = self.state["old"][role]["selector"]
        candidate = original | {INSTANCE: self.candidates[role]}
        require(current in (original, candidate) and destination in (original, candidate),
                f"Unexpected selector on {alias}. Investigate the concurrent change")
        self.k.patch("service", alias, [
            {"op": "test", "path": "/metadata/resourceVersion", "value": service["metadata"]["resourceVersion"]},
            {"op": "test", "path": "/spec/selector", "value": current},
            {"op": "replace", "path": "/spec/selector", "value": destination},
        ], "json")
        uid = self.k.get("pod", f"{destination[INSTANCE]}-0")["metadata"]["uid"]
        poll(lambda: self.k.endpoints(alias) == [uid], f"{alias} does not route exclusively to {destination[INSTANCE]}")

    def cutover(self):
        self.same_sources()
        self.write_state("CUTOVER", cutover_started=True, outage_started_at=utc_now())
        self.stop_apps()
        self.backup_quiet()
        for role in ROLES:
            self.fence(self.state["old"][role]["set"], self.state["old"][role])
        self.create_policy()
        self.create_database("primary")
        pod = self.candidates["primary"] + "-0"
        require(self.k.sql(pod, "SELECT system_identifier FROM pg_control_system();") == self.state["recovered_system_id"],
                "Candidate Primary did not open the verified restored data")
        selector = self.state["old"]["primary"]["selector"] | {INSTANCE: self.candidates["primary"]}
        self.route("primary", selector)
        self.write_state("REPLICATION_RECOVERY")
        self.create_database("replica")
        selector = self.state["old"]["replica"]["selector"] | {INSTANCE: self.candidates["replica"]}
        self.route("replica", selector)
        self.verify_databases()

    def verify_databases(self):
        active = {role: self.database(role) for role in ROLES}
        require(all(active[role]["set"] == self.candidates[role] for role in ROLES), "Unexpected active database generation")
        primary, replica = (active[role]["pod"] for role in ROLES)
        poll(lambda: self.k.sql(replica, "SELECT EXISTS (SELECT FROM pg_stat_wal_receiver WHERE status='streaming');") == "t",
             "New Replica is not streaming")
        health = self.db_health(primary, replica)
        require(health["system_id"] == self.state["recovered_system_id"] != self.state["old_health"]["system_id"],
                "Active system ID does not match the verified recovery cluster")
        current_primary = self.fingerprint(primary)
        require(current_primary == self.fingerprint(replica), "Primary and Replica data/catalog fingerprints differ")
        tables = [line.replace("TABLE\t", "", 1).split("\t") for line in current_primary.splitlines() if line.startswith("TABLE\t")]
        lines = [f"restored table={table} rows={count} sha256={digest}" for table, count, digest in tables]
        require(lines == self.state["backup_tables"], "Cutover fingerprints differ from backup")
        sequence_sql = (ROOT / "postgres/backup/verify-sequences.sql").read_text()
        state = self.k.sql(primary, sequence_sql, "--single-transaction").splitlines()
        digest = hashlib.sha256(("\n".join(sorted(state)) + "\n").encode()).hexdigest()
        require(digest == self.state["sequence_sha256"], "Serving Primary sequence state differs from archive")
        sql = (ROOT / "postgres/recovery/check-reporting-denials.sql").read_text()
        for role, target in (("primary", primary), ("replica", replica)):
            self.k.sql(target, sql, "-v", f"recovery={'true' if role == 'replica' else 'false'}")
            emit(f"{role}: reporting user denied UPDATE, INSERT, DELETE and DDL")
        for role in ROLES:
            self.assert_fenced(self.state["old"][role]["set"])
            require(active[role]["binding"]["uid"] != self.state["old"][role]["binding"]["uid"],
                    f"{role} unexpectedly uses its old claim")
        self.write_state("REPLICATION_RECOVERY", active=active, recovered_health=health, cutover_tables=lines)

    def recover_application(self):
        self.write_state("APPLICATION_RECOVERY")
        self.k.scale("deployment", "reporting", self.state["apps"]["reporting"]["count"])
        self.k.rollout("deployment", "reporting")
        poll(reports_fresh, "Reporting did not become fresh on the new Replica", timeout=90)
        for script in ("verify-reporting", "verify-network", "verify-reporting-data"):
            self.k.run_script(script)
        self.write_state("APPLICATION_RECOVERY", app_writes_may_have_occurred=True, reporting_verified_at=utc_now())
        self.k.scale("deployment", "petclinic", self.state["apps"]["petclinic"]["count"])
        self.k.rollout("deployment", "petclinic")
        count = self.k.get("deployment", "petclinic")["status"].get("readyReplicas")
        require(count == self.state["apps"]["petclinic"]["count"], "PetClinic did not regain its original Ready count")
        poll(petclinic_available, "PetClinic HTTP did not come back after recovery", timeout=90)
        self.write_state("APPLICATION_RECOVERY", petclinic_http_at=utc_now())
        self.k.run_script("test-replication-data", timeout=150)
        self.k.run_script("verify-replication")
        for role in ROLES:
            self.assert_fenced(self.state["old"][role]["set"])
            self.claim_info(self.state["active"][role]["claim"])
        for name, original in self.state["claims"].items():
            require(self.claim_info(name) == original, f"Original PVC changed: {name}")
        self.k.patch("cronjob", CRONJOB, {"spec": {"suspend": self.state["cron_was_suspended"]}})
        self.write_state("VERIFIED", verified_at=utc_now())

    def fail(self, error):
        origin = self.phase
        emit(f"Failure in {origin}: {error}")
        for stop in (self.stop_apps, self.backup_quiet):
            try:
                stop()
            except (RuntimeError, subprocess.SubprocessError) as stop_error:
                emit(f"Could not verify workloads or backups stopped: {stop_error}")
        end_state = "ROLLBACK_REQUIRED" if self.state["cutover_started"] else "FAILED"
        try:
            self.write_state(end_state, failed_phase=origin, error=str(error))
        except (RuntimeError, subprocess.SubprocessError) as state_error:
            emit(f"Could not update recovery journal: {state_error}. Treat the current journal as unresolved.")
        emit(f"Inspect the journal and follow docs/live-recovery.md. Operation ID: {self.id}.")

    def run(self, state):
        require(self.k.check() == state["namespace_uid"], "Namespace changed after preflight")
        self.lock(state)
        try:
            self.prepare()
            self.cutover()
            self.recover_application()
        except (RuntimeError, OSError, LookupError, ValueError, subprocess.SubprocessError, KeyboardInterrupt) as error:
            self.fail(error)
            raise

    def unfence(self, item):
        name = item["set"]
        sts = self.k.get("sts", name)
        require(sts["metadata"]["uid"] == item["set_uid"] and self.claim_info(item["claim"]) == item["binding"],
                f"Old controller or claim changed: {name}")
        annotations = sts["metadata"].get("annotations", {})
        if FENCE in annotations:
            require(annotations[FENCE] == self.id, f"Refusing to unfence {name} from another operation")
            init = sts["spec"]["template"]["spec"].get("initContainers", [])
            require(init and init[0]["name"] == "recovery-fence", f"Fence definition changed for {name}")
            self.k.patch("sts", name, {"metadata": {"resourceVersion": sts["metadata"]["resourceVersion"], "annotations": {FENCE: None}},
                                      "spec": {"replicas": 1, "template": {"spec": {"initContainers": init[1:]}}}})
        self.k.rollout("sts", name)

    def rollback(self, namespace_uid):
        self.journal = self.k.get("cm", STATE)
        self.state = record_of(self.journal)
        require(self.state["operation"] == self.id and self.state["namespace_uid"] == namespace_uid
                and self.state["phase"] in FAILED | {"VERIFIED"}, "Rollback requires the current failed or verified operation")
        emit(f"Operation {self.id} will discard traffic to the recovered generation. "
             "Writes on that generation will not be present on the old Primary. All PVCs are preserved.")
        confirmation("ROLLBACK", self.id)
        self.write_state("ROLLING_BACK")
        try:
            self.stop_apps()
            self.backup_quiet()
            if self.k.get("job", self.prep_job, optional=True):
                poll(lambda: not self.k.job_running(self.prep_job) and any(
                    c["status"] == "True" and c["type"] in ("Complete", "Failed")
                    for c in self.k.get("job", self.prep_job)["status"].get("conditions", [])),
                    "Preparation Job has not safely stopped")
            for role in ROLES:
                self.fence(self.candidates[role])
            for role in ROLES:
                item = self.state["old"][role]
                self.unfence(item)
                self.route(role, item["selector"])
            self.db_health(*(self.state["old"][role]["pod"] for role in ROLES))
            for app in ("reporting", "petclinic"):
                self.k.scale("deployment", app, self.state["apps"][app]["count"])
                self.k.rollout("deployment", app)
            poll(reports_fresh, "Reporting did not become fresh after rollback", timeout=90)
            poll(petclinic_available, "PetClinic HTTP did not come back after rollback", timeout=90)
            for script in ("verify-reporting", "verify-network"):
                self.k.run_script(script)
            self.k.patch("cronjob", CRONJOB, {"spec": {"suspend": self.state["cron_was_suspended"]}})
            self.write_state("ROLLED_BACK")
        except (RuntimeError, OSError, LookupError, ValueError, subprocess.SubprocessError, KeyboardInterrupt) as error:
            self.fail(error)
            raise


def confirmation(action, identifier):
    try:
        with open("/dev/tty", "w", encoding="utf-8") as prompt, open("/dev/tty", encoding="utf-8") as tty:
            prompt.write(f"Type {action} {identifier} to proceed: ")
            prompt.flush()
            response = tty.readline().rstrip("\r\n")
    except OSError as error:
        raise RuntimeError("An interactive terminal is required for operator confirmation") from error
    require(response == f"{action} {identifier}", "Confirmation did not match. No cutover was attempted")


def interrupted(_signal, _frame):
    raise KeyboardInterrupt("Interrupted by operator")


def main():
    require(len(sys.argv) == 3 and sys.argv[1] in ("preflight", "run", "rollback"),
            "Usage: live-recovery.py {preflight|run|rollback} <backup-or-operation-id>")
    mode, identifier = sys.argv[1:]
    k = Cluster()
    if mode in ("run", "rollback") and k.namespace != "pawprint":
        require(re.fullmatch(r"http://(?:localhost|127\.0\.0\.1):[1-9][0-9]{0,4}", URL)
                and URL.rsplit(":", 1)[1] != "8080", "Disposable recovery tests require a separate loopback HTTP port")
    if mode == "rollback":
        require(GENERATION.fullmatch(identifier), "Invalid or missing OPERATION_ID")
        Recovery(k, identifier).rollback(k.check())
        return
    require(BACKUP_ID.fullmatch(identifier), "Invalid or missing BACKUP_ID. Use the exact ID printed by make backup")
    recovery = Recovery(k)
    state = recovery.preflight(identifier)
    if mode == "run":
        emit(f"Destructive cutover in namespace {k.namespace} using backup {identifier}. "
             "The application will be offline. Writes committed after the backup snapshot will disappear from service. "
             "The old data will be retained on its PVCs.")
        confirmation("RESTORE", identifier)
        recovery.run(state)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        main()
    except (RuntimeError, OSError, LookupError, ValueError, subprocess.SubprocessError, KeyboardInterrupt) as exc:
        sys.exit(str(exc))
