# 2026-08-30 — FWB world data loss on StatefulSet node migration

| | |
|---|---|
| **Workload** | `minecraft-fwb` (`jdwillmsen-prd`) |
| **Damage occurred** | 2026-08-30 20:17:35 UTC |
| **Reported** | 2026-08-30 23:47 UTC (player noticed missing builds) |
| **Service restored** | 2026-08-31 00:33 UTC |
| **Data loss** | 11 `.ldb` files; ~29 MB of world data; ~16 h of play rolled back to restore |
| **User impact** | Builds and terrain missing; ~9 min server downtime during recovery, in two windows |

## Summary

The Bedrock server pod migrated between the two nodes its `nodeAffinity`
permits. The ReadWriteOnce iSCSI volume was unmounted from the old node and
staged on the new one, but the ext4 journal was left dirty despite the unmount
reporting success. `fsck` on the receiving node recovered the journal and
corrected errors, dropping 11 LevelDB files. Minecraft then opened the world,
found those files missing, ran its own repair, and discarded what it could not
recover.

The world data was gone before Minecraft ever started. A server version upgrade
50 minutes later made this look like an upgrade failure, and it was not.

## Impact

Comparing the last pre-damage backup with the post-damage state:

| | db files | uncompressed db bytes |
|---|---:|---:|
| `fwb-20260830T040104Z.tar.gz` (04:01, pre-damage) | 215 | 407,260,093 |
| `fwb-20260830T235210Z.tar.gz` (23:52, post-damage) | 198 | 377,843,201 |

A net loss of **29,416,892 bytes** across a window that also *added* ~2.5 h of
gameplay, so gross loss is somewhat higher. LevelDB named 11 missing files.

Recovery rolled the world back to 04:01, discarding roughly 16 hours, of which
about 1.5 h was human play and the remainder AFK bot activity.

## Timeline

All times UTC.

Prior signals, unnoticed at the time:

```
08-17 01:17:01 [ERROR] A previous save has not been completed.
08-17 04:30:44 [ERROR] Level corruption detected, disconnecting clients and shutting down server
08-19 04:14:58 [ERROR] Level corruption detected, disconnecting clients and shutting down server
08-19 16:17:00 [ERROR] Level corruption detected, disconnecting clients and shutting down server
08-25 03:19:02 libc++abi: terminating due to uncaught exception of type std::length_error
08-25 05:07:49 [ERROR] Level corruption detected, disconnecting clients and shutting down server
08-25 05:12:34-05:24:52  repeated FailedMount events on minecraft-bedrock-0
08-25 05:27:03 [WARN] LevelDB worlds/FWB/db status NOT OK(Corruption: 5 missing files;
                      e.g.: worlds/FWB/db/990838.ldb). Trying repair.
```

The 08-25 event has the same `FailedMount` signature but its CSI-level logs
fall outside Loki retention, so its mechanism is consistent with, but not
proven identical to, the one below.

The incident itself:

```
04:01:04  Saving... → "Data saved. Files are now ready to be copied."
04:01:28  backup fwb-20260830T040104Z.tar.gz, 394,585,604 bytes, quiesced=1
          (last known-good world)

20:16:37  Forwarding signal signal=terminated
20:16:37  Sending message on stdin due to SIGTERM message=stop
20:16:40  Quit correctly
20:16:40  mc-server-runner Done                      ← clean application shutdown

20:17:07  umount /var/lib/kubelet/plugins/.../globalmount        talos-lx0-6a4
20:17:07  FailedAttachVolume: Multi-Attach error for volume      talos-4h8-zy6
20:17:08  NodeUnstageVolume response: {}             ← unstage reported SUCCESS
20:17:17  SuccessfulAttachVolume
20:17:18  NodeStageVolume                                        talos-4h8-zy6
20:17:22  executing filesystem command: fsck /dev/sdc -- -f -p
20:17:23  failed to execute filesystem command: fsck /dev/sdc -- -f -p,
          response: {"code":1,"stdout":"fsck from util-linux 2.38.1\n
          /dev/sdc: recovering journal\n
          /dev/sdc: 11171/327680 files (0.0% non-contiguous), 229972/1310720 bl...
20:17:23  FailedMount: MountVolume.MountDevice failed
20:17:26  fsck retried

20:17:33  Starting Server / Version: 1.26.43.1
20:17:35  [WARN] LevelDB worlds/FWB/db status NOT OK(Corruption: 11 missing files;
          e.g.: worlds/FWB/db/1112176.ldb). Trying repair.
```

Everything after this point is unrelated to the damage but shaped the
misdiagnosis:

```
21:06:48  clean shutdown
21:07:27  Backing up behavior_packs into backup-pre-1.26.45.1   (server assets only, no world)
21:07:30  Version: 1.26.45.1        ← VERSION=LATEST resolved to a new release
21:30:02  ArgoCD sync completes, pod restarts again
23:47     incident reported
```

Recovery:

```
23:52:10  off-cycle backup of the damaged world taken before touching anything
00:05:42  restore job attempt 1 fails: dial tcp 10.96.0.1:443: connect: no route to host
00:16     restore job attempt 2 succeeds — 217 files onto the scratch PVC
00:25     throwaway server opens the scratch world: no corruption, no repair
00:27     promoted 215 db files onto the live world PVC
00:31     ownership corrected to 1000:2000 (verify pod had run as root)
00:33:18  server started on the restored world, clean
00:34:27  first player reconnects
```

## Root cause

The server pod is permitted to schedule on either of two nodes
(`values.yaml`, `nodeAffinity` on `talos-lx0-6a4` and `talos-4h8-zy6`), and
`strategyType: RollingUpdate` restarts it automatically on any chart change.
When a restart places the pod on the other node, the world's ReadWriteOnce
iSCSI volume has to move with it.

That move is not safe on this storage path:

1. The application closed cleanly and the kubelet unmounted the filesystem.
2. `NodeUnstageVolume` returned success, but the ext4 journal was still dirty —
   writes acknowledged into page cache had not been committed to the device.
3. democratic-csi runs `fsck -f -p` before staging on the receiving node. It
   found a dirty filesystem, recovered the journal, and returned **exit code 1,
   meaning errors were found and corrected**.
4. Correcting ext4 errors discards inodes. Eleven `.ldb` files went with it.
5. LevelDB opened, reported 11 missing files, and ran its own repair, which
   discards data it cannot reconstruct.

Two independent repairs therefore ran over the world before the server was
serving: `fsck` at the filesystem layer and LevelDB at the application layer.

Why the filesystem was left dirty despite a successful unmount is **not
established**. `values.yaml` already records that this volume "has twice
remounted read-only underneath a running pod after a transient error on the
iSCSI path", so an unreliable iSCSI path is the leading explanation, but
confirming it needs node kernel logs (`talosctl dmesg`) and TrueNAS-side
evidence that were not available during this investigation.

### Why the pod migrated nodes

Established from git. `a054f03`, bumping `image.tag` from `2026.8.1` to
`2026.8.2`, landed on `main` at **20:15:47 UTC**. ArgoCD auto-synced it, the
image tag is part of the StatefulSet's pod template, and `RollingUpdate`
therefore deleted the pod — **50 seconds later, at 20:16:37**. All three pod
recreations that evening line up the same way:

| Commit landed (UTC) | Change | Restart |
|---|---|---|
| 20:15:47 `a054f03` | image tag `2026.8.1` → `2026.8.2` | 20:16:37 SIGTERM — the one that lost data |
| 21:03:22 `4280433` | pinned version `1.26.43.1` → `1.26.45.1` | 21:06:48 shutdown, 21:07:30 restart |
| 21:29:03 `72dba50` | track `LATEST` | 21:30:02 sync, pod restarts |

Which node it landed on is explained by the scheduler's default
`LeastAllocated` scoring. Reconstructed from Prometheus at 20:15:

```
talos-lx0-6a4   cpu 19.9% free, mem 75.2% free   score 47.6
talos-4h8-zy6   cpu 66.6% free, mem 64.1% free   score 65.4   ← chosen
```

`talos-lx0-6a4` is CPU-saturated, so the replacement was placed on the other
permitted node and the volume had to follow. Note this is CPU-driven: an
earlier reading of this incident blamed the 08-29 memory resize of
`talos-4h8-zy6`, but the counterfactual disproves it — pre-resize that node
still scores ~58.6 against 47.6 and would have won anyway.

The version-check CronJob was **not** involved. It did not exist: `cac6851`
landed at 2026-08-31 00:33:37 UTC, four hours and eighteen minutes after the
damage, while the restore was in progress.

## Contributing factors

- **Two-node affinity on a ReadWriteOnce volume.** The affinity exists for
  memory headroom, not availability — RWO cannot give failover — but it creates
  a migration path that is unsafe on this storage.
- **`RollingUpdate` applies chart changes without a human present**, so the
  migration can happen unattended.
- **Renovate auto-merges the very image whose bump triggered this.**
  `renovate.json` sets `automerge: true` and `platformAutomerge: true` for
  `itzg/minecraft-bedrock-server`. Its justification names `RollingUpdate` and
  the nightly backup as the safety net — but `RollingUpdate` is the mechanism
  that migrated the volume, and the backup is a recovery path, not a guard.
  Enabled by `6a891f5` at 21:53 UTC the same evening: after the damage,
  before anyone understood it. This makes the path that caused the incident
  both unattended and the most frequent pod-template change this workload has.
- **`version: "LATEST"`** meant an unrelated Bedrock upgrade landed 50 minutes
  after the damage, supplying a highly plausible false cause.
- **Daily backups** put the blast radius at up to 24 hours.
- **`volume-recovery` CronJob** mitigates the read-only-remount symptom every
  5 minutes, which keeps the service up and the underlying fault quiet.
- **No alerting on LevelDB repair warnings.** `Corruption: N missing files` had
  been in the logs since 08-25 and nothing surfaced it.

## Hypotheses considered and rejected

| Hypothesis | Why it looked right | What disproved it |
|---|---|---|
| The 1.26.43.1 → 1.26.45.1 upgrade corrupted the world | Player reported corruption hours after an upgrade; Bedrock upgrades worlds one-way on open | Damage is timestamped 20:17:35 on 1.26.43.1; the upgrade ran at 21:07:30, 50 minutes later |
| The backup CronJob multi-attached the world PVC from the wrong node | The job mounts the live world PVC and its co-location is only `preferred` | Every scheduled backup has been co-located with the server (08-25 through 08-28, all `talos-lx0-6a4`); the 08-25 loss had no cross-node pod near it |
| Container logs were not collected, so history was unavailable | The `platform` Loki tenant returns only `source="kubernetes-events"` for this namespace | Logs are under the per-tenant `jdwillmsen` Loki tenant, named by the tenant Grafana datasource |

The second hypothesis reached a merged-ready PR before being disproved; it was
closed rather than merged (#37).

## Detection

Detected by a player noticing missing builds, roughly 3.5 hours after the
damage. The machine-readable signal — `LevelDB ... Corruption: N missing files.
Trying repair.` — had been present since 08-25 and was not alerted on.

Reviewing why afterwards turned up something worse than a missing alert. The
right alert already exists. `loki-rules-node-kernel` in the `monitoring`
namespace carries `NodeKernelISCSISessionRecovery`, whose own description
reads:

> Left unrecovered this aborts the filesystem journal on any volume the
> session backs.

That is this incident, written down in advance. It did not fire because it
queries `{job="integrations/talos/kernel"}` and that stream is almost entirely
absent:

```
talos streams, last 7d:  series: 1
   {'node': 'talos-g1i-e3h', 'job': 'integrations/talos/kernel'}
```

One node out of eight, it is neither node the server runs on
(`talos-lx0-6a4`, `talos-4h8-zy6`), and even that one stopped at
2026-08-26 04:32 — four days before the incident. The two sibling alerts,
`NodeKernelFilesystemFault` and `NodeKernelBlockIOError`, are blind for the
same reason.

So the gap is not "nobody thought of this". Someone did, wrote the alert, and
it has been evaluating against an empty stream. Coverage was assumed from the
alert's existence rather than from its data.

What is genuinely missing on the workload side: nothing alerts on
`Level corruption detected` or `Corruption: N missing files` from the server's
own log, nothing alerts on the server being down (the 08-19 and 08-25
crash-shutdowns were silent), and nothing alerts on a backup archive coming
back materially smaller than its predecessor — which is the one signal that
would have caught the data loss itself rather than its cause.

## Resolution

1. Took an off-cycle backup of the damaged world before any recovery action.
2. Scanned all 15 archives, comparing uncompressed `db` bytes to find the last
   snapshot before the loss. `fwb-20260830T040104Z.tar.gz` had the largest db
   of any archive and was the last before the damage.
3. Ran the restore job to stage that archive on the scratch PVC.
4. Verified it by booting a throwaway server against scratch: clean open, no
   repair.
5. Promoted the verified copy onto the live world PVC, corrected ownership, and
   scaled the server back up.

## Action items

| # | Action | Type | Status |
|---|--------|------|--------|
| 1 | Establish why the ext4 journal was dirty after a successful unstage — needs `talosctl` access and TrueNAS logs | detect | open |
| 2 | Pin the server to a single node, removing the migration path entirely | prevent | open |
| 3 | Alert on `Corruption: .* missing files` and `Level corruption detected` in the server log | detect | open |
| 3a | Restore Talos kernel log shipping — one node of eight reports, neither of them the server's, and that one stopped 2026-08-26. Unblocks the three existing kernel-fault alerts, which are the ones that name this failure | detect | open, `jdwlabs/platform` |
| 3b | Alert on the server being unreachable, using the mc-monitor metrics already scraped | detect | open, `jdwlabs/platform` |
| 3c | Alert when a backup archive is materially smaller than its predecessor. `backup_last_artifact_bytes` is already exported; the 08-30 drop was 29 MB against a series that had only ever grown | detect | open, `jdwlabs/platform` |
| 4 | Correct the two invalidated safety comments in the chart | prevent | open |
| 5 | Increase backup frequency to reduce the 24 h blast radius | mitigate | open |
| 6 | Evaluate moving the world to Longhorn, already installed and replicated | prevent | open |
| 7 | Restore job claims the server is "left scaled to 0 until a human decides" — ArgoCD `selfHeal: true` scales it back up regardless | prevent | open |
| 8 | Restore job has no API-reachability retry; it died on a Cilium endpoint race on first attempt | mitigate | open |
| 9 | Document the per-tenant Loki routing so logs are not presumed missing again | detect | open |

## Assumptions invalidated

Added to the register in [README.md](README.md):

- A ReadWriteOnce volume cannot attach to a second node, so a misplaced pod
  fails safe.
- `RollingUpdate` is safe with a ReadWriteOnce volume because a StatefulSet
  never runs two writers.
- A clean application shutdown means the filesystem was left clean.
- An alert existing means the failure it names is covered.
- A workload's logs reaching Loki means they are queryable where you look.
