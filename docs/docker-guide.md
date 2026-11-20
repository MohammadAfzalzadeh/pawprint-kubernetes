# Image builds and Kind imports

The PetClinic checkout declares Java 17 and Spring Boot 4.1.0. Maven Wrapper 3.3.4 selects Maven 3.9.16. The Docker build uses the wrapper to package the executable JAR. Integration tests are skipped during packaging because some upstream tests require Docker. The runtime uses the JRE image, UID 10001, an exec-form Java entrypoint and a container-aware heap limit. Docker-specific ignore files restrict the root build context to the audited build inputs. The checkout also has a development container Dockerfile and Compose examples for MySQL and PostgreSQL.

```bash
make build
make load
docker image inspect pawprint/petclinic:500158f73241 --format '{{.Id}} {{.Os}}/{{.Architecture}}'
docker image inspect pawprint/reporting:1.0.0 --format '{{.Id}} {{.Os}}/{{.Architecture}}'
```

PostgreSQL uses `postgres:18.6-trixie` from Liara. The observed mirror digest is `sha256:e3d24f6906d0760bf4da0dae872415391ededefad23fd471c47dc53b0ddf3c42`. NGINX uses the `nginx/nginx-ingress:5.8.0` release. The image loading script prints source digests and image IDs from each Kind node. Use the original image name and `IfNotPresent` in workload manifests. See [registry mirrors](image-registry-mirrors.md).

A workstation with access to a shared registry can publish the built app tags there and configure the workload image reference and registry Secret accordingly. The lab uses Kind image imports for all three nodes.

The live PetClinic image was built with the checked-in multi-stage Dockerfile using a local Ubuntu OpenJDK 17.0.21.1 builder on Trixie while the mirror's Temurin JDK layers downloaded. The final stage used the pinned Temurin JRE. Both images were exercised on the local Kind cluster. See [image IDs and build evidence](acceptance-report.md).
