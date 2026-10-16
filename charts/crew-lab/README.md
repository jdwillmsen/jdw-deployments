# crew-lab

An offline Bedrock lab server and `crew-1`, a worker unit that joins it. The
lab is a separate ArgoCD app from the main server, so a mistake here cannot
restart or reschedule that server.

| Piece | What |
|---|---|
| `<release>-minecraft-bedrock` | itzg `minecraft-bedrock` subchart: StatefulSet, ClusterIP Service on 19132/UDP, world on `truenas-iscsi` |
| `crew-1` | Deployment (1 replica, `Recreate`), ClusterIP Service on 8080, data on `truenas-nfs` |

## Offline, and therefore private

The lab server runs with online mode and the allow list off, and `crew-1` sets
`MC_OFFLINE=true`, so there is no sign-in step at all. An offline server lets
anyone who can reach it join under any name, so its Service is ClusterIP only:
no NodePort, no LAN exposure. Keep it that way unless online mode is turned
back on.

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

Neither the status API nor the camera stream has authentication and both carry
the unit's position, so there is no Ingress. Use a port-forward:

```
kubectl -n jdwillmsen-prd port-forward deploy/crew-1 8080:8080
```

Then open `http://127.0.0.1:8080/camera`, or `curl 127.0.0.1:8080/readyz`. The
page loads three.js from a CDN, so the browser needs internet access.

## Checks after a sync

```
kubectl -n jdwillmsen-prd get pods -l app=crew-1
kubectl -n jdwillmsen-prd logs deploy/crew-1 | grep auth_offline
```

To test a death or a server restart, `kubectl exec` into the server pod and use
its console, or delete the server pod and watch `/readyz` go false and come back
without the crew pod restarting.
