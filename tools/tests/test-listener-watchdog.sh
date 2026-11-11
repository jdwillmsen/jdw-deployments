#!/usr/bin/env bash
# Exercises the NetherNet listener watchdog's decisions against staged states,
# for every chart that ships it. The script is extracted from the rendered chart,
# so the test cannot drift from what runs, and kubectl is a shim that records a
# stop instead of delivering it.
set -euo pipefail

here="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

mkdir -p "$work/bin" "$work/state"
echo -n "test-ns" > "$work/ns"
cat > "$work/bin/kubectl" <<'SHIM'
#!/usr/bin/env bash
if [[ "$1" == "get" ]]; then
  printf '%s' "${FAKE_STARTED-2020-01-01T00:00:00Z}"; exit 0
fi
if [[ "$1" == "exec" ]]; then
  if [[ "$*" == *"send-command stop"* ]]; then
    echo __STOP_CALLED__ >> "$STATE_DIR/calls"; [[ "${FAKE_STOP_OK:-yes}" == "no" ]] && exit 2; exit 0
  fi
  if [[ "$*" == *"/proc/net/tcp6"* ]]; then
    [[ "${FAKE_LISTEN:-yes}" == "unreadable" ]] && exit 1
    echo "  sl  local_address rem_address st"
    [[ "${FAKE_LISTEN:-yes}" == "yes" ]] && echo "   0: 00000000000000000000000000000000:799C 00000000000000000000000000000000:0000 0A"
    [[ "${FAKE_TIME_WAIT:-no}" == "yes" ]] && echo "   1: 0000000000000000FFFF0000FA06F40A:799C 0000000000000000FFFF0000E307F40A:DD0A 06"
    exit 0
  fi
fi
exit 0
SHIM
chmod +x "$work/bin/kubectl"

for chart in minecraft-fwb crew-lab proving-grounds fwb-seed; do
  helm template x "$here/charts/$chart" -f "$here/charts/$chart/values.yaml" | python3 -c "
import sys, yaml
for d in yaml.safe_load_all(sys.stdin):
    if d and d.get('kind') == 'CronJob' and 'listener-watchdog' in d['metadata']['name']:
        print(d['spec']['jobTemplate']['spec']['template']['spec']['containers'][0]['args'][0])
" > "$work/$chart.sh"
  [ -s "$work/$chart.sh" ] || fail "$chart: could not extract the watchdog script"
  sed -i "s|/var/run/secrets/kubernetes.io/serviceaccount/namespace|$work/ns|" "$work/$chart.sh"

  run() {
    rm -rf "$work/state"; mkdir -p "$work/state"
    local out
    out="$(env PATH="$work/bin:$PATH" STATE_DIR="$work/state" SERVER_POD=server-0 SERVER_CONTAINER=server \
        SIGNAL_PORT=31132 MIN_AGE_SECONDS=360 "$@" bash "$work/$chart.sh" 2>&1)" || true
    printf '%s\n%s' "$out" "$(cat "$work/state/calls" 2>/dev/null || true)"
  }
  has() { local name="$1" needle="$2"; shift 2; local o; o="$(run "$@")"; [[ "$o" == *"$needle"* ]] || fail "$chart: $name: wanted '$needle' in: $o"; echo "  ok: $chart: $name"; }
  lacks() { local name="$1" needle="$2"; shift 2; local o; o="$(run "$@")"; [[ "$o" != *"$needle"* ]] || fail "$chart: $name: '$needle' appeared in: $o"; echo "  ok: $chart: $name"; }

  has   "a listening server is left alone" '"event":"ok"'
  lacks "a listening server is not stopped" __STOP_CALLED__
  has   "a missing listener is stopped" __STOP_CALLED__ FAKE_LISTEN=no
  has   "a missing listener is reported" '"event":"listener_missing"' FAKE_LISTEN=no
  lacks "a young container is not stopped" __STOP_CALLED__ FAKE_LISTEN=no FAKE_STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  lacks "TIME_WAIT sockets still holding the port defer the stop" __STOP_CALLED__ FAKE_LISTEN=no FAKE_TIME_WAIT=yes
  lacks "an unreadable socket table is not guessed at" __STOP_CALLED__ FAKE_LISTEN=unreadable
  has   "an unreadable socket table is reported" '"event":"unverified"' FAKE_LISTEN=unreadable
  lacks "a stopped container is skipped" __STOP_CALLED__ FAKE_LISTEN=no FAKE_STARTED=
  has   "an undelivered stop fails loudly" '"event":"failed"' FAKE_LISTEN=no FAKE_STOP_OK=no
done

# The two side servers are parameterised by release name and port; the shim
# above cannot see that, so check the rendered wiring against the real releases.
wiring() {
  local chart="$1" release="$2" port="$3"
  helm template "$release" "$here/charts/$chart" -f "$here/charts/$chart/values.yaml" -f "$here/charts/$chart/values-prd.yaml" | python3 -c "
import sys, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
name = '$release-listener-watchdog'
cj = next(d for d in docs if d['kind'] == 'CronJob' and d['metadata']['name'] == name)
env = {e['name']: e['value'] for e in cj['spec']['jobTemplate']['spec']['template']['spec']['containers'][0]['env']}
role = next(d for d in docs if d['kind'] == 'Role' and d['metadata']['name'] == name)
rb = next(d for d in docs if d['kind'] == 'RoleBinding' and d['metadata']['name'] == name)
pod = '$release-minecraft-bedrock-0'
assert env['SERVER_POD'] == pod, env
assert env['SERVER_CONTAINER'] == '$release-minecraft-bedrock', env
assert env['SIGNAL_PORT'] == '$port', env
assert cj['spec']['jobTemplate']['spec']['template']['spec']['serviceAccountName'] == name
assert sorted((tuple(r['resources']), tuple(r['verbs']), tuple(r['resourceNames'])) for r in role['rules']) == [(('pods',), ('get',), (pod,)), (('pods/exec',), ('create',), (pod,))], role
assert rb['subjects'][0]['name'] == name
sts = [d for d in docs if d['kind'] == 'StatefulSet']
assert any(d['metadata']['name'] == env['SERVER_CONTAINER'] for d in sts), [d['metadata']['name'] for d in sts]
" || fail "$chart: rendered watchdog is not wired to $release on port $port"
  echo "  ok: $chart: wired to $release, signaling port $port"
}
wiring proving-grounds jdwillmsen-proving-grounds-prd 31200
wiring fwb-seed jdwillmsen-fwb-seed-prd 31300
echo PASS
