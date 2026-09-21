#!/usr/bin/env bash
# Proves the tick-rate alert rules fire when they should and stay quiet when
# they should not.
#
# The pairing these cases exist for: mc_agent_server_tps deliberately holds its
# last good reading rather than resetting when a measurement fails, so a low
# value alone does not mean the server is slow -- it can equally mean the probe
# died while the server was struggling. Reading the gauge without joining it to
# the freshness of that reading gives an alert that is wrong in both
# directions, and no amount of staring at the expression shows which.
#
# That is not hypothetical here. The rule shipped unable to fire and needed a
# follow-up fix; nothing failed in between, because an alert that cannot fire
# looks exactly like an alert with nothing to say.
#
# The rules are extracted from the rendered chart rather than copied here, so
# the cases cannot drift away from what actually ships.
set -euo pipefail

here="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

if ! command -v promtool >/dev/null 2>&1; then
  # Loud rather than silent: a skipped alert test is an untested alert. CI
  # installs promtool so this branch is never taken there; locally it lets the
  # rest of the suite run on a machine without it.
  echo "SKIP: promtool not on PATH; alert rules not verified"
  exit 0
fi

# Rendered into the production namespace because the rules stamp
# `namespace: {{ .Release.Namespace }}` onto every alert as a label and pin the
# same value inside each expression. Rendering into helm's default would test a
# namespace that never ships.
helm template minecraft-fwb "$here/charts/minecraft-fwb" \
  --namespace jdwillmsen-prd \
  -f "$here/charts/minecraft-fwb/values.yaml" \
  | python3 -c "
import sys, yaml
for doc in yaml.safe_load_all(sys.stdin):
    if doc and doc.get('kind') == 'PrometheusRule' and doc['metadata']['name'].endswith('-tick-rate'):
        print(yaml.safe_dump({'groups': doc['spec']['groups']}, sort_keys=False))
" > "$work/rules.yaml"
[ -s "$work/rules.yaml" ] || fail "could not extract the tick-rate rules from the chart"

promtool check rules "$work/rules.yaml" >/dev/null || fail "promtool rejected the rendered rules"

# promtool's clock starts at unix 0, so a timestamp series counting 60 per
# minute reads back exactly the evaluation time in seconds, making
# `time() - series` zero: a measurement taken right now. Holding it at 0
# instead makes that difference equal the evaluation time, i.e. arbitrarily
# stale. Those two shapes are what every case below is built from.
#
# avg_over_time over a 30m window does not need 30m of data -- it averages
# whatever the window holds, so a series pinned below the threshold is already
# under it at the first sample and `for: 5m` is the only delay. Cases that want
# the rule quiet are still evaluated late, because an early eval_time would
# pass whether the rule worked or not.
cat > "$work/tests.yaml" <<'EOF'
rule_files:
  - rules.yaml
evaluation_interval: 1m
tests:
  # Slow server, measurement fresh: the real condition the rule exists for.
  - interval: 1m
    input_series:
      - series: 'mc_agent_server_tps{namespace="jdwillmsen-prd"}'
        values: '13+0x60'
      - series: 'mc_agent_tps_last_success_timestamp_seconds{namespace="jdwillmsen-prd"}'
        values: '0+60x60'
    alert_rule_test:
      # Inside `for`, so pending rather than firing.
      - eval_time: 4m
        alertname: JdwillmsenMinecraftTickRateDegraded
        exp_alerts: []
      - eval_time: 12m
        alertname: JdwillmsenMinecraftTickRateDegraded
        exp_alerts:
          - exp_labels:
              severity: warning
              namespace: jdwillmsen-prd
            exp_annotations:
              summary: "Minecraft FWB is running below 17 TPS"
              description: "Server tick rate has averaged under 17 of 20 across 30m, so mobs, redstone and farms are all running slow. A restart is the known remedy for the decay this server shows on Bedrock 1.26.51.1; the scheduled restart does it nightly, and doing it early is `send-command stop` through the server console -- never a pod delete."

  # The case the pairing exists for. Same low reading, but nothing has measured
  # it for a long time: the server may be fine and the probe is what is broken,
  # so Degraded must stay quiet and Unmeasured must be the one that fires.
  - interval: 1m
    input_series:
      - series: 'mc_agent_server_tps{namespace="jdwillmsen-prd"}'
        values: '13+0x60'
      - series: 'mc_agent_tps_last_success_timestamp_seconds{namespace="jdwillmsen-prd"}'
        values: '0+0x60'
    alert_rule_test:
      - eval_time: 50m
        alertname: JdwillmsenMinecraftTickRateDegraded
        exp_alerts: []
      - eval_time: 50m
        alertname: JdwillmsenMinecraftTickRateUnmeasured
        exp_alerts:
          - exp_labels:
              severity: warning
              namespace: jdwillmsen-prd
            exp_annotations:
              summary: "Minecraft FWB tick rate is not being measured"
              description: "Every TPS reading for the last 15 minutes has been older than 300s, or the metric is gone entirely, so the degradation alert above cannot fire whatever the server is doing. The measurement runs over the console bridge, so this usually means the agent or the bridge is down rather than the server."

  # Healthy server, fresh readings: neither rule has anything to say.
  - interval: 1m
    input_series:
      - series: 'mc_agent_server_tps{namespace="jdwillmsen-prd"}'
        values: '20+0x60'
      - series: 'mc_agent_tps_last_success_timestamp_seconds{namespace="jdwillmsen-prd"}'
        values: '0+60x60'
    alert_rule_test:
      - eval_time: 50m
        alertname: JdwillmsenMinecraftTickRateDegraded
        exp_alerts: []
      - eval_time: 50m
        alertname: JdwillmsenMinecraftTickRateUnmeasured
        exp_alerts: []

  # The series stops being produced entirely. A threshold rule cannot fire on a
  # series that is not there, so without the absent() arm this state looks
  # healthiest of all.
  - interval: 1m
    input_series: []
    alert_rule_test:
      - eval_time: 20m
        alertname: JdwillmsenMinecraftTickRateUnmeasured
        exp_alerts:
          - exp_labels:
              severity: warning
              namespace: jdwillmsen-prd
            exp_annotations:
              summary: "Minecraft FWB tick rate is not being measured"
              description: "Every TPS reading for the last 15 minutes has been older than 300s, or the metric is gone entirely, so the degradation alert above cannot fire whatever the server is doing. The measurement runs over the console bridge, so this usually means the agent or the bridge is down rather than the server."

  # Exactly on the threshold. The comparison is a strict <, so a server holding
  # 17 is not alerting. Pinned because loosening it to <= would be an easy and
  # invisible edit.
  - interval: 1m
    input_series:
      - series: 'mc_agent_server_tps{namespace="jdwillmsen-prd"}'
        values: '17+0x60'
      - series: 'mc_agent_tps_last_success_timestamp_seconds{namespace="jdwillmsen-prd"}'
        values: '0+60x60'
    alert_rule_test:
      - eval_time: 50m
        alertname: JdwillmsenMinecraftTickRateDegraded
        exp_alerts: []

  # A dip rather than a decay: the server drops to 5 TPS for four minutes -- a
  # save hold or a chunk load -- and recovers. Averaging over 30m is what keeps
  # this quiet, and a future edit back to an instantaneous comparison would
  # page on it.
  - interval: 1m
    input_series:
      - series: 'mc_agent_server_tps{namespace="jdwillmsen-prd"}'
        values: '20+0x40 5+0x4 20+0x40'
      - series: 'mc_agent_tps_last_success_timestamp_seconds{namespace="jdwillmsen-prd"}'
        values: '0+60x90'
    alert_rule_test:
      - eval_time: 60m
        alertname: JdwillmsenMinecraftTickRateDegraded
        exp_alerts: []
  # The shape the rule was rewritten for, and the reason the averaging window
  # is not a `for`. This server's tick rate oscillates: in the twelve hours to
  # 2026-09-19 it sat under 17 for 171 minutes across 51 separate spans, not
  # one of which lasted 30 continuous minutes. The original rule compared the
  # instantaneous value and held it with `for: 30m`, so it never fired while
  # the server ran at 12-15 TPS.
  #
  # Alternating 12 and 18 reproduces that exactly: the mean is 15, well under
  # the threshold, while no single evaluation span stays under it for more than
  # a minute. An instantaneous rule cannot fire here however long its `for`;
  # the average fires as it should. Reverting to the older shape turns this
  # case red, which every other case in this file would let through.
  - interval: 1m
    input_series:
      - series: 'mc_agent_server_tps{namespace="jdwillmsen-prd"}'
        values: '12 18 12 18 12 18 12 18 12 18 12 18 12 18 12 18 12 18 12 18 12 18 12 18 12 18 12 18 12 18 12 18 12 18 12 18 12 18 12 18 12 18 12 18 12 18 12 18 12 18 12 18 12 18 12 18 12 18 12 18'
      - series: 'mc_agent_tps_last_success_timestamp_seconds{namespace="jdwillmsen-prd"}'
        values: '0+60x60'
    alert_rule_test:
      - eval_time: 40m
        alertname: JdwillmsenMinecraftTickRateDegraded
        exp_alerts:
          - exp_labels:
              severity: warning
              namespace: jdwillmsen-prd
            exp_annotations:
              summary: "Minecraft FWB is running below 17 TPS"
              description: "Server tick rate has averaged under 17 of 20 across 30m, so mobs, redstone and farms are all running slow. A restart is the known remedy for the decay this server shows on Bedrock 1.26.51.1; the scheduled restart does it nightly, and doing it early is `send-command stop` through the server console -- never a pod delete."
EOF

( cd "$work" && promtool test rules tests.yaml ) || fail "alert rule unit tests did not pass"

echo "PASS: tick-rate alerts fire on a sustained slow reading, stay quiet on a stale one or a brief dip, and notice their own absence"
