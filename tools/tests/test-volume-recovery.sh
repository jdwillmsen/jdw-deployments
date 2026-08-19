#!/usr/bin/env bash
# Exercises the recovery CronJob's decision logic against staged pod states.
#
# The script under test ends in `kubectl delete pod`, so it is tested rather
# than reasoned about. The shim below forwards reads to the real kubectl and
# intercepts delete, which means these cases can run against a live cluster
# without being able to remove anything.
#
# The script is extracted from the rendered chart rather than copied here, so
# the test cannot drift away from what actually ships.
set -euo pipefail

here="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

helm template minecraft-fwb "$here/charts/minecraft-fwb" \
  -f "$here/charts/minecraft-fwb/values.yaml" \
  --set volumeRecovery.enabled=true \
  | python3 -c "
import sys, yaml
for doc in yaml.safe_load_all(sys.stdin):
    if doc and doc.get('kind') == 'CronJob' and 'volume-recovery' in doc['metadata']['name']:
        print(doc['spec']['jobTemplate']['spec']['template']['spec']['containers'][0]['args'][0])
" > "$work/recovery.sh"
[ -s "$work/recovery.sh" ] || fail "could not extract the recovery script from the chart"

mkdir -p "$work/sa"
echo -n "test-ns" > "$work/sa/namespace"
sed -i "s|/var/run/secrets/kubernetes.io/serviceaccount/namespace|$work/sa/namespace|" "$work/recovery.sh"

mkdir -p "$work/bin"
cat > "$work/bin/kubectl" <<'SHIM'
#!/usr/bin/env bash
if [[ "$1" == "delete" ]]; then echo "__DELETE_CALLED__"; exit 0; fi
if [[ "$1" == "get" ]]; then
  [[ "${FAKE_EXISTS:-yes}" == "no" ]] && exit 1
  [[ "$*" == *"containerStatuses[0].ready"* ]] && { printf '%s' "${FAKE_READY:-true}"; exit 0; }
  [[ "$*" == *"restartCount"* ]] && { printf '%s' "${FAKE_RESTARTS:-0}"; exit 0; }
  exit 0
fi
[[ "$1" == "logs" ]] && { printf '%s\n' "${FAKE_LOGS:-}"; exit 0; }
exit 0
SHIM
chmod +x "$work/bin/kubectl"

run() {
  env PATH="$work/bin:$PATH" \
      SERVER_POD=server-0 MIN_RESTARTS=2 SIGNATURE="Read-only file system" \
      "$@" bash "$work/recovery.sh" 2>&1
}

# Output is captured before matching rather than piped into grep. `grep -q`
# exits on its first match and closes the pipe, the script under test takes
# SIGPIPE on its next write, and `set -o pipefail` then reports 141 for a
# pipeline whose behaviour was correct — an assertion that fails on success.
assert_deletes() {
  local name="$1" out; shift
  out="$(run "$@")"
  [[ "$out" == *__DELETE_CALLED__* ]] || fail "$name: expected the pod to be deleted"
  echo "  ok: $name"
}

assert_leaves_alone() {
  local name="$1" out; shift
  out="$(run "$@")"
  [[ "$out" != *__DELETE_CALLED__* ]] || fail "$name: pod was deleted and must not have been"
  echo "  ok: $name"
}

# The one state this exists for.
assert_deletes "read-only volume, repeated restarts" \
  FAKE_READY=false FAKE_RESTARTS=5 FAKE_LOGS="server.properties: Read-only file system"

# A healthy server must never be touched, which is the failure that would
# matter most: a bug here takes down a working server every five minutes.
assert_leaves_alone "healthy pod" FAKE_READY=true

# Deletion cannot fix a corrupt world or a bad image. Recreating such a pod
# forever would hide a crash loop that should stay visible.
assert_leaves_alone "crash looping without the signature" \
  FAKE_READY=false FAKE_RESTARTS=5 FAKE_LOGS="Exception: level.dat is corrupt"

# The server downloads its binary on first boot; the chart allows ten minutes.
# Deleting a pod that is merely slow turns a slow start into a loop.
assert_leaves_alone "slow first start" \
  FAKE_READY=false FAKE_RESTARTS=0 FAKE_LOGS="server.properties: Read-only file system"

assert_leaves_alone "server pod absent" FAKE_EXISTS=no

echo "PASS"
