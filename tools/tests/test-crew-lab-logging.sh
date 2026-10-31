#!/usr/bin/env bash
# The lab must print add-on script logs to the container log, and must not
# send telemetry off the cluster.
set -euo pipefail

here="$(cd "$(dirname "$0")/../.." && pwd)"
fail() { echo "FAIL: $1"; exit 1; }
command -v helm >/dev/null || { echo "SKIP: helm is not installed"; exit 0; }

out="$(helm template lab "$here/charts/crew-lab" -f "$here/charts/crew-lab/values-prd.yaml")" || fail "helm template failed"

# A name rendered twice (the subchart's default plus extraEnv) would let the
# first value hide the one the server actually gets.
env_value() {
  [ "$(grep -c -- "- name: $1\$" <<<"$out")" -eq 1 ] || fail "$1 is rendered more than once or not at all"
  grep -A1 -- "- name: $1\$" <<<"$out" | grep -m1 'value:' | sed 's/.*value: *"\(.*\)"/\1/'
}

[ "$(env_value CONTENT_LOG_LEVEL)" = verbose ] || fail "CONTENT_LOG_LEVEL is not verbose"
[ "$(env_value CONTENT_LOG_CONSOLE_OUTPUT_ENABLED)" = true ] || fail "content log is not printed to the console"
[ "$(env_value ITEM_TRANSACTION_LOGGING_ENABLED)" = true ] || fail "item transaction logging is off"
[ "$(env_value EMIT_SERVER_TELEMETRY)" = false ] || fail "server telemetry must stay off without the owner's OK"
echo "ok"
