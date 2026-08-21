# Minecraft FWB — restore runbook

Covers restoring a backup archive produced by the `minecraft-fwb` chart's
backup CronJob (`templates/backup-cronjob.yaml`) via its companion restore
mechanism (`templates/restore-cronjob.yaml`, `restore-pvc.yaml`,
`restore-rbac.yaml`). Read this before you ever run the restore Job for
real — it walks through what the mechanism does automatically, what stays a
manual decision, and how to verify a restore before it touches anything
that matters.

## What this does and does not do

The restore mechanism:

* Scales the live `minecraft-bedrock` StatefulSet to `0` and waits for its
  pod to terminate, so nothing is writing to the world while a restore is
  in flight.
* Extracts one named backup archive onto a **separate scratch PVC**
  (`<release>-restore-scratch`), never onto the live world PVC
  (`datadir-<release>-minecraft-bedrock-0`).
* Refuses to run at all if the target archive is missing, unnamed, or if
  the scratch PVC already holds a level directory from a previous attempt
  you haven't cleared or explicitly asked to overwrite.

It does **not**:

* Touch the live world PVC. There is no code path in
  `restore-cronjob.yaml` that mounts it, and its RBAC (`restore-rbac.yaml`)
  grants no permission to it.
* Scale the server back up, or decide whether a restore is good. Both are
  left to you, below.
* Run on a schedule. `spec.suspend: true` is hardcoded in the CronJob
  manifest, independent of `restore.enabled` and of the (inert) `schedule`
  field — nothing in `values.yaml` can turn this into an automatic job.

## Prerequisites

* `restore.enabled: true` in the chart's values (on by default) — this
  deploys the CronJob, its RBAC, and the scratch PVC, all suspended/idle
  until you invoke them.
* You know the exact archive filename you want back. List what the backup
  CronJob has produced:

  ```bash
  kubectl exec -n jdwillmsen-prd deploy/jdwillmsen-minecraft-fwb-prd-backup-exporter -- \
    sh -c 'true'   # the exporter has no shell access to the archive dir; instead:
  kubectl run -n jdwillmsen-prd backup-archive-list --rm -i --restart=Never \
    --image=alpine/k8s:1.36.2 --overrides='
  {
    "spec": {
      "containers": [{
        "name": "list",
        "image": "alpine/k8s:1.36.2",
        "command": ["ls", "-la", "/backup"],
        "volumeMounts": [{"name": "backup", "mountPath": "/backup", "readOnly": true}]
      }],
      "volumes": [{"name": "backup", "persistentVolumeClaim": {"claimName": "jdwillmsen-minecraft-fwb-prd-backup", "readOnly": true}}]
    }
  }'
  ```

  (Or read the CronJob's own recent completed pod logs — each run prints
  the archive name and byte size on success.)

## Step 1 — set the archive name and run the restore

The restore CronJob's pod template is rendered from `restore.archiveName`
at Helm-render time, so setting it means a values change and a sync (or, in
a hurry, a direct `kubectl patch` of the CronJob — but prefer the GitOps
path so the choice is reviewable):

```bash
# in this chart's values-prd.yaml, or an --set at the CLI if you're doing
# this out of band:
restore:
  archiveName: "fwb-20260821T040001Z.tar.gz"
```

Once that's synced (or patched in directly for urgency), trigger one run.
Every invocation needs its own job name — the CronJob itself never fires on
its own:

```bash
kubectl create job --from=cronjob/jdwillmsen-minecraft-fwb-prd-restore \
  restore-manual-1 -n jdwillmsen-prd
```

Watch it:

```bash
kubectl logs -n jdwillmsen-prd -f job/restore-manual-1
```

A successful run's last lines look like:

```
restored <N> files from fwb-20260821T040001Z.tar.gz onto jdwillmsen-minecraft-fwb-prd-restore-scratch, under /scratch/FWB

This job wrote only to jdwillmsen-minecraft-fwb-prd-restore-scratch. It never touched datadir-jdwillmsen-minecraft-fwb-prd-minecraft-bedrock-0,
the live world PVC.

jdwillmsen-minecraft-fwb-prd-minecraft-bedrock is left scaled to 0. It stays that way until a human decides what
happens next -- verify the scratch copy, then either promote it or scale the
server back up unchanged.
```

At this point: the live server is down (you did that deliberately by
running this job), the live world PVC is untouched, and a candidate world
sits on the scratch PVC waiting for you to look at it.

If the job instead fails, its logs name exactly why — an empty or missing
archive name, or a scratch PVC that still holds a previous attempt
(`restore.overwriteScratch: true` clears that guard for a deliberate
second try). Nothing is scaled down or extracted on a failed precondition
check; the StatefulSet scale-down only happens once the archive is
confirmed present.

## Step 2 — verify the scratch restore before trusting it

Never promote a restore you haven't looked at. The cheapest check is
booting a throwaway server against the scratch PVC, not the real one:

```bash
kubectl run -n jdwillmsen-prd restore-verify --rm -i --restart=Never \
  --image=itzg/minecraft-bedrock-server:2026.8.1 \
  --overrides='
{
  "spec": {
    "containers": [{
      "name": "verify",
      "image": "itzg/minecraft-bedrock-server:2026.8.1",
      "env": [{"name": "EULA", "value": "TRUE"}],
      "volumeMounts": [{"name": "scratch", "mountPath": "/data/worlds"}]
    }],
    "volumes": [{"name": "scratch", "persistentVolumeClaim": {"claimName": "jdwillmsen-minecraft-fwb-prd-restore-scratch"}}]
  }
}'
```

Watch its logs for a normal startup with no LevelDB repair/corruption
messages, and check the level actually contains what you expect
(`allowlist.json` present with real XUIDs, `level.dat` non-trivial size).
Delete the throwaway pod when done — it never had a Service, so it was
never reachable from the LAN and nothing else could have connected to it.

## Step 3 — promote or abandon (human action only, deliberately not automated)

**If the scratch restore checks out** and you want it to become the live
world:

1. Confirm the StatefulSet is still at `0` replicas (the restore job left
   it there):
   ```bash
   kubectl get statefulset -n jdwillmsen-prd jdwillmsen-minecraft-fwb-prd-minecraft-bedrock
   ```
2. Copy the verified level directory from the scratch PVC onto the live
   world PVC, replacing what's there. The simplest safe way is a one-off
   pod mounting both PVCs read-write and read-only respectively:
   ```bash
   kubectl run -n jdwillmsen-prd restore-promote --rm -i --restart=Never \
     --image=alpine/k8s:1.36.2 --overrides='
   {
     "spec": {
       "containers": [{
         "name": "promote",
         "image": "alpine/k8s:1.36.2",
         "command": ["sh", "-c", "rm -rf /world/worlds/FWB && cp -a /scratch/FWB /world/worlds/FWB && echo done"],
         "volumeMounts": [
           {"name": "world", "mountPath": "/world"},
           {"name": "scratch", "mountPath": "/scratch", "readOnly": true}
         ]
       }],
       "volumes": [
         {"name": "world", "persistentVolumeClaim": {"claimName": "datadir-jdwillmsen-minecraft-fwb-prd-minecraft-bedrock-0"}},
         {"name": "scratch", "persistentVolumeClaim": {"claimName": "jdwillmsen-minecraft-fwb-prd-restore-scratch", "readOnly": true}}
       ]
     }
   }'
   ```
   This is the one step the chart deliberately never automates — the
   restore Job stops at the scratch PVC precisely so a bad restore can
   never overwrite the only good copy without a human reading this section
   and typing the command themselves.
3. Scale the StatefulSet back up:
   ```bash
   kubectl scale statefulset -n jdwillmsen-prd jdwillmsen-minecraft-fwb-prd-minecraft-bedrock --replicas=1
   ```
4. Watch the pod come up healthy and confirm `mc-monitor`'s metrics and a
   real client join both work again.

**If the scratch restore does not check out**, the live world was never
touched — just scale the StatefulSet back up unchanged:

```bash
kubectl scale statefulset -n jdwillmsen-prd jdwillmsen-minecraft-fwb-prd-minecraft-bedrock --replicas=1
```

Either way, clean up the scratch PVC's contents (or leave them for the
next attempt) and delete any leftover manual Job names with `kubectl delete
job restore-manual-1 -n jdwillmsen-prd` once you're done — the CronJob
itself does not accumulate history beyond `successfulJobsHistoryLimit`/
`failedJobsHistoryLimit`, but Jobs created by hand via `--from=cronjob` are
outside that bookkeeping and are yours to remove.

## Cautions

* **Don't run a restore during the nightly backup window** (`04:00 UTC` by
  default). The restore Job mounts the backup PVC read-only; the backup
  CronJob mounts it read-write to write a fresh archive. Both are
  `ReadWriteOnce` claims — running them at the same time risks one being
  stuck `Pending` on a volume attach rather than a clean failure.
* **The restore Job scales down the real server.** Anyone with access to
  `kubectl create job --from=cronjob/...restore` in `jdwillmsen-prd` can
  take the live Minecraft server offline. That's the point — a restore is
  an incident action — but it means this is not a command to run casually
  or test against production.
* This mechanism was built and tested against a throwaway namespace with a
  synthetic StatefulSet/pod and a synthetic archive (same directory shape
  the real backup produces: a `<levelName>/` directory with `.ldb`/`level.dat`
  files, plus `allowlist.json`/`permissions.json` at the archive root) —
  see JDWLABS-334. It has not yet been run against a real production
  archive end to end; Step 2 above (booting a throwaway server against the
  scratch PVC) is how to close that gap the first time this is used for
  real, and is worth doing once even outside of an actual incident.
