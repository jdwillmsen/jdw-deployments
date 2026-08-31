# 2026-08-31 — Bedrock server crashes when a player joins

| | |
|---|---|
| **Workload** | `minecraft-fwb` (`jdwillmsen-prd`) |
| **First observed** | 2026-08-25 03:19:02 UTC |
| **Most recent** | 2026-08-31 04:32:48 UTC |
| **Data loss** | None |
| **User impact** | ~60s outage per occurrence; players and AFK bots reconnect on their own |
| **Status** | Open. Upstream defect, no local fix |

## Summary

The Bedrock server process aborts within a second of a player connecting, and
the container restarts in place. It has happened three times, on two different
Bedrock versions, and is not caused by anything in this repository. The world
is undamaged each time.

Recovery is automatic and takes about a minute. Nothing alerts on it — all
three occurrences were found by reading logs.

## Impact

Each crash disconnects everyone and the server is unreachable for roughly 60
seconds while the container restarts. No world data has been lost: every
restart reopens the level with no LevelDB repair, and the db file count and
size track normal growth across all three.

## Evidence

Three crashes match the pattern. Each is `exitCode 1` with a Mojang
`CrashReporter Key`, and each follows a `Player connected` line by under a
second:

```
08-25 03:19:01:993  Player connected: JoshLSorenson21, xuid: 2535466479459975
08-25 03:19:02      libc++abi: terminating due to uncaught exception of
                    type std::length_error: basic_string
                    Version: 1.26.43.1

08-31 03:43:14:049  Player connected: Dotablaze, xuid: 2535473803383948
08-31 03:43:14:835  Crash                                    (+786ms)
                    Version: 1.26.45.1

08-31 04:32:47:918  Player connected: LightKing0221, xuid: 2535466479459975
08-31 04:32:48:428  Crash                                    (+510ms)
                    Version: 1.26.45.1
```

Only the first captured an exception type. The later two emitted just
`at __clone` before `mc-server-runner` reported `{"exitCode": 1}`.

Three further server failures in the same period are a **different** problem —
`Level corruption detected` shutdowns on 08-17, 08-19 (×2) and 08-25 05:07,
which belong to
[the storage incident](2026-08-30-fwb-world-data-loss.md). They are not
counted here.

## What is established

- The crash is upstream. It occurs on **both** 1.26.43.1 and 1.26.45.1, so it
  predates the version change and is unrelated to it.
- It is triggered at, or immediately after, player connect.
- The one captured exception is `std::length_error: basic_string` — a
  string-length fault, not a memory or world-data fault.
- It is self-healing: `restartPolicy: Always` restarts the container in place,
  the volume never unmounts, and the world reopens clean.
- Base rate is low: 72 player connects in 14 days, three crashes.

## Unconfirmed: the gamertag correlation

For one account, both of its crashes coincide exactly with the server seeing a
**new (xuid, gamertag) pair**:

```
08-25 03:19:01  JoshLSorenson21   first sighting of xuid 2535466479459975  -> crash
08-31 04:32:47  LightKing0221     same xuid, renamed                       -> crash
08-31 04:33:46  LightKing0221     retry one minute later                   -> joined fine
```

`allowlist.json` carries player names and the server rewrites it on connect;
its size moved 668 -> 666 bytes across the rename, exactly the difference
between the two gamertags. A string-length exception while reconciling a
changed name is a plausible mechanism.

Against it: the 08-31 03:43 crash was a long-known account with no rename, and
an 08-17 backup shows `JoshLSorenson21` already carried an xuid before its
first connect — so "writes the xuid on first join" is not the mechanism. Treat
the correlation as a lead, not a cause.

**A prediction worth watching.** `allowlist.json` contains one entry with no
`xuid` at all:

```json
{"ignoresPlayerLimit":false,"name":"ShadowFr33z3"}
```

That account has never connected. If the correlation is real, its first
connect is a candidate to reproduce the crash.

## Detection

All three were found by reading logs. Nothing alerts on the server being
unreachable — that is action item 3b of the storage incident, open in
`jdwlabs/platform` (see jdwlabs/platform#399). A crash lasting ~60s inside an
hourly window is invisible without it.

## Resolution

None applied. Nothing in this chart causes it and nothing here can fix it. The
existing behaviour — in-place container restart, world intact, clients
reconnect — is the correct response and already works.

## Action items

| # | Action | Type | Status |
|---|--------|------|--------|
| 1 | Alert on the server being unreachable, so these stop being found by eye | detect | open, `jdwlabs/platform#399` |
| 2 | Watch whether `ShadowFr33z3`'s first connect reproduces it | detect | open |
| 3 | Capture a full crash dump — the later crashes lost the exception type, so raise the container's crash output if the image allows | detect | open |
| 4 | Report upstream if a fourth occurrence sharpens the trigger. No matching public report was found for `std::length_error` on join in BDS 1.26.x | prevent | open |

## Notes

This incident is a useful control for the storage incident. On 08-31 03:43 the
server died uncleanly and restarted in place with **no** corruption, while the
08-30 clean shutdown that recreated the pod lost 11 `.ldb` files. The process
dying is survivable; the volume moving is not. That contrast is the evidence
behind the in-place restart in #44.
