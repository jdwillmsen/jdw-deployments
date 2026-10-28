#!/usr/bin/env bash
# Proves the crew-units-offline alert fires for a fleet that stays offline and
# stays quiet through an ordinary lab server restart. The rule is extracted
# from the rendered chart so the cases cannot drift from what ships.
set -euo pipefail

here="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

if ! command -v promtool >/dev/null 2>&1; then
  echo "SKIP: promtool not on PATH; alert rules not verified"
  exit 0
fi

helm template crew-lab "$here/charts/crew-lab" \
  --namespace jdwillmsen-prd \
  -f "$here/charts/crew-lab/values.yaml" \
  | python3 -c "
import sys, yaml
for doc in yaml.safe_load_all(sys.stdin):
    if doc and doc.get('kind') == 'PrometheusRule' and doc['metadata']['name'] == 'crew-units-offline':
        print(yaml.safe_dump({'groups': doc['spec']['groups']}, sort_keys=False))
" > "$work/rules.yaml"
[ -s "$work/rules.yaml" ] || fail "could not extract the crew-units-offline rule from the chart"

promtool check rules "$work/rules.yaml" >/dev/null || fail "promtool rejected the rendered rules"

# Four units, one series each for the offline state: 1 is offline. Three of
# four offline is 0.75, over the 0.5 threshold.
cat > "$work/tests.yaml" <<'YAML'
rule_files:
  - rules.yaml
evaluation_interval: 1m
tests:
  # Three of four units offline for the whole run: the hung-units signature.
  - interval: 1m
    input_series:
      - {series: 'crew_fleet_unit_state{namespace="jdwillmsen-prd",state="offline",unit="crew-01"}', values: '1+0x30'}
      - {series: 'crew_fleet_unit_state{namespace="jdwillmsen-prd",state="offline",unit="crew-02"}', values: '1+0x30'}
      - {series: 'crew_fleet_unit_state{namespace="jdwillmsen-prd",state="offline",unit="crew-03"}', values: '1+0x30'}
      - {series: 'crew_fleet_unit_state{namespace="jdwillmsen-prd",state="offline",unit="crew-04"}', values: '0+0x30'}
    alert_rule_test:
      - eval_time: 5m
        alertname: JdwillmsenCrewUnitsOffline
        exp_alerts: []
      - eval_time: 15m
        alertname: JdwillmsenCrewUnitsOffline
        exp_alerts:
          - exp_labels:
              severity: warning
              namespace: jdwillmsen-prd
            exp_annotations:
              summary: Most crew units are offline
              description: >-
                More than 50% of crew units have been offline for 10m. After a lab server
                restart this usually means the Bedrock version moved past what
                crew's gophertunnel decodes: read the server's `Version:` line,
                then re-pin minecraft-bedrock.minecraftServer.version and crew.image.tag.
  # All units offline for five minutes, then back: a normal server restart.
  - interval: 1m
    input_series:
      - {series: 'crew_fleet_unit_state{namespace="jdwillmsen-prd",state="offline",unit="crew-01"}', values: '1x5 0x25'}
      - {series: 'crew_fleet_unit_state{namespace="jdwillmsen-prd",state="offline",unit="crew-02"}', values: '1x5 0x25'}
    alert_rule_test:
      - eval_time: 20m
        alertname: JdwillmsenCrewUnitsOffline
        exp_alerts: []
YAML

promtool test rules "$work/tests.yaml" || fail "alert rule cases did not hold"
echo "PASS: crew-units-offline alert"
