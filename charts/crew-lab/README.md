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
- `/data` holds the token cache (unused offline) and the texture atlas cache.
  The atlas is a few MB: the pack it is built from is fetched into `/tmp` and
  dropped after the build.
- Units 01-03 each keep the atlas on their own claim. Units 04 and up share the
  `crew-shared` claim and one atlas directory (`crew.camera.atlasDir`): the first
  unit to need it fetches Mojang's sample resource pack from github.com and
  builds it, the others wait and read it, and a restart finds it already built.
  That claim is ReadWriteMany, so the storage driver does not hand its root to
  the pod's group; the `share-owner` init container makes `/data` owned by
  1000:1000 on each start, which changes only the root directory.
- If the fetch fails the camera stays on flat colours and retries after 5 to 10
  minutes; nothing else is affected. GitHub limits anonymous API calls to 60 an
  hour per address, which a single shared build stays far inside.
- The image tag in `values.yaml` must be a published `minecraft-crew` release.
  A tag that does not exist leaves the pods in `ImagePullBackOff`.

## Reaching the console

Open <https://crew.prd.jdwlabs.com>. It is the crew-control console: every unit's
camera and state on one page, public and with no sign-in. That is fine for the
lab, which is not FWB, but it shows where the units are to anyone with the link,
and at most `crew.camera.maxViewers` people can watch one unit at once.

Keys: `1`-`9` pick a unit, `c` cycles the camera mode (`first`, `third`, `orbit`,
`top`), `w` toggles the wall of all units.

crew-control (`crew.control`) renders its unit list from `crew.units`, skipping
any with `replicas: 0`, and proxies only each unit's camera routes. The route
allow-lists `/`, `/camera`, `/units`, `/v1/units/stream`, `/static`, `/signin`,
`/auth`, `/v1/work`, `/v1/jobs` and `/v1/places`, all served by crew-control.
Viewing needs no sign-in. Every request to `/v1/work`, `/v1/jobs` and
`/v1/places`, reads included, needs a passkey session; `/auth` is the sign-in
itself. The task API, `/metrics`, the
probes and the units' own `/v1/units/{id}/work` and `/events` stay
cluster-only; `tools/tests/test-crew-route.sh` fails if any of them
becomes reachable. For those, use a port-forward:

```
kubectl -n jdwillmsen-prd port-forward deploy/crew-01 8080:8080
```

The image tag in `values.yaml` must be a published `minecraft-crew-control`
release.

The page loads three.js from a CDN, so the browser needs internet access.

## Signing in

Operators (`crew.control.operators`) sign in with a passkey to queue work. Each
has an invite code, a key in the Secret `crew-control-invites` named by the
operator id. The chart only references the Secret. To enrol, open
`https://crew.prd.jdwlabs.com/signin#operator=<id>&invite=<code>`. The owner reads
a code to send it (the owner's command, not an agent's):

```
kubectl -n jdwillmsen-prd get secret crew-control-invites -o jsonpath='{.data.josh}' | base64 -d
```

Each operator must get a different code. Ten wrong codes in a minute briefly
block enrolment for everyone.

Units pull queued work from crew-control with the shared token in Secret
`crew-work` (key `token`), which crew-control and every unit read. Both Secrets
are optional, so pods start without them.

The invite sits in the URL fragment, so it never reaches server or proxy logs.

Rotate one operator's invite, or the work token, without echoing the value, then
restart whoever reads it (crew-control for an invite; crew-control and the units
for the token). The patch touches only that operator's key:

```
kubectl -n jdwillmsen-prd patch secret crew-control-invites --type merge \
  -p "{\"stringData\":{\"josh\":\"$(openssl rand -hex 24)\"}}"
kubectl -n jdwillmsen-prd create secret generic crew-work \
  --from-literal=token="$(openssl rand -hex 24)" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n jdwillmsen-prd rollout restart deploy/crew-control
kubectl -n jdwillmsen-prd rollout restart deploy -l app.kubernetes.io/component=crew
```

Passkeys live in `passkeys.json` on the `crew-control` PVC. To remove one, scale
crew-control to 0 first, edit the file on the volume, then scale back up;
otherwise a write from the running server can undo the edit. Removing an
operator from `crew.control.operators` also means deleting their passkeys the
same way. Work is queued in the shared Postgres (`crew.control.database`), whose
credentials arrive through the `crew-control-db` ExternalSecret.

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

Submit over a port-forward to the unit's Deployment (see "Reaching the console"),
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

## Nightly field rebuild

`labRebuild` (values.yaml; on in `values-prd.yaml`) is a CronJob,
`lab-field-rebuild`, that rebuilds the test fields in `labRebuild.fields`
(`grounds`, `courses`, `trees` and `works`) at 08:15 UTC, 03:15 CDT, so a
test starts from a clean field. An init container runs the crew image's
`/labcourses -o` to write the plans and gameops' `courses.sh` and `nightly.sh`
into a volume; an `alpine/k8s` container runs `nightly.sh`, the same feed as a
manual `courses.sh` run. The crew image supplies the scripts, so they move with
`crew.image.tag`, which must be a release that ships `/labcourses`.

It skips with exit 0 and a log line while anyone online does not match a crew
name or one of `labRebuild.nonHumanPlayerPatterns` (such as `load-*`), or a
`crew-course-*` ticking area exists. It exits 1 if a field reports errors or
the server's state is unreadable. Its ServiceAccount can only `get` the lab
server pod, `get` its logs and `create` on `pods/exec`. `concurrencyPolicy` is
`Forbid` and a run ends after `activeDeadlineSeconds` (40 minutes).

```
kubectl -n jdwillmsen-prd create job --from=cronjob/lab-field-rebuild lab-field-rebuild-now
kubectl -n jdwillmsen-prd logs job/lab-field-rebuild-now -c rebuild
```

## Jobs and places

The console's Jobs panel (press `Shift+J`) queues multi-step jobs that crew-control
splits across the free units. The built-in parallel demo is one of them: it
sends one unit to mine cobblestone, one to fell oak, and one to haul both into
the store chest, using the places below. A stock goal asks for a count of an
item in a chest (for example 64 cobblestone in `store`) and keeps the job
running until the units' last sighting of that chest meets it.

Places are the named chests and areas jobs refer to. The seeded ones come from
`crew.control.places` in values, rendered as `CREW_PLACES`, so they change only
through a values PR and a pod roll, and the console shows them read-only. Today
they are the quarry, grove and three chests of the test grounds on the lab
world. Chests the units find elsewhere appear as unnamed places in the ledger.
Setting `places: []` clears the seeded places.

## Checks after a sync

```
kubectl -n jdwillmsen-prd get pods -l app.kubernetes.io/component=crew
kubectl -n jdwillmsen-prd logs deploy/crew-01 | grep auth_offline
```

To test a death or a server restart, `kubectl exec` into the server pod and use
its console, or delete the server pod and watch `/readyz` go false and come back
without the crew pods restarting.
