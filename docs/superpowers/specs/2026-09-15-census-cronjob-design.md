# Census CronJob design

Date: 2026-09-15
Status: approved design, not yet implemented

## Problem

`internal/census` and `cmd/census` landed in minecraft-server-agent (#34). The
binary reads a Bedrock world and prints a population report explaining which
9x9-chunk regions have hit their spawn cap. Nothing runs it. It exists, it is
tested, and it has never produced a report anybody sees.

Two things are missing. The chart has no workload that invokes it, and the
binary can only read a backup archive — so the only report it can produce is
of last night's world. The original design called for a second source giving a
fresh snapshot on demand.

## Goals

- The census runs on a schedule and its report reaches the job log.
- A fresh snapshot is possible, without reimplementing the save protocol.
- The census can never corrupt, hold open, or otherwise damage the live world.
- A failed snapshot degrades to a stale-but-correct report, never a wrong one.

## Non-goals

- Postgres persistence, Prometheus metrics and run-to-run leak deltas. Those
  need the `jdwillmsen-schemas` migration in `jdwlabs/platform` first.
- The in-game chat command.
- A block-palette scanner for beds and workstations. The iron-farm question
  wants it; it reads chunk block data rather than entity records and is
  separate work.

## Why the snapshot is shell, not Go

The original spec called for a Go `LiveSource` performing Bedrock's
`save hold` / `save query` / `save resume` sequence. Reading the existing
implementation changed that decision.

`backup-cronjob.yaml` already performs that sequence, in roughly sixty lines
of bash hardened by real incidents: `save hold` under a bounded `timeout`
(added after JDWLABS-392, where an unresponsive pod blocked the exec until the
job's hour-long deadline killed it), a thirty-iteration poll scraping the
file manifest off the pod log, per-file `head -c "$len"` truncation because
LevelDB keeps appending past its committed length and copying the whole file
is what produces a backup that will not restore, and `trap resume RETURN`
alongside `trap resume EXIT` so a killed shell cannot leave the server unable
to persist anything.

Porting that to Go duplicates the most safety-critical script in this
repository, and puts a second implementation in a position to leave a live
server holding saves. The protocol stays in shell. The Go side gains a source
that reads a directory somebody else prepared.

## Architecture

A `census` CronJob with two containers.

**Init container `snapshot`** runs the reduced snapshot script, mounting the
world PVC read-only at `/data` and an `emptyDir` at `/snapshot`. It drives
`save hold` / `save query` / `save resume` against the server pod, copies each
file in the manifest truncated to its committed length, and writes
`/snapshot/snapshot-taken-at` holding the RFC3339 time the hold was taken.

**Main container `census`** runs
`/census -world-dir /snapshot -backup-dir /backup` from the agent image,
mounting the same `emptyDir` and the backup PVC read-only.

### How the fallback actually works

Two constraints shape this, and both rule out the obvious design.

A failed init container means the main container **never starts** — the pod
fails and the job ends. So the init container cannot signal "no snapshot
today" by exiting non-zero, or the fallback path would be unreachable. It
exits zero for any expected failure (server absent, hold refused, manifest
never arrived) and simply does not write `snapshot-taken-at`. It exits
non-zero only for a genuine internal fault, such as being unable to write to
`/snapshot` at all.

The agent image is `distroless/static`, which has no shell. The main container
therefore cannot branch on whether the snapshot exists. The decision lives in
Go instead: `cmd/census` takes both flags, prefers the snapshot when
`-world-dir` holds a usable one, and falls back to the newest archive
otherwise. The report's existing provenance line states which it used and how
old that world is, so a fallback run is visibly stale rather than quietly so.

### Why not reuse the backup job's script verbatim

The census copy is deliberately a reduction, not a fork:

- No `cold_copy` fallback. A cold copy of a live world is exactly the torn
  read the census must never present as an answer. Where the backup prefers a
  possibly-imperfect archive to no archive, the census prefers no fresh
  snapshot to a wrong one.
- No tar, no gzip, no retention, no size floor. The snapshot is read once by
  the next container and dies with the pod.
- No metrics ConfigMap.

What remains shared is the hold/query/truncate sequence itself. The two
scripts must stay in step; a comment in each names the other. Unifying them
behind one ConfigMap is deliberately deferred: the backup job is what protects
the world, and refactoring it for a DRY benefit before the census has proven
itself in production is the wrong order of risk.

## Agent-side change

`internal/census` gains a second `Source`:

```go
// DirectorySource reads a world that something else has already snapshotted.
type DirectorySource struct {
    Dir string
}
```

`Open` locates the LevelDB under `Dir` using the existing `findDB` search,
reads `snapshot-taken-at` for provenance, and reports `Kind: "snapshot"`.

**A missing or unparsable `snapshot-taken-at` is an error, not a fallback to
the current time.** The report's provenance line is what stops a stale census
being believed, and a source that invents its own timestamp would forge
exactly that. A snapshot without one is malformed.

`cmd/census` gains `-world-dir`, and both flags may be supplied together —
that combination is the CronJob's normal operating mode, not a mistake:

- `-world-dir` set and holding a usable snapshot: use it.
- `-world-dir` set but empty or lacking `snapshot-taken-at`: fall back to
  `-backup-dir` if given, and say so on stderr so the run's own log records
  that the fresh path was attempted and missed.
- `-world-dir` set, unusable, and no `-backup-dir`: error.
- Neither flag: error. There is no default world.

A snapshot directory that exists but is malformed in some *other* way — a
`snapshot-taken-at` that will not parse, a directory holding no LevelDB — is
an error rather than a fallback. Absent means "the snapshot did not happen";
present-but-wrong means something is broken, and silently reading yesterday's
archive instead would bury it.

## RBAC

A ServiceAccount, Role and RoleBinding mirroring the backup job's, minus what
the census does not do:

- `pods` get/list and `pods/exec` create — to drive the save protocol.
- `pods/log` get — `save query` returns its manifest on the pod log, which is
  the only place to read it.

No `statefulsets` read (the census does not care why a server is absent; it
falls back to the archive either way) and no `configmaps` write (it publishes
nothing).

## Values

```yaml
census:
  # Off until an agent release containing cmd/census has been published and
  # agent.image.tag points at it. The binary landed after 0.15.0, so the tag
  # in this file does not yet carry it. Turning this on before then gets a
  # CrashLoopBackOff whose cause is one line deep in a job log.
  enabled: false
  schedule: "0 5 * * *"
  # Drives the save protocol through kubectl exec, same as the backup job,
  # so it tracks the cluster's minor version for the same reason.
  image: alpine/k8s:1.36.2
  # The hold poll is 30 iterations of roughly 5s, and the scan of a 570MB
  # world measured 270ms, so a run that reaches this is wedged, not slow.
  timeoutSeconds: 900
  ttlSecondsAfterFinished: 86400
  resources:
    requests:
      memory: 256Mi
      cpu: 100m
    limits:
      # The scan holds every entity in memory at once. The production world
      # has ~22,600 of them, which is small, but the limit is sized for the
      # extraction and the LevelDB read rather than the entity slice.
      memory: 1Gi
      cpu: 500m
```

The namespace quota is the binding constraint on any new workload here: the
backup (1000m), volume-recovery (500m) and version-check (500m) CronJobs can
already land together against a `limits.cpu` cap of 8000m, of which the
bedrock server holds 4000m. 500m for a job that runs once a day, an hour after
the backup has finished, fits without reopening the quota fight documented at
length in `minecraft-bedrock.resources`.

Scheduled an hour after the backup's `0 4 * * *`, so the archive the fallback
path reads is the freshest one that exists.

## Failure handling

| Failure | Behaviour |
|---|---|
| Server pod absent or not ready | Init exits 0 writing no marker; census reads the newest archive and says so |
| `save hold` times out | Same |
| Manifest never appears within the poll budget | Same |
| A truncated copy fails | Same |
| Init cannot write to `/snapshot` at all | Init exits non-zero; job fails loudly — this is a fault, not a missed snapshot |
| Init killed mid-hold | `trap resume EXIT` releases the hold; job fails; next run retries |
| Snapshot present but `snapshot-taken-at` unparsable | Census errors; a broken snapshot must not be papered over with an archive |
| No usable snapshot and no archive | Census errors naming both paths it tried |

The job never leaves the server held, and never emits a report from bytes it
is not confident in.

## Testing

`DirectorySource` is tested the way `ArchiveSource` is: construct a directory
holding a real fixture LevelDB plus a `snapshot-taken-at`, and assert the
world opens with the right provenance. Cover the missing-timestamp and
unparsable-timestamp cases explicitly, since silently inventing provenance is
the failure this design rejects.

The chart templates are covered by `helm template` rendering in CI, as the
existing jobs are. The snapshot script's hold/resume behaviour cannot be
unit-tested without a live server; it is exercised the first time the job runs,
which is why the job is off by default and turned on deliberately.

## Sequencing

1. Agent PR: `DirectorySource` plus the `-world-dir` flag.
2. An agent release containing it, and the chart's `agent.image.tag` bumped.
3. Deployments PR: snapshot script, CronJob, RBAC, values — shipped with
   `enabled: false`.
4. Flip `enabled: true` once the tag is confirmed to carry the binary.

Steps 1 and 3 are independent to write. Only step 4 depends on both.
