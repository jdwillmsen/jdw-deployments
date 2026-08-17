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

Dependencies are declared in `Chart.yaml`, pinned by `Chart.lock`, and the
resolved `charts/*/charts/` directory **is committed**. That differs from
`jdwlabs/deployments`, which gitignores it — those dependencies are `file://`
siblings already in the checkout, whereas these come from an external Helm
repository. Vendoring keeps ArgoCD's render path free of an upstream fetch
that would otherwise fail as a broken sync rather than a clear error.

After changing a dependency:

```bash
helm dependency update charts/<name>   # refreshes Chart.lock and charts/
helm lint charts/<name> -f charts/<name>/values.yaml
helm template <name> charts/<name> -f charts/<name>/values.yaml
```
