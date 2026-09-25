#!/usr/bin/env bash
# Pins what the chart derives from global.actors.
#
# One list feeds three processes that never talk about it to each other: the
# agent's registry, each bot's own identity and the bridge's kick allowlist. A
# drift between them is silent -- a bot the agent does not know is one nobody
# can park, and a gamertag missing from the bridge's list is a park that never
# unloads its chunks. So the three are read back from the rendered objects and
# compared, rather than trusted to the helper that built them.
set -euo pipefail

here="$(cd "$(dirname "$0")/../.." && pwd)"
chart="$here/charts/minecraft-fwb"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

render() {
  helm template jdwillmsen-minecraft-fwb-prd "$chart" -n jdwillmsen-prd \
    -f "$chart/values.yaml" -f "$chart/values-prd.yaml" \
    -f "$chart/values-console-bridge.yaml" "$@"
}

# Renders with an override file and expects the render to fail naming $2.
expect_refused() {
  local label="$1" needle="$2" overrides="$3" out
  printf '%s\n' "$overrides" > "$work/override.yaml"
  if out="$(render -f "$work/override.yaml" 2>&1)"; then
    fail "$label: the render succeeded"
  fi
  grep -qF -- "$needle" <<<"$out" || fail "$label: refused, but not for the right reason: $out"
  echo "  ok: refuses $label"
}

# The shipped bots, for the gamertag cases below that only vary the agent's.
bots='
    - {id: afk-bot-1, kind: afk-bot, valuesKey: bot, gamertag: LightBlaz3, defaultState: present, groups: [bots]}
    - {id: afk-bot-2, kind: afk-bot, valuesKey: bot2, gamertag: Dotablaze7321, defaultState: present, groups: [bots]}'

# Refuses the agent's gamertag $2 (a YAML scalar) for the reason every unsafe
# gamertag shares.
expect_gamertag_refused() {
  expect_refused "$1" "gamertag must be set, with no comma" "
global:
  actors:
    - {id: agent, kind: agent, gamertag: $2, defaultState: present, groups: []}$bots"
}

# --- the shipped list renders ---------------------------------------------
render > "$work/default.yaml" || fail "the chart does not render with its own values"
echo "  ok: the shipped actor list renders"

# --- names the bots' token caches and Deployments are filed under ----------
# The Deployment and PVC names are what ArgoCD, the token caches and the
# README's kubectl lines all key on. Renaming one orphans a signed-in cache.
python3 - "$work/default.yaml" <<'PY'
import sys, yaml
names = {(d["kind"], d["metadata"]["name"]) for d in yaml.safe_load_all(open(sys.argv[1])) if d}
for want in [
    ("Deployment", "jdwillmsen-minecraft-fwb-prd-afk-bot"),
    ("Deployment", "jdwillmsen-minecraft-fwb-prd-afk-bot-2"),
    ("Deployment", "jdwillmsen-minecraft-fwb-prd-server-agent"),
    ("PersistentVolumeClaim", "jdwillmsen-minecraft-fwb-prd-afk-bot"),
    ("PersistentVolumeClaim", "jdwillmsen-minecraft-fwb-prd-afk-bot-2"),
]:
    assert want in names, f"{want} is no longer rendered; renaming it orphans live state"
PY
echo "  ok: Deployment and PVC names are unchanged"

# --- a gamertag may contain a plain space ----------------------------------
# The agent quotes it when it kicks, and both it and the bridge accept it, so
# the chart must not be stricter than the processes it feeds.
printf '%s\n' "
global:
  actors:
    - {id: agent, kind: agent, gamertag: \"JDW Server Agent\", defaultState: present, groups: []}$bots" > "$work/override.yaml"
render -f "$work/override.yaml" > /dev/null || fail "a gamertag with an inner space is refused"
echo "  ok: accepts a gamertag with an inner space"

# --- validation -------------------------------------------------------------
expect_refused "a malformed id" "must match" '
global:
  actors:
    - {id: Agent, kind: agent, gamertag: JDWServerAgent, defaultState: present, groups: []}
    - {id: afk-bot-1, kind: afk-bot, valuesKey: bot, gamertag: LightBlaz3, defaultState: present, groups: [bots]}
    - {id: afk-bot-2, kind: afk-bot, valuesKey: bot2, gamertag: Dotablaze7321, defaultState: present, groups: [bots]}'

expect_refused "the id all" "names every actor and cannot be one" '
global:
  actors:
    - {id: all, kind: agent, gamertag: JDWServerAgent, defaultState: present, groups: []}
    - {id: afk-bot-1, kind: afk-bot, valuesKey: bot, gamertag: LightBlaz3, defaultState: present, groups: [bots]}
    - {id: afk-bot-2, kind: afk-bot, valuesKey: bot2, gamertag: Dotablaze7321, defaultState: present, groups: [bots]}'

expect_refused "a duplicate id" "is listed twice" '
global:
  actors:
    - {id: agent, kind: agent, gamertag: JDWServerAgent, defaultState: present, groups: []}
    - {id: afk-bot-1, kind: afk-bot, valuesKey: bot, gamertag: LightBlaz3, defaultState: present, groups: [bots]}
    - {id: afk-bot-1, kind: afk-bot, valuesKey: bot2, gamertag: Dotablaze7321, defaultState: present, groups: [bots]}'

expect_gamertag_refused "a gamertag with a comma" '"JDW,ServerAgent"'
expect_gamertag_refused "a gamertag with a quote" '"JDW\"Agent"'
expect_gamertag_refused "a gamertag with a backslash" '"JDW\\Agent"'
expect_gamertag_refused "a gamertag with a leading @" '"@JDWServerAgent"'
expect_gamertag_refused "a padded gamertag" '" JDWServerAgent"'
expect_gamertag_refused "a gamertag with a control character" '"JDW\aAgent"'
expect_gamertag_refused "a gamertag with a zero-width space" '"JDW​Agent"'
expect_gamertag_refused "a gamertag with a bidi override" '"JDW‮Agent"'
expect_gamertag_refused "a gamertag with a no-break space" '"JDW Agent"'
expect_gamertag_refused "a gamertag with an ideographic space" '"JDW　Agent"'
expect_gamertag_refused "an empty gamertag" '""'

expect_refused "a gamertag shared by two actors" "belongs to another actor" '
global:
  actors:
    - {id: agent, kind: agent, gamertag: JDWServerAgent, defaultState: present, groups: []}
    - {id: afk-bot-1, kind: afk-bot, valuesKey: bot, gamertag: LightBlaz3, defaultState: present, groups: [bots]}
    - {id: afk-bot-2, kind: afk-bot, valuesKey: bot2, gamertag: lightblaz3, defaultState: present, groups: [bots]}'

expect_refused "an unknown default state" "must be present or parked" '
global:
  actors:
    - {id: agent, kind: agent, gamertag: JDWServerAgent, defaultState: away, groups: []}
    - {id: afk-bot-1, kind: afk-bot, valuesKey: bot, gamertag: LightBlaz3, defaultState: present, groups: [bots]}
    - {id: afk-bot-2, kind: afk-bot, valuesKey: bot2, gamertag: Dotablaze7321, defaultState: present, groups: [bots]}'

expect_refused "the implicit group listed" "which every actor is already in" '
global:
  actors:
    - {id: agent, kind: agent, gamertag: JDWServerAgent, defaultState: present, groups: [all]}
    - {id: afk-bot-1, kind: afk-bot, valuesKey: bot, gamertag: LightBlaz3, defaultState: present, groups: [bots]}
    - {id: afk-bot-2, kind: afk-bot, valuesKey: bot2, gamertag: Dotablaze7321, defaultState: present, groups: [bots]}'

expect_refused "a group named like an actor" "is also an actor id" '
global:
  actors:
    - {id: agent, kind: agent, gamertag: JDWServerAgent, defaultState: present, groups: []}
    - {id: afk-bot-1, kind: afk-bot, valuesKey: bot, gamertag: LightBlaz3, defaultState: present, groups: [agent]}
    - {id: afk-bot-2, kind: afk-bot, valuesKey: bot2, gamertag: Dotablaze7321, defaultState: present, groups: [bots]}'

# The agent checks groups once every id is known, so a group naming an actor
# listed after it is as ambiguous as one naming an actor listed before.
expect_refused "a group named like a later actor" "is also an actor id" '
global:
  actors:
    - {id: agent, kind: agent, gamertag: JDWServerAgent, defaultState: present, groups: []}
    - {id: afk-bot-1, kind: afk-bot, valuesKey: bot, gamertag: LightBlaz3, defaultState: present, groups: [afk-bot-2]}
    - {id: afk-bot-2, kind: afk-bot, valuesKey: bot2, gamertag: Dotablaze7321, defaultState: present, groups: [bots]}'

expect_refused "no agent" "exactly one actor of kind agent" '
global:
  actors:
    - {id: afk-bot-1, kind: afk-bot, valuesKey: bot, gamertag: LightBlaz3, defaultState: present, groups: [bots]}
    - {id: afk-bot-2, kind: afk-bot, valuesKey: bot2, gamertag: Dotablaze7321, defaultState: present, groups: [bots]}'

expect_refused "a bot naming no values block" "valuesKey must be one of" '
global:
  actors:
    - {id: agent, kind: agent, gamertag: JDWServerAgent, defaultState: present, groups: []}
    - {id: afk-bot-1, kind: afk-bot, valuesKey: bot3, gamertag: LightBlaz3, defaultState: present, groups: [bots]}
    - {id: afk-bot-2, kind: afk-bot, valuesKey: bot2, gamertag: Dotablaze7321, defaultState: present, groups: [bots]}'

expect_refused "two actors on one bot" "is already another actor" '
global:
  actors:
    - {id: agent, kind: agent, gamertag: JDWServerAgent, defaultState: present, groups: []}
    - {id: afk-bot-1, kind: afk-bot, valuesKey: bot, gamertag: LightBlaz3, defaultState: present, groups: [bots]}
    - {id: afk-bot-2, kind: afk-bot, valuesKey: bot, gamertag: Dotablaze7321, defaultState: present, groups: [bots]}'

expect_refused "an enabled bot nobody registered" "bot2.enabled is true but no global.actors entry" '
global:
  actors:
    - {id: agent, kind: agent, gamertag: JDWServerAgent, defaultState: present, groups: []}
    - {id: afk-bot-1, kind: afk-bot, valuesKey: bot, gamertag: LightBlaz3, defaultState: present, groups: [bots]}'

# The operator token shares PRESENCE_TOKENS with the bots' tokens, which are
# named after their actors, and names its own Secret key the same way.
expect_refused "an operator token named after an actor" "operatorToken.name \"afk-bot-1\" is also an actor id" '
global:
  presence:
    operatorToken:
      name: afk-bot-1'

# The bots' PRESENCE_URL is the agent's metrics Service, which renders only
# with the agent.
expect_refused "presence without the agent" "global.presence.enabled needs agent.enabled" '
global:
  presence:
    enabled: true
agent:
  enabled: false'

expect_refused "an operator token name that is not an id" "operatorToken.name \"Tools_MC\" must match" '
global:
  presence:
    operatorToken:
      name: Tools_MC'

# --- the presence secret -----------------------------------------------------
# ESO renders target.template with the Vault properties as `.<key>`. Doing the
# same substitution here proves the three things that matter: the agent's JSON
# parses, every bot's own key holds exactly the token the agent binds to it,
# and the operator token cannot report as a bot.
python3 - "$work/default.yaml" <<'PY'
import json, re, sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
es = next((d for d in docs if d["kind"] == "ExternalSecret"
           and d["metadata"]["name"] == "jdwillmsen-minecraft-fwb-prd-presence"), None)
assert es, "the presence ExternalSecret is not rendered while presence is off; it must sync before anything reads it"
props = {r["secretKey"]: r["remoteRef"] for r in es["spec"]["data"]}
assert set(props) == {"presence_token_afk_bot_1", "presence_token_afk_bot_2", "presence_token_tools_mc"}, sorted(props)
for key, ref in props.items():
    assert ref["key"] == "minecraft-fwb" and ref["property"] == key, (key, ref)
fake = {k: "tok-" + k for k in props}
rendered = {k: re.sub(r"\{\{ \.(\w+) \}\}", lambda m: fake[m.group(1)], v)
            for k, v in es["spec"]["target"]["template"]["data"].items()}
tokens = {t["name"]: t for t in json.loads(rendered["presence_tokens"])}
assert set(tokens) == {"afk-bot-1", "afk-bot-2", "tools-mc"}, sorted(tokens)
for bot in ("afk-bot-1", "afk-bot-2"):
    key = "presence_token_" + bot.replace("-", "_")
    assert rendered[key] == tokens[bot]["token"], f"{bot}'s own key and the agent's list disagree"
    assert tokens[bot]["actor"] == bot and sorted(tokens[bot]["scopes"]) == ["presence:read", "presence:report"], tokens[bot]
assert "actor" not in tokens["tools-mc"] and sorted(tokens["tools-mc"]["scopes"]) == ["presence:read", "presence:write"], tokens["tools-mc"]
PY
echo "  ok: the presence secret binds each bot's token to its own actor"

# --- consumers, off and on ---------------------------------------------------
# Off must read exactly as before this feature: no variable a bot or the agent
# would act on, and no kick allowlist. Both states are set explicitly, so the
# suite means the same whichever one values.yaml ships.
render --set global.presence.enabled=false > "$work/presence-off.yaml"
python3 - "$work/presence-off.yaml" <<'PY'
import sys, yaml
for d in yaml.safe_load_all(open(sys.argv[1])):
    if not d or d["kind"] not in ("Deployment", "StatefulSet"):
        continue
    for c in d["spec"]["template"]["spec"]["containers"]:
        names = {e["name"] for e in c.get("env") or []}
        stray = {n for n in names if n.startswith("PRESENCE_") or n == "BRIDGE_KICKABLE"}
        assert not stray, f"{d['metadata']['name']}/{c['name']} carries {sorted(stray)} while presence is off"
PY
echo "  ok: presence off renders no consumer"

render --set global.presence.enabled=true > "$work/on.yaml" || fail "the chart does not render with presence on"
python3 - "$work/on.yaml" <<'PY'
import json, sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
def workload(kind, name):
    return next(d for d in docs if d["kind"] == kind and d["metadata"]["name"] == name)
def env_of(kind, name, container):
    c = next(c for c in workload(kind, name)["spec"]["template"]["spec"]["containers"] if c["name"] == container)
    return {e["name"]: e for e in c.get("env") or []}

agent = env_of("Deployment", "jdwillmsen-minecraft-fwb-prd-server-agent", "agent")
actors = json.loads(agent["PRESENCE_ACTORS"]["value"])
assert actors == [
    {"id": "agent", "gamertag": "JDWServerAgent", "kind": "agent", "groups": [], "default_state": "present"},
    {"id": "afk-bot-1", "gamertag": "LightBlaz3", "kind": "afk-bot", "groups": ["bots"], "default_state": "present"},
    {"id": "afk-bot-2", "gamertag": "Dotablaze7321", "kind": "afk-bot", "groups": ["bots"], "default_state": "present"},
], actors
assert agent["PRESENCE_SELF_ID"]["value"] == "agent"
ref = agent["PRESENCE_TOKENS"]["valueFrom"]["secretKeyRef"]
assert ref == {"name": "jdwillmsen-minecraft-fwb-prd-presence", "key": "presence_tokens"}, ref

# The agent's worst-case clean shutdown takes about 22s. Unset means the
# default 30s, which covers it; a shorter one would SIGKILL it partway.
grace = workload("Deployment", "jdwillmsen-minecraft-fwb-prd-server-agent")["spec"]["template"]["spec"].get(
    "terminationGracePeriodSeconds", 30)
assert grace >= 25, f"the agent gets {grace}s to stop; it needs at least 25"

# The ready-only metrics Service, on purpose: a parked leader and a standby
# both report ready, and the only not-ready pod is one still starting, which
# answers /v1 with a bare 404 until its routes mount.
url = "http://jdwillmsen-minecraft-fwb-prd-server-agent-metrics.jdwillmsen-prd.svc.cluster.local:9090"
svc = workload("Service", "jdwillmsen-minecraft-fwb-prd-server-agent-metrics")
assert svc["spec"]["ports"][0]["port"] == 9090, svc["spec"]["ports"]
for d in docs:
    if d["kind"] == "Service" and d["spec"].get("selector") == {"app": "jdwillmsen-minecraft-fwb-prd-server-agent"}:
        assert not d["spec"].get("publishNotReadyAddresses"), f"{d['metadata']['name']} routes to agent pods that cannot answer yet"
for name, container, actor in (("jdwillmsen-minecraft-fwb-prd-afk-bot", "bot", "afk-bot-1"),
                               ("jdwillmsen-minecraft-fwb-prd-afk-bot-2", "bot2", "afk-bot-2")):
    env = env_of("Deployment", name, container)
    assert env["PRESENCE_URL"]["value"] == url, env["PRESENCE_URL"]
    assert env["PRESENCE_ACTOR_ID"]["value"] == actor
    assert env["PRESENCE_DEFAULT"]["value"] == "present"
    assert "PRESENCE_POLL_MS" not in env, "the bot's own default poll interval applies"
    ref = env["PRESENCE_TOKEN"]["valueFrom"]["secretKeyRef"]
    assert ref == {"name": "jdwillmsen-minecraft-fwb-prd-presence",
                   "key": "presence_token_" + actor.replace("-", "_")}, ref
PY
echo "  ok: presence on wires the agent and both bots to the agent's metrics Service"

# --- the deploy-announce digests ----------------------------------------------
# global.* is merged into the subchart's values, so the server digest would
# see every edit to global.actors and global.presence. Only the rendered kick
# list can reach the StatefulSet: a default flipped here restarts a bot, not
# the server, and must not buy players a restart countdown.
digests() {
  python3 -c '
import sys, yaml
for d in yaml.safe_load_all(open(sys.argv[1])):
    if d and d["kind"] == "ConfigMap" and d["metadata"]["name"].endswith("-server-spec-hash"):
        print(d["data"]["hash"], d["data"]["agentHash"])
' "$1"
}
cat > "$work/flip.yaml" <<'YAML'
global:
  actors:
    - {id: agent, kind: agent, gamertag: JDWServerAgent, defaultState: present, groups: []}
    - {id: afk-bot-1, kind: afk-bot, valuesKey: bot, gamertag: LightBlaz3, defaultState: parked, groups: [bots, night]}
    - {id: afk-bot-2, kind: afk-bot, valuesKey: bot2, gamertag: Dotablaze7321, defaultState: present, groups: [bots]}
  presence:
    secret:
      create: false
    operatorToken:
      name: tools-mc-2
YAML
cat > "$work/rename.yaml" <<'YAML'
global:
  actors:
    - {id: agent, kind: agent, gamertag: JDWServerAgent, defaultState: present, groups: []}
    - {id: afk-bot-1, kind: afk-bot, valuesKey: bot, gamertag: LightBlaz4, defaultState: present, groups: [bots]}
    - {id: afk-bot-2, kind: afk-bot, valuesKey: bot2, gamertag: Dotablaze7321, defaultState: present, groups: [bots]}
YAML
render -f "$work/flip.yaml" --set global.presence.enabled=false > "$work/flip-off.yaml"
render -f "$work/flip.yaml" --set global.presence.enabled=true > "$work/flip-on.yaml"
render -f "$work/rename.yaml" --set global.presence.enabled=false > "$work/rename-off.yaml"
render -f "$work/rename.yaml" --set global.presence.enabled=true > "$work/rename-on.yaml"
render --set global.presence.enabled=false --set minecraft-bedrock.image.tag=0.0.0 > "$work/server-change.yaml"
render --set global.presence.enabled=false --set global.consoleBridge.secret.name=elsewhere > "$work/global-change.yaml"
read -r off_server off_agent < <(digests "$work/presence-off.yaml")
read -r on_server on_agent < <(digests "$work/on.yaml")
read -r flip_off_server flip_off_agent < <(digests "$work/flip-off.yaml")
read -r flip_on_server flip_on_agent < <(digests "$work/flip-on.yaml")
read -r rename_off_server _ < <(digests "$work/rename-off.yaml")
read -r rename_on_server _ < <(digests "$work/rename-on.yaml")
read -r changed_server _ < <(digests "$work/server-change.yaml")
read -r global_server _ < <(digests "$work/global-change.yaml")
[ "$off_server" = "$flip_off_server" ] || fail "an actor or presence edit moved the server digest while presence is off"
[ "$off_server" = "$rename_off_server" ] || fail "a gamertag moved the server digest while presence is off, when no kick list renders"
[ "$on_server" = "$flip_on_server" ] || fail "an actor or presence edit moved the server digest though the kick list is unchanged"
[ "$on_server" != "$rename_on_server" ] || fail "a renamed gamertag changes the bridge's kick list, so it must move the server digest"
[ "$off_server" != "$changed_server" ] || fail "a server image change must move the server digest"
[ "$off_server" != "$global_server" ] || fail "global keys outside actors and presence still reach the server"
[ "$off_agent" = "$flip_off_agent" ] || fail "an actor edit moved the agent digest while presence is off"
[ "$on_agent" != "$flip_on_agent" ] || fail "a changed actor list must move the agent digest: the agent restarts for it"
[ "$off_agent" != "$on_agent" ] || fail "turning presence on must move the agent digest"
echo "  ok: only what reaches a workload moves its digest"

# --- the bridge's kick list ---------------------------------------------------
# Read from the rendered sidecar, and from a render with a gamertag renamed, so
# the list is shown to follow global.actors rather than merely to match today.
python3 - "$work/on.yaml" "$work/rename-on.yaml" <<'PY'
import sys, yaml
def kickable(path):
    docs = [d for d in yaml.safe_load_all(open(path)) if d]
    sts = next(d for d in docs if d["kind"] == "StatefulSet")
    bridge = next(c for c in sts["spec"]["template"]["spec"]["containers"] if c["name"] == "console-bridge")
    env = {e["name"]: e for e in bridge["env"]}
    return env["BRIDGE_KICKABLE"]["value"]
got = kickable(sys.argv[1])
assert got == "JDWServerAgent,LightBlaz3,Dotablaze7321", got
got = kickable(sys.argv[2])
assert got == "JDWServerAgent,LightBlaz4,Dotablaze7321", got
PY
echo "  ok: the bridge may kick every actor and nobody else"

echo "PASS"
