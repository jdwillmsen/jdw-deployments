#!/usr/bin/env bash
# Exercises the hold-wedge watchdog's decisions against staged states. The
# script is extracted from the chart as production renders it, so the test
# cannot drift from what runs, and kubectl is a shim that records a kill
# instead of delivering it. Every condition is checked on its own: the one
# action this job has is killing the game server, so each gate has to be shown
# to hold it back.
set -euo pipefail

here="$(cd "$(dirname "$0")/../.." && pwd)"
chart="$here/charts/minecraft-fwb"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

render() {
  helm template minecraft-fwb "$chart" --namespace jdwillmsen-prd \
    -f "$chart/values.yaml" -f "$chart/values-prd.yaml" "$@"
}

render -f "$chart/values-console-bridge.yaml" -f "$chart/values-map-pack.yaml" > "$work/rendered.yaml"
python3 - "$work/rendered.yaml" "$work/watchdog.sh" <<'PY' || fail "the rendered watchdog is not wired to the server"
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
name = "minecraft-fwb-hold-wedge-watchdog"
cj = next(d for d in docs if d["kind"] == "CronJob" and d["metadata"]["name"] == name)
spec = cj["spec"]["jobTemplate"]["spec"]["template"]["spec"]
c = spec["containers"][0]
env = {e["name"]: e["value"] for e in c["env"]}
pod = "minecraft-fwb-minecraft-bedrock-0"
assert env["SERVER_POD"] == pod, env
assert env["SERVER_CONTAINER"] == "minecraft-fwb-minecraft-bedrock", env
sts = next(d for d in docs if d["kind"] == "StatefulSet" and d["metadata"]["name"] == env["SERVER_CONTAINER"])
server = next(x for x in sts["spec"]["template"]["spec"]["containers"] if x["name"] == env["SERVER_CONTAINER"])
# The same address the server's own readiness probe pings.
assert env["SERVER_PORT"] in server["readinessProbe"]["exec"]["command"], (env, server["readinessProbe"])
bridge = next(x for x in sts["spec"]["template"]["spec"]["containers"] if x["name"] == "console-bridge")
assert int(env["BRIDGE_PORT"]) in [p["containerPort"] for p in bridge["ports"]], (env, bridge["ports"])
assert int(env["WEDGE_SECONDS"]) >= 600, env
assert int(env["BACKOFF_SECONDS"]) >= 3600, env
# Never acts on a pod it may not name, and never deletes one.
role = next(d for d in docs if d["kind"] == "Role" and d["metadata"]["name"] == name)
assert sorted((tuple(r["resources"]), tuple(r["verbs"]), tuple(r["resourceNames"])) for r in role["rules"]) == \
    [(("pods",), ("get",), (pod,)), (("pods/exec",), ("create",), (pod,))], role
assert spec["serviceAccountName"] == name
assert cj["spec"]["concurrencyPolicy"] == "Forbid"
open(sys.argv[2], "w").write(c["args"][0])
PY
echo "  ok: wired to the server, its probe port and the bridge, with get and exec only"

# Without the bridge there is no gauge to read, so nothing renders.
if render | grep -q "hold-wedge-watchdog"; then
  fail "the watchdog renders without the console bridge"
fi
echo "  ok: absent without the console bridge"

mkdir -p "$work/bin" "$work/state"
echo -n "test-ns" > "$work/ns"
sed -i "s|/var/run/secrets/kubernetes.io/serviceaccount/namespace|$work/ns|" "$work/watchdog.sh"
cat > "$work/bin/kubectl" <<'SHIM'
#!/usr/bin/env bash
if [[ "$1" == "get" ]]; then
  if [[ "${*: -1}" == json ]]; then
    [[ "${FAKE_POD:-yes}" == "no" ]] && exit 1
    python3 - <<'PY'
import datetime, json, os
since = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=int(os.environ.get("FAKE_NOT_READY_FOR", "3600")))
ready = os.environ.get("FAKE_READY", "false") == "true"
state = {"running": {"startedAt": "2020-01-01T00:00:00Z"}} if os.environ.get("FAKE_RUNNING", "yes") == "yes" else {"waiting": {}}
last = {}
if os.environ.get("FAKE_LAST_EXIT"):
    ended = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=int(os.environ.get("FAKE_LAST_EXIT_AGO", "600")))
    last = {"terminated": {"exitCode": int(os.environ["FAKE_LAST_EXIT"]), "finishedAt": ended.strftime("%Y-%m-%dT%H:%M:%SZ")}}
print(json.dumps({"status": {
    "containerStatuses": [{"name": "server", "ready": ready, "started": os.environ.get("FAKE_STARTED", "true") == "true", "state": state, "lastState": last}],
    "conditions": [{"type": "Ready", "status": "True" if ready else "False", "lastTransitionTime": since.strftime("%Y-%m-%dT%H:%M:%SZ")}],
}}))
PY
    exit 0
  fi
  # The restart count: unchanged until a kill has been recorded.
  if [[ -f "$STATE_DIR/killed" && "${FAKE_RESTARTS:-yes}" == "yes" ]]; then
    printf '%s 8' "${FAKE_NEW_UID:-uid-1}"
  else
    printf 'uid-1 7'
  fi
  exit 0
fi
if [[ "$1" == "exec" ]]; then
  if [[ "$*" == *"/metrics"* ]]; then
    [[ "${FAKE_OWED:-1}" == "unreadable" ]] && exit 7
    printf '# HELP mc_console_bridge_snapshot_resume_owed x\nmc_console_bridge_snapshot_resume_owed %s\n' "${FAKE_OWED:-1}"
    exit 0
  fi
  if [[ "$*" == *"mc-monitor"* ]]; then
    [[ "${FAKE_PING:-fail}" == "noexec" ]] && exit 1
    echo pings >> "$STATE_DIR/calls"
    n="$(grep -c pings "$STATE_DIR/calls")"
    if [[ "${FAKE_PING:-fail}" == "ok" || ( "${FAKE_PING:-fail}" == "third" && "$n" -ge 3 ) ]]; then echo ping=0; else echo ping=1; fi
    exit 0
  fi
  if [[ "$*" == *"/proc/[0-9]"* ]]; then
    [[ "${FAKE_PROC:-yes}" == "no" ]] && { echo none; exit 0; }
    echo __KILL_CALLED__ >> "$STATE_DIR/calls"; touch "$STATE_DIR/killed"
    # The exec dies with the container it signalled.
    exit 137
  fi
fi
exit 0
SHIM
chmod +x "$work/bin/kubectl"
# Ping retries and the restart poll sleep; nothing here needs real time.
printf '#!/bin/sh\nexit 0\n' > "$work/bin/sleep"
chmod +x "$work/bin/sleep"

run() {
  rm -rf "$work/state"; mkdir -p "$work/state"
  local out
  out="$(env PATH="$work/bin:$PATH" STATE_DIR="$work/state" SERVER_POD=server-0 SERVER_CONTAINER=server \
      SERVER_PORT=31132 BRIDGE_PORT=8766 WEDGE_SECONDS=900 BACKOFF_SECONDS=21600 "$@" bash "$work/watchdog.sh" 2>&1)" || out="$out (exit $?)"
  printf '%s\n%s' "$out" "$(cat "$work/state/calls" 2>/dev/null || true)"
}
has() { local name="$1" needle="$2"; shift 2; local o; o="$(run "$@")"; [[ "$o" == *"$needle"* ]] || fail "$name: wanted '$needle' in: $o"; echo "  ok: $name"; }
lacks() { local name="$1" needle="$2"; shift 2; local o; o="$(run "$@")"; [[ "$o" != *"$needle"* ]] || fail "$name: '$needle' appeared in: $o"; echo "  ok: $name"; }

has   "the 2026-11-18 wedge is killed" __KILL_CALLED__
has   "a kill is confirmed by the restart count" '"event":"killed"'
lacks "a killed server is not a failed run" '(exit'

lacks "a ready server is left alone" __KILL_CALLED__ FAKE_READY=true
lacks "a server not ready for under wedgeSeconds is left alone" __KILL_CALLED__ FAKE_NOT_READY_FOR=600
lacks "a server still booting is the startup probe's" __KILL_CALLED__ FAKE_STARTED=false
lacks "a stopped container is left alone" __KILL_CALLED__ FAKE_RUNNING=no
lacks "an absent pod is left alone" __KILL_CALLED__ FAKE_POD=no
lacks "an outage with no resume owed is not a hold wedge" __KILL_CALLED__ FAKE_OWED=0
has   "an outage with no resume owed is reported" '"event":"not_held"' FAKE_OWED=0
lacks "an unreadable gauge is not guessed at" __KILL_CALLED__ FAKE_OWED=unreadable
has   "an unreadable gauge is reported" '"event":"unverified"' FAKE_OWED=unreadable
lacks "a server answering a ping is left alone" __KILL_CALLED__ FAKE_PING=ok
lacks "one answered ping of three holds the kill" __KILL_CALLED__ FAKE_PING=third
lacks "a ping that could not run is not a failed ping" __KILL_CALLED__ FAKE_PING=noexec
lacks "a second wedge soon after a kill is left for a person" __KILL_CALLED__ FAKE_LAST_EXIT=137
has   "a second wedge soon after a kill is reported" '"event":"backoff"' FAKE_LAST_EXIT=137
lacks "a wedge soon after a crash is left for a person" __KILL_CALLED__ FAKE_LAST_EXIT=255
has   "a kill older than the backoff does not hold the next" __KILL_CALLED__ FAKE_LAST_EXIT=137 FAKE_LAST_EXIT_AGO=30000
has   "a clean previous exit does not hold the kill" __KILL_CALLED__ FAKE_LAST_EXIT=0
has   "no server process fails loudly" '"event":"failed"' FAKE_PROC=no
has   "a kill that restarts nothing fails loudly" '"event":"failed"' FAKE_RESTARTS=no
has   "a recreated pod fails loudly" 'not restarted in place' FAKE_NEW_UID=uid-2
# A value bash cannot compare must hold the kill back, not pass the gate it
# guards.
lacks "a non-integer wedgeSeconds does not kill" __KILL_CALLED__ WEDGE_SECONDS=15m
lacks "a non-integer backoffSeconds does not kill" __KILL_CALLED__ BACKOFF_SECONDS=6h
lacks "an empty wedgeSeconds does not kill" __KILL_CALLED__ WEDGE_SECONDS=
lacks "a non-integer backoffSeconds does not kill after a crash" __KILL_CALLED__ BACKOFF_SECONDS=6h FAKE_LAST_EXIT=137

# The chart refuses such values before they reach the job.
for bad in 'wedgeSeconds=15m' 'backoffSeconds=6h' 'wedgeSeconds=60' 'backoffSeconds=60'; do
  if render -f "$chart/values-console-bridge.yaml" -f "$chart/values-map-pack.yaml" --set "holdWedgeWatchdog.$bad" >/dev/null 2>&1; then
    fail "the chart rendered with holdWedgeWatchdog.$bad"
  fi
  echo "  ok: the chart refuses holdWedgeWatchdog.$bad"
done
echo PASS
