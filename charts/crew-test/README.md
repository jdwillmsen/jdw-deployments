# crew-test

A second, separate Bedrock server, the **test server**, for trying things that
must not touch the lab or the main server: the signed-in NetherNet join with a
few real accounts, add-ons and behaviour packs, the lab-packs mechanism, and
later training bots. It is its own ArgoCD app (`crew-test-prd`), so nothing here
can sync, restart or reschedule `crew-lab-prd` or `minecraft-fwb-prd`.

| Piece | What |
|---|---|
| `<release>-minecraft-bedrock` | itzg `minecraft-bedrock` 2.9.0 subchart: StatefulSet, UDP NodePort Service on 31200, world on `truenas-iscsi` (5Gi) |
| `<release>-nethernet` | NodePort Service: signaling TCP 31201 and gameplay UDP 31210-31229 |
| `install-lab-packs` | init container from the lab's `ghcr.io/jdwillmsen/lab-packs` image |

The release is `jdwillmsen-crew-test-prd`, so the objects are
`jdwillmsen-crew-test-prd-minecraft-bedrock` and `jdwillmsen-crew-test-prd-nethernet`.
Nothing else is rendered: no crew units, no `crew-control`, no ConfigMaps, no
CronJobs.

## Joining

Windows retail clients (1.26.60) dial NetherNet only. Add a server on the LAN
at `192.168.1.163`, port **31201**, and sign in with the Microsoft account.
Gameplay UDP 31210-31229 is negotiated per client and advertised as the node's
address. The server is **LAN only**: there is no router forward or HAProxy NAT
for it, so it is not reachable from outside the house. It does not appear in a
client's Friends tab (LAN discovery broadcasts do not cross a NodePort), so add
it by address.

It runs in online mode with no allow list, so any signed-in account that can
reach the port joins. Nobody is an operator; to make one, set
`minecraft-bedrock.minecraftServer.ops` to its XUID (safe here because online
mode makes XUIDs trustworthy) or use the server console:

    kubectl -n jdwillmsen-prd attach -it jdwillmsen-crew-test-prd-minecraft-bedrock-0

## Add-ons

`install-lab-packs` installs the wildlife packs into `/data/worlds/crew-test` on
every start and merges them into the world's pack lists, keeping other entries.
The installer does nothing while the world folder does not exist, so after the
first start of a fresh volume restart the pod once:

    kubectl -n jdwillmsen-prd delete pod jdwillmsen-crew-test-prd-minecraft-bedrock-0

To try a pack that is not in the image yet, copy it to
`/data/worlds/crew-test/behavior_packs/<name>` (and `resource_packs/`) and add
its uuid and version to `world_behavior_packs.json`; the installer keeps entries
it did not write. Boot errors from packs are in `/data/logs` (content log is on).
The lab-packs tag is a literal bumped by hand, as in the lab. Unlike the lab
there is no unit-kit gate: a change restarts this server at once.

## Stop, restart, delete

- **Restart**: `kubectl -n jdwillmsen-prd delete pod jdwillmsen-crew-test-prd-minecraft-bedrock-0`.
- **Stop** keeping the world: scale the StatefulSet to 0 (`kubectl -n
  jdwillmsen-prd scale sts jdwillmsen-crew-test-prd-minecraft-bedrock
  --replicas=0`). ArgoCD may revert it on its next sync, in which case pause
  that app's auto-sync first.
- **Reset the world**: delete the pod and the PVC
  `datadir-jdwillmsen-crew-test-prd-minecraft-bedrock-0`; the server generates
  a new flat world on the next start. There is no backup.
- **Remove the server**: delete the `crew-test-prd` entry in
  `argocd/prd/config.yaml`. Whether the PVC goes with it depends on the
  ApplicationSet's prune settings, so check, and delete the PVC by hand if it
  stays.

## Resources

| | Request | Limit |
|---|---|---|
| server | 250m cpu, 512Mi | 750m cpu, 1Gi |
| `install-lab-packs` (init) | 10m, 16Mi | 50m, 64Mi |

An init container only counts toward the quota where it exceeds the main
container, so the pod's charge is the server's alone. The namespace quota
(`tenant-quota`: 12 cpu and 24Gi of limits, 6 cpu and 12Gi of requests) is
shared with the main server and the lab, and the backup, volume-recovery and
version-check CronJobs need 2000m of `limits.cpu` free to create their pods. On
2026-10-30 that was 2950m free, so 750m leaves 2200m. Do not raise the limits
without raising the quota. Storage is one 5Gi PVC (13 of the 20 allowed were in
use).

## How it differs from the lab

| | crew-lab | crew-test |
|---|---|---|
| Purpose | crew workers, colosseum, wildlife | signed-in joins, add-ons, bots later |
| Online mode | off | **on** |
| World | survival, generated | creative, fresh **flat**, `crew-test` |
| Crew units / `crew-control` / route | yes | none |
| Unit-kit pack and gate | yes | none |
| Version check, rebuild job | available | none |
| Ports (server / signaling / gameplay) | 31136 / 31137 / 31140-31159 | 31200 / 31201 / 31210-31229 |
| Router / HAProxy forward | RakNet 19133 | none, LAN only |
| Limits | 2000m, 2Gi | 750m, 1Gi |

Both servers pin to node `talos-lx0-6a4` (`192.168.1.163`), which `SERVER_UDP_PORTS`
advertises. If the node changes, change the affinity, `SERVER_UDP_PORTS`, and
the join address together.

## Design

**A new chart, not a second crew-lab release.** Reusing `crew-lab` with
`crew.enabled=false` was rejected because the chart renders objects with fixed
names that a second release in the same namespace would collide with, and
Argo/Helm refuse to adopt them: the `crew-lab-unit-kit` ConfigMap
(unconditional, and referenced by an init container in `values.yaml`), the
`crew-tactics-control` ConfigMap, the `crew-control`, `crew-shared`, `crew-NN`
objects, the `crew` HTTPRoute, the `crew-units-offline` PrometheusRule, and the
`unit-kit-gate` and `lab-field-rebuild` Jobs, Roles and ServiceAccounts. Only
the subchart's objects and the NetherNet Service are named from the release.
Making every one of those switchable would put edits in the lab chart, which is
the thing this server exists to stay away from. The tradeoff is a 25-line
`nethernet-service.yaml` and the NetherNet env/probe block copied from the lab;
the test `tools/tests/test-crew-test.sh` renders the lab and the main server
beside this chart and fails on any repeated kind and name or NodePort.

**Same namespace.** `jdwillmsen-prd` has the headroom (see Resources) and the
storage class, node and secrets it needs; a new namespace would need its own
governance entry for quota and limits.

**No version check, no gate.** The version is pinned to 1.26.60.6 because
LATEST (1.26.61.1) is ahead of the Windows client. A version-check CronJob would
see the pin differ from LATEST and restart the server every hour, so none is
rendered. Unpin once the public client catches up.

**NetherNet probes.** The subchart's probes are RakNet pings, which a NetherNet
server never answers. As in the lab, startup is off, liveness is delayed a year
and readiness fails, so the pod reads NotReady and the NetherNet Service sets
`publishNotReadyAddresses`.

**Ports.** Signaling is TCP on the server port (31200), but the signaling
nodePort is 31201: the apiserver rejects reusing 31200 because the subchart's
UDP Service already holds it, as in the lab. Gameplay UDP is pinned to
31210-31229 by `SERVER_UDP_PORTS` and exposed one to one.
