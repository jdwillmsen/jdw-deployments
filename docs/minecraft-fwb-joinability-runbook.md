# Minecraft FWB — "nobody can join" runbook

For `JdwillmsenMinecraftUnjoinable`, and for the report that reaches you
before any alert does: *someone says they cannot get in.*

The distinction this runbook exists to make is **server down** versus **server
up but unjoinable**. They look identical from a player's chair and completely
different from the cluster, and on 2026-09-15 every check in this repo insisted
the server was healthy while nobody could join — the ping answered,
`mc-monitor` reported two players online, and all three kubelet probes were
green. The clients that were connected had joined before the fault and speak
RakNet themselves, so their presence argued the opposite of the truth.

## First question: what does the probe say

`<release>-join-probe` performs the pre-login handshake once a minute and
publishes how far it got.

```bash
kubectl logs -n <namespace> deploy/<release>-join-probe --tail=5
```

```json
{"event":"join_probe_ok","stage":"handshake","dialed_protocol":2193,"server_version":"1.26.51"}
{"event":"join_probe_failed","stage":"refused","play_status":2,"dialed_protocol":2250,"server_protocol":2193}
```

`mc_joinprobe_stage` is the same answer as a number, and it is the fastest
triage this server has:

| Stage | Means | Go to |
|---|---|---|
| `3` handshake | the server will start a session | [Joinable but a player still cannot get in](#joinable-but-a-player-still-cannot-get-in) |
| `2` refused | the server answered and said no | [Refused](#refused-the-server-said-no) |
| `1` pong | it answered the ping and then stopped | [Answers the ping, nothing after](#answers-the-ping-nothing-after) |
| `0` unreachable | nothing answered at all | [Unreachable](#unreachable-the-server-is-down) |

## Refused: the server said no

The server processed the handshake and rejected it. `mc_joinprobe_play_status`
carries its own reason:

| Status | Name | Meaning |
|---|---|---|
| `1` | `LoginFailedClient` | the client is older than the server |
| `2` | `LoginFailedServer` | **the server is older than the client** |
| `7` | `LoginFailedServerFull` | player cap reached |

**Status 2 is the 2026-09-15 outage.** Retail clients auto-update; the server
does not, except when the hourly `version-check` CronJob restarts it into a new
one. Check what each side is on:

```bash
kubectl logs -n <namespace> -l job-name --tail=20 | grep version-check
kubectl exec -n <namespace> <release>-minecraft-bedrock-0 -c <release>-minecraft-bedrock -- \
  sh -c 'cat /proc/[0-9]*/cmdline | tr "\0" "\n" | grep -m1 "^\./bedrock_server-"'
```

If the version check has been failing, fix that first — it is the mechanism
that keeps the server current, and restarting by hand only buys one cycle. Its
restart path is `send-command stop` over the server's own console; **never**
`kubectl rollout restart` or a pod delete, which migrates the world volume and
cost 11 `.ldb` files on 2026-08-30.

Status 7 with nobody visibly online usually means sessions the server still
believes are live. `playerIdleTimeout` is 0 here, so nothing times them out:

```bash
tools/mc run "kick <gamertag>"
```

## Answers the ping, nothing after

The RakNet listener is up and the server does not carry the handshake to a
verdict. Usually a server mid-restart, mid-save or too busy to service a join.

```bash
kubectl get pod -n <namespace> <release>-minecraft-bedrock-0
curl -s <prometheus>/api/v1/query?query=mc_agent_server_tps
```

Give it two minutes. The nightly restart at 09:40 UTC and the hourly version
check both produce this state briefly and legitimately, which is why the alert
waits ten. If it persists with a healthy pod and a normal tick rate, capture a
thread sample before restarting anything — a server that accepts connections
and will not finish a handshake is worth a ticket, not just a restart.

## Unreachable: the server is down

Nothing answered the ping. This is the ordinary outage, and the one every other
check in this repo already covers.

```bash
kubectl get pod -n <namespace> <release>-minecraft-bedrock-0 -o wide
kubectl describe pod -n <namespace> <release>-minecraft-bedrock-0 | tail -20
kubectl logs -n <namespace> <release>-minecraft-bedrock-0 -c <release>-minecraft-bedrock --tail=50
```

Look for a node problem, a volume that remounted read-only (the
`volume-recovery` CronJob handles that one automatically within five minutes),
or a crash loop. If the probe pod itself is what is unhealthy, the alert to
read is `JdwillmsenMinecraftJoinProbeMissing` instead.

## Joinable but a player still cannot get in

The probe reaches the handshake, so the server will start a session — for a
client inside the cluster. What is left is everything between a player and that
port, none of which the probe passes through:

* the NodePort, HAProxy and the nftables DNAT rules on the node
* the player's own client version, which the probe does not know
* that player's account, if the server holds a stale session for it (see the
  kick above)

Ask which version their client is on and compare against `server_version` in
the probe's log. A client *older* than the server is status `1` from their side
and tells them to update; there is nothing to fix here.

## What the alerts mean

| Alert | Condition | Read as |
|---|---|---|
| `JdwillmsenMinecraftUnjoinable` | no handshake for 10m | players cannot get in, whatever the pod says |
| `JdwillmsenMinecraftJoinProbeMissing` | no probe series for 15m | nothing is watching joinability |
| `JdwillmsenMinecraftAgentSessionStale` | no agent session reached spawn in 2.5 recycles | a real account cannot complete a join, or the recycle stopped |

The last one only exists while `agent.sessionRecycleMs` is non-zero. It is the
deeper check: the probe stops before authentication, so a failure that lives in
Xbox Live rather than in the server is invisible to it and visible here.

## Reproducing the failure on purpose

To check the alerting path end to end without waiting for an outage, run a
probe pinned to a protocol the server will refuse. It touches nothing:

```bash
kubectl run joinprobe-skew --rm -i --restart=Never -n <namespace> \
  --image=ghcr.io/jdwillmsen/minecraft-server-agent:<tag> \
  --command -- /joinprobe -interval 1h \
  -address <release>-join-probe-target.<namespace>.svc.cluster.local:31132 \
  -protocol 2250
```

Confirmed against production on 2026-09-19: `stage=refused`, `play_status=2`,
`server_protocol=2193` — the 09-15 conditions, reproduced in under a second.
