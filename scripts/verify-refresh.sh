#!/usr/bin/env bash
set -euo pipefail
python3 - "${PAWPRINT_URL:-http://localhost:8080}" <<'PY'
import json
import sys
import time
from datetime import datetime
from urllib.request import urlopen

url = sys.argv[1] + "/api/reports/status"

def sample():
    with urlopen(url, timeout=5) as response:
        data = json.load(response)
    if data["stale"]:
        raise SystemExit("Reporting is degraded during refresh verification")
    return data["generatedAt"]

first = sample()
deadline = time.monotonic() + 38
while time.monotonic() < deadline:
    time.sleep(1)
    current = sample()
    if current != first:
        difference = (datetime.fromisoformat(current) - datetime.fromisoformat(first)).total_seconds()
        print(f"Refresh timestamps {first} -> {current}; interval {difference:.3f}s")
        if abs(difference - 30) > 2:
            raise SystemExit("Observed interval is outside the 30-second tolerance")
        break
else:
    raise SystemExit("Report snapshot did not refresh within 38 seconds")
PY
