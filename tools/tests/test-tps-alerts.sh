#!/usr/bin/env bash
# Proves the TPS alert rules fire when they should and stay quiet when they
# should not.
#
# The pairing these cases exist for: mc_agent_server_tps deliberately holds its
# last good reading rather than resetting when a measurement fails, so a low
# value alone does not mean the server is slow -- it can equally mean the probe
# died an hour ago while the server was struggling. Reading the gauge without
# joining it to the freshness of that reading produces an alert that is wrong in
# both directions, and no amount of staring at the expression shows which.
#
# The rules are extracted from the rendered chart rather than copied here, so
# the test cannot drift away from what actually ships.
set -euo pipefail

here="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

if ! command -v promtool >/dev/null 2>&1; then
  # Loud rather than silent: a skipped alert test in CI is an untested alert,
  # and the CI job installs promtool precisely so this branch is never taken
  # there. Locally it lets the rest of the suite run on a machine without it.
  echo "SKIP: promtool not on PATH; alert rules not verified"
  exit 0
fi

# Rendered into the production namespace because the rules stamp
# `namespace: {{ .Release.Namespace }}` onto every alert as a label, overriding
# whatever the series carried. Rendering into helm's default would test a label
# value that never ships.
helm template minecraft-fwb "$here/charts/minecraft-fwb" \
  --namespace jdwillmsen-prd \
  -f "$here/charts/minecraft-fwb/values.yaml" \
  | python3 -c "
import sys, yaml
for doc in yaml.safe_load_all(sys.stdin):
    if doc and doc.get('kind') == 'PrometheusRule' and doc['metadata']['name'].endswith('-tps'):
        print(yaml.safe_dump({'groups': doc['spec']['groups']}, sort_keys=False))
" > "$work/rules.yaml"
[ -s "$work/rules.yaml" ] || fail "could not extract the TPS rules from the chart"

promtool check rules "$work/rules.yaml" >/dev/null || fail "promtool rejected the rendered rules"

# promtool's clock starts at unix 0, so a series counting 60 per minute reads
# back exactly the evaluation time in seconds -- which makes `time() - series`
# zero, i.e. a measurement taken right now. Holding the series at 0 instead
# makes that difference equal the evaluation time, i.e. arbitrarily stale.
cat > "$work/tests.yaml" <<'EOF'
rule_files:
  - rules.yaml
evaluation_interval: 1m
tests:
  # Slow server, measurement fresh: this is the real condition.
  - interval: 1m
    input_series:
      - series: 'mc_agent_server_tps{namespace="jdwillmsen-prd",pod="agent-1"}'
        values: '13+0x60'
      - series: 'mc_agent_tps_last_success_timestamp_seconds{namespace="jdwillmsen-prd",pod="agent-1"}'
        values: '0+60x60'
    alert_rule_test:
      # Under `for`, so still pending rather than firing.
      - eval_time: 20m
        alertname: JdwillmsenMinecraftLowTPS
        exp_alerts: []
      - eval_time: 35m
        alertname: JdwillmsenMinecraftLowTPS
        exp_alerts:
          - exp_labels:
              severity: warning
              namespace: jdwillmsen-prd
              pod: agent-1
            exp_annotations:
              summary: "Minecraft FWB is running below 17 TPS"
              description: "Server tick rate has been under 17 of a possible 20 for 30m. Mobs, redstone and farms all run at that fraction of normal speed. On healthy days the 10th percentile sits at 19.5-20.0, so this is well outside jitter. A restart resets it; see the nightly scheduled-restart CronJob, and check whether that job has been failing."

  # Same low reading, but nothing has measured it for an hour. The server may be
  # fine; what is broken is the probe, so LowTPS must stay quiet and the
  # staleness rule must be the one that fires.
  - interval: 1m
    input_series:
      - series: 'mc_agent_server_tps{namespace="jdwillmsen-prd",pod="agent-1"}'
        values: '13+0x60'
      - series: 'mc_agent_tps_last_success_timestamp_seconds{namespace="jdwillmsen-prd",pod="agent-1"}'
        values: '0+0x60'
    alert_rule_test:
      - eval_time: 50m
        alertname: JdwillmsenMinecraftLowTPS
        exp_alerts: []
      # Staleness crosses 1800s just after 30m, then has to hold for 15m.
      - eval_time: 50m
        alertname: JdwillmsenMinecraftTPSUnmeasured
        exp_alerts:
          - exp_labels:
              severity: warning
              namespace: jdwillmsen-prd
              pod: agent-1
            exp_annotations:
              summary: "Minecraft FWB tick rate is not being measured"
              description: "No fresh TPS measurement for 30 minutes, so the low-TPS alert cannot fire whatever the server is doing. The reading comes from the agent's console probe, so this usually means the agent lost its session or the console bridge is down rather than that the server is unwell."

  # Healthy server: neither rule has anything to say.
  - interval: 1m
    input_series:
      - series: 'mc_agent_server_tps{namespace="jdwillmsen-prd",pod="agent-1"}'
        values: '20+0x60'
      - series: 'mc_agent_tps_last_success_timestamp_seconds{namespace="jdwillmsen-prd",pod="agent-1"}'
        values: '0+60x60'
    alert_rule_test:
      - eval_time: 50m
        alertname: JdwillmsenMinecraftLowTPS
        exp_alerts: []
      - eval_time: 50m
        alertname: JdwillmsenMinecraftTPSUnmeasured
        exp_alerts: []

  # The series stops being produced entirely. A threshold rule cannot fire on a
  # series that is not there, so without the absent() arm this is the state that
  # looks healthiest of all.
  - interval: 1m
    input_series: []
    alert_rule_test:
      - eval_time: 20m
        alertname: JdwillmsenMinecraftTPSUnmeasured
        exp_alerts:
          - exp_labels:
              severity: warning
              namespace: jdwillmsen-prd
            exp_annotations:
              summary: "Minecraft FWB tick rate is not being measured"
              description: "No fresh TPS measurement for 30 minutes, so the low-TPS alert cannot fire whatever the server is doing. The reading comes from the agent's console probe, so this usually means the agent lost its session or the console bridge is down rather than that the server is unwell."

  # Right at the boundary: 17 is the threshold and the rule is a strict <, so a
  # server sitting exactly on it is not alerting. Pinned because changing the
  # comparison would be an easy and invisible edit.
  - interval: 1m
    input_series:
      - series: 'mc_agent_server_tps{namespace="jdwillmsen-prd",pod="agent-1"}'
        values: '17+0x60'
      - series: 'mc_agent_tps_last_success_timestamp_seconds{namespace="jdwillmsen-prd",pod="agent-1"}'
        values: '0+60x60'
    alert_rule_test:
      - eval_time: 50m
        alertname: JdwillmsenMinecraftLowTPS
        exp_alerts: []
EOF

( cd "$work" && promtool test rules tests.yaml ) || fail "alert rule unit tests did not pass"

echo "PASS: TPS alert rules fire on a fresh slow reading, stay quiet on a stale one, and notice their own absence"
