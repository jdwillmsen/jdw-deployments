# jdw-deployments

Private deployment manifests for the `jdwillmsen` tenant of the jdwlabs
Kubernetes platform.

ArgoCD discovers work here through the tenant's `deploymentRepo.url`. The
`jdwillmsen-deployments` ApplicationSet reads every `argocd/*/config.yaml`,
and generates one Application per entry in its `apps` list.

## Layout

```
argocd/<env>/config.yaml   app list for that environment
charts/<name>/             the chart each app points at
```

An entry names the chart by `chartPath` within this repo, so charts are
self-contained here rather than referenced remotely.

## Charts

| Chart | What |
|---|---|
| `minecraft-fwb` | Minecraft Bedrock server, migrated off an unmanaged Proxmox VM |

## Working on a chart

Dependencies are declared in `Chart.yaml` and pinned by `Chart.lock`. The
vendored `charts/*/charts/` directory is not committed — rebuild it locally:

```bash
helm dependency build charts/<name>
helm template <name> charts/<name> -f charts/<name>/values.yaml
```
