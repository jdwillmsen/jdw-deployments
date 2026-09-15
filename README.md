# jdw-deployments

Private deployment manifests for the `jdwillmsen` tenant of the jdwlabs
Kubernetes platform.

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

### NetherNet transition

**The server currently speaks NetherNet, and while it does, nothing is health
checking it.** Read this before touching the chart.

Bedrock 1.26.51 made NetherNet the only transport retail clients will use.
RakNet still answers the server-list ping and still serves library clients, so
a server left on `transport=raknet` looks reachable, answers a ping, and
accepts the Go bots -- while no player can join it. That is what the
2026-09-15 outage was.

**Players connect on port `31134`, not `31132`.** A nodePort is allocated per
number across the cluster and not per protocol, so the TCP signaling port
cannot reuse the number the subchart's UDP Service already holds.

Two of the settings live on the world PVC rather than in the chart, because
the itzg image has no property mapping for either key:

```
transport=nethernet
server-udp-ports=192.168.1.87:31160-31179:31160-31179
```

The address in `server-udp-ports` is the **node's** LAN address, not the
pod's. NetherNet negotiates gameplay UDP per client and advertises where to
reach it; left to itself it advertises the pod IP, which is a `10.244.x`
address nothing on the LAN can route to. The range is pinned so the matching
NodePorts can be opened, and its size matches `maxPlayers`.

What is switched off while this is in place, and why:

| Off | Why | Back on when |
|---|---|---|
| `startupProbe`, and `livenessProbe` in all but name | Both are `mc-monitor status-bedrock` RakNet pings hardcoded in the vendored subchart. Left on, the startup probe kills the container and liveness restarts it every ~60s | The workload template is vendored out of the subchart with probes that do not assume a transport |
| Readiness, in effect | Same ping. It fails, so the pod reads `NotReady` and the ArgoCD app reads `Degraded` — deliberately, because that is true | Same as above |
| `bot`, `bot2`, `agent` (`replicas: 0`) | All three dial RakNet. Against a NetherNet server they are not degraded, they are a reconnect loop against a port that will never answer | Their client can speak NetherNet |
| mc-monitor's metrics | The sidecar scrapes over RakNet, so `minecraft_status_healthy` goes stale and the `Jdwillmsen*` alerts that read it will fire | Same as above |

The NetherNet Service carries `publishNotReadyAddresses: true`, which is the
only reason players reach a pod that never becomes Ready. Do not remove that
line while the probes are in this state.

**Reverting** is `transport=raknet` in `server.properties` plus restoring the
probe values -- but understand what it buys: monitoring and the bots come
back, and players are locked out again. It is the right move only if NetherNet
turns out not to work on this network.

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
