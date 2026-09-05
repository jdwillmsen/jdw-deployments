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
   for a `device_code_required` event and complete that login once — in a
   private/incognito browser window, or signed out of any account you don't
   want to accidentally authenticate instead. The token caches to a volume,
   so restarts are unattended afterwards.

The bot's XUID then goes on the server allowlist. It appears in the server log
on first connect.

**A device code can land on the wrong account.** The device-code page just
authenticates whatever Microsoft account is already active in the browser
that opens it — it does not prompt you to choose. If the wrong account ends
up signed in (confirm by checking which gamertag connects in the server log,
not by trusting what you intended to type): clear the cache and redo the
login —

```bash
kubectl exec -n jdwillmsen-prd <bot-pod> -- sh -c 'rm -rf /data/auth/*'
kubectl delete pod -n jdwillmsen-prd <bot-pod>
```

— then repeat step 2 above, this time actually in a fresh incognito window.

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

Unlike the bots, the console-bridge half of this feature is **not gated** —
`minecraft-bedrock.extraEnv` (which enables `WEBSOCKET_CONSOLE` on the server
itself) and the console-bridge sidecar in `minecraft-bedrock.sidecarContainers`
apply as soon as this chart change merges, regardless of `agent.enabled`.

**Merging this alone restarts the live server pod.** The extraEnv and
sidecarContainers changes go on the server's own StatefulSet, and Bedrock has
no live-reload for either — ArgoCD's `selfHeal: true` will roll the pod on
the next sync. Time the merge for low player activity, the same care any
`minecraft-bedrock` chart change already warrants (see the incidents in
`docs/incidents/`), and be aware of the open upstream crash-on-join defect
(`docs/incidents/2026-08-31-bedrock-crash-on-player-join.md`) before doing so.

Bootstrap, in order:

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
2. Merge this chart change. The server pod restarts (see above); confirm it
   comes back healthy (`tools/mc status`) before continuing.
3. Publish the image tag named in `agent.image.tag`, then set
   `agent.enabled: true` and merge/sync.
4. Read the agent pod's log for a `device_code_required` event and complete
   that login once, same caveats as the bots above — **a device code can
   land on the wrong account**; confirm the gamertag that actually connects
   in the server log, and if it's wrong, clear the cache
   (`kubectl exec -n jdwillmsen-prd <agent-pod> -- sh -c 'rm -rf /data/auth/*'`,
   `kubectl delete pod -n jdwillmsen-prd <agent-pod>`) and redo the login in
   a fresh incognito window.
5. Add the agent's gamertag to the server allowlist — it cannot join without
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
