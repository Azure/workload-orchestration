# How to use gitopsWoMigrator

`gitopsWoMigrator.ps1` converts one direct Flux HelmRelease or one direct Argo
CD Application into one standalone Azure Workload Orchestration Solution
Template Bicep file.

The script is self-contained. It does not call another migration script, clone
a repository, connect to Flux or Argo CD, contact a Kubernetes cluster, or
deploy resources.

## Prerequisites

- PowerShell (`pwsh`)
- The `powershell-yaml` module, used for local YAML parsing
- Azure CLI with Bicep support, only if you want to compile the generated file

Install the YAML module once for the current user:

```powershell
Install-Module powershell-yaml -Scope CurrentUser
```

## Quick start

Run the script from PowerShell with three required parameters:

```powershell
.\gitopsWoMigrator.ps1 `
  -Platform flux `
  -Repo .\flux `
  -AppFile podinfo.yaml
```

The script reads the application name from the manifest and writes:

```text
.\flux\podinfo-flux.solutionTemplate.bicep
```

Use `-Platform argo` for an Argo CD Application.

## Command syntax

```powershell
.\gitopsWoMigrator.ps1 `
  -Platform <flux|argo> `
  -Repo <local-folder> `
  -AppFile <relative-application-path> `
  [-App <application-name>] `
  [-OutputFile <bicep-path>] `
  [-SolutionVersion <version>] `
  [-Capabilities <capability...>] `
  [-Force]
```

## Required parameters

| Parameter | Required | Default | Behavior |
| --- | --- | --- | --- |
| `-Platform` | Yes | None | Selects the source format. Accepted values are `flux` and `argo`. |
| `-Repo` | Yes | None | Local root directory containing the application and any referenced local files. The script does not require this directory to be a Git repository. |
| `-AppFile` | Yes | None | File path relative to `-Repo`. For Flux, pass a file containing the target HelmRelease. For Argo CD, pass a direct Application file. The path must remain inside `-Repo`. |

## Optional parameters

| Parameter | Default | When to use it |
| --- | --- | --- |
| `-App` | Inferred | Use only when `-AppFile` contains more than one HelmRelease or Application. The value must exactly match `metadata.name`. |
| `-OutputFile` | Beside `-AppFile` | Override the generated Bicep destination. Relative paths are resolved from the current PowerShell directory. |
| `-SolutionVersion` | `1.0.0` | Set the Solution Template version resource name. It must start with a letter or number and contain only letters, numbers, periods, underscores or hyphens. |
| `-Capabilities` | Placeholder | One or more capability names to emit as the solution template `capabilities` array. Must be a subset of the target's capabilities. When omitted, the script emits the placeholder `['REPLACE_WITH_TARGET_CAPABILITY']` and marks the output `MIGRATION INCOMPLETE` so the value cannot be shipped unreviewed. Example: `-Capabilities web` or `-Capabilities web,data`. |
| `-Force` | Off | Replace an existing output file. Without it, the script stops rather than overwriting the file. |

## Default output

Without `-OutputFile`, the script creates:

```text
<application-folder>\<metadata.name>.solutionTemplate.bicep
```

Example:

```text
flux\podinfo.yaml
    -> flux\podinfo-flux.solutionTemplate.bicep

argo\podinfo.yaml
    -> argo\podinfo-argo.solutionTemplate.bicep
```

The console displays the generated location as a path relative to the current
directory.

## Flux requirements

The supplied file must contain one matching Flux HelmRelease.

The referenced HelmRepository may be:

- in the same YAML file; or
- in another `.yaml` or `.yml` file in the same directory.

Supported Flux configuration:

- HelmRelease v2
- `spec.chart.spec` with a HelmRepository `sourceRef`
- exact semantic chart version
- inline `spec.values`
- explicit release name or the Flux default release-name rule
- optional target namespace

The standalone converter does not support Flux `chartRef`, `valuesFrom`,
private repository authentication, remote kubeconfig, post-renderers,
service-account configuration or suspended releases.

### Flux example

```powershell
.\gitopsWoMigrator.ps1 `
  -Platform flux `
  -Repo .\flux `
  -AppFile podinfo.yaml
```

## Argo CD requirements

The supplied file must contain one matching direct Argo CD Application.

Supported Argo CD configuration:

- one external Helm chart source
- exact `targetRevision`
- explicit `helm.releaseName`
- in-cluster destination
- optional repository-local `$values` files
- either `spec.source` or `spec.sources`

Repository-local values must use this form:

```yaml
helm:
  valueFiles:
    - $values/values.yaml
```

The Application must include exactly one source with:

```yaml
ref: values
```

The standalone converter does not support ApplicationSets, Git-path
applications, remote destinations, inline `helm.values`, `valuesObject`, Helm
parameters, file parameters, credential forwarding, CRD skipping or schema
validation skipping.

### Argo CD example

```powershell
.\gitopsWoMigrator.ps1 `
  -Platform argo `
  -Repo .\argo `
  -AppFile podinfo.yaml
```

## Custom output and version

```powershell
.\gitopsWoMigrator.ps1 `
  -Platform flux `
  -Repo C:\repos\customer-app `
  -AppFile apps\payments.yaml `
  -OutputFile C:\generated\payments.solutionTemplate.bicep `
  -SolutionVersion 2.0.0
```

Add `-Force` only when you intentionally want to replace an existing output
file.

## Compile the generated Bicep

```powershell
az bicep build --file .\flux\podinfo-flux.solutionTemplate.bicep
az bicep build --file .\argo\podinfo-argo.solutionTemplate.bicep
```

Compilation validates Bicep syntax. It does not deploy the Solution Template.

> [!IMPORTANT]
> Always review generated Bicep before using it in a Workload Orchestration
> deployment.

Once validated, the Solution Template file can be stitched to the appropriate
target for deployment.
