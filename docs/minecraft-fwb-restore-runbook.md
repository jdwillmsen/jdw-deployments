# Minecraft FWB — restore runbook

Covers restoring a backup archive produced by the `minecraft-fwb` chart's
backup CronJob (`charts/minecraft-fwb/templates/backup-cronjob.yaml`) via its
companion restore mechanism (`restore-cronjob.yaml`, `restore-pvc.yaml`,
`restore-rbac.yaml`). It was rewritten after the first restore against a real
production archive (2026-10-02, see [the 2026-10-02 run](#the-2026-10-02-run)),
and every command below is either taken from that run or marked otherwise
(see [Provenance of the commands](#provenance-of-the-commands)).

Read it end to end before running anything. A restore takes the live server
down and rolls the world back to the archive's timestamp, so the decision to
do it, and what it will cost, comes first.

## What this does and does not do

The restore mechanism:

* Scales the live `minecraft-bedrock` StatefulSet to `0` and waits for its
  pod to terminate, so nothing is writing to the world while a restore is
  in flight.
* Extracts one named backup archive onto a **separate scratch PVC**
  (`<release>-restore-scratch`), never onto the live world PVC
  (`datadir-<release>-minecraft-bedrock-0`).
* Refuses to run at all if the target archive is missing or unnamed, or if
  the scratch PVC already holds a level directory from a previous attempt
  you have not cleared or explicitly asked to overwrite.

It does **not**:

* Touch the live world PVC. There is no code path in
  `restore-cronjob.yaml` that mounts it, and its RBAC (`restore-rbac.yaml`)
  grants no permission to it.
* Scale the server back up, verify the restored world, or promote it. Those
  are the manual steps below, on purpose.
* Run on a schedule. `spec.suspend: true` is hardcoded in the CronJob
  manifest, independent of `restore.enabled` and of the (inert) `schedule`
  field.

The ArgoCD Application syncs with `selfHeal: true`, but the chart renders no
`replicas` field on the server StatefulSet, so Argo does not revert the
scale-down or the scale-up this runbook performs with `kubectl`. (Observed:
the StatefulSet held at `0` for the whole restore and verify.) Do not take that
as licence to `kubectl scale` anything else in this chart.

## Conventions

Every command assumes these variables in your shell:

```bash
N=jdwillmsen-prd
R=jdwillmsen-minecraft-fwb-prd
```

The world, the scratch claim and the backup claim:

| What | PVC | Class | Notes |
| --- | --- | --- | --- |
| Live world | `datadir-$R-minecraft-bedrock-0` | iSCSI, RWO | Mounted at `/data` by the server; world is `worlds/FWB` |
| Scratch | `$R-restore-scratch` | iSCSI, RWO, 5 Gi | Extraction target, verify copy, saved-aside worlds |
| Backups | `$R-backup` | NFS, RWO | `fwb-<UTC timestamp>.tar.gz`, written nightly at 04:00 UTC |

## Before you start

### Decide that a restore is the right move

A restore throws away everything written since the archive's timestamp. Before
committing, measure what is actually broken and what a rollback would cost:

* Check the server log for the LevelDB repair signature on its latest start:

  ```bash
  kubectl -n $N logs $R-minecraft-bedrock-0 -c $R-minecraft-bedrock | grep -i "corruption\|repair"
  ```

  A world damaged by an abrupt node loss logs, on the first start after it,
  `LevelDB worlds/FWB/db status NOT OK(Corruption: N missing files; ...). Trying
  repair.` The critical `JdwillmsenMinecraftWorldArchiveShrank` alert is the
  other signal, but it only fires after the next nightly backup.
* Size the damage by comparing the last good archive with the damaged one; see
  [Measuring the loss](#measuring-the-loss).
* Work out who played since the archive. Each human who was on is someone whose
  progress is lost. Players online, by minute, since `SINCE`, which must be the
  timestamp of the archive you would restore (see [Pick the
  archive](#pick-the-archive)); the value below is the 2026-10-02 one, and a
  window that starts anywhere else misstates what the rollback costs:

  ```bash
  SINCE='2026-10-01 04:00 UTC'   # replace with the timestamp of your archive
  kubectl get --raw "/api/v1/namespaces/monitoring/services/platform-kube-prometheus-s-prometheus:9090/proxy/api/v1/query_range?query=minecraft_status_players_online_count%7Bnamespace%3D%22$N%22%7D&start=$(date -d "$SINCE" +%s)&end=$(date +%s)&step=60"
  ```

  The agent and the two AFK bots count as three of those, so a steady `3`
  means no human was on.

### Pick the archive

List what the backup CronJob has produced, with a read-only pod on the backup
claim:

```bash
kubectl -n $N run backup-reader --restart=Never --image=alpine/k8s:1.37.0 --overrides='
{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":1000,"runAsGroup":2000,"fsGroup":2000,"seccompProfile":{"type":"RuntimeDefault"}},
 "containers":[{"name":"reader","image":"alpine/k8s:1.37.0","command":["sleep","3600"],
  "resources":{"limits":{"cpu":"500m","memory":"128Mi"},"requests":{"cpu":"50m","memory":"32Mi"}},
  "securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}},
  "volumeMounts":[{"name":"backup","mountPath":"/backup","readOnly":true}]}],
 "volumes":[{"name":"backup","persistentVolumeClaim":{"claimName":"jdwillmsen-minecraft-fwb-prd-backup","readOnly":true}}]}}'
kubectl -n $N wait --for=condition=Ready pod/backup-reader --timeout=90s
kubectl -n $N exec backup-reader -- ls -la /backup
```

Keep this pod running if you will also [measure the loss](#measuring-the-loss);
delete it when you are done with `kubectl -n $N delete pod backup-reader`.

The listing also shows a small `.meta` file per archive and an older
`fwb-emergency-backup-*`; the archive you want is the `fwb-<timestamp>.tar.gz`
itself (name in UTC, `20261001T040103Z` is 2026-10-01 04:01:03 UTC).

Choose the newest archive that predates the damage and is not itself damaged.
An archive taken after the damage carries the damage; the size drop between
consecutive archives is the tell.

### Record what production runs now

The verify step must boot the restored world on exactly the server production
runs, or it can upgrade the world before you promote it. Capture this **before**
the restore Job scales the server down, because the version only appears in the
log of the running pod:

```bash
IMAGE=$(kubectl -n $N get sts $R-minecraft-bedrock -o jsonpath='{.spec.template.spec.containers[0].image}')
NODE=$(kubectl -n $N get pod $R-minecraft-bedrock-0 -o jsonpath='{.spec.nodeName}')
MCVER=$(kubectl -n $N logs $R-minecraft-bedrock-0 -c $R-minecraft-bedrock | sed -n 's/.*INFO\] Version: //p' | head -1)
echo "image=$IMAGE node=$NODE version=$MCVER"
```

Production sets `VERSION=LATEST`, so the StatefulSet's env is not a pin: the
version that matters is the one the running server resolved, which is the
`Version:` line in its log (`1.26.52.3` on 2026-10-02, image
`itzg/minecraft-bedrock-server:2026.9.0`). Write all three down; the verify pod
and the promote pod use them. The server's node is pinned by affinity, and its
security context is `runAsUser: 1000`, `runAsGroup: 3000`, `fsGroup: 2000`,
`runAsNonRoot`, `RuntimeDefault` seccomp, no capabilities, read-only root
filesystem.

If the server had already been scaled down before you got here, its log is gone
with the pod. Take the version from the log aggregator for the server container
instead (this fallback has not been exercised).

## Step 1 — run the restore Job

The restore CronJob renders `ARCHIVE_NAME` and `OVERWRITE_SCRATCH` from
`restore.archiveName` and `restore.overwriteScratch` in the chart values, but a
values change means a pull request and a sync in the middle of an incident.
Instead, create the Job from the CronJob and set both variables on the **Job**.
`kubectl create job --from` takes no env flag, so render it, edit the env, and
create the result:

```bash
JOB=restore-$(date -u +%Y%m%d)
ARCHIVE=fwb-20261001T040103Z.tar.gz   # the archive you picked above
OVERWRITE=false                       # "true" only if scratch holds a level you are done with

kubectl -n $N create job --from=cronjob/$R-restore $JOB --dry-run=client -o json |
ARCHIVE=$ARCHIVE OVERWRITE=$OVERWRITE python3 -c "
import json, os, sys
j = json.load(sys.stdin)
for c in j['spec']['template']['spec']['containers']:
    for e in c['env']:
        if e['name'] == 'ARCHIVE_NAME': e['value'] = os.environ['ARCHIVE']
        if e['name'] == 'OVERWRITE_SCRATCH': e['value'] = os.environ['OVERWRITE']
json.dump(j, sys.stdout)" > /tmp/$JOB.json
kubectl -n $N create -f /tmp/$JOB.json
n=0; STATE=
until [ -n "$STATE" ] || [ $n -ge 620 ]; do
  STATE=$(kubectl -n $N get job $JOB -o jsonpath='{range .status.conditions[?(@.status=="True")]}{.type}{"\n"}{end}' | grep -xE 'Complete|Failed')
  [ -n "$STATE" ] || { n=$((n+1)); sleep 3; }
done
kubectl -n $N logs job/$JOB
echo "restore Job: ${STATE:-NOT FINISHED}"
```

**Go on to Step 2 only if the last line reads `restore Job: Complete`.** On
`Failed`, see the two sections below. `NOT FINISHED` means the Job is still
running and may still be extracting onto scratch; run the loop again and do not
start Step 2, which would copy a half-extracted world. The loop polls for 31
minutes because the Job's own deadline (`restore.timeoutSeconds`) is 30, so it
normally ends on one of the two terminal states.

The job scales the server to `0`, waits for the pod to go, extracts the archive
onto scratch and then stops. A successful run ends with:

```
restored 412 files from fwb-20261001T040103Z.tar.gz onto jdwillmsen-minecraft-fwb-prd-restore-scratch, under /scratch/FWB

This job wrote only to jdwillmsen-minecraft-fwb-prd-restore-scratch. It never touched datadir-jdwillmsen-minecraft-fwb-prd-minecraft-bedrock-0,
the live world PVC.

jdwillmsen-minecraft-fwb-prd-minecraft-bedrock is left scaled to 0. ...
```

Note the file count; the verify copy and the promoted world must match it. For
the 733 MB archive on 2026-10-02 the Job took about a minute end to end. The
server is down from the moment the Job starts until the scale-up in Step 4.

### If the Job refuses

Its logs say why, and nothing has been scaled down or extracted:

* `FATAL: restore.archiveName is empty` or `... does not exist` — `ARCHIVE` is
  wrong; the log lists the archives it can see.
* `FATAL: /scratch/FWB already exists on the scratch PVC` — scratch still holds
  a world from an earlier restore. This is what stopped the first attempt on
  2026-10-02: the August restore was still parked there. Delete the refused Job
  (`kubectl -n $N delete job $JOB`, the name cannot be reused), then re-run
  this step with `OVERWRITE=true`. That replaces `/scratch/FWB` only; any
  `FWB-damaged-*` copy next to it is left alone. If the old `FWB` is something you
  still want, save it aside first (see [What is parked on the scratch
  claim](#what-is-parked-on-the-scratch-claim)).

### If the Job fails after scaling down

A Job whose log got as far as `scaling ... to 0 replicas before touching
anything` and then failed has taken the server down and left it down. That is
the case when the server pod was still present after five minutes, when the
extraction failed or produced no level directory, and when the Job ran into its
deadline. The live world is untouched in all of them, but `/scratch/FWB` may be
missing or half-extracted, so do not go on to Step 2. Either:

* fix the cause and re-run this step under a new Job name with
  `OVERWRITE=true`, so the partial extraction is replaced; or
* bring the server back on the unchanged world, as in [If the verify step
  fails or you change your mind](#if-the-verify-step-fails-or-you-change-your-mind),
  and come back to the restore later.

Do not leave it between the two: nothing scales the server back up for you.

The loop above reads the Job's `Complete` and `Failed` conditions. Do not wait
on `kubectl wait --for=condition=complete` instead: on a Job that failed it
just times out, which is how the refused first attempt on 2026-10-02 looked.

## Step 2 — verify on a copy, never on the scratch world itself

Booting a server on `/scratch/FWB` would let it rewrite the files: a newer
server than the one that made the archive upgrades the world on open, and that
is one-way. The world you promote must be byte-identical to the archive, so the
verify pod boots a **copy**, `FWB-verify`, and the original stays untouched.
The pod is pinned to the image and `VERSION` production runs (recorded above)
and uses the server's security context, so an unreadable or non-upgradeable
world fails here and not on production.

```bash
kubectl -n $N delete pod restore-verify --ignore-not-found --wait=true
sed -e "s|__IMAGE__|$IMAGE|g" -e "s|__MCVER__|$MCVER|g" <<'EOF' | kubectl create -f -
apiVersion: v1
kind: Pod
metadata:
  name: restore-verify
  namespace: jdwillmsen-prd
  labels: {purpose: restore-verify}
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 3000
    fsGroup: 2000
    seccompProfile: {type: RuntimeDefault}
  initContainers:
    - name: copy
      image: alpine/k8s:1.37.0
      command: ["sh", "-c"]
      args:
        - |
          set -e
          rm -rf /scratch/FWB-verify
          cp -a /scratch/FWB /scratch/FWB-verify
          echo "db files: $(ls /scratch/FWB/db | wc -l), bytes: $(du -sb /scratch/FWB/db | cut -f1)"
          ls -la /scratch/FWB /scratch
          sync
      resources:
        limits: {cpu: 500m, memory: 256Mi}
        requests: {cpu: 100m, memory: 64Mi}
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: {drop: ["ALL"]}
      volumeMounts:
        - {name: scratch, mountPath: /scratch}
  containers:
    - name: verify
      image: __IMAGE__
      env:
        - {name: EULA, value: "TRUE"}
        - {name: VERSION, value: "__MCVER__"}
        - {name: LEVEL_NAME, value: FWB-verify}
        - {name: ALLOW_LIST, value: "false"}
      resources:
        limits: {cpu: "2", memory: 4Gi}
        requests: {cpu: 500m, memory: 1Gi}
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: {drop: ["ALL"]}
        readOnlyRootFilesystem: true
      volumeMounts:
        - {name: data, mountPath: /data}
        - {name: tmp, mountPath: /tmp}
        - {name: scratch, mountPath: /data/worlds}
  volumes:
    - name: scratch
      persistentVolumeClaim: {claimName: jdwillmsen-minecraft-fwb-prd-restore-scratch}
    - {name: data, emptyDir: {}}
    - {name: tmp, emptyDir: {}}
EOF
```

`/data` and `/tmp` are `emptyDir`s because the root filesystem is read-only, as
on production. `ALLOW_LIST=false` is deliberate: the verify pod has no
`allowlist.json` of its own and nothing but you can reach it, since it has no
Service and no port is published.

Wait for the server to either start or complain, then read what it said:

```bash
n=0; until kubectl -n $N logs restore-verify -c verify 2>/dev/null | grep -q "Server started\|Corruption\|rror opening" || [ $n -ge 80 ]; do n=$((n+1)); sleep 3; done
kubectl -n $N logs restore-verify -c copy
kubectl -n $N logs restore-verify -c verify | grep -n "Version:\|Level Name\|Opening level\|LevelDB\|Corruption\|repair\|Server started"
```

A good result, from 2026-10-02:

```
db files: 409, bytes: 785885768
[... INFO] Version: 1.26.52.3
[... INFO] Level Name: FWB-verify
[... INFO] Opening level 'worlds/FWB-verify/db'
[... INFO] Server started.
```

Check all of these:

* `db files` equals the DB file count the restore Job reported (409 of its 412
  files on 2026-10-02; the other three are `level.dat`, `level.dat_old`,
  `levelname.txt`).
* `Version:` equals the version you recorded, so nothing upgraded.
* `Opening level` is followed by `Server started` within a couple of seconds,
  with **no** `LevelDB ... Corruption` and no `Trying repair` line. A repair
  line means the archive is damaged too; go back and pick an older one.

Then delete the pod. Do this before promoting: the scratch claim is RWO and the
promote pod needs it.

```bash
kubectl -n $N delete pod restore-verify --wait=true
```

For a world you care about, join with a real client against a copy before you
trust the archive further (the verify server is not reachable from outside the
cluster, so that is a separate exercise and was not part of the 2026-10-02
run).

## Step 3 — save the damaged world aside, promote, compare

Promotion replaces `/data/worlds/FWB` on the live claim. Two guards matter:

* The damaged world is copied aside onto scratch first. Once the live
  directory is replaced there is no way back to it, and the damaged copy holds
  whatever happened after the archive (on 2026-10-02, about 42 hours of AFK-bot
  farm output) in case anyone ever wants it back.
* The restored world is copied onto the live claim **next to** the live
  directory and compared with the scratch copy by sha256 manifest before the
  live directory is touched. Only then are the two swapped, by rename. A short
  or garbled copy therefore fails loudly with the server still off and the
  live directory still whole, and the only moment the live path does not hold
  a complete world is between two renames.

The live claim is iSCSI and RWO and is attached to the server's node, so the
promote pod is pinned to that node (`$NODE`, recorded above) or it cannot mount
it. It runs as the server's uid and fsGroup so the copied files have the
ownership the server expects. Only `worlds/FWB` is replaced: `server.properties`
and the rest of `/data` stay as they are, and so do the `allowlist.json` and
`permissions.json` that the archive extracted at the scratch root (the live
copies are current; the archived ones are not promoted).

```bash
kubectl -n $N get sts $R-minecraft-bedrock -o jsonpath='replicas={.spec.replicas}{"\n"}'   # must print replicas=0
kubectl -n $N delete pod restore-promote --ignore-not-found
sed "s|__NODE__|$NODE|g" <<'EOF' | kubectl create -f -
apiVersion: v1
kind: Pod
metadata:
  name: restore-promote
  namespace: jdwillmsen-prd
  labels: {purpose: restore-promote}
spec:
  restartPolicy: Never
  nodeSelector: {kubernetes.io/hostname: __NODE__}
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 3000
    fsGroup: 2000
    seccompProfile: {type: RuntimeDefault}
  containers:
    - name: promote
      image: alpine/k8s:1.37.0
      command: ["sh", "-c"]
      args:
        - |
          set -eu
          cd /
          ASIDE=/scratch/FWB-damaged-$(date -u +%Y%m%d)
          LIVE=/world/worlds/FWB
          INCOMING=/world/worlds/FWB-incoming
          OUTGOING=/world/worlds/FWB-outgoing
          manifest() { (cd "$1" && find . -type f | sort | xargs sha256sum | sha256sum | cut -d' ' -f1); }
          count() { find "$1" -type f | wc -l; }

          echo '== before'
          ls -la /world/worlds
          df -h /world /scratch | tail -2
          [ ! -e "$OUTGOING" ] || { echo "FATAL: $OUTGOING exists: an earlier promotion stopped mid-swap. Do not re-run; see the runbook."; exit 1; }
          [ -d "$LIVE" ] || { echo "FATAL: $LIVE is missing; nothing to save aside. Do not re-run; see the runbook."; exit 1; }
          rm -rf /scratch/FWB-verify "$INCOMING"

          echo '== saving the damaged world aside on scratch'
          [ ! -e "$ASIDE" ] || { echo "FATAL: $ASIDE already exists; move or delete it first. Live world untouched."; exit 1; }
          cp -a "$LIVE" "$ASIDE"
          [ "$(count "$LIVE")" = "$(count "$ASIDE")" ] || { echo 'FATAL: damaged copy is incomplete; live world untouched'; exit 1; }
          echo "damaged copy: $(count "$ASIDE") files"

          WANT=$(manifest /scratch/FWB)
          echo "restored manifest: $WANT, $(count /scratch/FWB) files"

          echo '== staging the restored world next to the live one'
          cp -a /scratch/FWB "$INCOMING"
          sync
          GOT=$(manifest "$INCOMING")
          echo "staged manifest:   $GOT, $(count "$INCOMING") files"
          [ "$WANT" = "$GOT" ] || { echo 'FATAL: staged copy does not match the restored copy; live world untouched'; exit 1; }

          echo '== swapping'
          mv "$LIVE" "$OUTGOING"
          mv "$INCOMING" "$LIVE"
          sync
          GOT=$(manifest "$LIVE")
          echo "live manifest:     $GOT, $(count "$LIVE") files"
          [ "$WANT" = "$GOT" ] || { echo 'FATAL: live world does not match the restored copy'; exit 1; }
          rm -rf "$OUTGOING"
          ls -la /world/worlds "$LIVE"
          sync
          echo PROMOTED
      resources:
        limits: {cpu: "1", memory: 512Mi}
        requests: {cpu: 200m, memory: 128Mi}
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: {drop: ["ALL"]}
      volumeMounts:
        - {name: world, mountPath: /world}
        - {name: scratch, mountPath: /scratch}
  volumes:
    - name: world
      persistentVolumeClaim: {claimName: datadir-jdwillmsen-minecraft-fwb-prd-minecraft-bedrock-0}
    - name: scratch
      persistentVolumeClaim: {claimName: jdwillmsen-minecraft-fwb-prd-restore-scratch}
EOF
n=0; until kubectl -n $N get pod restore-promote -o jsonpath='{.status.phase}' | grep -qE "Succeeded|Failed" || [ $n -ge 150 ]; do n=$((n+1)); sleep 3; done
kubectl -n $N get pod restore-promote -o jsonpath='{.status.phase}{"\n"}'
kubectl -n $N logs restore-promote
```

Proceed only if the phase is `Succeeded`, the log ends in `PROMOTED`, and the
`restored manifest`, `staged manifest` and `live manifest` lines carry the same
hash and file count. On 2026-10-02 the restored and live lines both read
`47985f0521d49d962ade7e16d69da500bb14d3276e66d0d47b685d8b901c5168`, 412 files,
and the damaged copy held 443 files.

The staged copy needs room for a second world on the live claim (5 Gi, about
0.8 GB per world); the `df` output at the top of the log shows what is free.

### If the promote pod fails

The server is still at `0`; do not scale up until you know which of these it
was. The last `==` line in the log tells you:

* **Any line before `== swapping`**: the live directory is still the damaged
  world, whole and untouched. Fix the cause and re-run the pod. It refuses
  while today's `FWB-damaged-*` copy exists; in this case that copy duplicates
  the live directory (or is a short copy of it), so delete it first, as in
  [What is parked on the scratch claim](#what-is-parked-on-the-scratch-claim).
* **`== swapping` or later**, or a log that says `Do not re-run`: the live path
  may hold no world, and the `FWB-damaged-*` copy on scratch may be the
  **only** complete copy of the damaged world. Do not delete it and do not
  re-run the pod. Nothing is lost: the restored world is still at
  `/scratch/FWB`, and the damaged one is in the scratch copy and, if the first
  rename happened, in `worlds/FWB-outgoing` on the live claim. Start a pod
  with the same spec but `args: ["sleep 3600"]`, look at `/world/worlds`, and
  finish the renames by hand. This path has not been exercised.

## Step 4 — scale up and check

```bash
kubectl -n $N delete pod restore-promote --wait=true
kubectl -n $N scale statefulset $R-minecraft-bedrock --replicas=1
n=0; until kubectl -n $N logs $R-minecraft-bedrock-0 -c $R-minecraft-bedrock 2>/dev/null | grep -q "Server started\|Corruption" || [ $n -ge 100 ]; do n=$((n+1)); sleep 3; done
kubectl -n $N logs $R-minecraft-bedrock-0 -c $R-minecraft-bedrock | grep -n "Version:\|Level Name\|Opening level\|LevelDB\|Corruption\|repair\|Server started"
kubectl -n $N wait --for=condition=Ready pod/$R-minecraft-bedrock-0 --timeout=120s
```

Expect `Level Name: FWB`, `Opening level 'worlds/FWB/db'` and `Server started.`
with no corruption line (on 2026-10-02: Version 1.26.52.3, started at 22:22:14
UTC, about 20 seconds after the scale-up). Then:

* The agent and the AFK bots reconnect on their own; confirm with
  `kubectl -n $N get pods | grep -E "server-agent|afk-bot|map-"`. The agent
  pod can show `0/1` for a minute while the server comes up.
* The world map mirrors the world and replaces its copy on its next snapshot;
  that snapshot is the restored world. Give it one cycle (it renders a few
  minutes after a successful snapshot).
* Tell whoever is online. `tools/mc announce "<message>"` broadcasts to online
  players only. There is no mechanism that tells players who are offline, so
  anyone who joins later will not know the world moved back unless they are told.
* The `JdwillmsenMinecraftWorldArchiveShrank` alert, if it was firing, keeps
  firing until the 04:00 UTC backup produces an archive back near the old size.
* Delete the Job: `kubectl -n $N delete job $JOB`. Jobs made by hand with
  `--from=cronjob` sit outside the CronJob's history limits and are yours to
  remove.

### If the verify step fails or you change your mind

The live world was never touched before Step 3. Scale the server back up
unchanged:

```bash
kubectl -n $N scale statefulset $R-minecraft-bedrock --replicas=1
```

Remember the world is still the damaged one in that case, and the restored copy
stays on scratch until you remove it.

## Measuring the loss

Nightly archives are the only record of what the world looked like before the
damage, so the way to size a loss is to compare the key sets of two archives:
the last good one and the first damaged one (or the current damaged world).
Bedrock worlds are LevelDB databases whose keys encode the chunk (`x`, `z`,
dimension) plus a record tag; chunks that vanish from the later database
without anyone deleting them are what lost compaction output files look like.

1. Copy both archives off the backup claim (the `backup-reader` pod from
   [Pick the archive](#pick-the-archive)) and check that the bytes arrived
   intact against the sha256 computed next to the archives:

   ```bash
   mkdir -p ~/fwb-loss && cd ~/fwb-loss
   for a in fwb-20261001T040103Z fwb-20261002T040112Z; do   # good archive, then damaged archive
     kubectl -n $N exec backup-reader -- cat /backup/$a.tar.gz > $a.tar.gz
   done
   kubectl -n $N exec backup-reader -- sh -c 'cd /backup && sha256sum fwb-20261001T040103Z.tar.gz fwb-20261002T040112Z.tar.gz'
   sha256sum fwb-20261001T040103Z.tar.gz fwb-20261002T040112Z.tar.gz
   ```

2. Extract each into its own new directory:

   ```bash
   mkdir pre post &&
     tar -xzf fwb-20261001T040103Z.tar.gz -C pre &&
     tar -xzf fwb-20261002T040112Z.tar.gz -C post
   ```

   `mkdir` without `-p` is deliberate: it stops if `pre` or `post` is left over
   from an earlier comparison. Remove them and start again rather than
   extracting on top. A database directory holding files from two archives
   opens without complaint and reads as a mixture, so the comparison reports
   differences that are in neither archive.

3. Build `keydiff`, a read-only comparer (source below; the build needs Go and
   network access to fetch `github.com/df-mc/goleveldb`):

   ```bash
   mkdir -p keydiff && cd keydiff
   # save the source below as main.go, then:
   go mod init keydiff && go mod tidy && go build -o keydiff .
   cd ..
   ```

4. Compare. It opens both databases read-only and writes `lost-chunks.json`
   (the chunks that are gone or thinner) into the current directory:

   ```bash
   ./keydiff/keydiff pre/FWB/db post/FWB/db
   ```

On 2026-10-02 this printed:

```
pre:  153058 chunks, 217941 other keys
post: 146598 chunks, 213716 other keys

chunks in pre missing entirely from post: 6460 (161.6 MB of values)
chunks in both, post lacks some of pre's keys: 107
chunks in both, post has keys pre lacks: 12
chunks in both, same keys, some value differs: 802
chunks identical: 145677
chunks only in post (new since pre): 0
  dim 0: 4753 chunks gone, ...
  dim 1: 1413 chunks gone, ...
  dim 2: 294 chunks gone, ...

non-chunk keys in pre missing from post, by kind: map[VILLAGE_:4 actorprefix:246 map_:4385]
```

How to read it:

* **Chunks missing entirely** is the headline number. Losing a few chunks
  because someone broke a farm does not happen; thousands vanishing across all
  three dimensions is storage damage.
* **A contiguous key range** (on 2026-10-02, chunk X mod 256 in 10..29) is the
  signature of lost compaction output files whose inputs were already deleted.
  Read the `lost-chunks.json` coordinates to see it.
* **Chunks only in post** should be `0` when nobody played between the two
  archives. If it is not, the later world holds real new work and a restore
  loses it; weigh that, or consider merging only the lost key range.
* **Chunks where post has keys pre lacks** gained a record (a new sub-chunk,
  block entity or pending tick) since the earlier archive. A handful is what a
  running world with bots on it does; many, like chunks only in post, is new
  work that a restore loses. Each chunk is counted on one line only, the first
  that applies in the order printed, so the lines add up to pre's chunk count
  and a chunk that both lost and gained keys is on the line above this one.
* **Value differences** in chunks present in both are normal for a world that
  was running (redstone, mob movement, bot activity) and say nothing about
  damage.
* `map_`, `actorprefix` and `VILLAGE_` are non-chunk records: map items,
  entities and villages that went with the lost chunks.

The tool is a throwaway: on 2026-10-02 it lived on the devbox under
`~/fwb-incident-2026-10-02/keydiff` and is not otherwise in this repository.
The source is kept here so the procedure does not depend on that directory.

<details>
<summary>keydiff main.go</summary>

```go
// Throwaway: compares the key sets of two Bedrock worlds, read-only.
package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"os"
	"sort"

	"github.com/df-mc/goleveldb/leveldb"
	"github.com/df-mc/goleveldb/leveldb/opt"
)

type chunk struct {
	Dim  int32 `json:"dim"`
	X, Z int32
}

type world struct {
	chunks map[chunk]map[string]uint64 // chunk -> key suffix -> value hash
	other  map[string]uint64
	bytes  map[chunk]int
}

func hash(b []byte) uint64 {
	var h uint64 = 14695981039346656037
	for _, c := range b {
		h ^= uint64(c)
		h *= 1099511628211
	}
	return h
}

func isASCII(k []byte) bool {
	for _, c := range k {
		if c < 0x20 || c > 0x7e {
			return false
		}
	}
	return true
}

func load(path string) (*world, error) {
	db, err := leveldb.OpenFile(path, &opt.Options{ReadOnly: true, Compression: opt.FlateCompression})
	if err != nil {
		return nil, err
	}
	defer db.Close()
	w := &world{chunks: map[chunk]map[string]uint64{}, other: map[string]uint64{}, bytes: map[chunk]int{}}
	it := db.NewIterator(nil, nil)
	defer it.Release()
	for it.Next() {
		k, v := it.Key(), it.Value()
		var c chunk
		var rest []byte
		switch {
		case (len(k) == 9 || len(k) == 10) && !isASCII(k):
			c = chunk{0, int32(binary.LittleEndian.Uint32(k[0:4])), int32(binary.LittleEndian.Uint32(k[4:8]))}
			rest = k[8:]
		case (len(k) == 13 || len(k) == 14) && !isASCII(k):
			c = chunk{int32(binary.LittleEndian.Uint32(k[8:12])), int32(binary.LittleEndian.Uint32(k[0:4])), int32(binary.LittleEndian.Uint32(k[4:8]))}
			rest = k[12:]
		default:
			w.other[string(k)] = hash(v)
			continue
		}
		if c.Dim < 0 || c.Dim > 2 || rest[0] < 0x2b || rest[0] > 0x77 {
			w.other[string(k)] = hash(v)
			continue
		}
		m := w.chunks[c]
		if m == nil {
			m = map[string]uint64{}
			w.chunks[c] = m
		}
		m[string(rest)] = hash(v)
		w.bytes[c] += len(v)
	}
	return w, it.Error()
}

func prefix(k string) string {
	b := []byte(k)
	for _, p := range []string{"player_server_", "player_", "actorprefix", "digp", "map_", "VILLAGE_", "structuretemplate", "tickingarea", "portals", "scoreboard", "mobevents", "schedulerWT", "AutonomousEntities", "BiomeData", "Overworld", "Nether", "TheEnd", "LevelChunkMetaDataDictionary", "~local_player", "game_flatworldlayers", "dimension", "PositionTrackDB", "chunk_loaded_request", "RealmsStoriesData", "LevelSpawnWasFixed"} {
		if bytes.HasPrefix(b, []byte(p)) {
			return p
		}
	}
	if isASCII(b) {
		return "ascii:" + k[:min(len(k), 12)]
	}
	return fmt.Sprintf("binary(len %d)", len(k))
}

func main() {
	pre, err := load(os.Args[1])
	if err != nil {
		panic(err)
	}
	post, err := load(os.Args[2])
	if err != nil {
		panic(err)
	}
	fmt.Printf("pre:  %d chunks, %d other keys\npost: %d chunks, %d other keys\n", len(pre.chunks), len(pre.other), len(post.chunks), len(post.other))

	var gone, thinner, grew, changed, added []chunk
	same := 0
	lostBytes := 0
	for c, keys := range pre.chunks {
		pk, ok := post.chunks[c]
		if !ok {
			gone = append(gone, c)
			lostBytes += pre.bytes[c]
			continue
		}
		missing, differ := 0, 0
		for k, h := range keys {
			if ph, ok := pk[k]; !ok {
				missing++
			} else if ph != h {
				differ++
			}
		}
		extra := 0
		for k := range pk {
			if _, ok := keys[k]; !ok {
				extra++
			}
		}
		switch {
		case missing > 0:
			thinner = append(thinner, c)
		case extra > 0:
			grew = append(grew, c)
		case differ > 0:
			changed = append(changed, c)
		default:
			same++
		}
	}
	for c := range post.chunks {
		if _, ok := pre.chunks[c]; !ok {
			added = append(added, c)
		}
	}
	fmt.Printf("\nchunks in pre missing entirely from post: %d (%.1f MB of values)\n", len(gone), float64(lostBytes)/1e6)
	fmt.Printf("chunks in both, post lacks some of pre's keys: %d\n", len(thinner))
	fmt.Printf("chunks in both, post has keys pre lacks: %d\n", len(grew))
	fmt.Printf("chunks in both, same keys, some value differs: %d\n", len(changed))
	fmt.Printf("chunks identical: %d\n", same)
	fmt.Printf("chunks only in post (new since pre): %d\n", len(added))

	for dim := int32(0); dim < 3; dim++ {
		n := 0
		minX, maxX, minZ, maxZ := int32(1<<30), int32(-1<<30), int32(1<<30), int32(-1<<30)
		for _, c := range gone {
			if c.Dim != dim {
				continue
			}
			n++
			minX, maxX, minZ, maxZ = min(minX, c.X), max(maxX, c.X), min(minZ, c.Z), max(maxZ, c.Z)
		}
		if n > 0 {
			fmt.Printf("  dim %d: %d chunks gone, block X %d..%d, Z %d..%d\n", dim, n, minX*16, maxX*16+15, minZ*16, maxZ*16+15)
		}
	}

	missingOther := map[string]int{}
	changedOther := map[string]int{}
	var missingNames []string
	for k, h := range pre.other {
		ph, ok := post.other[k]
		if !ok {
			missingOther[prefix(k)]++
			if p := prefix(k); p != "actorprefix" && p != "digp" && len(missingNames) < 40 {
				missingNames = append(missingNames, fmt.Sprintf("%q", k))
			}
		} else if ph != h {
			changedOther[prefix(k)]++
		}
	}
	fmt.Println("\nnon-chunk keys in pre missing from post, by kind:", missingOther)
	fmt.Println("non-chunk keys changed, by kind:", changedOther)
	sort.Strings(missingNames)
	for _, n := range missingNames {
		fmt.Println("  missing:", n)
	}
	out, _ := json.Marshal(map[string]any{"gone": gone, "thinner": thinner})
	if err := os.WriteFile("lost-chunks.json", out, 0o644); err != nil {
		panic(err)
	}
}
```

</details>

## What is parked on the scratch claim

As of 2026-10-03 the scratch claim (`jdwillmsen-minecraft-fwb-prd-restore-scratch`,
4.8 GB usable) holds about 1.4 GB:

| Path | What it is | Size |
| --- | --- | --- |
| `FWB/` | The world restored from `fwb-20261001T040103Z.tar.gz`, exactly as extracted and never opened by a server | 412 files, 786 MB |
| `FWB-damaged-20261002/` | The damaged live world as it stood at 22:18 UTC on 2026-10-02, saved aside before promotion; includes the roughly 42 hours of AFK-bot farm output that the rollback discarded | 443 files, 747 MB |
| `allowlist.json`, `permissions.json` | Extracted from the archive root by the restore Job; never promoted | small |

Neither is needed to run the world. The next restore needs one of two things
because `FWB/` is still there: run the Job with `OVERWRITE=true` (it replaces
`FWB/` only), or clean the claim first.

When to clean:

* **`FWB-damaged-20261002/`**: delete it once nobody wants the bots' farm
  output back and the nightly archives since the restore are back to full size
  (the 04:00 UTC backup on 2026-10-03 should be near 770 MB, not 731 MB). It
  is the only copy of that output.
* **`FWB/`**: keep it until a later archive supersedes it, then let the next
  restore overwrite it.
* Do not let the claim fill. It holds about six worlds of 0.8 GB each; the
  promote pod's saved-aside copy and the next extraction both need room, so
  clear old `FWB-damaged-*` directories before the next restore, not during it.

To delete a directory from the claim, from a pod pinned to the server's node
(the claim is RWO). This deletes data and was not run as part of the 2026-10-02
restore:

```bash
kubectl -n $N run scratch-clean --restart=Never --image=alpine/k8s:1.37.0 --overrides='
{"spec":{"nodeSelector":{"kubernetes.io/hostname":"'$NODE'"},
 "securityContext":{"runAsNonRoot":true,"runAsUser":1000,"runAsGroup":3000,"fsGroup":2000,"seccompProfile":{"type":"RuntimeDefault"}},
 "containers":[{"name":"clean","image":"alpine/k8s:1.37.0","command":["rm","-rf","/scratch/FWB-damaged-20261002"],
  "securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}},
  "volumeMounts":[{"name":"scratch","mountPath":"/scratch"}]}],
 "volumes":[{"name":"scratch","persistentVolumeClaim":{"claimName":"jdwillmsen-minecraft-fwb-prd-restore-scratch"}}]}}'
kubectl -n $N wait --for=jsonpath='{.status.phase}'=Succeeded pod/scratch-clean --timeout=120s
kubectl -n $N delete pod scratch-clean
```

## The 2026-10-02 run

This mechanism was built and tested against a throwaway namespace with a
synthetic StatefulSet and archive. Its first use on a real production archive
was 2026-10-02, after an abrupt loss of the server's node left the world with
`Corruption: 25 missing files` and 6,460 of 153,058 chunks gone. All times
UTC:

| Time | Event |
| --- | --- |
| 22:11 | First Job refused: `/scratch/FWB already exists on the scratch PVC` (left by the August restore). The server had not been touched. |
| 22:18:28 | Second Job, `OVERWRITE_SCRATCH=true` and `ARCHIVE_NAME=fwb-20261001T040103Z.tar.gz` set on the Job. Server scaled to 0; 412 files (409 db files, 785,869,384 bytes) extracted. |
| 22:19-22:20 | Verify pod on a copy, pinned to image `2026.9.0` and `VERSION=1.26.52.3`, server security context: `Opening level`, then `Server started` one second later, no repair line. |
| 22:20-22:21 | Damaged world saved aside (443 files), then promoted from a pod pinned to the server's node. Live and restored sha256 manifests equal, 412 files. |
| 22:22:14 | Production server started on the restored world, no corruption line. Down for 3m46s. |

It rolled the world back about 42 hours, to 2026-10-01 04:01 UTC. The run
departed from the previous version of this runbook in three ways, all folded in
above:

* The archive name was set on the Job rather than through a values change.
* The verify server ran on a copy, so the promoted world is byte-identical to
  the archive. The earlier procedure booted the scratch world itself under an
  unpinned image tag with no `VERSION`; with `LATEST` that can upgrade the
  world one-way before promotion.
* The damaged world was saved aside before the live directory was replaced.

Still not exercised end to end: a real client joining a verified copy before
promotion, and a restore started while the nightly backup was running (see the
caution below).

## Cautions

* **Don't run a restore during the nightly backup window** (`04:00 UTC` by
  default). The restore Job mounts the backup PVC read-only; the backup
  CronJob mounts it read-write to write a fresh archive. Running them at the
  same time risks one being stuck `Pending` on a volume attach rather than a
  clean failure.
* **The restore Job scales down the real server.** Anyone with access to
  `kubectl create job --from=cronjob/...restore` in `jdwillmsen-prd` can take
  the live Minecraft server offline. That is the point, since a restore is an
  incident action, but it is not a command to run casually or to test against
  production.
* **A restore rolls everyone back.** Whatever any player did after the archive
  is gone from the live world; the saved-aside copy on scratch is the only
  record of it.
* **Players who are offline are not told.** Announce to the online ones, and
  plan to tell the rest by another channel.

## Provenance of the commands

Status of every command block above. "Run" means executed against production on
2026-10-02 during the restore, as shown (or with the variable substitution
noted). "Dry-run" means checked on 2026-10-03 without changing production: the
Kubernetes API server's `--dry-run=server` admission check, a local container
run of the shell logic, or a read-only `kubectl` query.

| Command block | Status |
| --- | --- |
| Server log grep for corruption/repair; players-online query; list of archives from the backup reader pod | Run on 2026-10-02 (the reader pod and the archive copy at 07:58 UTC; the log and Prometheus queries throughout the day); all three re-run read-only on 2026-10-03 |
| Record production's image, node and version | Dry-run: queried read-only on 2026-10-03 against the live StatefulSet and pod |
| Step 1: render, edit the env, create the restore Job | Run (the Job was rendered with `--dry-run=client -o json`, the env edited in Python, then created); the single-script form here is dry-run only, and the wait loop on the Job's conditions was written afterwards and checked read-only against a completed Job |
| Step 2: verify pod on a copy | Run as JSON on 2026-10-02; the YAML form with `__IMAGE__`/`__MCVER__` substitution is dry-run only |
| Step 3: promote pod, saved-aside copy and manifest compare | Run as JSON on 2026-10-02, where the live directory was removed and then copied over in place; the YAML form, the dated aside name, the refuse-if-exists guard and the stage-then-rename swap are dry-run only (shell logic exercised locally in a container, including a failed staging copy) |
| Step 4: scale up, log check, readiness | Run |
| `tools/mc announce` | Run on 2026-10-02 |
| Measuring the loss: copy archives, extract, build and run `keydiff` | Run on 2026-10-02 on the devbox; the build recipe here was re-run on 2026-10-03 and reproduced the printed output. The "post has keys pre lacks" class was added afterwards and the printed output is from re-running that source on the same two archives |
| Cleaning directories off the scratch claim | Not run (it deletes the parked data); the pod pattern matches the run reader pods |
| Version fallback from the log aggregator | Unverified |
