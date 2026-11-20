# Reporting configuration

Kubernetes supplies `PORT` via `k8s/reporting/configmap.yaml` and `REPORT_DB_PASSWORD` from the Secret. The source fixes the standby DNS name, PostgreSQL role, refresh interval and query timeout.
