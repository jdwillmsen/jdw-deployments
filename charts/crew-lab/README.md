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

**Windows 1.26.60 and later** dial NetherNet only: on the LAN add the server at
`192.168.1.163`, port **31137** (TCP signaling; gameplay UDP 31140-31159 is
negotiated). The RakNet route below no longer reaches the server, because the
server runs `transport=nethernet` and the crew units, which dial RakNet only,
cannot join it until crew gains a NetherNet dialer. The `crew.prd.jdwlabs.com`
router forward is RakNet-only and does not carry NetherNet.

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
| `crew-21` | Umber (mender) |
| `crew-22` | Vein (builder) |

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

## Squads

`crew-18`-`crew-20` (Rusty, Slate, Tinder) are not working units: they are
squad `lab-alpha`'s three warriors (`role: warrior` with `squadRole` vanguard,
striker, ranger, in that order), built to fight side by side rather than work
a plot. Rendering leaves them out of everything a working unit gets: no
`WORK_PLAN` on the pod, no plot tp and no yard restocking from the unit-kit
pack, so their plots in the yards grid stay unbuilt. What the pack
gives them is a catalog kit at tier 5 (netherite, maxed enchantments;
[KITS.md](KITS.md)): `kits/vanguard/t5` for the vanguard, `kits/duelist/t5` for
the striker and `kits/ranger/t5` for the ranger. The pack hands it over whole
when no netherite chestplate is worn or carried, so it is given on join and
again after a death or a restart. Each hand-out starts a 16 s cooldown, so a
slow pickup or a full inventory cannot produce a second kit; a chestplate that
is carried but not worn gets the wearing step again instead. Golden apples are
topped up to 16 when none are left. The world's `keepinventory` rule is
switched on once by the pack, so a dead warrior keeps its kit; the rule is
world-wide, so it also applies to real players and yard units. An unknown
`squadRole` fails the render.
Changes to that kit follow the pack
rules above the init container in `values.yaml`: rerun
`tools/crew-lab-kit-rev.py --write` to update `UNIT_KIT_REV` (the chart test
fails while it is stale), which restarts the lab server and disconnects its
players. The `unitKitGate` PreSync job holds that sync until no human is online
(crew units and `load-*` bots do not count); see Kit rollouts below.

The pod carries `CREW_ROLE/<squadRole>` and `CREW_SQUAD/<squad>` on warriors
only.

### Warriors on NetherNet

The lab server accepts NetherNet only, and it turns an unsigned player away at
the transport, so a unit cannot join it offline. `crew-18`-`crew-20` set
`nethernet: true`: they take `crew.nethernet.host` and `.port` as `MC_HOST` and
`MC_PORT` and run with `MC_OFFLINE=false`, so each signs in with a Microsoft
account that owns Minecraft. Every other unit keeps the RakNet address and the
offline join, and stays unable to connect until it is given an account.

Each warrior needs one device-code login, run by the owner. The unit prints a
code once to its log on the first start with an empty token cache and waits;
open the Microsoft link it names in a browser, enter the code, and sign in as
that unit's account:

    kubectl -n jdwillmsen-prd logs -f deploy/crew-18

Do this in your own terminal, not through an agent. The token is kept under
`/data/crew-18/auth` on the shared volume, so a restart does not ask again.
Use a different account for each warrior: one account cannot be in the world
twice. Check Microsoft's terms and rate limits for the accounts you use.

### Warrior training switch

The squad id carries a `lab-` prefix on purpose: the squad service only hands a
tactics profile or a duel roster to a squad with that prefix, and a unit only
asks for one when its squad has it and `TACTICS_CONTROL_DIR` is set (this
chart sets it for exactly those warriors). The directory is the ConfigMap
`crew-tactics-control`; its file `training` must hold exactly `on` for a unit to
take anything from its squad. `crew.tactics.training` sets it and defaults to
`"off"`, so a fresh or half-applied release trains nothing. Kubelet refreshes
the mounted file in about a minute and the units re-read it every second, with
no pod restart. Changing it is a values change, so turning training on is a
reviewed PR like any other; the squad side also lapses on its own (a duel in 45
seconds, a profile five minutes after its last fetch). See the gameops
`docs/tactics-training.md` for the operator side.

## Menders and builders

`crew-21` Umber (`role: mender`) and `crew-22` Vein (`role: builder`) work in
creative mode on a task and never in a yard. The pod carries `CREW_ROLE=<role>`
and `CREW_LAB=true`, which crew requires of these roles and sets nowhere else;
it carries no `CREW_SQUAD`, `WORK_PLAN` or `CREW_UNIT_ROLE` (no outfit, so the
plain name-coloured skin). They idle until tasked and take one task template
each through crew-control: `repair_build` for a mender, `build_blueprint` for a
builder. Both are on the shared claim, so they add no PVC.

- **Creative:** only the server console can set it, and an offline unit is a
  fresh survival player on every join. The unit-kit pack's equip function runs
  `gamemode creative` for each of them whenever it is not creative, about every
  2 s, so no `labcreative` process is needed.
- **Home:** repair needs the mender on loaded chunks inside the Colosseum, but
  a task may only `goto` within x, z -500..499. So when the mender joins within
  200 blocks of the hub the pack teleports it to `crew.menderHome` (the arena
  floor at the centre, two blocks up; creative takes no fall damage), or to
  its own `home` (`x`, `"y"`, `z`; quote `y`, YAML reads a bare one as true).
  The builder has no home: it is tasked with a `goto` inside the bound.
- **Gear:** none. They get no plot tp, yard restock, work tools or bread.

To add another, append the next id and name from the ordered list in
`values.yaml` with `role: mender` or `builder` and `sharedVolume: true`, then
rerun `tools/crew-lab-kit-rev.py --write`. A role no template knows, a squad on
one of these units, or a mender with no home fails the render. Like any pack
change it restarts the lab server (see Kit rollouts).

- Probes: a startup probe on `/healthz` (five minutes), then liveness `/healthz`, readiness `/readyz`. Readiness is false while
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

## Kits

[KITS.md](KITS.md) lists the kit catalog: 12 roles in 6 tiers for players and
crew units, and 7 mob types in the same tiers, each handed out from the
console or rolled at random (`function kits/random`, `function mobs/random`).
`tools/crew-lab-kits.py` builds it into `files/kits.tar.gz`, which the pack's
init container unpacks; a change ships like any pack edit, with a
`UNIT_KIT_REV` refresh.

### Kit rollouts

`UNIT_KIT_REV` is a checksum of the rendered pack and the install container,
so a kit change cannot merge without a new revision. With `unitKitGate.enabled`
(on in `values-prd.yaml`) every sync first runs the `unit-kit-gate` PreSync
job. It passes at once when the server pod already runs the new revision or
does not exist, and otherwise waits up to `unitKitGate.waitSeconds` (600) for
the human players to leave, checking every 30 s. A player counts as human
unless named by `crew.units`, matching `labRebuild.nonHumanPlayerPatterns`, or
signed in with an empty XUID. If someone is still on after the wait, or the
player list cannot be read, the job fails, the sync fails and nothing is
restarted; run the sync again once the lab is empty. Set
`unitKitGate.enabled=false` to skip the check.

## Wildlife packs

The wildlife add-on packs (behavior and resource) are installed by the
`install-lab-packs` init container, which runs the `ghcr.io/jdwillmsen/lab-packs`
image after `install-unit-kit`. The installer replaces each pack's folders in
the world and merges its uuid and version, read from the pack's own manifest,
into the world's pack lists, keeping other entries. The source is in the
gameops repo: the packs in `packs/` and the installer in `minecraft/lab-packs`.

To ship a pack update, publish a new `lab-packs` image through the gameops
release, set the tag in `values.yaml` (Renovate leaves it alone), and run
`tools/crew-lab-kit-rev.py --write`. The revision covers this container, so the
restart goes through the unit-kit gate like any kit change.

The wildlife pack's README has a manual checklist that only works on the live
lab with a client; the owner runs it after a rollout.

## Colosseum

The lab's arena stands on the flat ground centred on x 0, z -758: an ellipse
with a 100 x 72 sand floor, three tiers of seating, a three-storey arcaded
outer wall with an attic, four portcullis gates on the axes, eight spawn pens
under the stands and a paved plaza. It is built into the world, not the pack,
so no restart is involved. `tools/crew-lab-colosseum.py` generates the build
as `fill` commands and writes `arena.json`, the layout the arena director reads
(pens, gate boxes, squad start gate, boss point):

```
tools/crew-lab-colosseum.py /tmp/colo --save=/tmp/colo/vox.npy
tools/crew-lab-colosseum.py /tmp/colo --feed=jdwillmsen-prd/jdwillmsen-crew-lab-prd-minecraft-bedrock-0
minecraft/crew/lab/arena.sh run k8s:jdwillmsen-prd/<pod> --layout /tmp/colo/arena.json ...
```

The console runs about 20 commands a second, so a full build takes about 15
minutes. The build only places blocks: clear the footprint (x -112..111, z
-860..-637, y 64..113) and load it first, with four ticking areas of at most
100 chunks each, and remove them afterwards. Save the area in 56-block tiles
with `structure save` before a rebuild so it can be put back with `structure
load`. To change a built Colosseum, save the voxels with `--save` and later
pass `--against` to emit only the difference.

Each pen gate is a straight 3 x 3 box of iron bars the director opens with
`fill ... air` and shuts with `fill ... iron_bars`. The generator refuses to
write a build in which a pen could reach the arena with its gate shut.

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
`/auth`, `/v1/work`, `/v1/jobs`, `/v1/places`, `/v1/heatmap`, `/v1/insights`, `/v1/capacity` and
`/v1/units/{id}/explain`, `/v1/units/{id}/inventory/changes`, `/v1/events` and `/v1/replay/positions`, all served by crew-control.
Viewing needs no sign-in. Every request to `/v1/work`, `/v1/jobs` and
`/v1/places`, reads included, needs a passkey session, and so do `/v1/heatmap`, `/v1/events` and `/v1/replay/positions`; `/auth` is the sign-in
itself. The task API, `/metrics`, the
probes and the units' own `/v1/units/{id}/work` and `/events` stay
cluster-only; `tools/tests/test-crew-route.sh` fails if any of them
becomes reachable. For those, use a port-forward:

```
kubectl -n jdwillmsen-prd port-forward deploy/crew-01 8080:8080
```

crew-control's fleet series are scraped from `/metrics` by a ServiceMonitor
(`crew.control.metrics`), which reaches the Service directly; the metric
catalogue is in the crew-control README in gameops.

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

### Signing in with Xbox

Off by default (`crew.control.xbox.enabled: false`). On, set `clientId` (the
Entra application ID) and `accounts` (`operator` and `xuid` pairs; every
operator must be in `crew.control.operators`). The client secret is read from
key `client-secret` of Secret `crew-control-xbox`, mounted at `/xbox`; the chart
never creates it. The public route already forwards `/auth`, which covers the
sign-in paths. Set-up and rollback steps are in the gameops runbook
`docs/runbooks/crew-xbox-signin.md`.

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
