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
measurement has stopped, which is the state in which none of the four above can
fire whatever the world is doing. Treat it as urgent for the same reason.

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
2. Do not restart the server pod to "see if it comes back clean". The repair the
   server runs at world open drops the records it cannot find, so a clean start
   is the damage being made permanent, not the world being intact.

**Then measure it.** The point of this signal is that the size and the location
of the loss are both already known:

- The dashboard **jdwillmsen / Minecraft FWB World Integrity** has the count per
  dimension, the per-snapshot delta, the server's corruption lines and the map's
  own log line with block coordinates.
- The map's internal API has the full list rather than the logged sample. It is
  on the cluster-only port, so reach it with a port-forward:
  ```bash
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

**Then restore.** The restore procedure itself is
[docs/minecraft-fwb-restore-runbook.md](../../docs/minecraft-fwb-restore-runbook.md):
it covers choosing an archive, extracting it onto a scratch PVC, verifying it
there, and promoting it onto the live world as a deliberate manual step. Two
things specific to a chunk loss:

- Verify the candidate archive by its chunk count, not only by its size. The
  archive is compressed, so a few thousand chunks are a percent or two of
  bytes; the count is exact.
- Once the restore is promoted, the map's ledger still remembers the chunks the
  damaged world was missing, which is deliberate — a restart during an incident
  must not take the damage as the new normal. Clear it only after the restore is
  verified:
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

## Tests

```bash
tools/tests/test-world-integrity-alerts.sh   # promtool unit tests for the rules above
tools/tests/test-tick-rate-alerts.sh
```

Every `tools/tests/test-*.sh` is discovered and run by CI. The alert suites skip
themselves with a message when `promtool` is not on `PATH`, so a local pass is
not evidence on its own.
