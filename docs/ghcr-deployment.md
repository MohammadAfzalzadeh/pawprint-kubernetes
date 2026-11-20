# Publish and deploy PawPrint images from GHCR

The [Build and publish PawPrint images](https://github.com/MohammadAfzalzadeh/pawprint-kubernetes/actions/workflows/publish-images.yml) workflow runs on pushes to `main` and can also be started from the Actions tab. It checks out the pinned Spring PetClinic source, builds both `linux/amd64` images, and runs HTTP smoke checks before pushing. PetClinic uses its default H2 profile for the CI smoke check. Reporting's `/healthz` verifies that its HTTP server starts. The Kind acceptance tests exercise both applications with PostgreSQL.

## Image names and publication

| Component | GitHub Container Registry repository |
| --- | --- |
| PetClinic | `ghcr.io/mohammadafzalzadeh/pawprint-kubernetes-petclinic` |
| Reporting | `ghcr.io/mohammadafzalzadeh/pawprint-kubernetes-reporting` |

Each workflow attempt publishes a distinct tag in the format `sha-<commit>-<run-id>-<attempt>`. The run summary records each tag with the digest reported by GHCR. The workflow uses its short-lived `GITHUB_TOKEN` with `packages: write` to perform these pushes. [GitHub Actions image publication](https://docs.github.com/en/actions/tutorials/publish-packages/publish-docker-images)

```bash
prefix="ghcr.io/${GITHUB_REPOSITORY,,}"
tag="sha-${GITHUB_SHA}-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
docker push "$prefix-petclinic:$tag"
docker push "$prefix-reporting:$tag"
```

The checked-in Deployment manifests pin the verified GHCR digests. `make deploy STAGES="reporting petclinic"` uses those digests by default. `IfNotPresent` allows a node to reuse the same digest from its cache. [Kubernetes image pull policies](https://kubernetes.io/docs/concepts/containers/images/#image-pull-policy)

To deploy another release or run the worker pull checks, open the relevant successful run and download its `ghcr-release` artifact. Extract `release.json` into `.pawprint/ghcr/` from the repository root and set `GHCR_RELEASE`. Keep the run URL and the artifact together so you can trace the build or redeploy the same digests.

```bash
mkdir -p .pawprint/ghcr
unzip "$HOME/Downloads/ghcr-release.zip" -d .pawprint/ghcr
export GHCR_RELEASE="$PWD/.pawprint/ghcr/release.json"
```

## Private package access

The GitHub repository and its GHCR packages have separate visibility settings. Newly published packages are private by default. For private packages, create a GitHub classic personal access token with `read:packages` using an account with access to both packages. The following commands create `pawprint-ghcr` in the `pawprint` namespace and prompt for the username and token in the current terminal. The token prompt hides input. Rerun `make ghcr-secret` to rotate the credential. For public packages, skip Secret creation and unset `GHCR_PULL_SECRET`. [GHCR authentication and package visibility](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry)

```bash
kubectl --kubeconfig "$HOME/.kube/pawprint-config" --context kind-pawprint apply -f k8s/namespace.yaml
make ghcr-secret
export GHCR_PULL_SECRET=pawprint-ghcr
```

The deploy script and worker probes add the following field under the Deployment's `spec.template.spec` and the probe Pod's `spec`, respectively. Kubernetes uses the namespaced `kubernetes.io/dockerconfigjson` Secret to authenticate to `ghcr.io`. Keep the token and generated Secret out of Git and test evidence. [Kubernetes private registry pulls](https://kubernetes.io/docs/tasks/configure-pod-container/pull-image-private-registry/)

```yaml
imagePullSecrets:
  - name: pawprint-ghcr
```

## Prove registry pulls and deploy

Use the dedicated `kind-pawprint` context and set `GHCR_RELEASE` as shown above. Complete the PostgreSQL Primary, bootstrap and Replica stages before deploying the applications. On a new cluster, follow the [README setup steps](../README.md#setup) through the database stages, then run the commands below for Reporting and PetClinic before continuing with Ingress, network policies and backup.

From Bash, run the following in order. The worker test schedules one short-lived Pod per image on each worker. `imagePullPolicy: Always` makes the kubelet contact GHCR for the requested digest even when image layers are already cached. Each result includes the worker name, a successful `Pulled` event, the requested digest and the runtime image ID. Retain the output and the Actions run URL as release evidence. [Kubernetes image pull behavior](https://kubernetes.io/docs/concepts/containers/images/#image-pull-policy)

```bash
set -o pipefail
make verify-ghcr-pulls | tee .pawprint/ghcr/worker-pulls.log &&
make deploy STAGES="reporting petclinic" IMAGE_SOURCE=ghcr &&
kubectl --kubeconfig "$HOME/.kube/pawprint-config" --context kind-pawprint \
  -n pawprint get pods -l 'app.kubernetes.io/name in (petclinic,reporting)' -o wide
```

After Ingress and network policies are in place, run `make verify`. Check the homepage and Reporting separately if you are recording a demo.

```bash
curl -fsS -o /dev/null -w 'PetClinic HTTP %{http_code}\n' http://localhost:8080/
curl -fsS http://localhost:8080/api/reports/summary
```

PetClinic rolls forward one Pod at a time using its existing surge and readiness settings. Reporting has one replica and may be briefly unavailable during its rollout. For rollback to a previously published version, repeat the worker check and deploy using its saved `release.json`. To use the pinned manifests again, unset `GHCR_RELEASE` before deploying. For locally loaded images, follow the [local build and load steps](deployment-guide.md#build-load-and-deploy-locally).

For `ImagePullBackOff`, describe the affected Pod and inspect its Events for authorization, DNS, timeouts or a missing digest. If Kind's optional GHCR mirror is configured, treat the worker probe as proof that the worker resolved a GHCR image reference through its configured registry route. Verify the actual endpoint separately if the evidence needs to distinguish direct GHCR from mirror traffic. [PawPrint registry mirrors](image-registry-mirrors.md)

## Verified release on 2026-11-20

GitHub Actions built both images, passed both HTTP smoke checks, pushed both tagged images, and uploaded `ghcr-release`. The published tag for each image was `sha-c984634e202957071d9439723ac30d97db1c8f42-44779128531-1`. [GitHub Actions run 44779128531](https://github.com/MohammadAfzalzadeh/pawprint-kubernetes/actions/runs/44779128531)

```text
ghcr.io/mohammadafzalzadeh/pawprint-kubernetes-petclinic@sha256:0a94cdce2f652a8ae6e1dd60342b6f419ca6403ec596080813ef20207fee1a4a
ghcr.io/mohammadafzalzadeh/pawprint-kubernetes-reporting@sha256:05e1fa332aed008e46acf695f3cf15934d96fe6533462dfddad214ceebdac3aa
```

`make verify-ghcr-pulls` finished successfully with no `imagePullSecret`. All four probes emitted `Successfully pulled image`, and each runtime image ID matched the requested digest.

| Kind node | Image | Probe Pod | Successful pull duration |
| --- | --- | --- | ---: |
| `pawprint-worker` | PetClinic | `ghcr-pull-petclinic-bbf7t` | 24.686 s |
| `pawprint-worker` | Reporting | `ghcr-pull-reporting-fxwmw` | 4.984 s |
| `pawprint-worker2` | PetClinic | `ghcr-pull-petclinic-4fwz2` | 18.340 s |
| `pawprint-worker2` | Reporting | `ghcr-pull-reporting-nwd7v` | 4.809 s |

The first PetClinic pull attempt on `pawprint-worker2` timed out while downloading a blob. Kubernetes retried the same digest successfully. The table records the successful `Pulled` event durations. The local transcript is `.pawprint/ghcr/worker-pulls.log`.

Both Deployments rolled out those digests on `kind-pawprint`. PetClinic reached 2/2 Ready with one Pod on each worker. Reporting reached 1/1 Ready. PostgreSQL Primary and Replica Pod UIDs and all PVC UIDs and volume bindings matched before and after.

| Endpoint | Before rollout | During rollout | After rollout |
| --- | --- | --- | --- |
| PetClinic `/` | 3 × HTTP 200 | 59 × HTTP 200 | 4 × HTTP 200 |
| Reporting `/api/reports/summary` | 3 × HTTP 200 | 55 × HTTP 200, 6 × HTTP 502 | 5 × HTTP 200 |

Reporting returned 502s while its single replica was being replaced. `make verify` passed after the rollout. PostgreSQL was streaming, the report matched the Replica query, and Reporting could reach the Replica while the Primary was blocked by network policy. The deploy and verification transcripts are `.pawprint/ghcr/rollout.log` and `.pawprint/ghcr/verify.log`.
