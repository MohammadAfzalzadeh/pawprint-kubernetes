#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "$0")/common.sh"
check_cluster

source_data=$(ns exec -i deploy/reporting -- python - <<'PY'
import json
import os

import psycopg

with psycopg.connect(
    host=os.environ.get("REPORT_DB_HOST", "postgres-replica"),
    dbname="petclinic",
    user="reporting_user",
    password=os.environ["REPORT_DB_PASSWORD"],
    connect_timeout=3,
    options="-c statement_timeout=3000",
    autocommit=True,
) as conn:
    recovery, read_only = conn.execute(
        "SELECT pg_is_in_recovery(), current_setting('transaction_read_only')"
    ).fetchone()
    if not recovery or read_only != "on":
        raise SystemExit("Reporting role is not connected to a read-only standby")
    with conn.transaction():
        counts = conn.execute("""
            SELECT (SELECT count(*) FROM owners), (SELECT count(*) FROM pets),
                   (SELECT count(*) FROM vets), (SELECT count(*) FROM visits),
                   (SELECT max(id) FROM owners)
        """).fetchone()
        types = conn.execute("""
            SELECT t.name, count(p.id)
            FROM types t LEFT JOIN pets p ON p.type_id=t.id
            GROUP BY t.id,t.name ORDER BY t.name
        """).fetchall()
    try:
        # Even if misconfigured, a zero-row UPDATE changes no application rows.
        conn.execute("UPDATE owners SET first_name=first_name WHERE false")
    except (psycopg.errors.ReadOnlySqlTransaction, psycopg.errors.InsufficientPrivilege) as exc:
        denied = exc.sqlstate
    else:
        raise SystemExit("UPDATE was unexpectedly allowed for reporting_user")
    data = dict(zip(("owners", "pets", "vets", "visits", "latestOwnerId"), counts))
    data["pet-types"] = [{"type": name, "count": count} for name, count in types]
    print(json.dumps({"data": data, "writeDeniedSqlstate": denied}))
PY
)

url=$(pawprint_http_url)
python3 - "$source_data" "$url" <<'PY'
import json
import sys
import time
from urllib.request import urlopen

expected = json.loads(sys.argv[1])
deadline = time.monotonic() + 40
while time.monotonic() < deadline:
    with urlopen(sys.argv[2] + "/api/reports/summary", timeout=5) as response:
        report = json.load(response)
    if not report["stale"] and report["replicaStatus"] == "streaming" and report["data"] == expected["data"]:
        print("Fresh HTTP report equals Replica queries as reporting_user.")
        print("Zero-row UPDATE rejected with SQLSTATE", expected["writeDeniedSqlstate"])
        break
    time.sleep(2)
else:
    raise SystemExit("HTTP report did not match the sampled Replica data")
PY
