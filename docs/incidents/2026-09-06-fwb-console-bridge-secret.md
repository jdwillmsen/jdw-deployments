# 2026-09-06 — FWB offline 40 hours on a Vault secret that never existed

| | |
|---|---|
| **Workload** | `jdwillmsen-prd/jdwillmsen-minecraft-fwb-prd-minecraft-bedrock` |
| **Detected** | 2026-09-06 03:38 UTC (alert fired, unacted) |
| **Resolved** | 2026-09-07 21:55 UTC |
| **Data loss** | None. World opened clean on restart |
| **User impact** | Server unreachable ~42 h; no player could connect |

## Summary

A chart change wired the console-bridge sidecar's Vault-backed secret onto the
**game server** container as well as the sidecar. The Vault document it read
from did not exist, so the secret was never created, so the server container
could not be configured and never started. The revert was authored and merged
within seven hours, but never reached the pod for another 40: a StatefulSet
does not replace a pod that has never become Ready, and nothing in the cluster
was watching for that shape of failure.

## Impact

The FWB world was unreachable from 2026-09-06 03:25 UTC to 2026-09-07 21:55
UTC — 42 hours 30 minutes. Both AFK bots stayed up and reconnected on their
own once the server returned. No world data was lost: the level opened clean
(`Opening level 'worlds/FWB/db'`, no recovery messages) and the nightly backup
kept running throughout, though as unquiesced copies (see Contributing
factors).

## Timeline

All times UTC.

```
09-05 22:25  44bf487 "feat: wire console-bridge sidecar and server-agent
             Deployment (Stage 2, retry)" authored. Commit message asserts
             "Vault kv put confirmed done by the user."
09-06 03:25  ExternalSecret minecraft-fwb-console-bridge first reports
             SecretSyncedError. Pod begins failing to create containers.
09-06 03:38  JdwillmsenMinecraftServerUnreachable (critical) starts firing.
09-06 05:21  6ae0029 "hotfix: revert the Stage 2 console-bridge retry, live
             server down again" merged.
09-06 05:22  ArgoCD sync operation starts against the reverted revision.
             It does not finish.
09-07 21:48  Alert still firing — 42 h continuous, ~10 Discord notifications
             delivered at the 4 h repeat_interval, none acted on.
09-07 21:55  Wedged pod deleted (actor unidentified; no SuccessfulDelete
             event, so not the StatefulSet controller). Replacement pod
             starts on the reverted spec.
09-07 21:56  Sync operation completes; console-bridge Service and
             ExternalSecret pruned. App returns Synced / Healthy.
09-07 21:55  Server started. Reachable externally, version 1.26.45.
```

Kubelet, repeating for 42 hours (11,750 occurrences):

```
Error: secret "minecraft-fwb-console-bridge" not found
```

external-secrets, repeating (372 occurrences):

```
error processing spec.data[0] (key: minecraft-fwb), err: Secret does not exist
```

## Root cause

`kv/minecraft-fwb` does not exist in Vault. The ExternalSecret asking for it
therefore never produced `minecraft-fwb-console-bridge`, and every container
referencing that secret stayed in `CreateContainerConfigError`.

The reason this took the *server* down, rather than only the new sidecar, is
`minecraft-bedrock.extraEnv`. The change put `WEBSOCKET_PASSWORD` there, from
the same secret, which places the reference on the game server's own container.
A missing secret for an optional sidecar became a missing secret for the
world.

The reason it stayed down after the revert is that a StatefulSet will not
replace a pod that has never been Ready. The reverted spec was applied within
a minute of the merge and the StatefulSet's `updateRevision` moved to it, but
the pod stayed on the superseded revision, unready, unreplaced, indefinitely.
ArgoCD's sync waited on a health that could never arrive (`PruneLast: true`),
so the operation stayed Running for 40 hours, and every subsequent reconcile
logged `Skipping auto-sync: another operation is in progress`. Only an
out-of-band pod delete could break it, and only a human could issue one.

## Contributing factors

- **The claim that the Vault document existed was never checked.** `44bf487`
  states "Vault kv put confirmed done by the user", and `values.yaml` described
  the document as one "the bot LLM secret already uses". That second claim is
  what made the first plausible — but `bot-llm-externalsecret.yaml` is gated
  off (`bot.llm.apiKeySecret.create`) and has never rendered, so nothing in the
  cluster had ever asked Vault for that document. Nothing was checked, and the
  thing cited as corroboration could not corroborate anything.
- **This was the second attempt, and the first failed the same way.** `38eccde`
  (09-03) was reverted by `3c7c648` the same evening, "live server down". The
  retry addressed image pull access, which was one of the first attempt's
  problems, and re-landed the untested secret dependency unchanged.
- **`volume-recovery` could not see this failure.** It gates deletion on
  `restartCount >= 2`, and `CreateContainerConfigError` never starts a
  container, so the count sat at 0 for 40 hours. Its log said so every five
  minutes: `not ready, 0 restarts, below the 2 threshold`.
- **Backups silently degraded.** They kept running but fell back to unquiesced
  copies with the server down, which also fired `WorldArchiveShrank` on 09-05.
  The archives are usable; nothing was lost.

## Hypotheses considered and rejected

| Hypothesis | Why it looked right | What disproved it |
|---|---|---|
| Vault or the ClusterSecretStore is unhealthy | An ExternalSecret was failing, and a broken store fails exactly this way | `ClusterSecretStore vault` reads `Valid`/`Ready`, revalidated 2,821 times over 9 days; all 29 other ExternalSecrets across the cluster were `SecretSynced` |
| The chart still contains the bad wiring | The live pod had a console-bridge container with the missing secret | The StatefulSet's own spec had two containers and no secret references at all — the pod was running a revision the StatefulSet had already superseded, which was itself the second half of the bug |
| Alerting missed it | 42 hours of downtime nobody acted on looks like a monitoring gap | `JdwillmsenMinecraftServerUnreachable` fired continuously from 03:38 and Alertmanager logged zero notification failures. Detection worked; response did not |
| `volume-recovery` was broken | It runs every 5 minutes and did nothing for 40 hours | It ran successfully every time and correctly declined to act — its trigger is a restart count this failure never produces |

## Detection

`JdwillmsenMinecraftServerUnreachable` (critical, `for: 2m`) fired at 03:38,
13 minutes after the first failure, and kept firing for 42 hours. Routing is
correct: severity `critical` reaches the `discord` receiver with a 4-hour
`repeat_interval`, and Alertmanager recorded no delivery errors. The alert was
delivered roughly ten times and not acted on.

This is not a detection gap. It is an alert that fires into a channel nobody
was reading, for a service whose outage nobody else reported for two days.

What was missing was a *distinct* signal for the wedge itself. "Server
unreachable" does not distinguish a crash that will self-heal from a pod no
controller will ever replace, and the second needs a human where the first
does not.

## Resolution

1. The wedged pod was deleted (actor unidentified). The StatefulSet recreated
   it on the already-reverted spec; the server came up in ~20 seconds and
   passed its startup probe.
2. ArgoCD's blocked sync completed on its own once the StatefulSet went
   healthy, pruning the orphaned console-bridge Service and ExternalSecret.
3. Verified externally: RakNet unconnected-ping to `mc.jdwlabs.com:19132`
   returned `MCPE;FWB Server;...;1.26.45;3;20`, and both AFK bots reconnected.

## Action items

| # | Action | Type | Status |
|---|--------|------|--------|
| 1 | Gate console-bridge behind `values-console-bridge.yaml`, not applied by default, so the server's startup never depends on the sidecar's secret | prevent | done |
| 2 | Render the ExternalSecret by default but gate the wiring separately, so Vault can be proven Synced before anything consumes it | prevent | done |
| 3 | Give `volume-recovery` a second trigger: pod unready on a revision the StatefulSet has already superseded, gated on the revision mismatch alone | mitigate | done |
| 4 | Alert on a StatefulSet whose `updateRevision` has not rolled out, so the wedge is visible as itself rather than as a generic outage | detect | done (jdwlabs/platform) |
| 5 | Populate `kv/minecraft-fwb` in Vault | prevent | **open — human only, credential-minting** |

## Assumptions invalidated

- **"A sidecar's dependencies are the sidecar's problem."** They are not, once
  a value file puts them on the main container. `minecraft-bedrock.extraEnv` is
  rendered by plain `toYaml` and cannot carry a condition, so anything placed
  there is unconditional for every render — a secret reference in it is a
  hard startup dependency for the game server itself.
- **"A reverted change is a resolved change."** A StatefulSet will not replace
  a pod that has never been Ready, so a revert of a change that broke pod
  startup does not apply itself. Merging the revert ended the outage in git 40
  hours before it ended in the cluster.
- **"ArgoCD auto-sync will converge eventually."** A sync operation blocked on
  resource health blocks every later reconcile for that Application, and
  reports itself as `Running`, not failed. There is no timeout.
