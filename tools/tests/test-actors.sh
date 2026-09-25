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

echo "PASS"
