# Network boundaries

`database.yaml` restricts ingress to PostgreSQL and limits reporting egress to Replica and CoreDNS. The local Kind cluster runs kindnet. Apply with `make deploy STAGES=network` and test with `bash scripts/verify-network.sh`. The Pod CIDR must match the DB HBA configuration.
