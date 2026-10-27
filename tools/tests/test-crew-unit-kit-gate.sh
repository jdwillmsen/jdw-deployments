#!/usr/bin/env bash
# Exercises the unit-kit PreSync gate against staged server states. A kubectl
# shim answers from FAKE_* variables, so no case can reach the real lab. The
# script under test is the chart's own file, and the render check below proves
# the Job ships exactly that file.
set -euo pipefail

here="$(cd "$(dirname "$0")/../.." && pwd)"
chart="$here/charts/crew-lab"
gate="$chart/files/unit-kit-gate.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

helm template jdwillmsen-crew-lab-prd "$chart" --namespace jdwillmsen-prd \
  -f "$chart/values.yaml" -f "$chart/values-prd.yaml" > "$work/prd.yaml"
helm template jdwillmsen-crew-lab-prd "$chart" --namespace jdwillmsen-prd \
  -f "$chart/values.yaml" > "$work/base.yaml"
grep -q 'name: unit-kit-gate' "$work/base.yaml" && fail "the gate renders without the overlay enabling it"

python3 - "$work/prd.yaml" "$gate" "$chart/values.yaml" <<'PY' || fail "the gate is not rendered as expected"
import sys, yaml

docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
named = lambda kind: [d for d in docs if d.get("kind") == kind and d["metadata"]["name"] == "unit-kit-gate"]
(job,), (role,), (rb,), (sa,) = named("Job"), named("Role"), named("RoleBinding"), named("ServiceAccount")

for d in (job, role, rb, sa):
    assert d["metadata"]["annotations"]["argocd.argoproj.io/hook"] == "PreSync", d["kind"]
(rbac_wave,) = {d["metadata"]["annotations"]["argocd.argoproj.io/sync-wave"] for d in (role, rb, sa)}
assert rbac_wave == "-1"

server = "jdwillmsen-crew-lab-prd-minecraft-bedrock-0"
for rule in role["rules"]:
    assert rule["resourceNames"] == [server], rule
allowed = {(r, v) for rule in role["rules"] for r in rule["resources"] for v in rule["verbs"]}
assert allowed == {("pods", "get"), ("pods/exec", "create"), ("pods/log", "get")}, allowed

spec = job["spec"]
assert spec["backoffLimit"] == 0
pod = spec["template"]["spec"]
assert pod["serviceAccountName"] == "unit-kit-gate" and pod["securityContext"]["runAsNonRoot"] is True
(c,) = pod["containers"]
assert c["args"][0] == open(sys.argv[2]).read(), "the Job does not carry files/unit-kit-gate.sh"
env = {e["name"]: e["value"] for e in c["env"]}
assert env["SERVER_POD"] == f"jdwillmsen-prd/{server}"
assert spec["activeDeadlineSeconds"] > int(env["WAIT_S"])
assert c["securityContext"]["readOnlyRootFilesystem"] and c["securityContext"]["capabilities"]["drop"] == ["ALL"]

# The gate compares with the revision the server pod will be given.
rev = next(e["value"] for ic in yaml.safe_load(open(sys.argv[3]))["minecraft-bedrock"]["initContainers"]
           for e in ic.get("env", []) if e["name"] == "UNIT_KIT_REV")
assert env["WANT_REV"] == rev, (env["WANT_REV"], rev)
units = {"Agate", "Tinder", "Pebble"}
assert units <= set(env["NON_HUMAN"].split()) and "load-*" in env["NON_HUMAN"].split()
PY

mkdir -p "$work/bin"
cat > "$work/bin/kubectl" <<'SHIM'
#!/usr/bin/env bash
case "$1 $2 $3" in
  *"-n "*) shift 2 ;;
esac
case "$1" in
  get)
    if [[ ${FAKE_GET:-ok} == notfound ]]; then echo 'Error from server (NotFound): pods "x" not found' >&2; exit 1; fi
    if [[ ${FAKE_GET:-ok} == denied ]]; then echo 'Error from server (Forbidden): nope' >&2; exit 1; fi
    printf '%s' "${FAKE_REV:-old}"
    ;;
  exec)
    [[ ${FAKE_EXEC:-ok} == down ]] && exit 2
    echo "__LIST__" >> "$STATE_DIR/calls"
    ;;
  logs)
    if [[ "$*" == *"--since"* ]]; then
      [[ ${FAKE_LIST:-} == garbled ]] && { echo "nothing useful"; exit 0; }
      printf 'There are %s players online:\n%s\n' "${FAKE_COUNT:-0/20}" "${FAKE_PLAYERS:-}"
    else
      printf '%s\n' "${FAKE_CONNECTED:-}"
    fi
    ;;
esac
SHIM
chmod +x "$work/bin/kubectl"
mkdir -p "$work/state"

run() {
  : > "$work/state/calls"
  timeout 60 env PATH="$work/bin:$PATH" STATE_DIR="$work/state" SERVER_POD=ns/server-0 WANT_REV=new \
    NON_HUMAN="Agate Tinder load-*" WAIT_S=2 POLL_S=1 SETTLE_S=0 "$@" bash "$gate" 2>&1
}
expect() { # name, exit code, pattern, command...
  local name=$1 want=$2 pat=$3 out rc=0
  shift 3
  out="$(run "$@")" || rc=$?
  [[ $rc == "$want" ]] || fail "$name: exit $rc, want $want: $out"
  grep -q -- "$pat" <<<"$out" || fail "$name: no '$pat' in: $out"
  echo "ok: $name"
}

expect "same revision passes without asking" 0 "already running" FAKE_REV=new FAKE_PLAYERS=Jake FAKE_COUNT=1/20
grep -q __LIST__ "$work/state/calls" && fail "an unchanged revision still listed players"
expect "no pod yet passes" 0 "nothing to restart" FAKE_GET=notfound
expect "an unreadable pod fails" 1 "could not read" FAKE_GET=denied
expect "empty server passes" 0 "no human players" FAKE_COUNT=0/20
expect "only crew units and bots pass" 0 "no human players" FAKE_COUNT=3/20 FAKE_PLAYERS="Agate, Tinder, load-3"
expect "a signed-in player holds it" 1 "waiting for: Jake" FAKE_COUNT=2/20 FAKE_PLAYERS="Agate, Jake" \
  FAKE_CONNECTED="Player connected: Jake, xuid: 2535400000000000"
expect "a player with no connect line counts as human" 1 "waiting for: Mia" FAKE_COUNT=1/20 FAKE_PLAYERS=Mia
expect "an offline bot with an empty xuid does not" 0 "no human players" FAKE_COUNT=1/20 FAKE_PLAYERS=Probe \
  FAKE_CONNECTED="Player connected: Probe, xuid: "
expect "an unreadable list fails" 1 "could not read the player list" FAKE_LIST=garbled
expect "a server that is not up passes" 0 "not accepting commands" FAKE_EXEC=down

echo "PASS: crew unit-kit gate"
