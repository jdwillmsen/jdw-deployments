# jdw-deployments

[![License](https://img.shields.io/badge/License-PolyForm%20NonCommercial%201.0-blue)](https://polyformproject.org/licenses/noncommercial/1.0.0/)

Deployment manifests for the `jdwillmsen` tenant of the jdwlabs Kubernetes
platform. A personal homelab, published to read rather than to depend on: no
support is offered and the layout changes to suit its one operator.

ArgoCD discovers work here through the tenant's `deploymentRepo.url`. The
`jdwillmsen-deployments` ApplicationSet reads every `argocd/*/config.yaml`,
and generates one Application per entry in its `apps` list.

## Layout

```
argocd/<env>/config.yaml   app list for that environment
charts/<name>/             the chart each app points at
```

An entry names the chart by `chartPath` within this repo, so charts are
self-contained here rather than referenced remotely.

## Charts

| Chart | What |
|---|---|
| `minecraft-fwb` | Minecraft Bedrock server, migrated off an unmanaged Proxmox VM |

### NetherNet, and why this server is not on it

Bedrock 1.26.51 prints this at ERROR level on every RakNet start:

```
Your current connection type is not set to NetherNet. In this release,
NetherNet is the only supported transport type.
Players will not be able to connect to your game without NetherNet.
```

**Do not act on that message the way it reads.** On 2026-09-15 it was taken at
face value and production was moved to `transport=nethernet` during an outage.
The signaling listener came up, the port was reachable from the LAN and
answered HTTP, and a real client still could not join -- it reported trouble
establishing NetherNet services. Meanwhile the switch took the server agent and
both AFK bots offline, because they are RakNet clients and there is no
configuration where both transports work.

The server runs `transport=raknet` and players connect on **31132**, unchanged.

What was actually wrong that day was the version: clients auto-updated to
1.26.51 while the server was on 1.26.45, and a version-mismatched server
rejects them. Updating the server fixed that. The NetherNet move came after,
on the assumption that RakNet was dead -- an assumption never tested against a
real client, because the only clients that connected in that window were Go
library clients that implement RakNet themselves and are unaffected by what
retail clients do. See `docs/incidents/2026-09-15-fwb-version-check-nethernet.md`.

The chart keeps everything the attempt produced, switched off:

| Kept | State | Why it is still here |
|---|---|---|
| `nethernet-service.yaml` | rendered, unused | NetherNet is where Mojang is going; the nodePort and UDP-range mechanics were expensive to work out |
| `nethernet-probe.yaml` | `netherNet.probe.enabled: false` | It is a TCP connect against a signaling port a RakNet server does not open, so it would report a false outage |

What a second attempt needs, beyond what is here:

- `transport=nethernet` and `server-udp-ports` in `server.properties` on the
  world PVC -- the itzg image maps neither key, so the chart cannot set them.
  A copy of the NetherNet file is kept at `/data/server.properties.nethernet`
- A **verified client join** before anything else is changed, and before the
  bots are taken down for it
- Probes that do not assume a transport. Every one the vendored subchart
  renders is an `mc-monitor status-bedrock` RakNet ping, so a NetherNet server
  has to run with liveness and startup disabled, which is how this workload
  spent that evening with no health check at all
- A route for the agent and both AFK bots, which have no NetherNet client

### The AFK bot(s)

`minecraft-fwb` also carries one or more optional headless clients, off by
default. Each holds a player slot so mob farms tick, and mirrors in-game chat
to its stdout as JSON — the server itself never logs chat, and no
`server.properties` setting makes it.

Two independent instances exist today, `bot` and `bot2` — separate
Deployment, PVC, and `MC_USERNAME` token-cache key each, so a second (or
third — copy the pattern) bot never collides with the first. They are kept as
separate named blocks + templates rather than a generic list on purpose: a
list would rename `bot`'s currently-unsuffixed resources and orphan its
already-authenticated token cache the moment the chart changed shape.

Enabling one is a two-step bootstrap, because it signs in as a real Microsoft
account:

1. Publish the image tag named in `bot.image.tag` (or `bot2.image.tag`).
2. Set `bot.enabled: true` (or `bot2.enabled: true`), then read the pod log
   for the device code and complete that login once — in a private/incognito
   browser window, or signed out of any account you don't want to
   accidentally authenticate instead. The token caches to a volume, so
   restarts are unattended afterwards.

   What to watch for depends on the implementation. The Go bot prints a plain
   line, `Authenticate at https://www.microsoft.com/link using the code
   XXXXXXXX.`; the TypeScript one emits a `device_code_required` JSON event
   carrying `user_code` and `verification_uri`. Grepping for the JSON event
   against a Go bot waits forever.

The bot's XUID then goes on the server allowlist. It appears in the server log
on first connect.

**Switching a bot between implementations costs a login.** The Go client's
token cache format is its own, and a cache written by the TypeScript build
cannot be read by it. Moving `bot.image.tag` from a `0.x` tag to a `1.x` one
is therefore not a plain image bump: the pod comes up unauthenticated and waits
on a device code, exactly like step 2 above. The PVC does not need clearing —
the stale cache is simply ignored — so `enabled` stays `true` throughout.

**A device code can land on the wrong account.** The device-code page just
authenticates whatever Microsoft account is already active in the browser
that opens it — it does not prompt you to choose. If the wrong account ends
up signed in (confirm by checking which gamertag connects in the server log,
not by trusting what you intended to type): the cache has to be cleared and
the login redone.

Clearing it goes through git, by PRing `bot.enabled: false` (or
`bot2.enabled: false`), letting ArgoCD sync, then setting it back to `true`.
`enabled` gates the PVC as well as the Deployment and the Application prunes,
so the cache goes with it — which is the one situation where wiping it is the
point rather than an accident.

Then repeat step 2 above, this time actually in a fresh incognito window.

Do **not** reach for `kubectl exec ... rm -rf /data/auth/*`. The Go bot's
image is distroless and has no shell, so that fails with
`exec: "sh": executable file not found in $PATH` — and reading a token cache
out of a running pod is not something to reach for either.

#### Relocating a bot

The bot has no movement logic of its own — it just stands wherever it last
was. To move it, someone has to drive that account's client by hand, which
means taking the bot's own connection down first (only one active session per
account) and bringing it back after:

1. **PR** `bot.replicas: 0` (or `bot2.replicas: 0`) into this chart's
   `values.yaml`, merge, and let ArgoCD sync. Do **not** `kubectl scale`
   directly — this Application syncs with `selfHeal: true`, so a scale done
   outside git gets reverted on the next resync. `replicas` is deliberately
   the only thing gated here, not `enabled`: `enabled: false` would also
   delete the PVC and wipe the token cache, forcing another device-code
   login for no reason.
2. Sign into that Microsoft account on your own device (phone, console, PC —
   same credentials as the device-code login) and move the character where
   you want it.
3. Log out on your device, then PR `bot.replicas` back out (or explicitly to
   `1`), merge, sync. The bot reconnects the same cached account and resumes
   exactly where you left the character — position is part of the world
   save, and the token cache was never touched.

A server restart alone does **not** need any of this: the bot reconnects on
its own (`RECONNECT_MIN_MS`/`RECONNECT_MAX_MS`), no manual step required.

### The server agent

`minecraft-fwb` also carries `minecraft-server-agent` (a chat-reading,
tool-calling assistant) and its sidecar `mc-console-bridge` (the only thing
with write access to the server console — a fixed command allowlist, no free
console access). Off by default, same `agent.enabled: false` pattern as the
bots above, for the same reason: it signs in as a real Microsoft account too.

#### Enabling the console bridge

The console-bridge half is gated by its own values file, `charts/minecraft-fwb/
values-console-bridge.yaml`, which the ArgoCD Application does not list. Until
it is listed, the chart renders the sidecar, the Service and the server's
`WEBSOCKET_*` settings not at all.

That gate exists because of one line. `minecraft-bedrock.extraEnv` sets
`WEBSOCKET_PASSWORD` on the **game server container** from the same secret the
sidecar uses, and the vendored subchart renders `extraEnv` through plain
`toYaml`, never `tpl` — so nothing in it can be made conditional, and a secret
reference there binds the server's own startup to that secret existing. On
2026-09-06 it did not exist: the server would not start, the StatefulSet would
not replace a pod that had never gone Ready, and the world was offline for 40
hours (`docs/incidents/2026-09-06-fwb-console-bridge-secret.md`).

**Enabling this restarts the live server pod.** The extraEnv and
sidecarContainers changes go on the server's own StatefulSet, and Bedrock has
no live-reload for either — ArgoCD's `selfHeal: true` will roll the pod on
the next sync. Time the merge for low player activity, the same care any
`minecraft-bedrock` chart change already warrants (see the incidents in
`docs/incidents/`), and be aware of the open upstream crash-on-join defect
(`docs/incidents/2026-08-31-bedrock-crash-on-player-join.md`) before doing so.

Bootstrap, in order. Steps 1 and 2 are separated on purpose: the ExternalSecret
renders by default precisely so that Vault can be proven *before* anything
depends on it. Do not collapse them.

1. **Populate the Vault secret this needs.** Run this yourself, in your own
   terminal — not through an agent's shell, per this repo's credential-
   minting rule (`AGENTS.md`):
   ```bash
   vault kv put kv/minecraft-fwb \
     console_websocket_password=<generate a real value> \
     console_bridge_token=<generate a different real value>
   ```
   (`llm_api_key`, if that secret is ever populated, lives in this same `kv/
   minecraft-fwb` document — this adds two properties to it, not a new path.)
2. **Confirm the secret actually materialised**, and do not proceed on any
   weaker evidence than this command's output. A `kv put` you believe you ran
   is not evidence; neither is another ExternalSecret in the chart naming the
   same document, since `bot-llm-externalsecret.yaml` is gated off and has
   never rendered:
   ```bash
   kubectl -n jdwillmsen-prd get externalsecret minecraft-fwb-console-bridge
   ```
   It must read `SecretSynced` / `True`. `SecretSyncedError` means the document
   or a property is missing — fix that first; nothing is broken yet while
   nothing consumes it.
3. Add `values-console-bridge.yaml` to `valueFiles` for `minecraft-fwb-prd` in
   `argocd/prd/config.yaml`, after `values.yaml` and `values-prd.yaml` (order
   matters — it merges over both). The server pod restarts (see above);
   confirm it comes back healthy (`tools/mc status`) before continuing. If it
   does not, remove that line again — the revert only takes effect once the
   wedged pod is deleted, which `volume-recovery` now does within five minutes
   on its own.
4. Publish the image tag named in `agent.image.tag`, then set
   `agent.enabled: true` and merge/sync.
5. Read the agent pod's log for a `device_code_required` event and complete
   that login once, same caveats as the bots above — **a device code can
   land on the wrong account**; confirm the gamertag that actually connects
   in the server log, and if it's wrong, clear the cache
   (`kubectl exec -n jdwillmsen-prd <agent-pod> -- sh -c 'rm -rf /data/auth/*'`,
   `kubectl delete pod -n jdwillmsen-prd <agent-pod>`) and redo the login in
   a fresh incognito window.
6. Add the agent's gamertag to the server allowlist — it cannot join without
   this, and the console-bridge only ever *reads* `allowlist.json`, never
   writes it:
   ```bash
   tools/mc run allowlist add "<agent's gamertag>"
   ```

#### Why the console's origin check is off

Every start of the server logs a WARN saying the websocket origin check is
disabled and the server is open to Cross-Site WebSocket Hijacking. That is
deliberate, and it currently cannot be otherwise from this repo.

`mc-server-runner` admits a websocket only when the request's literal `Origin`
header appears in `WEBSOCKET_ALLOWED_ORIGINS`, and its flag parser drops blank
fields from that list — so the empty string cannot be an entry, and a client
that sends no `Origin` at all is refused under *every* allow-list, empty or
not. The console-bridge sidecar is exactly that client: it sends no `Origin`.
Turning the check on therefore answers the bridge with `403 origin not
allowed` and takes the console path down; it admits only clients that do send
an `Origin`, which means browsers, which is the threat. It was configured this
way round on first deploy and did exactly that.

What holds instead is the bind address: `WEBSOCKET_ADDRESS` puts the console on
`127.0.0.1`, no Service publishes that port, and no container declares it — so
the browser the attack needs has nothing it can reach. That pair is what
`tools/tests/test-console-origin.sh` pins, including that an allow-list is
never left set while the check is disabled, where it would read as protection
that is not applied.

Closing this properly needs the sidecar to send a fixed `Origin` of its own,
released as a new `mc-console-bridge` image; the chart can then name that value
in `WEBSOCKET_ALLOWED_ORIGINS` and drop `WEBSOCKET_DISABLE_ORIGIN_CHECK`. Until
that image exists, changing the setting here is an outage, not a hardening.

### Reading the mob census

`census` runs daily at 05:40 UTC and prints a report of what lives in the world
and which 9x9-chunk regions have reached Bedrock's mob spawn cap — the
reproducible form of "why is nothing spawning near my base". That slot is not
arbitrary: it is clear of the backup, which starts at 04:00 and may run for an
hour, and of the version check, whose 05:00 run can be restarting the server
until 05:25. All three drive the same server's save protocol, and two of them
holding it at once produces a snapshot taken while the server was writing.

```bash
kubectl logs -n <namespace> job/$(kubectl get jobs -n <namespace> \
  -l job-name --sort-by=.metadata.creationTimestamp -o name | grep census | tail -1 | cut -d/ -f2)
```

Its first line says which world it read and when that world was captured. A
report reading `via archive` means the fresh snapshot could not be taken that
run — the server was down, or refused the save hold — and the numbers are up
to a day old. `via snapshot` means they are minutes old.

`census.enabled` is the switch. It shipped off, because the binary rides in the
agent image and a release carrying it had to be published first; it has been on
since agent 0.16.0, which is that release. `census.metrics.enabled` below
follows the same two-step and is on as of 0.17.0.

#### The counts as metrics

The report is the better artefact for the spawn-cap and concentration tables,
and a bad one for "is world load growing?" — the Job log holding it is evicted
by `successfulJobsHistoryLimit` within three days. `census.metrics.enabled`
publishes the same counts as time series, without changing the report.

The path is three parts, because the census image is distroless and so has
neither a shell nor `kubectl`:

1. `/census -metrics-file /tmp/metrics.txt` writes a Prometheus payload at the
   end of a run that produced a report — and only then, so a world the census
   refused to report cannot put a fabricated dip on a graph
2. a `metrics-publish` sidecar in the same pod watches that file and writes it
   into the `<release>-census-metrics` ConfigMap. It is a native sidecar
   (`restartPolicy: Always` among the init containers), so it cannot hold the
   Job open, and it publishes once more on SIGTERM because the file lands
   moments before the census exits
3. `<release>-census-exporter` serves that ConfigMap, scraped by its own
   ServiceMonitor

A second exporter rather than a second payload in the backup exporter:
Prometheus drops an entire scrape on one malformed line, and the backup
freshness contract should not be able to lose to a census bug.

```bash
kubectl get configmap -n <namespace> <release>-census-metrics -o jsonpath='{.data.metrics\.txt}'
```

`mc_census_reported` is 0 until a census has published, which is what separates
"no run yet" from "a world with nothing in it".
`mc_census_world_taken_at_timestamp_seconds` and `mc_census_world_from_snapshot`
carry the provenance the report prints in words: a run that fell back to an
archive is reporting numbers up to a day old, and a graph cannot say so on its
own. The full metric list is in the agent repo's README.

### The nightly restart, and the tick rate alert

`scheduledRestart` stops and restarts the server every day at **16:40 UTC**
(11:40 CDT). It exists because Bedrock 1.26.51.1 loses tick rate with process
age: 20.00 TPS after a restart, roughly 3.5 TPS/day lost after that, down to
12.5 by the second day. The same world on 1.26.45 held 20.00 flat across a
4.7-day process, and a restart puts it straight back — 12.8 to 19.98 TPS,
measured on 2026-09-18. The decay itself has no fix yet.

The slot is picked for where it leaves the decay. TPS holds near 20 for about
twelve hours of process age and falls after that, and players are online from
22:00 to 07:00 UTC with the peak at 02:00-03:00. 16:40 puts that peak at ten
hours of age, and had no players beyond the always-on bots in fourteen days of
session history. The slot also clears the other actors that drive this same
server: the backup starts at 04:00 and may hold the save until 05:00, the
census runs at 05:40, and the hourly version check can be restarting the
server until HH:25.

The restart is `send-command stop` through the server's own console — never
`kubectl rollout restart`, never a pod delete. The container comes back inside
the same pod on the same node with the world volume never unmounted; deleting
the pod is what migrated the volume and cost 11 `.ldb` files on 2026-08-30. The
job fails loudly if it sees a new pod UID afterwards rather than an incremented
restart count. Players online get a 120-second countdown first
(`scheduledRestart.leadSeconds`); an empty server is restarted immediately.

After each restart the job also records the network statistics the server
wrote for the process that just stopped. Bedrock writes them to
`/data/packet-statistics.txt` on every shutdown and overwrites the file each
time, and the backups copy only the world, so nothing else keeps them. They
come out as one JSON line, which makes a day's worth of processes comparable
in Loki:

```bash
logcli query '{namespace="<namespace>", container="scheduled-restart"} |= "packet_statistics" | json'
```

`seconds` is how long that process ran, and every count is a total over it.
Divide by `seconds` before comparing two nights.

`tickRateAlert` is the other half, and separately switchable. It fires when
`mc_agent_server_tps` sits under 17 for 30 minutes, paired with the agent's
freshness timestamp so a stale reading suppresses the alert instead of paging
about a frozen number. A second rule reports the measurement being gone at all,
since a comparison never matches a series nobody is producing. Replayed against
the 2026-09-16 decay the first rule would have fired at 20:15 that evening,
about thirteen hours in — the real thing went unnoticed for two days.

### Knowing whether players can actually join

Every check in this chart passed for the whole of the 2026-09-15 outage while
nobody could join. The RakNet ping answered, `mc-monitor` reported the server
online with players on it, and all three kubelet probes were green — the server
was a version behind its clients and refuses a mismatched protocol *before*
login, which is past everything being checked. The two clients that were
connected had joined before the fault and speak RakNet themselves, so their
presence argued the server was fine.

Two things now ask the question those checks could not.

**`joinProbe`** runs `/joinprobe` from the agent image as its own Deployment. It
performs the pre-login handshake once a minute against the in-cluster Service —
not the NodePort, which would also be testing HAProxy and the DNAT rules — and
publishes how far it got:

```bash
kubectl port-forward -n <namespace> deploy/<release>-join-probe 9103:9103 &
curl -s localhost:9103/metrics | grep mc_joinprobe
```

`port-forward` rather than `kubectl exec`: the agent image is distroless, so
there is no shell and no `wget` in that container to exec into.

`mc_joinprobe_joinable` is the one to read; `mc_joinprobe_stage` says where it
stopped (0 unreachable, 1 answered the ping, 2 refused the session) and
`mc_joinprobe_play_status` carries the server's own reason for a refusal, where
`2` is the version skew from September. `JdwillmsenMinecraftUnjoinable` fires
after ten minutes of that, which clears both an ordinary restart and the
nightly one with its countdown.

It needs no Microsoft account, because the protocol verdict arrives before any
credential is examined. What it cannot prove is that a real client can
authenticate and spawn.

When the alert fires — or when someone just says they cannot get in —
[docs/minecraft-fwb-joinability-runbook.md](docs/minecraft-fwb-joinability-runbook.md)
walks each stage the probe can report, and separates "server down" from "server
up but unjoinable", which look identical from a player's chair.

**`agent.sessionRecycleMs`** covers that half, at **six hours** — four proofs a
day. Each cycle is a real client authenticating and reaching spawn —
`mc_agent_session_established_timestamp_seconds` is when that last worked, and
`JdwillmsenMinecraftAgentSessionStale` fires if two and a half cycles pass
without one. Open player sessions are credited before the drop, the way a
leadership handover does, so nobody loses playtime to it.

The one thing worth knowing about it, because it was the open question before
this shipped at full cadence: this server holds a session open after a client
leaves (`playerIdleTimeout: 0`, and freeing an account has needed
`tools/mc run kick` before), so a rejoin by the same account could have been
refused as already connected. It is not — the first recycle dropped and was
spawned again 10.2 seconds later on the same account. A recycle that ever does
fail to come back raises `JdwillmsenMinecraftAgentSessionStale` after two and a
half cycles, and `sessionRecycleMs: 0` switches the whole thing off.

### Restoring a backup

The chart also carries a restore mechanism alongside the backup CronJob:
[docs/minecraft-fwb-restore-runbook.md](docs/minecraft-fwb-restore-runbook.md)
is the runbook, and covers what runs automatically (scaling the server down,
extracting onto a scratch PVC) versus what stays a manual, deliberate step
(promoting a verified restore onto the live world).

## Working on a chart

Dependencies are declared in `Chart.yaml`, pinned by `Chart.lock`, and the
resolved `charts/*/charts/` directory **is committed**. That differs from
`jdwlabs/deployments`, which gitignores it — those dependencies are `file://`
siblings already in the checkout, whereas these come from an external Helm
repository. Vendoring keeps ArgoCD's render path free of an upstream fetch
that would otherwise fail as a broken sync rather than a clear error.

After changing a dependency:

```bash
helm dependency update charts/<name>   # refreshes Chart.lock and charts/
helm lint charts/<name> -f charts/<name>/values.yaml
helm template <name> charts/<name> -f charts/<name>/values.yaml
```
