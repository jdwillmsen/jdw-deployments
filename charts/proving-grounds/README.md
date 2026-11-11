# proving-grounds

A second, separate Bedrock server, the **test server**, for trying things that
must not touch the lab or the main server: the signed-in NetherNet join with a
few real accounts, add-ons and behaviour packs, the lab-packs mechanism, and
later training bots. It is its own ArgoCD app (`proving-grounds-prd`), so nothing here
can sync, restart or reschedule `crew-lab-prd` or `minecraft-fwb-prd`.

| Piece | What |
|---|---|
| `<release>-minecraft-bedrock` | itzg `minecraft-bedrock` 2.9.0 subchart: StatefulSet, UDP NodePort Service on 31200, world on `truenas-iscsi` (5Gi) |
| `<release>-nethernet` | NodePort Service: signaling TCP 31201 and gameplay UDP 31210-31229 |
| `install-lab-packs` | init container from the lab's `ghcr.io/jdwillmsen/lab-packs` image |

The release is `jdwillmsen-proving-grounds-prd`, so the objects are
`jdwillmsen-proving-grounds-prd-minecraft-bedrock` and `jdwillmsen-proving-grounds-prd-nethernet`.
Nothing else is rendered: no crew units, no `crew-control`, no ConfigMaps, no
CronJobs.

## Joining

Windows retail clients (1.26.60) dial NetherNet only. Add a server on the LAN
at `192.168.1.163`, port **31201**, or from outside the house at
`mc.jdwlabs.com`, port **19134**, and sign in with the Microsoft account.
Gameplay UDP 31210-31229 is negotiated per client and advertised as the WAN
address with external ports 19180-19199 (HAProxy VM NAT and a gateway forward,
see `docs/minecraft-nethernet-public-route.md`). It does not appear in a
client's Friends tab (LAN discovery broadcasts do not cross a NodePort), so add
it by address.

It runs in online mode with no allow list, so any signed-in account that can
reach the port joins, and the port is reachable from the internet. Nobody is an operator; to make one, set
`minecraft-bedrock.minecraftServer.ops` to its XUID (safe here because online
mode makes XUIDs trustworthy) or use the server console:

    kubectl -n jdwillmsen-prd attach -it jdwillmsen-proving-grounds-prd-minecraft-bedrock-0

## Add-ons

`install-lab-packs` installs the wildlife packs into `/data/worlds/proving-grounds` on
every start and merges them into the world's pack lists, keeping other entries.
The installer does nothing while the world folder does not exist, so after the
first start of a fresh volume restart the pod once:

    kubectl -n jdwillmsen-prd delete pod jdwillmsen-proving-grounds-prd-minecraft-bedrock-0

To try a pack that is not in the image yet, copy it to
`/data/worlds/proving-grounds/behavior_packs/<name>` (and `resource_packs/`) and add
its uuid and version to `world_behavior_packs.json`; the installer keeps entries
it did not write. Boot errors from packs are in `/data/logs` (content log is on).
The lab-packs tag is a literal bumped by hand, as in the lab. Unlike the lab
there is no unit-kit gate: a change restarts this server at once.

## Stop, restart, delete

- **Restart**: `kubectl -n jdwillmsen-prd delete pod jdwillmsen-proving-grounds-prd-minecraft-bedrock-0`.
- **Stop** keeping the world: scale the StatefulSet to 0 (`kubectl -n
  jdwillmsen-prd scale sts jdwillmsen-proving-grounds-prd-minecraft-bedrock
  --replicas=0`). The chart renders no replica count, so ArgoCD should not
  revert it; if it does, remove the `proving-grounds-prd` entry instead, which is the
  durable way. Scaling back up is the same command with `--replicas=1`.
- **Reset the world**: scale the StatefulSet to 0 and wait for the pod to
  terminate, so nothing holds the claim, then delete the PVC and wait for it to
  go, then scale back to 1:
  `kubectl -n jdwillmsen-prd scale sts jdwillmsen-proving-grounds-prd-minecraft-bedrock
  --replicas=0`, then `kubectl -n jdwillmsen-prd delete pvc
  datadir-jdwillmsen-proving-grounds-prd-minecraft-bedrock-0`, then `--replicas=1`.
  The server generates a new flat world on the next start. There is no
  backup. The storage class keeps the underlying volume after the claim goes
  (`reclaimPolicy: Retain`), so the iSCSI volume and its PV are left behind and
  need deleting by hand if the space matters.
- **Remove the server**: delete the `proving-grounds-prd` entry in
  `argocd/prd/config.yaml`. The StatefulSet and the Services go with the app,
  but the claim carries no ArgoCD tracking and no retention policy, so it stays
  and so does the world (read from how the lab's identical claim is rendered;
  not exercised here). Delete the claim by hand to reclaim the space.

## Resources

| | Request | Limit |
|---|---|---|
| server | 250m cpu, 512Mi | 750m cpu, 1Gi |
| `install-lab-packs` (init) | 10m, 16Mi | 50m, 64Mi |

An init container only counts toward the quota where it exceeds the main
container, so the pod's charge is the server's alone. The namespace quota
(`tenant-quota`: 12 cpu and 24Gi of limits, 6 cpu and 12Gi of requests) is
shared with the main server and the lab.

- **CPU:** the backup, volume-recovery and version-check CronJobs need 2000m of
  `limits.cpu` free to create their pods. On 2026-10-30 that was 2950m free, so
  750m leaves 2200m. Do not raise the limit without raising the quota.
- **Memory, and a gate on the version check:** the check creates a Job and a
  candidate pod (1 CPU, 2Gi limits), so it needs about 2560Mi of
  `limits.memory` free while it runs. That was exactly what was free before this
  server; with its 1Gi, pod creation by the check is refused. The check is off
  while the main server and the lab are pinned to 1.26.60.6, so nothing fails
  today. **Before re-enabling `versionCheck` on either, raise the tenant
  quota's `limits.memory` by at least 1Gi, or remove this server.** The quota
  lives in the platform repo's tenant envelope, not here.

Storage is one 5Gi PVC (13 of the 20 allowed were in use).

## How it differs from the lab

| | crew-lab | proving-grounds |
|---|---|---|
| Purpose | crew workers, colosseum, wildlife | signed-in joins, add-ons, bots later |
| Online mode | off | **on** |
| World | survival, generated | creative, fresh **flat**, `proving-grounds` |
| Crew units / `crew-control` / route | yes | none |
| Unit-kit pack and gate | yes | none |
| Version check, rebuild job | available | none |
| Ports (server / signaling / gameplay) | 31136 / 31137 / 31140-31159 | 31200 / 31201 / 31210-31229 |
| Router / HAProxy forward | RakNet 19133 | NetherNet TCP 19134, UDP 19180-19199 |
| Limits | 2000m, 2Gi | 750m, 1Gi |

Both servers pin to node `talos-lx0-6a4` (`192.168.1.163`). `SERVER_UDP_PORTS`
advertises the WAN address (`104.53.12.62`, not static) with external ports
19180-19199; remote players enter `mc.jdwlabs.com:19134`. If the node changes, change the
affinity, the VM's nft targets and the join address together. See
`docs/minecraft-nethernet-public-route.md`.

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
the test `tools/tests/test-proving-grounds.sh` renders the lab and the main server
beside this chart and fails on any repeated kind and name or NodePort.

**Same namespace.** `jdwillmsen-prd` has the headroom (see Resources) and the
storage class, node and secrets it needs; a new namespace would need its own
governance entry for quota and limits.

**No version check, no gate.** The version is pinned to 1.26.60.6 because
LATEST (1.26.61.1) is ahead of the Windows client. A version-check CronJob would
see the pin differ from LATEST and restart the server every hour, so none is
rendered. Unpin once the public client catches up.

**NetherNet probes.** The subchart's probes run `mc-monitor status-bedrock` in
`auto` mode, which tries NetherNet first, so readiness passes and the pod is
Ready. The startup probe is on (about 10 minutes to come up); liveness is
delayed a year, and the NetherNet Service keeps `publishNotReadyAddresses`. The `mc-monitor` exporter
is RakNet-only and is not deployed here. See the minecraft-fwb README,
"NetherNet transition".

**Ports.** Signaling is TCP on the server port (31200), but the signaling
nodePort is 31201: the apiserver rejects reusing 31200 because the subchart's
UDP Service already holds it, as in the lab. Gameplay UDP is pinned to
31210-31229 by `SERVER_UDP_PORTS` and exposed one to one; the public
ports 19180-19199 map to them in order.

## World guard

This server is where the world guard, the sync sidecar and the assisted restore are
rehearsed before the main server runs them (JDW-341; [docs/world-guard.md](../../docs/world-guard.md)).

- **`world-guard`** is the first init container, in `enforce`: a world whose database
  names a table the disk does not have holds the pod in `Init:0/3` and re-checks every
  30 s. Let the server open it anyway with
  `kubectl -n jdwillmsen-prd exec jdwillmsen-proving-grounds-prd-minecraft-bedrock-0 -c world-guard -- touch /data/.world-guard-accept`.
- **`world-sync`** (`global.worldSync.enabled`, on here) runs `sync -f /data` every 2 s from the
  server image. `tools/world-guard/tps-ab.py` measures what that costs.
- **`restoreScratch`** is the claim `tools/world-restore` stages on. It is never pruned: it
  can hold the only complete copy of a damaged world.
- There is no backup and no map here, so the restore source is a world put on the scratch
  claim by hand (`--source scratch:DIR`, the world at `/scratch/DIR/proving-grounds`).
