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

It is off by default (`census.enabled`), because the binary ships in the agent
image and a release carrying it has to be published before the job can run.

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
