# minecraft-fwb

The FWB Minecraft Bedrock server and everything that watches it. How the chart
is deployed, how its values are organised and how to work on it all live in the
repository [README](../../README.md); this file is for the runbooks that belong
to the chart itself.

## World chunk loss

**Symptom.** One of these fires, all of them critical, all of them saying the
same thing from a different distance:

| Alert | Reads | Notices a loss within |
|---|---|---|
| `JdwillmsenMinecraftWorldCorruptionReported` | the server's own log line, through the console bridge | a minute |
| `JdwillmsenMinecraftWorldChunksLost` | the map's census of the world against every chunk it has seen | one map refresh interval (15 minutes) |
| `JdwillmsenMinecraftWorldChunkCountDropped` | the same census against its own recent maximum | one refresh interval plus 5 minutes |
| `JdwillmsenMinecraftWorldArchiveShrank` | the nightly backup archive's size | a day |

`JdwillmsenMinecraftWorldNotCensused` is the other half of the set: it says the
census has stopped, which is the state in which neither of the two alerts that
read it, `JdwillmsenMinecraftWorldChunksLost` and
`JdwillmsenMinecraftWorldChunkCountDropped`, can fire whatever the world is
doing. The corruption and archive alerts do not read the census and still can,
at their own distances. Treat it as urgent for the same reason.

A world that is played in only gains chunks. Any of these is data loss until
proven otherwise.

One thing to know before reading the numbers: a lost chunk does not stay
absent. Bedrock generates it again from the seed as soon as a player walks
near, as empty terrain with everything built on it gone. So
`mcmap_world_chunks_missing` falls back towards zero on its own while
`mcmap_world_chunks_lost` — what the alert reads — does not. The gap between
the two on the dashboard is ground that has already been walked back over, and
it is the part a restore cannot be postponed on.

**First, stop the loss getting worse.** The nightly backup rotates archives, so
the clock on the last good copy is running:

1. Suspend the backup CronJob, so tonight's run cannot push the good archive
   out of the retention window.
   ```bash
   kubectl -n jdwillmsen-prd patch cronjob jdwillmsen-minecraft-fwb-prd-backup \
     -p '{"spec":{"suspend":true}}'
   ```
   Suspending stops runs that have not started, not one already in flight. The
   run starts at 04:00 UTC and takes about three minutes; if the alert arrived
   inside it, this prints the Job's name:
   ```bash
   kubectl -n jdwillmsen-prd get cronjob jdwillmsen-minecraft-fwb-prd-backup \
     -o jsonpath='{.status.active[*].name}{"\n"}'
   ```
   Let it finish and do not delete it. It may be holding the server's saves,
   and what it trims is the oldest of the `backup.keep` (14) archives, not the
   newest good one. Count the window from the archive list afterwards, since
   that run has added an archive of the damaged world to it.
2. Do not restart the server pod to "see if it comes back clean". The repair the
   server runs at world open drops the records it cannot find, so a clean start
   is the damage being made permanent, not the world being intact.

**Then measure it.** The point of this signal is that the size and the location
of the loss are both already known:

- The dashboard **jdwillmsen / Minecraft FWB World Integrity** has the count per
  dimension, the per-snapshot delta, the server's corruption lines and the map's
  own log line with block coordinates.
- The map's internal API has the full list rather than the logged sample. It is
  on the cluster-only port, so reach it with a port-forward. Every call to it
  in this file wants its bearer token in `INTERNAL_TOKEN`; this loads it into
  the variable without printing it, and belongs in your own terminal rather
  than an agent's. The port-forward holds the terminal it runs in, here and
  wherever else this file shows one: run it in a second terminal, and keep
  the token and the requests together in the first:
  ```bash
  INTERNAL_TOKEN=$(kubectl -n jdwillmsen-prd get secret jdwillmsen-minecraft-fwb-prd-map-internal-token -o jsonpath='{.data.token}' | base64 -d)
  kubectl -n jdwillmsen-prd port-forward deploy/jdwillmsen-minecraft-fwb-prd-map 9090:9090
  curl -s -H "Authorization: Bearer $INTERNAL_TOKEN" \
    http://127.0.0.1:9090/internal/v1/world | jq
  ```
  The response carries `chunks`, `missing` and `lost` per dimension, and up to
  20 lost chunks as block coordinates in `lostSample`. The token is the map's
  internal-token Secret. Mint nothing and print nothing else from that
  namespace in a shared terminal.
- The server's log line names how many table files went:
  `LevelDB worlds/FWB/db status NOT OK(Corruption: N missing files; e.g.: ...)`.

A missing chunk is not the same as a census that could not run. If the tables are
gone but the database's manifest still lists them, the census cannot read the
world at all: it fails, `mcmap_world_census_failures_total` moves, the gauges
hold their last values, and `JdwillmsenMinecraftWorldNotCensused` is the alert
that fires. That state resolves itself the moment the server repairs the
database, at which point the chunk count is short and the lost-chunk alert
takes over. Measured in the local test rig: 3 of 5 table files deleted left the
census failing; after LevelDB's recovery — the server's own "Trying repair" — the
next census reported 51,357 of 153,058 chunks missing.

**Then restore.** There are two sources to restore from, and the map's is
usually the better one:

| From | How far back | Where |
|---|---|---|
| The map's retained generation | one map refresh interval (15 min) or two | [Restoring from a retained generation](#restoring-from-a-retained-generation) below |
| The nightly backup archive | up to 24 hours | [docs/minecraft-fwb-restore-runbook.md](../../docs/minecraft-fwb-restore-runbook.md) |

The archive runbook covers choosing an archive, extracting it onto the scratch
PVC, verifying it there, and promoting it onto the live world as a deliberate
manual step. The generation procedure below replaces only its first step —
where the world on scratch comes from — and then hands back to it. Two things
specific to a chunk loss whichever source is used:

- Verify the candidate archive by its chunk count, not only by its size. The
  archive is compressed, so a few thousand chunks are a percent or two of
  bytes; the count is exact.
- Once the restore is promoted, the map's ledger still remembers the chunks the
  damaged world was missing, which is deliberate — a restart during an incident
  must not take the damage as the new normal. Clear it only after the restore is
  verified, and note that clearing it is also what lets the map start promoting
  snapshots again, so a generation you still want must be copied off first:
  ```bash
  curl -s -X POST -H "Authorization: Bearer $INTERNAL_TOKEN" \
    -H 'Content-Type: application/json' \
    -d '{"checkedAt":"<checkedAt from the GET above>"}' \
    http://127.0.0.1:9090/internal/v1/world/acknowledge
  ```
  It names the count it accepts, so a census that landed while you were reading
  the last one — and may hold losses nobody has looked at — is refused with 409
  rather than accepted in its place. Acknowledging is logged with the number of
  chunks it forgets. It is the only action that clears the alert without the
  world being repaired, so it is also the wrong move while the loss is
  unexplained.

**Finally, turn the backup back on.**

```bash
kubectl -n jdwillmsen-prd patch cronjob jdwillmsen-minecraft-fwb-prd-backup \
  -p '{"spec":{"suspend":false}}'
```

`JdwillmsenMinecraftWorldArchiveShrank` will keep firing until the median of the
week's archives has moved past the restored size, and
`JdwillmsenMinecraftWorldChunkCountDropped` until the 24-hour baseline rolls
past it. Both are true statements about the world while they last.

### What each signal depends on

- The chunk census needs the map (`map.enabled`) and the console bridge
  (`global.consoleBridge.enabled`), and a map image carrying the census. The
  rules evaluate against nothing until that image is deployed, which
  `JdwillmsenMinecraftWorldNotCensused` reports rather than leaving silent.
- The corruption gauge needs the console bridge sidecar, and only sees lines
  from the process it is attached to plus the history that process replays.
- The Loki rule `JdwillmsenMinecraftWorldCorruptionLogged` ships in this chart
  but does not evaluate yet; `worldIntegrity.loki` in `values.yaml` says exactly
  which two platform-side changes it waits on. The Prometheus corruption rule
  reads the same two log lines and needs neither.

## Restoring from a retained generation

The map holds the last two world snapshots it proved whole, on its own PVC
under `/data/generations`, and stops promoting new ones the moment the chunk
census reports a loss. So after a loss the newest copy it holds is from
*before* the loss — minutes of play rather than the archive's hours. The map
image must be one that carries generations (`map.image.tag`); if
`mcmap_generations` is absent or `0`, there is nothing here to restore from
and the archive runbook is the only path.

This replaces **Step 1** of
[the restore runbook](../../docs/minecraft-fwb-restore-runbook.md#step-1--run-the-restore-job):
it puts a world on the scratch claim without running the restore Job. Its
[Conventions](../../docs/minecraft-fwb-restore-runbook.md#conventions),
[Before you start](../../docs/minecraft-fwb-restore-runbook.md#before-you-start)
and Steps 2 to 4 are unchanged and are what verifies and promotes the result.
Read that file first; everything it says about not booting the world you are
about to promote, and about saving the damaged world aside, applies here too.

**Provenance**, in the same sense as the runbook's own
[Provenance of the commands](../../docs/minecraft-fwb-restore-runbook.md#provenance-of-the-commands):
the map has kept generations in production since 2026-10-05, when its first
snapshot was counted whole and promoted and `mcmap_generations` read 1. The
copy below has not been run against production, since that takes the server
and the map down. The copy pod's shell logic and the layout it
reads were exercised against a real world in the local test rig; the claim
names, the map Deployment's name and both security contexts were checked
against `helm template` with the production value files; the read-only mount
of the map PVC in a second pod on its node was exercised read-only against
production. Everything from step 5 on is the runbook's, with its own
provenance.

### 1. Record what production runs, before anything scales down

Do [Record what production runs
now](../../docs/minecraft-fwb-restore-runbook.md#record-what-production-runs-now)
first. The server's version only appears in the log of the running pod, and
Step 2 needs it.

### 2. Choose the generation

```bash
kubectl -n $N port-forward deploy/$R-map 9090:9090
curl -s -H "Authorization: Bearer $INTERNAL_TOKEN" \
  http://127.0.0.1:9090/internal/v1/world | jq .generations
```

```json
{
  "current":  {"name": "a", "takenAt": "2026-10-01T23:43:38Z", "files": 412, "bytes": 780906719},
  "previous": {"name": "b", "takenAt": "2026-10-01T23:28:37Z", "files": 412, "bytes": 780888301},
  "damaged":  {"name": "damaged", "takenAt": "2026-10-02T02:04:49Z", "files": 405, "bytes": 736112044}
}
```

`current` is the newest snapshot the census found whole and is normally the
one to take. Take `previous` instead when `current`'s `takenAt` is **after**
the first corruption line from the server — the census counts whole chunks
only, so a world that lost part of a chunk's records can still be promoted,
and the dashboard's corruption panel is where that timestamp is. `damaged` is
kept for [measuring the
loss](../../docs/minecraft-fwb-restore-runbook.md#measuring-the-loss) and is
never a restore source.

Compare the chosen `takenAt` with the newest good archive's timestamp. That
difference is what this saves; everything else about the decision is the
runbook's [Decide that a restore is the right
move](../../docs/minecraft-fwb-restore-runbook.md#decide-that-a-restore-is-the-right-move).

### 3. Scale the server and the map down

```bash
kubectl -n $N scale statefulset $R-minecraft-bedrock --replicas=0
kubectl -n $N wait --for=delete pod/$R-minecraft-bedrock-0 --timeout=180s
kubectl -n $N scale deployment $R-map --replicas=0
kubectl -n $N wait --for=delete pod -l app=$R-map --timeout=180s
```

The map is scaled down because its PVC is RWO and the copy pod needs it, not
because the generations are at risk: the map promotes nothing while chunks are
lost. `JdwillmsenMinecraftMapStale` fires while it is down, as does
`JdwillmsenMinecraftWorldNotCensused` after a while. Both are true.

The server is down from here until the runbook's Step 4 scales it back up.

### 4. Copy the generation onto the scratch claim

The map's PVC is mounted **read-only**, so this cannot damage the copy it is
reading even if the pod is wrong. Set `GEN` to the `name` chosen above and
`TAKEN` to its `takenAt`, exactly as the API printed it.

A name is a slot, not a snapshot: the map writes each new snapshot into the
slot `current` does not name, so between choosing and Step 3 stopping the map
a capture can put a different snapshot under the name you picked. The pod
therefore refuses to copy unless the slot still holds the snapshot taken at
`TAKEN`.

```bash
GEN=a
TAKEN=2026-10-01T23:43:38Z
kubectl -n $N delete pod restore-generation --ignore-not-found --wait=true
sed "s|__GEN__|$GEN|g; s|__TAKEN__|$TAKEN|g" <<'EOF' | kubectl create -f -
apiVersion: v1
kind: Pod
metadata:
  name: restore-generation
  namespace: jdwillmsen-prd
  labels: {purpose: restore-generation}
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 2000
    fsGroup: 2000
    seccompProfile: {type: RuntimeDefault}
  containers:
    - name: copy
      image: alpine/k8s:1.37.0
      command: ["sh", "-c"]
      args:
        - |
          set -eu
          GEN=__GEN__
          SRC=/mapdata/generations/$GEN
          [ -f "$SRC/generation.json" ] || { echo "FATAL: $SRC is not a complete generation"; exit 1; }
          grep -qF '"takenAt":"__TAKEN__"' "$SRC/generation.json" || { echo "FATAL: slot $GEN no longer holds the snapshot taken at __TAKEN__; choose again from the markers below. Nothing copied."; cat /mapdata/generations/*/generation.json; exit 1; }
          cat "$SRC/generation.json"; echo
          [ ! -e /scratch/FWB ] || { echo 'FATAL: /scratch/FWB already exists; clear it or save it aside first. Nothing copied.'; exit 1; }
          cp -a "$SRC/FWB" /scratch/FWB
          sync
          echo "copied $(find /scratch/FWB -type f | wc -l) files, $(du -sb /scratch/FWB | cut -f1) bytes from generation $GEN"
          echo "db files: $(ls /scratch/FWB/db | wc -l)"
          ls -la /scratch /scratch/FWB
          df -h /mapdata /scratch | tail -2
      resources:
        limits: {cpu: "1", memory: 512Mi}
        requests: {cpu: 200m, memory: 128Mi}
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: {drop: ["ALL"]}
      volumeMounts:
        - {name: mapdata, mountPath: /mapdata, readOnly: true}
        - {name: scratch, mountPath: /scratch}
  volumes:
    - name: mapdata
      persistentVolumeClaim: {claimName: jdwillmsen-minecraft-fwb-prd-map, readOnly: true}
    - name: scratch
      persistentVolumeClaim: {claimName: jdwillmsen-minecraft-fwb-prd-restore-scratch}
EOF
n=0; until kubectl -n $N get pod restore-generation -o jsonpath='{.status.phase}' | grep -qE "Succeeded|Failed" || [ $n -ge 150 ]; do n=$((n+1)); sleep 3; done
kubectl -n $N get pod restore-generation -o jsonpath='{.status.phase}{"\n"}'
kubectl -n $N logs restore-generation
```

Proceed only on `Succeeded`. Check that the file count the pod reports matches
the generation's `files`, and that the `db files` count is that minus the
three files beside the database (`level.dat`, `level.dat_old`,
`levelname.txt`). If `/scratch/FWB` already held a world, deal with it exactly
as the runbook's [What is parked on the scratch
claim](../../docs/minecraft-fwb-restore-runbook.md#what-is-parked-on-the-scratch-claim)
says and re-run; the pod refuses rather than overwriting, and the generation
is untouched either way.

```bash
kubectl -n $N delete pod restore-generation --wait=true
```

### 5. Verify and promote with the runbook

Continue at the runbook's [Step 2 — verify on a copy, never on the scratch
world
itself](../../docs/minecraft-fwb-restore-runbook.md#step-2--verify-on-a-copy-never-on-the-scratch-world-itself).
From here nothing is specific to generations: the world on scratch is verified
by booting a copy of it on the exact server production runs, the damaged live
world is saved aside, and the promotion is compared by sha256 manifest. One
expectation differs — the verify pod's `db files` count is compared against
the copy pod's output above rather than against a restore Job's.

### 6. Bring the map back, then acknowledge

After the runbook's Step 4 has the server `Ready`:

```bash
kubectl -n $N scale deployment $R-map --replicas=1
```

Only then clear the map's ledger, with the `POST .../acknowledge` call under
[World chunk loss](#world-chunk-loss) above. Read `checkedAt` afresh for it:
the map counts the world again as it starts, so the value from before the
restore has been replaced and the call answers `409` with it. On a `409`,
read `/internal/v1/world` again and retry with the value it gives. Acknowledging is also what lets
the map promote snapshots again, so doing it earlier would let the next
snapshot overwrite the generation you are restoring from. The map's first
cycle after that promotes the restored world, and `mcmap_generations` returns
to `2` one cycle later.

### What the map does on its own

- It promotes a snapshot to `current` only when the census proved it whole.
  A snapshot that lost chunks goes to `generations/damaged` instead and
  displaces neither generation; only the first such snapshot is kept.
- A capture interrupted part-way — including by the node dying, which is the
  case this exists for — leaves the generation that was current whole and
  named. A copy is a generation only once its `generation.json` marker is
  there, and the next start discards anything a killed capture left.
- A volume with no room left costs the copy being built and nothing else; the
  retained copies are never deleted to make space. The failure shows up as
  `mcmap_generation_captures_total{outcome="failed"}` and the restore point
  simply ages.
- Generations are hard links to the mirror's files, so two of them cost one
  world plus what changed between them, not three worlds. Measured on the
  prd volume (2026-10-05): 909 MiB used of 4.84 GiB usable — 745 MiB world
  mirror, 80 MiB tiles, 84 MiB renderer — and 18% of the claim. The ceiling
  is a damaged snapshot and two frozen generations each pinning tables the
  mirror has since compacted away, about three worlds plus the tiles and the
  renderer, around 2.4 GiB or 49%. `JdwillmsenMinecraftVolumeNearFull` fires
  at 80% of any claim in the namespace, which is the signal to expand the map
  PVC; TrueNAS iSCSI expands online.

## Live layer

The map draws players and mobs where they are now, a second or two behind
the game.

```
script pack in the world   prints one line per list, once a second, to the server console
console bridge (sidecar)   keeps the newest 256 of those lines      GET /script, long poll
map                        newest whole list per dimension, in memory
browser                    GET /api/live, server-sent events, behind the map's login
```

- **The pack** is a behaviour pack on the stable script API. It reads
  positions and prints them, and does nothing else: no commands, no
  experiments, no resource pack, so the world stays a no-cheats world with
  its achievements. It ships inside the map image and is put into the world
  by the `install-map-pack` init container on the game server pod
  (`minecraft-bedrock.initContainers` in `values-map-pack.yaml`), which runs
  `install-pack` before the server opens the world.
- **The bridge** (0.7.0 and later) recognises the pack's lines by their
  `[Scripting] MCMAP1` prefix and holds them apart from the join and leave
  events the agent reads.
- **The map** (1.4.0 and later; the pack itself needs 1.5.0) asks the bridge
  for them, drops positions older than `map.live.ttl`, and streams the rest.
  Its settings are `map.live` in `values.yaml`.

The pack prints a heartbeat with every sample even when nobody is online, so
a layer that has gone quiet is broken, never merely empty.

### The init step cannot hold the server, and must stay that way

An init container that fails keeps the game server from starting. This one
is built not to: a missing world, an unwritable volume, a pack list it cannot
parse — the installer logs it and exits 0, and the server starts without the
pack. `tools/tests/test-map.sh` pins the pod spec around it so that stays
true — no Secret, one mount, the map's own image at a tag no newer than the
map's, the server's own user, no wrapper and no probe. The step is in a file of its own,
`values-map-pack.yaml`, which Renovate is told to leave alone: the map's image is merged
unattended, and that update must not reach the game server's pod. The comment on `minecraft-bedrock.initContainers`
has the reasons.

Two things can still hold the server in `Init`:

- **A replacement the installer could neither finish nor undo.** Updating an
  installed pack moves the old one aside first; if the new one cannot be put
  in place and the old one cannot be put back, the installer exits non-zero
  on purpose and the kubelet runs it again. The second run finds nothing to
  move aside, so it installs or skips like any other and the server starts.
  It is one retry, not a loop, and the container's log says `holding the
  server` when it happens.
- **The image pull.** The node keeps the image once it has it, but a server
  restart that has to fetch a new tag while ghcr.io is unreachable waits in
  `Init:ImagePullBackOff` until it can. That is true of every image in the
  pod, and this adds one.

### Turning it off

**Removing the init container does not remove the pack.** The pack's files
and the world's registration of them are on the server's volume
(`behavior_packs/mcmap-live/` and `worlds/FWB/world_behavior_packs.json`).
Delete the block and the server restarts with the pack still loaded.

To take the pack out of the world:

1. In `values-map-pack.yaml`, change the init container's argument from `install-pack`
   to `uninstall-pack`. Leave the rest of the block exactly as it is.
2. In the same change set `map.live.enabled: false`, so the map stops asking
   for records and the two live alerts are not rendered. Without this
   `JdwillmsenMinecraftMapLiveStale` fires fifteen minutes later, correctly.
3. Merge. The sync announces the restart to connected players and restarts
   the server; the init container unregisters the pack and deletes its files
   before the server starts.
4. Confirm it, because the uninstaller fails open exactly as the installer
   does and a step that could not run leaves the pack in place:

   ```bash
   kubectl -n jdwillmsen-prd logs jdwillmsen-minecraft-fwb-prd-minecraft-bedrock-0 -c install-map-pack
   # expect: "pack uninstalled"
   kubectl -n jdwillmsen-prd logs jdwillmsen-minecraft-fwb-prd-minecraft-bedrock-0 -c jdwillmsen-minecraft-fwb-prd-minecraft-bedrock | grep -E 'Pack Stack|MCMAP1' | head
   # expect: "Pack Stack - None" and no MCMAP1 lines
   ```

Leave `uninstall-pack` in place afterwards. It does nothing on a world with
no pack, and removing the block is another server restart that buys nothing;
fold it into the next change that restarts the server anyway.

`map.live.enabled: false` on its own is the smaller switch. It restarts only
the map and takes the markers off the page, and it does **not** unload the
pack: the server goes on sampling and printing. Use it for a problem in the
map or the browser, never for one in the server.

**When to roll back.** When the 30-minute average of `mc_agent_server_tps`
sits more than 2.0 below the average for the same half hour of the day over
the previous seven days:

```promql
max(avg_over_time(mc_agent_server_tps{namespace="jdwillmsen-prd"}[30m]))
  -
(
    max(avg_over_time(mc_agent_server_tps{namespace="jdwillmsen-prd"}[30m] offset 1d))
  + max(avg_over_time(mc_agent_server_tps{namespace="jdwillmsen-prd"}[30m] offset 2d))
  + max(avg_over_time(mc_agent_server_tps{namespace="jdwillmsen-prd"}[30m] offset 3d))
  + max(avg_over_time(mc_agent_server_tps{namespace="jdwillmsen-prd"}[30m] offset 4d))
  + max(avg_over_time(mc_agent_server_tps{namespace="jdwillmsen-prd"}[30m] offset 5d))
  + max(avg_over_time(mc_agent_server_tps{namespace="jdwillmsen-prd"}[30m] offset 6d))
  + max(avg_over_time(mc_agent_server_tps{namespace="jdwillmsen-prd"}[30m] offset 7d))
) / 7
```

Below `-2` is a rollback, by the procedure above, not something to tune in
place. Lowering `PACK_MOB_CAP` is not a substitute: the cap bounds what the
pack reads and prints, but the server still walks every entity to find the
nearest thousand. Read `mcmap_live_pack_scan_seconds` and
`mcmap_live_pack_interval_seconds` beside it; an interval above one second is
the pack slowing itself down because its samples were taking too long. The
same hours are compared because TPS follows who is online, and because a
restart lifts it by itself (see `scheduledRestart`), which the rollout's own
restart will do on its first day.

### When the layer is stale

`JdwillmsenMinecraftMapLiveStale` (no record for `map.live.alert.staleAfter`)
or `JdwillmsenMinecraftMapLiveNeverStarted` (no record at all in
`map.live.alert.lookback`), both warnings. Nothing but the markers is
affected. Work down the path, and stop at the first hop that has nothing:

1. `mcmap_live_frames_total` by `result`, and `mcmap_live_polls_total` by
   `result`, on the map. Polls `failed` or `busy` with no frames: the map
   cannot reach the bridge. Polls `empty` only: the bridge has nothing to
   give. Frames `unparseable`: the pack and the map disagree about the
   format, which the shared image tag exists to prevent.
2. `mc_console_bridge_script_records_total` by `result` on the bridge, with
   `mc_console_bridge_console_connected`. Not counting while connected: the
   server is not printing records.
3. The server log for `[Scripting]`. `Pack Stack - None` at start means the
   pack is not installed, and the `install-map-pack` container's log says why
   it skipped. A pack stack line naming `mcmap live positions` with no
   `MCMAP1` lines after it means the script failed to load, and the
   `[Scripting]` error beside it says how.

A server restart is not an outage of this layer and does not alert: the pack
stops with the server and resumes when the world has loaded, minutes later.

### Known limits

- **Log volume.** The pack writes about 11 to 14 KB/s of records to the
  server's stdout, roughly 1 GB a day, at the load measured on a copy of this
  world. Every byte is a container log line, and the whole cluster was
  sending Loki about 16 KB/s before it, so this about doubles the cluster's
  log ingest. Nothing in the collector drops these lines. A drop rule for
  `[Scripting] MCMAP1` belongs in the platform repo and is not part of this
  chart.
- **Console history.** The server keeps the last 50 console lines and
  replays them to the bridge whenever it reconnects. The pack fills those 50
  lines in a few seconds, so what a reconnect replays is now almost all
  records. Anything the bridge used to recover from that history has to have
  been printed in the last few seconds: joins and leaves, and the
  world-open corruption line `JdwillmsenMinecraftWorldCorruptionReported`
  reads. A bridge that is connected when a line is printed still sees it.
- **Restarts.** The pack is loaded when the server starts and at no other
  time. Installing it, removing it, a new map image tag in the init
  container and a changed `PACK_MOB_CAP` all take effect on the next server
  restart, which changing that block causes. For that reason the init
  container's tag does not follow `map.image.tag`: a map release that leaves
  the pack alone moves only the map's tag and restarts only the map. Move
  the init container's tag when the pack or its installer changed, and never
  past the map's.
- **A brand-new volume.** The installer skips a world that does not exist
  yet, and the server only creates it on its first start. So a server
  started on an empty volume runs without the pack until it is restarted
  once, and `JdwillmsenMinecraftMapLiveNeverStarted` fires meanwhile. A world
  restored onto the volume is there before the pod starts and is not
  affected.

## Tests

```bash
tools/tests/test-world-integrity-alerts.sh   # promtool unit tests for the rules above
tools/tests/test-tick-rate-alerts.sh
tools/tests/test-map.sh                      # the map's exposure, the pack's init step, the map and live alerts
```

Every `tools/tests/test-*.sh` is discovered and run by CI. The alert suites skip
themselves with a message when `promtool` is not on `PATH`, so a local pass is
not evidence on its own.
