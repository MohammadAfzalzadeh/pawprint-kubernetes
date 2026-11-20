# PetClinic image rollout and rollback

This exercise uses two consecutive Spring PetClinic source revisions on the PawPrint Kind cluster. The newer revision changes how the veterinary listing handles an out-of-range page. The test monitors the homepage and Reporting API while a read-only pagination request verifies each release's behavior.

## Release images

| Role | Image | Source commit | Image ID |
| --- | --- | --- | --- |
| Previous release | `pawprint/petclinic:0d064b04958d` | `0d064b04958da7715a9138459bafbde3bd10949d` | `sha256:1feed3e137802b35acdde79bbc7c09f63c0cfa3a11159d45a58e6b35e6d8b8a9` |
| Current release | `pawprint/petclinic:500158f73241` | `500158f732419217507c7656904b8e6aa1bcc0d6` | `sha256:f6666d2c35bc3e1afb4b4cc5ab585c44ddcad9b24a8b9b8bccc53c583a98706b` |

The previous release was built from a Git archive using the repository's multi-stage Dockerfile. Maven packaged the older source successfully. Both image IDs were checked in the CRI stores of the control-plane node and two workers. Standalone Docker checks returned `200` for `/` on each image. On `/vets.html?page=9999`, the previous release returned `200` directly and the current release returned `302` to `/vets.html?page=1`. Following the redirect returned `200`.

### Build the previous image

Run this from the project root after obtaining the pinned PetClinic checkout and base images. The current release can be built and imported with `bash scripts/build-images.sh petclinic` followed by `bash scripts/load-images.sh petclinic`.

```bash
previous=0d064b04958da7715a9138459bafbde3bd10949d
context=$(mktemp -d /tmp/pawprint-image-build.XXXXXXXX)
mkdir "$context/spring-petclinic"
git -C spring-petclinic archive "$previous" | tar -xf - -C "$context/spring-petclinic"
cp docker/petclinic/Dockerfile docker/petclinic/Dockerfile.dockerignore "$context/"
docker build --pull=false \
  --build-arg BUILD_BASE=docker-mirror.liara.ir/eclipse-temurin:17-jdk-jammy \
  --build-arg RUN_BASE=eclipse-temurin:17-jre-jammy \
  --label "org.opencontainers.image.revision=$previous" \
  -t pawprint/petclinic:0d064b04958d -f "$context/Dockerfile" "$context"
kind load docker-image pawprint/petclinic:0d064b04958d --name pawprint
```

## Rolling update settings

An earlier resource-only rollout logged a request timeout while NGINX tried to connect to a terminating Pod. The release test used an extra Pod during rolling updates and delayed container shutdown to give endpoint changes time to propagate. [Earlier rollout evidence](deployment-guide.md#petclinic-resource-sizing)

`maxUnavailable: 0` and `maxSurge: 1` allow a new Pod while the two existing replicas serve traffic. `minReadySeconds: 4` makes the controller wait for the new Pod to stay Ready before it counts it as Available. The replacement must pass the existing startup and database-aware readiness probes. The terminating Pod waits six seconds in a `preStop` sleep, giving NGINX time to consume EndpointSlice updates before Spring Boot receives the termination signal. The 35-second termination grace period includes the sleep and Spring Boot's 25-second shutdown phase budget. [PetClinic Deployment](../k8s/petclinic/deployment.yaml) · [Kubernetes rolling updates](https://kubernetes.io/docs/tasks/run-application/update-deployment-rolling/) · [Pod termination](https://kubernetes.io/docs/concepts/workloads/pods/pod-termination/)

This policy trades temporary capacity for service continuity. Check that the workers can schedule an extra PetClinic Pod with requests of `100m` CPU and `336Mi` memory. Allow room for Pods still exiting during graceful termination. [PetClinic resource sizing](deployment-guide.md#petclinic-resource-sizing)

## Reproduce the upgrade and rollback

Start with both images loaded, the `pawprint` namespace deployed and PetClinic serving HTTP through Ingress. Use the dedicated kubeconfig. Stage the previous release from the same hardened Deployment template and record the revision allocated to it.

```bash
kc="$HOME/.kube/pawprint-config"
k() { kubectl --kubeconfig "$kc" --context kind-pawprint -n pawprint "$@"; }
k set image --local -f k8s/petclinic/deployment.yaml \
  petclinic=pawprint/petclinic:0d064b04958d -o yaml | k apply -f -
k rollout status deployment/petclinic --timeout=210s
baseline=$(k get deployment petclinic \
  -o jsonpath='{.metadata.annotations.deployment\.kubernetes\.io/revision}')
```

Record the Pod count and HTTP status before each change. Keep `k get pods -l app.kubernetes.io/name=petclinic -w` and repeated requests to `http://127.0.0.1:8080/` running in separate terminals throughout the upgrade and rollback.

```bash
k set image deployment/petclinic petclinic=pawprint/petclinic:500158f73241
k rollout status deployment/petclinic --timeout=210s
k get pods -l app.kubernetes.io/name=petclinic -o wide
curl -sS --max-time 6 -o /dev/null -w '%{http_code} %{redirect_url}\n' \
  'http://127.0.0.1:8080/vets.html?page=9999'

k rollout undo deployment/petclinic --to-revision="$baseline"
k rollout status deployment/petclinic --timeout=210s
k get pods -l app.kubernetes.io/name=petclinic -o wide
curl -sS --max-time 6 -o /dev/null -w '%{http_code} %{redirect_url}\n' \
  'http://127.0.0.1:8080/vets.html?page=9999'

k set image --local -f k8s/petclinic/deployment.yaml \
  petclinic=pawprint/petclinic:500158f73241 -o yaml | k apply -f -
k rollout status deployment/petclinic --timeout=210s
make verify
```

## Observed upgrade and rollback

On 2026-11-20 the cluster started on the current image, then staged the previous source revision as Deployment revision `3`. The actual upgrade changed the Deployment to the current image at revision `4`. `kubectl rollout undo --to-revision=3` restored the previous image and assigned its ReplicaSet revision `5`. Each command reached `deployment "petclinic" successfully rolled out`.

The collector sampled the homepage about four times per second and the Reporting endpoint and Pod readiness about once per second. The Ready count excludes terminating Pods. Reporting samples in the table returned HTTP 200 with `stale=false` and `replicaStatus=streaming`.

| Phase | Ready PetClinic Pods | Homepage HTTP 200 | Fresh Reporting HTTP 200 |
| --- | ---: | ---: | ---: |
| Before upgrade | 2 | 20/20 | 5/5 |
| During upgrade | 2–3 | 196/196 | 50/50 |
| After upgrade | 2 | 31/31 | 8/8 |
| Before rollback | 2 | 20/20 | 5/5 |
| During rollback | 2–3 | 195/195 | 50/50 |
| After rollback | 2 | 29/29 | 8/8 |

Both old and new images were observed Ready simultaneously during each transition. Up to four Pod objects were visible together, including a terminating Pod. The pagination probe returned `200` directly at revision `3`, returned `302` to `/vets.html?page=1` with a final `200` at revision `4`, and returned `200` directly again after rollback at revision `5`. This confirms the application behavior changed with the image.

The upgrade completed in `50.41s` and rollback in `50.25s`, measured from the change command to successful rollout status. Reapplying the checked-in Deployment restored `500158f73241` at revision `6` with both Pods Ready on separate workers. Across staging, upgrade, rollback and restoration, all 968 homepage samples and 248 fresh Reporting samples returned HTTP 200. `make verify` passed on revision `6`. PostgreSQL Pod UIDs and all namespace PVC UIDs matched their pre-test values.

Local evidence in `.pawprint/evidence/image-rollout/` includes the Maven build log, image IDs from all three Kind nodes, the `rollout status` outputs, the per-phase summary, and timestamped samples in `petclinic-http.tsv`, `reporting-http.tsv` and `pods.tsv`.
