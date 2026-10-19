# crew-lab

An offline Bedrock lab server and the crew units that join it: `crew-01` Agate,
`crew-02` Basalt and `crew-03` Cobble. The
lab is a separate ArgoCD app from the main server, so a mistake here cannot
restart or reschedule that server.

| Piece | What |
|---|---|
| `<release>-minecraft-bedrock` | itzg `minecraft-bedrock` subchart: StatefulSet, NodePort Service on 31136/UDP, world on `truenas-iscsi` |
| `crew-NN` (one per unit) | Deployment (1 replica, `Recreate`), ClusterIP Service on 8080 and a 1Gi PVC on `truenas-nfs`, all named by the unit id |

## Joining the lab

Players join from a Bedrock client at `crew.prd.jdwlabs.com`, port **19133**,
from inside or outside the LAN. Any `jdwlabs.com` name works, since they all
resolve to the same address. The path is the same one FWB uses on 19132: the
router forwards UDP 19132-19141 to the HAProxy VM, and a DNAT rule there,
placed by hand in `/etc/minecraft-udp-nat.nft` and outside this repository,
sends 19133 to NodePort 31136 on `192.168.1.163`. If that node changes, the
rule has to follow it. On the LAN, any node's address on 31136 also works. It
does not show in a client's Friends tab: LAN discovery broadcasts do not cross
the NodePort, so add it as a server by address.

The server runs with both online mode and the allow list off, and the units set
`MC_OFFLINE=true`, because crew has no Microsoft account. So anyone who can
reach the port joins, under any name they choose. That is accepted for a
disposable world, and it is why the lab has no operators: an offline client can
forge the XUID that `permissions.json` keys operators by. Run lab commands from
the server console (see below), and turn online mode on before adding an
operator.

## Transport

The server is pinned to RakNet (`TRANSPORT: raknet`). Bedrock 1.26.51 and later
default a new world to NetherNet, which opens no RakNet listener; crew dials
RakNet only, and so do the subchart's own probes.

## The world

Disposable: no backup CronJob, no restore. If it is lost, delete the PVC and the
server generates a new one. The server is pinned to one node for the reason
given in `values.yaml`; the node was chosen by measured headroom, so recheck
`kubectl top nodes` before moving it.

## Units

`crew.units` in `values.yaml` is the only list. Each entry renders a Deployment,
Service and PVC named by its `id`, and joins the server under its `name`.

| Id | Name |
|---|---|
| `crew-01` | Agate |
| `crew-02` | Basalt |
| `crew-03` | Cobble |

The id is fixed for life (volumes, logs, metrics and the task API's identity use
it); the name is what players see in-game, 16 characters at most. Every crew
object carries `app.kubernetes.io/component: crew`, so
`kubectl get pods -l app.kubernetes.io/component=crew` lists all units.

To add a unit, append the next id and the next name from the ordered list in
`values.yaml` (`crew-04` Dusty, `crew-05` Ember, and on to `crew-26` Zinc).
Never renumber or rename a unit, and never reuse an id. Check the budget first:
each unit adds its `limits.cpu` (50m) to the namespace quota, and the three
units already use all the room FWB's 04:00 backup can spare. A fourth unit
needs the tenant quota raised, or a smaller limit for every unit.

Set `replicas: 0` on one unit to stop it without deleting its volume;
`crew.replicas` is the default for the rest.

- Probes: liveness `/healthz`, readiness `/readyz`. Readiness is false while
  the unit is dead or the server restarts, which can be long, so only liveness
  can restart the pod.
- `/data` (1Gi) holds the token cache (unused offline) and the texture atlas
  cache, about 313 MB once the pack is extracted and the atlas built.
- With the camera on, the first start fetches Mojang's sample resource pack from
  github.com. The namespace allows egress. If the fetch fails the camera stays
  on flat colours and retries on the next session; nothing else is affected.
- The image tag in `values.yaml` must be a published `minecraft-crew` release.
  A tag that does not exist leaves the pods in `ImagePullBackOff`.

## Reaching the camera

Open <https://crew.prd.jdwlabs.com>, which redirects to `/camera`. It shows one
unit, the one named by `crew.route.unit` (default `crew-01`). It is
public and has no sign-in. That is fine for the lab, which is not FWB, but the
page shows where that unit is to anyone with the link, and at most
`crew.camera.maxViewers` people can watch at once.

The route is view-only. It allow-lists `/camera`, `/v1/camera/*` and
`/v1/state`. The task API, `/metrics` and the probes share the same port and
stay cluster-only; `tools/tests/test-crew-route.sh` fails if any of them
becomes reachable. For those, use a port-forward:

```
kubectl -n jdwillmsen-prd port-forward deploy/crew-01 8080:8080
```

The page loads three.js from a CDN, so the browser needs internet access.

## Tasks

Each unit takes work over `POST /v1/tasks` once `TASKS_TOKEN` is set. All units
read it from one Secret, `crew-tasks` (key `token`), so adding a unit needs no
new Secret. The chart only references it, so the value never passes through Git
or Argo CD. Until the Secret exists the units run without the task routes.

Create it in your own terminal, then restart the units so they read the token:

```
kubectl -n jdwillmsen-prd create secret generic crew-tasks \
  --from-literal=token="$(openssl rand -hex 32)"
kubectl -n jdwillmsen-prd rollout restart deploy -l app.kubernetes.io/component=crew
```

Submit over a port-forward to the unit's Deployment (see "Reaching the camera"),
never the public host, which does not route `/v1/tasks`. The crew README has the
template.

## Parallel demo

Two scripts in gameops, `minecraft/crew/lab/parallel-scene.sh` and
`parallel-demo.sh`, show the three units working at once: Agate mines
cobblestone, Basalt chops logs, and Cobble hauls both into a store chest.

```
parallel-scene.sh --confirm-overwrite k8s:jdwillmsen-prd/<lab server pod>
parallel-demo.sh k8s:jdwillmsen-prd 600
```

The scene erases an area near the origin of the lab world, which real players
build in, so run it only with the owner's OK. The demo reads the token from the
`crew-tasks` Secret and port-forwards to each unit without printing it. It
prints one line per unit and exits non-zero unless all three finish `done`.

## Checks after a sync

```
kubectl -n jdwillmsen-prd get pods -l app.kubernetes.io/component=crew
kubectl -n jdwillmsen-prd logs deploy/crew-01 | grep auth_offline
```

To test a death or a server restart, `kubectl exec` into the server pod and use
its console, or delete the server pod and watch `/readyz` go false and come back
without the crew pods restarting.
