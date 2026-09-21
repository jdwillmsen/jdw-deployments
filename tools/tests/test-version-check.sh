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

# The wait for a previous candidate to go is the one bound a case here has to
# sit out, so the copy under test gets a shorter one. Rewritten in the copy
# rather than made a chart value: a knob that exists only for this suite would
# ship to production too. The count is asserted so that moving the literal
# fails the suite instead of silently restoring the 45s wait.
found="$(grep -c 'SECONDS + 45' "$work/version-check.sh" || true)"
[ "$found" = "1" ] || fail "expected one 45s gone-wait to shorten, found $found"
sed -i 's/SECONDS + 45 /SECONDS + 3 /' "$work/version-check.sh"

# Same treatment for the ready and version-read loops. A candidate that boots
# and then names no version is a case here, and it is the one case that cannot
# end early -- it can only run its deadline out, twice. Asserted before it is
# rewritten for the same reason as the wait above.
found="$(grep -c 'SECONDS + 60 ' "$work/version-check.sh" || true)"
[ "$found" = "2" ] || fail "expected two 60s loops to shorten, found $found"
sed -i 's/SECONDS + 60 /SECONDS + 4 /' "$work/version-check.sh"

# The poll interval has to shrink with the deadlines, and leaving it at 2s is
# what made this suite flaky.
#
# Those loops poll, sleep, and re-check against a wall clock, so the number of
# iterations a case gets is (deadline / sleep). At 3s and 4s against a 2s
# sleep that is two -- and the stale-candidate case needs exactly two, because
# the shim's linger counter clears on the second get. Zero margin: about a
# second of extra latency in one iteration moves the second check from
# `2 < 3` to `3 < 3`, the loop gives up, and the run reports "a previous
# candidate pod was still terminating" instead of recovering.
#
# It survives CPU pressure, which is why it looked unreproducible; what it
# cannot survive is fork/exec latency, which is what a full suite run and a
# busy CI runner actually produce. Injecting 1.1s per fake kubectl call fails
# it every time.
#
# So the sleep shrinks and the deadlines stay where they are. At 0.2s a 3s
# deadline offers about fourteen iterations where a case needs two, and the
# cases that exist to run a deadline out still finish in the same three
# seconds.
#
# Lengthening the deadlines instead was tried and reverted: it cost eleven
# seconds of suite time and bought no margin at all, because past roughly a
# second of per-call latency the binding constraint stops being the deadline
# and becomes the 25s `timeout` around the whole run. Spending longer inside
# that budget makes the run more likely to be cut off, not less.
#
# Asserted before rewriting, like the deadlines above, so adding a
# differently-spaced sleep to the job fails the suite rather than silently
# restoring the old margin.
found="$(grep -c '^ *sleep 2$' "$work/version-check.sh" || true)"
[ "$found" = "3" ] || fail "expected three 2s poll sleeps to shorten, found $found"
sed -i 's/^\( *\)sleep 2$/\1sleep 0.2/' "$work/version-check.sh"

mkdir -p "$work/bin"

# curl only carries the bot dispatch now. Production's own version is read by
# exec'ing the server pod (see the kubectl shim), because the mc-monitor
# metric this used to scrape goes stale the moment the server stops speaking
# RakNet -- which is exactly what it now does.
cat > "$work/bin/curl" <<'SHIM'
#!/usr/bin/env bash
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
    echo "DELETE" >> "$trace"
    # --wait=false returns before the pod is gone, so how long it lingers is
    # the shim's to decide: immediately by default, after a few reads when a
    # case wants the gone loop to actually iterate, never when it wants that
    # loop to give up.
    case "${FAKE_LINGER_GETS:-0}" in
      forever) : ;;
      0)       rm -f "$state/exists" ;;
      *)       echo "$FAKE_LINGER_GETS" > "$state/lingers" ;;
    esac
    exit 0
    ;;
  get)
    # The server pod, not the candidate: uid plus restart count, which the
    # restart branch reads before and after delivering its stop. Answered
    # before the candidate-existence guard below, since the server pod exists
    # whatever the candidate is doing. The count moves on the second read so a
    # restart the script correctly performed does not sit out its 120s
    # deadline here.
    if [[ "$*" == *"containerStatuses"* ]]; then
      reads=$(( $(cat "$state/serverreads" 2>/dev/null || echo 0) + 1 ))
      echo "$reads" > "$state/serverreads"
      if (( reads <= 1 )); then printf 'server-uid 0'; else printf 'server-uid 1'; fi
      exit 0
    fi
    [[ -f "$state/exists" ]] || exit 1
    if [[ "$*" == *"metadata.name"* ]]; then
      if [[ -f "$state/lingers" ]]; then
        left=$(( $(cat "$state/lingers") - 1 ))
        if (( left <= 0 )); then
          rm -f "$state/lingers" "$state/exists"
          exit 1
        fi
        echo "$left" > "$state/lingers"
      fi
      printf '%s' "$CANDIDATE_POD"
      exit 0
    fi
    if [[ "$*" == *"status.phase"* ]]; then
      gets=$(( $(cat "$state/gets") + 1 ))
      echo "$gets" > "$state/gets"
      # A candidate that cannot resolve its download URL still starts its
      # container and only exits once the entrypoint gives up, so the first
      # observation is normally Running -- but a run that looks a moment later
      # sees Failed straight away, and that is a case in its own right.
      if [[ "$attempt" == "${FAKE_GOOD_ATTEMPT:-1}" ]]; then
        printf 'Running'
      elif [[ "$gets" -le 1 ]]; then
        printf '%s' "${FAKE_FIRST_PHASE:-Running}"
      else
        printf 'Failed'
      fi
      exit 0
    fi
    exit 0
    ;;
  exec)
    # Asking either server to serve a status ping is the regression this shim
    # exists to catch: 1.26.51 defaults a fresh candidate to
    # transport=nethernet and production now runs that way too, so no RakNet
    # listener exists for a version read to reach. Traced rather than merely
    # refused, so the assertion names the cause.
    if [[ "$*" == *"mc-monitor"* ]]; then
      echo "EXEC_MCMONITOR" >> "$trace"
      exit 1
    fi
    # Production's running version, the way the job reads it: the command line
    # of the process serving the world, which the image names after the
    # version it downloaded.
    if [[ "$*" == *"/proc/"* ]]; then
      echo "EXEC_PROC" >> "$trace"
      printf './bedrock_server-%s\n' "${FAKE_PRODUCTION_VERSION-1.26.45.1}"
      exit 0
    fi
    # send-command, on the server pod -- the notice and the stop. Its real
    # counterpart exits 0 whenever the pipe was writable.
    echo "EXEC_SERVER" >> "$trace"
    exit 0
    ;;
  logs)
    [[ -f "$state/exists" ]] || exit 1
    # The line the image's entrypoint prints before the server starts, which
    # is where the version now comes from. A candidate that never got that far
    # prints only whatever the case staged.
    version="${FAKE_CANDIDATE_VERSION-1.26.45.1}"
    if [[ "$attempt" == "${FAKE_GOOD_ATTEMPT:-1}" && -n "$version" ]]; then
      printf 'Downloading Bedrock server version %s ...\n' "$version"
    fi
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
  # A candidate left behind by a run that hit its deadline: it is there before
  # this run starts, and nothing in this run created it.
  if [[ "$*" == *"FAKE_STALE=yes"* ]]; then
    touch "$state/exists"
  fi
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
[[ "$(trace)" != *"EXEC_MCMONITOR"* ]] \
  || fail "healthy candidate: the version was read by pinging the candidate, trace: $(trace)"
echo "  ok: healthy candidate answers on the first attempt, from its log"

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

# A candidate that is already Failed the first time it is looked at leaves the
# ready loop, not the version poll -- a different exit carrying the same need.
# Reporting the phase without the log names the state and not the cause, which
# is the whole of what was wrong before.
out="$(capture FAKE_GOOD_ATTEMPT=0 FAKE_FIRST_PHASE=Failed \
  FAKE_CANDIDATE_LOGS='curl: (6) Could not resolve host: net.web.minecraft-services.net')"
[[ "$out" == *"never reached Running"* ]] \
  || fail "candidate failed before first read: expected the ready-loop reason, got: $out"
[[ "$out" == *"Could not resolve host"* ]] \
  || fail "candidate failed before first read: expected the candidate's own log, got: $out"
echo "  ok: a candidate that dies before it is first seen still reports why"

# activeDeadlineSeconds kills the job pod outright, and a trap does not run on
# SIGKILL, so a deadline-exceeded run leaves its candidate behind. This role
# holds create/get/delete and no patch, so an apply over that leftover cannot
# replace it -- the run has to remove it first or it polls a pod that answered
# for a previous hour. --wait=false means the delete returns before the pod
# goes, so the run also has to watch it go rather than assume it has.
out="$(capture FAKE_GOOD_ATTEMPT=1 FAKE_STALE=yes FAKE_LINGER_GETS=2)"
[[ "$out" == *'"event":"current"'* ]] || fail "stale candidate: expected the run to recover, got: $out"
t="$(trace)"
# Ordering, not the first line: reading production's version now leaves its own
# EXEC_PROC entry ahead of any candidate work.
[[ "$(grep -n 'DELETE' <<<"$t" | head -1 | cut -d: -f1)" -lt "$(grep -n 'CREATE:1' <<<"$t" | head -1 | cut -d: -f1)" ]] \
  || fail "stale candidate: expected a delete before the first create, trace: $t"
[[ "$t" == *"CREATE:1"* ]] || fail "stale candidate: expected a candidate to be created after it, trace: $t"
echo "  ok: a leftover candidate is removed, waited out, and replaced"

# The same leftover, never going. Creating over it is what this role cannot do,
# so the run has to stop rather than poll whatever is still there.
out="$(capture FAKE_GOOD_ATTEMPT=1 FAKE_STALE=yes FAKE_LINGER_GETS=forever)"
[[ "$out" == *'"event":"failed"'* ]] || fail "candidate will not terminate: expected a failed event, got: $out"
[[ "$out" == *"still terminating"* ]] \
  || fail "candidate will not terminate: expected the terminating reason, got: $out"
[[ "$(trace)" != *"CREATE"* ]] \
  || fail "candidate will not terminate: a candidate was created over the leftover, trace: $(trace)"
echo "  ok: a leftover that will not go stops the run instead of being created over"

# The guard, not the mechanism. Both sources name four components today, but
# if either ever goes back to three the two strings are still the same release
# -- and a comparison that cannot see that restarts the server every hour
# forever.
out="$(capture FAKE_GOOD_ATTEMPT=1 FAKE_PRODUCTION_VERSION=1.26.45 FAKE_CANDIDATE_VERSION=1.26.45.1)"
[[ "$out" == *'"event":"current"'* ]] \
  || fail "same release named two ways: expected a current event, got: $out"
[[ "$out" != *'"event":"restarting"'* ]] \
  || fail "same release named two ways: production was restarted onto its own version, got: $out"
echo "  ok: a four-component candidate still matches a three-component production version"

# The cost of that tolerance, asserted so it stays a decision: against a
# three-component production version a build-level bump cannot be seen, and
# nothing restarts. This is why the read moved to the running binary, which
# names all four.
out="$(capture FAKE_GOOD_ATTEMPT=1 FAKE_PRODUCTION_VERSION=1.26.45 FAKE_CANDIDATE_VERSION=1.26.45.2)"
[[ "$out" == *'"event":"current"'* ]] \
  || fail "build-only bump against a truncated version: expected current, got: $out"
echo "  ok: the tolerance's blind spot is confined to a three-component version"

# A genuinely new release still has to reach the restart, and the stop still
# has to be delivered over the console rather than by recreating the pod --
# pod deletion is what migrates the world volume.
out="$(capture FAKE_GOOD_ATTEMPT=1 FAKE_CANDIDATE_VERSION=1.26.51.1)"
[[ "$out" == *'"event":"restarting"'* ]] \
  || fail "new release: expected a restarting event, got: $out"
[[ "$out" == *'"event":"restarted"'* ]] \
  || fail "new release: expected the run to confirm the restart, got: $out"
[[ "$(trace)" == *"EXEC_SERVER"* ]] \
  || fail "new release: expected a stop delivered to the server pod, trace: $(trace)"
echo "  ok: a new release restarts production in place"

# The failure this suite previously could not tell apart from a dead candidate:
# the pod runs, serves nothing a ping could reach, and names no version either.
# It must fail the run and say so in its own terms.
out="$(capture FAKE_GOOD_ATTEMPT=1 FAKE_CANDIDATE_VERSION= \
  FAKE_CANDIDATE_LOGS='[INFO] Server started.')"
[[ "$out" == *'"event":"failed"'* ]] \
  || fail "candidate names no version: expected a failed event, got: $out"
[[ "$out" == *"never named a version"* ]] \
  || fail "candidate names no version: expected the log-read reason, got: $out"
echo "  ok: a candidate that boots but names no version fails the run"

# The read that replaced the mc-monitor scrape. An unreadable production pod
# has to fail the run: the previous shape emitted `skipped` and exited 0,
# which would have reported success every hour while checking nothing.
out="$(capture FAKE_GOOD_ATTEMPT=1 FAKE_PRODUCTION_VERSION=)"
[[ "$out" == *'"event":"failed"'* ]] \
  || fail "unreadable production version: expected a failed event, got: $out"
[[ "$out" == *"could not read production's running version"* ]] \
  || fail "unreadable production version: expected the read to be named, got: $out"
echo "  ok: a production version that cannot be read fails the run"

# Both sides name four components now, so a build-level bump is visible where
# the old three-component metric could not express it.
out="$(capture FAKE_GOOD_ATTEMPT=1 FAKE_PRODUCTION_VERSION=1.26.51.1 FAKE_CANDIDATE_VERSION=1.26.51.2)"
[[ "$out" == *'"event":"restarting"'* ]] \
  || fail "build-level bump: expected a restart, got: $out"
echo "  ok: a build-level bump is now caught rather than truncated away"

echo "PASS"
