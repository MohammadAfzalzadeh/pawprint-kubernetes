# PetClinic on the host and in Docker

On 2026-11-20, PetClinic returned HTTP 200 when run directly on the Ubuntu host and when run as a standalone Docker container. The Docker run used the same image ID as both Kind workers. Both runs used the default Spring profile with an in-memory H2 datasource and sample data.

| Run | Build or image | Browser endpoint | Result |
| --- | --- | --- | --- |
| Host JVM | Maven-built `spring-petclinic-4.0.0-SNAPSHOT.jar` from commit `500158f732419217507c7656904b8e6aa1bcc0d6` | `http://127.0.0.1:18081/` | HTTP 200 |
| Standalone Docker | `pawprint/petclinic:500158f73241` | `http://127.0.0.1:18082/` | HTTP 200 and image ID matched on both Kind workers |

## Build with Maven and run on the host

From the PawPrint repository root, verify the nested PetClinic checkout and package it using Java 17. The recorded build used OpenJDK 17.0.21.1 and Spring Boot 4.1.0. Maven built and repackaged the executable JAR with `BUILD SUCCESS`. The `-DskipTests` option skips the upstream test suite for this packaging and HTTP smoke test. [Build command, commit and Java version](images/standalone/Screenshot%20from%202026-11-20%2019-10-55.png) · [Maven build result](images/standalone/Screenshot%20from%202026-11-20%2019-11-34.png)

```bash
cd spring-petclinic
git rev-parse HEAD
java -version
./mvnw -B -ntp -DskipTests package
```

Start the packaged JAR in the same terminal. Tomcat started on port `18081`, and the runtime log recorded a `jdbc:h2:mem:` connection. [Java launch command](images/standalone/Screenshot%20from%202026-11-20%2019-12-14.png) · [H2 connection and startup](images/standalone/Screenshot%20from%202026-11-20%2019-12-53.png)

```bash
java -jar target/spring-petclinic-4.0.0-SNAPSHOT.jar \
  --spring.profiles.active=default \
  --server.address=127.0.0.1 \
  --server.port=18081
```

In a second terminal, the following request printed `Native PetClinic HTTP 200`. The browser showed the PetClinic welcome page on the same port. [HTTP check](images/standalone/Screenshot%20from%202026-11-20%2019-10-17.png)

```bash
curl -fsS --max-time 10 -o /dev/null \
  -w 'Native PetClinic HTTP %{http_code}\n' http://127.0.0.1:18081/
```

![PetClinic welcome page served by the host JVM at 127.0.0.1 port 18081](images/standalone/Screenshot%20from%202026-11-20%2019-09-26.png)

Stop the host process with `Ctrl+C` after collecting the result.

## Run the Kubernetes image with Docker

Run the existing image from the local Docker image store. `--pull=never` pins this test to the locally loaded image. Docker maps host loopback port `18082` to Tomcat's container port `8080`. The startup log showed the default profile, an H2 connection and the application ready on the container port. [Docker run command](images/docker/Screenshot%20from%202026-11-20%2019-15-18.png) · [Container startup and H2 connection](images/docker/Screenshot%20from%202026-11-20%2019-15-57.png)

```bash
docker run --pull=never --rm --name pawprint-docker-demo \
  -p 127.0.0.1:18082:8080 \
  -e SPRING_PROFILES_ACTIVE=default \
  pawprint/petclinic:500158f73241
```

With the container running, use a second terminal to compare its image ID with the IDs in both workers' CRI stores and check HTTP.

```bash
docker inspect pawprint-docker-demo \
  --format 'Image={{.Config.Image}} ID={{.Image}}'

for node in pawprint-worker pawprint-worker2; do
  printf '%s: ' "$node"
  docker exec "$node" crictl inspecti pawprint/petclinic:500158f73241 |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["status"]["id"])'
done

curl -fsS --max-time 10 -o /dev/null \
  -w 'Docker PetClinic HTTP %{http_code}\n' http://127.0.0.1:18082/
```

The Docker container and both workers reported image ID `sha256:f6666d2c35bc3e1afb4b4cc5ab585c44ddcad9b24a8b9b8bccc53c583a98706b`. The request returned `Docker PetClinic HTTP 200`.

![Matching PetClinic image IDs for Docker and both Kind workers with HTTP 200](images/docker/Screenshot%20from%202026-11-20%2019-16-20.png)

![PetClinic welcome page served by the Docker container at 127.0.0.1 port 18082](images/docker/Screenshot%20from%202026-11-20%2019-17-06.png)

Stop the foreground container with `Ctrl+C`. Docker removes it because the command uses `--rm`.

## Test evidence

The screenshots are in `docs/images/`. Raw logs from the demo are in the local Git-ignored directory `.pawprint/evidence/standalone/`. `native-build.log`, `native-run.log` and `native-http.log` record the Maven build, JVM startup and native response. `docker-run.log` and `docker-proof.log` record container startup, matching image IDs and the Docker response. The Kubernetes deployment's PostgreSQL connection and reporting checks are recorded separately. [PawPrint acceptance report](acceptance-report.md)
