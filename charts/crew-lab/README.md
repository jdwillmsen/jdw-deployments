# crew-lab

An offline Bedrock lab server and `crew-1`, a worker unit that joins it. The
lab is a separate ArgoCD app from the main server, so a mistake here cannot
restart or reschedule that server.

| Piece | What |
|---|---|
| `<release>-minecraft-bedrock` | itzg `minecraft-bedrock` subchart: StatefulSet, NodePort Service on 31136/UDP, world on `truenas-iscsi` |
| `crew-1` | Deployment (1 replica, `Recreate`), ClusterIP Service on 8080, data on `truenas-nfs` |

## Joining the lab

Players join from a Bedrock client at any node's LAN address on port 31136
(for example `192.168.1.163:31136`), or from outside the LAN through a router
forward of UDP 31136, which is set up outside this repository. It does not
show in a client's Friends tab: LAN discovery broadcasts do not cross the
NodePort, so add it as a server by address.

The server runs with both online mode and the allow list off, and `crew-1` sets
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

## crew-1

- Probes: liveness `/healthz`, readiness `/readyz`. Readiness is false while
  the unit is dead or the server restarts, which can be long, so only liveness
  can restart the pod.
- `/data` (1Gi) holds the token cache (unused offline) and the texture atlas
  cache, about 313 MB once the pack is extracted and the atlas built.
- With the camera on, the first start fetches Mojang's sample resource pack from
  github.com. The namespace allows egress. If the fetch fails the camera stays
  on flat colours and retries on the next session; nothing else is affected.
- The image tag in `values.yaml` must be a published `minecraft-crew` release.
  A tag that does not exist leaves the pod in `ImagePullBackOff`.

## Reaching the camera

Open <https://crew.prd.jdwlabs.com>, which redirects to `/camera`. It is
public and has no sign-in. That is fine for the lab, which is not FWB, but the
page shows where crew-1 is to anyone with the link, and at most
`crew.camera.maxViewers` people can watch at once.

The route is view-only. It allow-lists `/camera`, `/v1/camera/*` and
`/v1/state`. The task API, `/metrics` and the probes share the same port and
stay cluster-only; `tools/tests/test-crew-route.sh` fails if any of them
becomes reachable. For those, use a port-forward:

```
kubectl -n jdwillmsen-prd port-forward deploy/crew-1 8080:8080
```

The page loads three.js from a CDN, so the browser needs internet access.

## Tasks

`crew-1` takes work over `POST /v1/tasks` once `TASKS_TOKEN` is set, and the
token comes from the Secret `crew-1-tasks` (key `token`). The chart only
references it, so the value never passes through Git or Argo CD. Until the
Secret exists the unit runs without the task routes.

Create it in your own terminal, then restart the unit so it reads the token:

```
kubectl -n jdwillmsen-prd create secret generic crew-1-tasks \
  --from-literal=token="$(openssl rand -hex 32)"
kubectl -n jdwillmsen-prd rollout restart deploy/crew-1
```

Submit over the port-forward in "Reaching the camera", never the public host,
which does not route `/v1/tasks`. The crew README has the
template.

## Checks after a sync

```
kubectl -n jdwillmsen-prd get pods -l app=crew-1
kubectl -n jdwillmsen-prd logs deploy/crew-1 | grep auth_offline
```

To test a death or a server restart, `kubectl exec` into the server pod and use
its console, or delete the server pod and watch `/readyz` go false and come back
without the crew pod restarting.
