import logging
import os
import subprocess
import tempfile

import httpx
import yaml
from azure.identity import DefaultAzureCredential

ARM_BASE = "https://management.azure.com"
HELM_V3 = "helm.v3"

# ACR convention: this literal GUID username signals "the password is a token".
_ACR_IDENTITY_USER = "00000000-0000-0000-0000-000000000000"

# Bounds the helm render subprocess so a slow or malicious chart pull can't hang
# the Function; a timeout is treated as a render failure and rejects the version.
HELM_TIMEOUT_SECONDS = int(os.environ.get("HELM_TIMEOUT_SECONDS", "45"))


def get_effective_namespace(target: dict, solution_version: dict) -> str:
    """Mirror BulkDeploymentDeployService: lower(solutionScope), fallback to solutionInstanceName."""
    tprops = target.get("properties", {}) or {}
    effective_ns = (tprops.get("solutionScope") or "").lower()
    if not effective_ns:
        svprops = solution_version.get("properties", {}) or {}
        effective_ns = (svprops.get("solutionInstanceName") or "").lower()
    return effective_ns


def collect_referenced_namespaces(solution_version: dict, effective_ns: str) -> set:
    """Namespaces the solution's Helm charts would deploy into.

    Render-only and fail-closed: every helm.v3 component is rendered with
    `helm template` and the manifests are scanned for referenced namespaces. Any
    render failure (or a helm.v3 component missing its chart coordinates) raises,
    so the caller rejects the solution version rather than letting it through.
    """
    spec = (solution_version.get("properties", {}) or {}).get("specification", {}) or {}
    components = spec.get("components", []) or []

    referenced = set()
    for comp in components:
        if (comp.get("type") or "").lower() != HELM_V3:
            continue

        props = comp.get("properties", {}) or {}
        values = props.get("values", {}) or {}
        chart = props.get("chart", {}) or {}
        release = comp.get("name") or "release"
        referenced |= _extract_namespaces_from_render(chart, values, release, effective_ns)

    return referenced


def _extract_namespaces_from_render(chart: dict, values: dict, release: str, effective_ns: str) -> set:
    """helm template the chart and collect every namespace its manifests reference.

    Fail-closed: a helm.v3 component must carry chart repo + version. If it does
    not, or the render fails, this raises so the solution version is rejected.
    """
    repo = chart.get("repo")
    version = chart.get("version")
    if not repo or not version:
        raise ValueError(
            f"helm.v3 component '{release}' is missing chart repo/version; "
            "cannot render to verify namespaces (rejecting)."
        )

    chart_ref = _to_oci_ref(repo)

    found = set()
    with tempfile.TemporaryDirectory() as d:
        values_path = os.path.join(d, "values.yaml")
        with open(values_path, "w", encoding="utf-8") as f:
            yaml.safe_dump(values, f)

        _registry_login(chart_ref)

        cmd = [
            "helm", "template", release, chart_ref,
            "--version", version,
            "--values", values_path,
            "--namespace", effective_ns,
        ]
        logging.info("Rendering chart: %s", " ".join(cmd))
        try:
            rendered = subprocess.run(
                cmd, check=True, capture_output=True, text=True, timeout=HELM_TIMEOUT_SECONDS
            ).stdout
        except subprocess.CalledProcessError as e:
            logging.error(
                "helm template failed (exit %s) for %s: %s",
                e.returncode, chart_ref, (e.stderr or "").strip(),
            )
            raise

    for doc in yaml.safe_load_all(rendered):
        if not doc or not isinstance(doc, dict):
            continue
        found |= _namespaces_in_manifest(doc)

    return found


def _namespaces_in_manifest(doc: dict) -> set:
    """Collect every namespace a single rendered manifest references.

    Catches:
      * metadata.namespace on any resource,
      * the name of a `kind: Namespace` object (a namespace being created),
      * any other 'namespace' field (e.g. RoleBinding/ClusterRoleBinding
        subjects[].namespace) so cross-namespace references are not missed.
    """
    found = set()

    if doc.get("kind") == "Namespace":
        name = (doc.get("metadata") or {}).get("name")
        if name:
            found.add(name)

    def walk(node):
        if isinstance(node, dict):
            for k, v in node.items():
                if k == "namespace" and isinstance(v, str) and v:
                    found.add(v)
                else:
                    walk(v)
        elif isinstance(node, list):
            for item in node:
                walk(item)

    walk(doc)
    return found


def _to_oci_ref(repo: str) -> str:
    """Normalize a WO chart repo into a helm-usable reference.

    WO stores the chart repo without a scheme (e.g. 'myacr.azurecr.io/helm/app').
    helm needs an explicit 'oci://' prefix to treat it as an OCI registry chart.
    Classic http(s) helm repos are left untouched.
    """
    if repo.startswith(("oci://", "http://", "https://")):
        return repo
    return "oci://" + repo


def get_acr_refresh_token(registry: str, tenant_id: str) -> str:
    """Exchange a managed-identity AAD token for an ACR refresh token.

    Mirrors what `az acr login` does under the hood:
      1. Acquire an AAD token (ARM audience) from the managed identity.
      2. POST it to the registry's /oauth2/exchange endpoint.
    `registry` is the registry host, e.g. 'myacr.azurecr.io'.
    """
    aad_token = DefaultAzureCredential().get_token(
        "https://management.azure.com/.default"
    ).token

    resp = httpx.post(
        f"https://{registry}/oauth2/exchange",
        data={
            "grant_type": "access_token",
            "service": registry,
            "tenant": tenant_id,
            "access_token": aad_token,
        },
        timeout=30,
    )
    resp.raise_for_status()
    return resp.json()["refresh_token"]


def _registry_login(repo: str) -> None:
    """Log helm in to the OCI registry using the managed identity (AcrPull).

    Uses the ACR OAuth2 token-exchange flow directly (no az CLI dependency),
    then hands the refresh token to `helm registry login --password-stdin`.
    """
    if not repo.startswith("oci://"):
        return
    registry_host = repo[len("oci://"):].split("/")[0]   # e.g. myacr.azurecr.io
    tenant_id = os.environ.get("AZURE_TENANT_ID", "")
    try:
        refresh_token = get_acr_refresh_token(registry_host, tenant_id)
        subprocess.run(
            ["helm", "registry", "login", registry_host,
             "--username", _ACR_IDENTITY_USER, "--password-stdin"],
            input=refresh_token.encode(),
            check=True, capture_output=True, timeout=30,
        )
        logging.info("helm registry login succeeded for %s", registry_host)
    except subprocess.CalledProcessError as e:
        stderr = e.stderr.decode() if isinstance(e.stderr, bytes) else (e.stderr or "")
        logging.error("helm registry login failed for %s: %s", registry_host, stderr.strip())
    except Exception:
        logging.exception("ACR login failed for %s (continuing; anonymous pull may still work).", registry_host)
