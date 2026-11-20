"""Exercise the recovery ordering and failure journal without editing a cluster."""

import importlib.util
from pathlib import Path
import unittest
from unittest.mock import Mock


source = Path(__file__).resolve().parents[1] / "scripts/live-recovery.py"
spec = importlib.util.spec_from_file_location("live_recovery", source)
recovery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recovery)


class CutoverFaults(unittest.TestCase):
    def setUp(self):
        self.kube = Mock()
        self.kube.sql.return_value = "new-system"
        self.operation = recovery.Recovery(self.kube, "r111111111111")
        self.operation.state = {
            "namespace_uid": "namespace-uid",
            "old": {role: {"set": f"postgres-{role}", "selector": {recovery.INSTANCE: f"postgres-{role}"}}
                    for role in recovery.ROLES},
            "cutover_started": False,
            "recovered_system_id": "new-system",
        }
        self.kube.check.return_value = "namespace-uid"
        self.old_running = {"postgres-primary", "postgres-replica"}
        self.new_running = set()
        self.writes_enabled = True
        self.log = []
        self.operation.same_sources = Mock()
        self.operation.create_policy = Mock()
        self.operation.backup_quiet = Mock()
        self.operation.verify_databases = Mock()

        def phase(name, **data):
            self.operation.phase = name
            self.operation.state.update(data)
            self.log.append(name)

        def stop_apps():
            self.writes_enabled = False
            self.log.append("apps stopped")

        def fence(name, _identity):
            self.assertFalse(self.writes_enabled)
            self.old_running.remove(name)

        def start(role):
            self.assertFalse(self.old_running, "Old database controllers still running")
            self.assertFalse(self.writes_enabled)
            self.new_running.add(role)

        def route(role, _selector):
            self.assertIn(role, self.new_running)
            self.log.append(f"routed {role}")

        self.operation.write_state = phase
        self.operation.stop_apps = stop_apps
        self.operation.fence = fence
        self.operation.create_database = start
        self.operation.route = route

    def invoke(self):
        self.operation.lock = Mock()
        self.operation.prepare = Mock()
        self.operation.recover_application = Mock()
        self.operation.run(self.operation.state)

    def test_success_orders_fencing_before_primary_and_replica(self):
        self.invoke()
        self.assertEqual(self.old_running, set())
        self.assertEqual(self.new_running, {"primary", "replica"})
        self.assertLess(self.log.index("routed primary"), self.log.index("routed replica"))
        self.operation.recover_application.assert_called_once()

    def test_primary_fence_failure_does_not_start_candidate(self):
        self.operation.fence = Mock(side_effect=RuntimeError("Fence failed"))
        with self.assertRaisesRegex(RuntimeError, "Fence failed"):
            self.invoke()
        self.assertEqual(self.new_running, set())
        self.assertFalse(self.writes_enabled)
        self.assertEqual(self.operation.phase, "ROLLBACK_REQUIRED")

    def test_route_failure_does_not_restart_fenced_primary(self):
        self.operation.route = Mock(side_effect=RuntimeError("Route failed"))
        with self.assertRaisesRegex(RuntimeError, "Route failed"):
            self.invoke()
        self.assertEqual(self.old_running, set())
        self.assertEqual(self.new_running, {"primary"})
        self.assertFalse(self.writes_enabled)
        self.assertEqual(self.operation.phase, "ROLLBACK_REQUIRED")

    def test_replica_rebuild_failure_keeps_writes_stopped(self):
        start = self.operation.create_database

        def fail_replica(role):
            if role == "replica":
                raise RuntimeError("Base backup failed")
            start(role)

        self.operation.create_database = fail_replica
        with self.assertRaisesRegex(RuntimeError, "Base backup failed"):
            self.invoke()
        self.assertEqual(self.old_running, set())
        self.assertEqual(self.new_running, {"primary"})
        self.assertFalse(self.writes_enabled)
        self.assertEqual(self.operation.state["failed_phase"], "REPLICATION_RECOVERY")

    def test_preparation_failures_never_fence_old_primary(self):
        for phase, error in (("PREPARING", "initdb"), ("RESTORING", "archive"), ("VALIDATING", "fingerprint")):
            with self.subTest(phase=phase):
                def prepare():
                    self.operation.phase = phase
                    raise RuntimeError(error)

                self.operation.lock = Mock()
                self.operation.prepare = prepare
                with self.assertRaisesRegex(RuntimeError, error):
                    self.operation.run(self.operation.state)
                self.assertEqual(self.new_running, set())
                self.assertEqual(self.old_running, {"postgres-primary", "postgres-replica"})
                self.assertFalse(self.writes_enabled)
                self.assertEqual(self.operation.phase, "FAILED")
                self.assertEqual(self.operation.state["failed_phase"], phase)

    def test_application_failure_rescales_writers_to_zero(self):
        self.operation.lock = Mock()
        self.operation.prepare = Mock()

        def failed_restart():
            self.operation.write_state("APPLICATION_RECOVERY", app_writes_may_have_occurred=True)
            self.writes_enabled = True
            raise RuntimeError("Application failed")

        self.operation.recover_application = failed_restart
        with self.assertRaisesRegex(RuntimeError, "Application failed"):
            self.operation.run(self.operation.state)
        self.assertEqual(self.old_running, set())
        self.assertEqual(self.new_running, {"primary", "replica"})
        self.assertFalse(self.writes_enabled)
        self.assertEqual(self.operation.phase, "ROLLBACK_REQUIRED")
        self.assertTrue(self.operation.state["app_writes_may_have_occurred"])


if __name__ == "__main__":
    unittest.main()
