# World guard — keeping a crashed host from becoming silent chunk loss

Three parts, each switchable per release:

| Part | What | Switch |
|---|---|---|
| **World guard** (init container `world-guard`) | Checks the world's LevelDB before the server opens it; reports, or holds the pod | Presence of the container in `minecraft-bedrock.initContainers`; `GUARD_MODE: warn` or `enforce` |
| **World sync** (sidecar `world-sync`) | `sync -f /data` every 2 s, so a power loss costs seconds of writes, not 30 | `global.worldSync.enabled`, `global.worldSync.intervalSeconds` |
| **Assisted restore** (`tools/world-restore`) | One command: copy a known-good world over a damaged one, with checks | You run it |

Source of truth for the guard is `tools/world-guard/world_guard.py`. Each chart carries
a generated copy (`tools/world-guard/embed.py --write`); `tools/tests/test-world-guard.sh`
fails when they differ.

## Why

A host that loses power takes the guest page cache with it. ext4 commits a new file's
*existence* with the 5 s journal but allocates and writes its *data* up to 30 s later.
LevelDB's compaction writes new tables, then fsyncs the MANIFEST that names them and
unlinks the inputs. After a power loss the MANIFEST is durable, the inputs are gone, and
the new tables are size-0 files. On 2026-11-06 that was 30 tables, 61,647,259 bytes of
records, 13,487 chunks. The server opens such a db without complaint (tables are opened
lazily) and repairs it, by dropping the tables, minutes later when something first reads
one. Nothing until then said the world was damaged.

## What the guard checks

Before the server opens the db, read-only, in about 0.1 s for a 450-table world:

1. `CURRENT` exists, ends in a newline and names a MANIFEST that exists and is not empty.
2. Every record of that MANIFEST has a valid checksum. LevelDB fails the open on a bad one,
   wherever it is, and the server then repairs; a record cut off by the end of the file is
   the one thing it treats as a clean end.
3. Every table the MANIFEST says is live exists, has the size the MANIFEST recorded, and
   ends in the table footer magic.

Only a positive finding holds the pod. These are reported but never hold it, because
LevelDB itself tolerates them: a MANIFEST cut off or zero-padded at its end, tables nothing
references (it deletes them at open), a `lost/` directory from an earlier repair. A missing
world (first boot), an unreadable directory, a MANIFEST the parser cannot decode, a check
that exceeds `CHECK_TIMEOUT` (120 s) and any crash of the guard itself are `inconclusive`:
logged, and the server starts. The guard's own bug must never be what keeps a world down.

Every outcome is one log line, `world-guard: {json}`, with an `event`:

| event | meaning |
|---|---|
| `clean`, `absent` | nothing wrong, or no world yet; server starts |
| `inconclusive` | could not decide; server starts |
| `would_hold` | damaged, `warn` mode: **the server starts**; this is what `enforce` would have held. Printed again every 2 s for 30 s (`repeat: true`) before the server may start (`WARN_LINGER_SECONDS`, capped at 120; startup is that much slower only when damage is found): the log shipper only reads lines written after it finds a container's log, so a single line from a container that exits at once is never shipped |
| `held` | damaged, `enforce` mode: pod stays `Init:0/N`, re-checked every 30 s |
| `released` | was held, the world now checks clean (an undecided or missing-world recheck keeps the hold) |
| `accepted` | an operator let the server open a damaged world |

The latest damaged finding is also written to `/data/.world-guard/report.json` (bad tables,
bytes, first and last modification time of the lost files).

## When it holds

`enforce` mode, damage found: the pod sits in `Init:0/N` and the server never opens the
db. Nothing is repaired, so nothing is lost beyond what the crash already took. It pages
(see the chart's alerts). Two ways out:

**Restore a good world** (preferred): `tools/world-restore`, below. When it finishes the
server is scaled back up and the guard passes.

**Accept the loss**: let the server open the world and repair it, dropping what it cannot read.

```bash
kubectl -n "$N" exec "$POD" -c world-guard -- touch /data/.world-guard-accept
```

Any agent may do this on a page, and must log it on JDW-341 (who, when, the report). The
guard deletes the file when it uses it, and deletes a stale one when the world is clean, so
one `touch` accepts one finding. Re-enabling `enforce` after a release has been put back to
`warn` is an R3 change.

Deleting the pod to "see if it comes back" achieves nothing: the init container runs again
and holds again.

## Known limits

- Init containers re-run when the pod is recreated (a node reboot or power loss, a
  `kubectl delete pod`, a rollout), not when only the server container restarts in place
  (a server crash, an OOM kill, the nightly in-place restart). The target case, a host
  power loss, recreates the pod. A damaged world after an in-place restart is still
  found by the existing corruption and chunk-census alerts, not by the guard.
- It cannot see damage inside a table that has the right size and footer.
- Its image (`alpine/k8s`, the CronJobs' toolbox) must be on the node or pullable. After a
  site-wide power loss the registry may not be reachable: a node that does not have the image
  holds the pod in `ImagePullBackOff`, which is not the guard failing open. Every node that has
  run a CronJob has it.
- It does not stop the damage; the sidecar shortens the window.

## Warn first

A release ships with `GUARD_MODE: warn`: the guard reports `would_hold` and the server starts.
After a week of clean (or understood) reports a separate small change flips it to `enforce`.
The container's `env` is a literal: init containers are rendered without templating, so the
flip is one line in the values file that carries the container.

## Assisted restore

```bash
tools/world-restore --release jdwillmsen-minecraft-fwb-prd --level FWB --source generation:a   # plan only
tools/world-restore --release jdwillmsen-minecraft-fwb-prd --level FWB --source generation:a --yes
```

`--source` is `generation:NAME` (the map's retained generation; add `--taken-at` with the
`takenAt` you chose so a slot that changed under you is refused) or `scratch:DIR` (a world
already on the scratch claim at `/scratch/DIR/<level>`). It scales the server (and the map)
down, copies the source onto the scratch claim, runs the guard's checker on the copy, boots a
*copy* of it on the server's own image and requires `Server started` with no corruption line,
saves the damaged world aside on scratch as `<level>-damaged-<UTC>`, stages the good one beside the
live one, compares sha256 manifests, swaps by rename, scales up and requires Ready. Exit 2 means
it failed after the swap began: do not re-run, read the message. The map's ledger needs its
acknowledgement afterwards (`charts/minecraft-fwb/README.md`, "Restoring from a retained
generation", step 6): that takes the internal token and is deliberately not done by the tool.

Choosing the generation, and deciding that a rollback is better than losing the damaged
chunks, are the README's. The tool does not restore on its own and nothing calls it
unattended.

## World sync

`sync -f /data` is `syncfs(2)` on the world's filesystem: it writes every dirty page of that
volume, including the table data and the journal, so the table files and the MANIFEST that
names them reach the disk together. Run from the server image in a sidecar of the same pod,
every `intervalSeconds` (2). It touches no node setting and no other workload. The mount is
read-only on purpose; syncfs flushes the filesystem behind the descriptor, not the mount.

It is switched on per release in `values*.yaml`:

```yaml
global:
  worldSync:
    enabled: true
    intervalSeconds: 2
```

Revert on any new tick-rate alert or a TPS drop over 2 %. `tools/world-guard/tps-ab.py` is
the A/B rig used to decide that on the test server.

## Drill (proving-grounds)

The test server runs `enforce`. To rehearse a hold and a restore without touching anything
that matters, in order: stop the server, take a good copy of its world onto the scratch claim
(`scratch:good`), zero the 30 newest tables of the live world's db, start the server (expect
`Init:0/3` and `held` lines), run `tools/world-restore --source scratch:good --yes`, and
expect `RESTORED`. The 2026-11-11 run is recorded in the PR for JDW-341.
