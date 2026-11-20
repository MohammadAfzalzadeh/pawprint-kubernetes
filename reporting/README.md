# PawPrint Reporting API

Run `bash scripts/build-images.sh reporting` from the repository root. The image contains a Python HTTP server and psycopg. The deployment reads the reporting password from the Kubernetes Secret and fixes the database destination to the PostgreSQL standby. See [API and freshness semantics](../docs/reporting-guide.md).
