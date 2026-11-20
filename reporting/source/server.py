"""Read-only PawPrint reports sampled periodically from the PostgreSQL standby."""
import json
import os
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer

import psycopg

REPLICA = os.environ.get("REPORT_DB_HOST", "postgres-replica")
INTERVAL = 30
MAX_CACHE_AGE = 65
REPORTS = {"owners", "pets", "vets", "visits", "pet-types", "summary", "status"}
COUNTS = """
SELECT (SELECT count(*) FROM owners), (SELECT count(*) FROM pets),
       (SELECT count(*) FROM vets), (SELECT count(*) FROM visits),
       (SELECT max(id) FROM owners)
"""
PET_TYPES = """
SELECT t.name, count(p.id)
FROM types t LEFT JOIN pets p ON p.type_id = t.id
GROUP BY t.id, t.name ORDER BY t.name
"""
lock = threading.Lock()
state = {"snapshot": None, "updated_at": 0.0, "connected": False}


def refresh():
    connection = None
    next_refresh = time.monotonic()
    while True:
        try:
            if connection is None:
                connection = psycopg.connect(
                    host=REPLICA, port=5432, dbname="petclinic", user="reporting_user",
                    password=os.environ["REPORT_DB_PASSWORD"], connect_timeout=3,
                    options="-c default_transaction_read_only=on -c statement_timeout=3000",
                    application_name="pawprint-reporting",
                )
                connection.read_only = True
            with connection.transaction(), connection.cursor() as cursor:
                cursor.execute("SELECT * FROM pawprint_meta.replica_health()")
                recovery, streaming, receipt, replay, pending_bytes = cursor.fetchone()
                now = datetime.now(timezone.utc)
                if not recovery or not streaming or not receipt or (now - receipt).total_seconds() > MAX_CACHE_AGE:
                    raise RuntimeError("standby stream unavailable or stale")
                cursor.execute(COUNTS)
                owners, pets, vets, visits, latest_owner_id = cursor.fetchone()
                cursor.execute(PET_TYPES)
                types = [{"type": name, "count": count} for name, count in cursor.fetchall()]
            snapshot = {
                "generatedAt": now.isoformat(),
                "dataFreshnessAt": replay.isoformat() if replay else None,
                "lastWalMessageAt": receipt.isoformat(),
                "replayPendingBytes": pending_bytes,
                "data": {"owners": owners, "pets": pets, "vets": vets, "visits": visits,
                         "pet-types": types, "latestOwnerId": latest_owner_id},
            }
            with lock:
                state.update(snapshot=snapshot, updated_at=time.monotonic(), connected=True)
        except (psycopg.Error, RuntimeError, OSError) as error:
            with lock:
                state["connected"] = False
            if connection is not None:
                connection.close()
                connection = None
            print(f"Report refresh degraded ({type(error).__name__})", flush=True)
        next_refresh += INTERVAL
        time.sleep(max(0, next_refresh - time.monotonic()))


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/healthz":
            self.reply(200, {"status": "up"})
            return
        prefix = "/api/reports/"
        report = self.path.removeprefix(prefix)
        if not self.path.startswith(prefix) or report not in REPORTS:
            self.reply(404, {"error": "not found"})
            return
        with lock:
            snapshot, updated_at, connected = state["snapshot"], state["updated_at"], state["connected"]
        stale = not connected or time.monotonic() - updated_at > MAX_CACHE_AGE
        payload = dict(snapshot) if snapshot else {
            "generatedAt": None, "dataFreshnessAt": None, "lastWalMessageAt": None,
            "replayPendingBytes": None, "data": None,
        }
        if report == "status":
            payload["data"] = None
        elif report != "summary" and snapshot:
            payload["data"] = snapshot["data"][report]
        payload.update(replicaStatus="degraded" if stale else "streaming",
                       stale=stale, degraded=stale, refreshSeconds=INTERVAL)
        self.reply(503 if stale else 200, payload)

    def reply(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass


class ReportServer(HTTPServer):
    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(5)
        return connection, address


if __name__ == "__main__":
    threading.Thread(target=refresh, daemon=True).start()
    with ReportServer(("0.0.0.0", int(os.getenv("PORT", "8080"))), Handler) as server:
        server.serve_forever()
