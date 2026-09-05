#!/usr/bin/env bash
# Exercises the version-check CronJob's candidate-boot handling against staged
# candidate outcomes.
#
# The cases here are the ones live runs actually produced: a candidate whose
# entrypoint aborts before the server starts (two resolver failures did that on
# 2026-09-01 and 2026-09-04), and a candidate left behind by a run the job
# deadline killed before its cleanup trap could run.
#
# The script is extracted from the rendered chart rather than copied here, so
# the test cannot drift away from what actually ships. curl and kubectl are
# both shimmed, so nothing here reaches a cluster or the network.
set -euo pipefail

here="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

helm template minecraft-fwb "$here/charts/minecraft-fwb" \
  -f "$here/charts/minecraft-fwb/values.yaml" \
  --set versionCheck.enabled=true \
  | python3 -c "
import sys, yaml
for doc in yaml.safe_load_all(sys.stdin):
    if doc and doc.get('kind') == 'CronJob' and 'version-check' in doc['metadata']['name']:
        print(doc['spec']['jobTemplate']['spec']['template']['spec']['containers'][0]['args'][0])
" > "$work/version-check.sh"
[ -s "$work/version-check.sh" ] || fail "could not extract the version-check script from the chart"

mkdir -p "$work/sa"
echo -n "test-ns" > "$work/sa/namespace"
sed -i "s|/var/run/secrets/kubernetes.io/serviceaccount/namespace|$work/sa/namespace|" "$work/version-check.sh"

mkdir -p "$work/bin"

# Production reports a version and the bot dispatch succeeds, so every case
# below turns only on what the candidate does.
cat > "$work/bin/curl" <<'SHIM'
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ "$arg" == *"/metrics" ]]; then
    echo 'minecraft_status_healthy{server_version="1.26.45"} 1'
    exit 0
  fi
done
exit 0
SHIM
chmod +x "$work/bin/curl"

# Models the one candidate lifecycle that matters: the pod reaches Running
# whether or not its entrypoint gets far enough to serve, and a candidate whose
# entrypoint aborts then goes to Failed with the reason only in its log. Which
# attempt is the healthy one is the single knob each case sets.
cat > "$work/bin/kubectl" <<'SHIM'
#!/usr/bin/env bash
state="$FAKE_STATE"
attempt=$(cat "$state/attempt")
trace="$state/trace"

case "$1" in
  create|apply)
    cat > /dev/null
    attempt=$(( attempt + 1 ))
    echo "$attempt" > "$state/attempt"
    echo 0 > "$state/gets"
    touch "$state/exists"
    echo "CREATE:$attempt" >> "$trace"
    echo "pod/$CANDIDATE_POD created"
    exit 0
    ;;
  delete)
    # Same reason recovery-cronjob.yaml documents on its own delete: this role
    # holds no list verb, so a delete that waits on a watch never returns.
    if [[ "$*" != *"--wait=false"* ]]; then
      echo 'pods is forbidden: cannot list resource "pods"' >&2
      sleep 3600
    fi
    rm -f "$state/exists"
    echo "DELETE" >> "$trace"
    exit 0
    ;;
  get)
    [[ -f "$state/exists" ]] || exit 1
    if [[ "$*" == *"metadata.name"* ]]; then
      printf '%s' "$CANDIDATE_POD"
      exit 0
    fi
    if [[ "$*" == *"status.phase"* ]]; then
      gets=$(( $(cat "$state/gets") + 1 ))
      echo "$gets" > "$state/gets"
      # The first observation is always Running: a candidate that cannot
      # resolve its download URL still starts its container, and only exits
      # once the entrypoint gives up.
      if [[ "$attempt" == "${FAKE_GOOD_ATTEMPT:-1}" || "$gets" -le 1 ]]; then
        printf 'Running'
      else
        printf 'Failed'
      fi
      exit 0
    fi
    exit 0
    ;;
  exec)
    [[ -f "$state/exists" ]] || exit 1
    if [[ "$attempt" == "${FAKE_GOOD_ATTEMPT:-1}" ]]; then
      echo "$CANDIDATE_POD version=1.26.45 players=0"
      exit 0
    fi
    exit 1
    ;;
  logs)
    [[ -f "$state/exists" ]] || exit 1
    printf '%s\n' "${FAKE_CANDIDATE_LOGS:-}"
    exit 0
    ;;
esac
exit 0
SHIM
chmod +x "$work/bin/kubectl"

# timeout, because the regression this guards against is a wait: a run that
# cannot tell a dead candidate from a slow one sits out its whole poll deadline
# before reporting. Without a bound the suite would be slow instead of red.
run() {
  local state="$work/state"
  rm -rf "$state"; mkdir -p "$state"
  echo 0 > "$state/attempt"
  echo 0 > "$state/gets"
  : > "$state/trace"
  timeout 25 env PATH="$work/bin:$PATH" FAKE_STATE="$state" \
      CANDIDATE_POD=fwb-candidate SERVER_POD=server-0 SERVER_CONTAINER=server \
      NOTICE_ENABLED=false METRICS_HOST=metrics CANDIDATE_IMAGE=image:tag \
      BOT_REPOSITORY=owner/repo BOT_WORKFLOW_FILE=w.yml BOT_DISPATCH_TOKEN=t \
      "$@" bash "$work/version-check.sh" 2>&1
}

trace() { cat "$work/state/trace"; }

# Output is captured before matching rather than piped into grep, for the same
# reason test-volume-recovery.sh documents: grep -q closes the pipe on its
# first match and the script under test then reports 141 for a run that
# behaved correctly.
capture() {
  local out
  # || true so a timed-out run reaches its assertion and reports why, rather
  # than aborting the suite through set -e with no message.
  out="$(run "$@")" || true
  printf '%s' "$out"
}

# The path every no-op hour takes. Guards the case where hardening the failure
# path costs an extra candidate boot on the runs that had no problem.
out="$(capture FAKE_GOOD_ATTEMPT=1)"
[[ "$out" == *'"event":"current"'* ]] || fail "healthy candidate: expected a current event, got: $out"
[[ "$(trace)" == *"CREATE:1"* && "$(trace)" != *"CREATE:2"* ]] \
  || fail "healthy candidate: expected exactly one candidate pod, trace: $(trace)"
echo "  ok: healthy candidate answers on the first attempt"

# The live failure. The entrypoint gives up rather than retrying, so the pod is
# already gone seconds in and no further waiting can produce an answer -- a
# second candidate is the only thing that recovers the run.
out="$(capture FAKE_GOOD_ATTEMPT=2 FAKE_CANDIDATE_LOGS='curl: (6) Could not resolve host: net.web.minecraft-services.net')"
[[ "$out" == *'"event":"current"'* ]] || fail "dead first candidate: expected the retry to answer, got: $out"
[[ "$(trace)" == *"CREATE:2"* ]] || fail "dead first candidate: expected a second candidate pod, trace: $(trace)"
echo "  ok: a candidate that dies mid-boot is retried"

# A candidate that never boots must still fail the run -- an hour that cannot
# learn the latest version is not an hour that confirmed production is current.
# What changes is that the reason travels with it: the generic
# "never reported a version" told nobody why, and the cleanup trap then removed
# the only pod that could have said.
out="$(capture FAKE_GOOD_ATTEMPT=0 FAKE_CANDIDATE_LOGS='curl: (6) Could not resolve host: net.web.minecraft-services.net')"
[[ "$out" == *'"event":"failed"'* ]] || fail "candidate never boots: expected a failed event, got: $out"
[[ "$out" == *"Could not resolve host"* ]] \
  || fail "candidate never boots: expected the candidate's own log in the output, got: $out"
echo "  ok: a candidate that never boots fails the run and reports why"

# activeDeadlineSeconds kills the job pod outright, and a trap does not run on
# SIGKILL, so a deadline-exceeded run leaves its candidate behind. This role
# holds create/get/delete and no patch, so an apply over that leftover cannot
# replace it -- the run has to remove it first or it polls a pod that answered
# for a previous hour.
out="$(capture FAKE_GOOD_ATTEMPT=1)"
t="$(trace)"
[[ "$t" == DELETE* ]] || fail "stale candidate: expected a delete before the first create, trace: $t"
echo "  ok: a leftover candidate is removed before the next one is created"

echo "PASS"
