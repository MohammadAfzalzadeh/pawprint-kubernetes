"""Validate GHCR release references and prepare Kubernetes objects."""

import json
from pathlib import Path
import re
import sys

COMPONENTS = ("petclinic", "reporting")


def release_images(path):
    release = json.loads(Path(path).read_text())
    if not re.fullmatch(r"[0-9a-f]{40}", release["commit"]):
        raise ValueError("release.json must identify a Git commit")
    images = release["images"]
    if set(images) != set(COMPONENTS):
        raise ValueError("release.json must contain PetClinic and Reporting references")
    for component in COMPONENTS:
        if not re.fullmatch(rf"ghcr\.io/[a-z0-9._-]+/[a-z0-9._-]+-{component}@sha256:[0-9a-f]{{64}}", images[component]):
            raise ValueError(f"Expected a digest-pinned GHCR image for {component}")
    return images


def configure_pull(spec, secret):
    if secret:
        spec["imagePullSecrets"] = [{"name": secret}]
    else:
        spec.pop("imagePullSecrets", None)


def render(component, image, secret):
    deployment = json.load(sys.stdin)
    if deployment["kind"] != "Deployment" or deployment["metadata"]["name"] != component:
        raise ValueError(f"Expected the {component} Deployment")
    spec = deployment["spec"]["template"]["spec"]
    containers = [c for c in spec["containers"] if c["name"] == component]
    if len(containers) != 1:
        raise ValueError(f"Expected one container named {component}")
    containers[0]["image"] = image
    configure_pull(spec, secret)
    return deployment


def probe(component, image, secret, hostname):
    spec = {
        "nodeSelector": {"kubernetes.io/hostname": hostname},
        "automountServiceAccountToken": False,
        "restartPolicy": "Never",
        "activeDeadlineSeconds": 240,
        "securityContext": {"runAsNonRoot": True, "runAsUser": 10001},
        "containers": [{
            "name": component,
            "image": image,
            "imagePullPolicy": "Always",
            "command": ["/bin/true"],
            "resources": {"requests": {"cpu": "5m", "memory": "8Mi"}, "limits": {"cpu": "50m", "memory": "32Mi"}},
        }],
    }
    configure_pull(spec, secret)
    return {"apiVersion": "v1", "kind": "Pod", "metadata": {"generateName": f"ghcr-pull-{component}-"}, "spec": spec}


def main(args):
    mode, path, secret, *rest = args
    if secret and not re.fullmatch(r"[a-z0-9](?:[a-z0-9.-]{0,251}[a-z0-9])?", secret):
        raise ValueError("Invalid imagePullSecret name")
    images = release_images(path)
    if mode == "check" and not rest:
        return
    if mode == "render" and len(rest) == 1:
        print(json.dumps(render(rest[0], images[rest[0]], secret)))
    elif mode == "probe" and len(rest) == 2:
        print(json.dumps(probe(rest[0], images[rest[0]], secret, rest[1])))
    else:
        raise ValueError("Expected check, render <component>, or probe <component> <hostname>")


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except (OSError, ValueError, KeyError, TypeError) as error:
        sys.exit(str(error))
