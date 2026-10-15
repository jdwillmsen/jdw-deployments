#!/usr/bin/env bash
# Pins the map's admin alerts: the owner is told when a passkey is added,
# across a restart and after every other passkey was revoked too, and when
# a real passkey is refused. The switches and the origin are pinned in
# test-map.sh. Read from the rendered chart with the value files
# production applies.
set -euo pipefail

here="$(cd "$(dirname "$0")/../.." && pwd)"
chart="$here/charts/minecraft-fwb"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

helm template minecraft-fwb "$chart" --namespace jdwillmsen-prd \
  -f "$chart/values.yaml" -f "$chart/values-prd.yaml" \
  -f "$chart/values-console-bridge.yaml" -f "$chart/values-map-pack.yaml" > "$work/prod.yaml" \
  || fail "the chart does not render with production values"

python3 - "$work/prod.yaml" <<'PY' || fail "the Loki copy of the passkey alert is missing or wrong"
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
cms = [d for d in docs if d["kind"] == "ConfigMap" and d["metadata"].get("labels", {}).get("loki_rule") == "true" and "map-admin" in d["metadata"]["name"]]
assert len(cms) == 1, f"{len(cms)} map admin Loki ConfigMaps"
text = "".join(cms[0]["data"].values())
for want in ("map passkey registered", "tenant: jdwillmsen", "JdwillmsenMinecraftMapPasskeyAddedLogged", 'container="map"'):
    assert want in text, want
PY

if ! command -v promtool >/dev/null 2>&1; then
  # Loud rather than silent, as test-map.sh is: CI installs promtool.
  echo "SKIP: promtool not on PATH; map admin alerts not verified"
  exit 0
fi

python3 - "$work/prod.yaml" > "$work/rules.yaml" <<'PY'
import sys, yaml
for doc in yaml.safe_load_all(open(sys.argv[1])):
    if doc and doc.get("kind") == "PrometheusRule" and doc["metadata"]["name"].endswith("-map-admin"):
        print(yaml.safe_dump({"groups": doc["spec"]["groups"]}, sort_keys=False))
PY
[ -s "$work/rules.yaml" ] || fail "could not extract the map admin rules from the chart"
# The duplicate-rule lint is off because the passkey alert is deliberately two
# rules of one name; syntax and expression errors still fail.
promtool check rules --lint=none "$work/rules.yaml" >/dev/null || fail "promtool rejected the map admin rules"

added_desc='"A passkey for logging in to the map as an admin was confirmed in the last 15 minutes. If nobody you know added one, the player it belongs to should type !map logout in the game, which logs out every browser and removes every passkey they hold."'
by_counter="
          - exp_labels: {severity: warning, tenant: jdwillmsen, namespace: jdwillmsen-prd, result: confirmed}
            exp_annotations: {summary: \"A passkey was added to the FWB map\", description: $added_desc}"
by_gauge="
          - exp_labels: {severity: warning, tenant: jdwillmsen, namespace: jdwillmsen-prd, state: active}
            exp_annotations: {summary: \"A passkey was added to the FWB map\", description: $added_desc}"
refused_desc='"In the last 15 minutes a passkey login whose signature was good was refused: a counter that went back (a copied key), a replay, a holder who is no longer an operator, or a passkey never confirmed. mcmap_admin_logins_total by result says which."'
refused() {
  printf '\n          - exp_labels: {severity: warning, tenant: jdwillmsen, namespace: jdwillmsen-prd, result: %s}\n            exp_annotations: {summary: "A real passkey was turned away at the FWB map", description: %s}' "$1" "$refused_desc"
}

cat > "$work/tests.yaml" <<TESTS
rule_files:
  - rules.yaml
evaluation_interval: 1m
tests:
  # The first passkey ever, from the gauge and counter declared at zero:
  # both expressions see it.
  - interval: 1m
    input_series:
      - series: 'mcmap_admin_passkeys{namespace="jdwillmsen-prd", pod="map-a", state="active"}'
        values: '0x60 1x60'
      - series: 'mcmap_admin_passkeys_registered_total{namespace="jdwillmsen-prd", pod="map-a", result="confirmed"}'
        values: '0x60 1x60'
    alert_rule_test:
      - eval_time: 65m
        alertname: JdwillmsenMinecraftMapPasskeyAdded
        exp_alerts:$by_counter$by_gauge
      - eval_time: 100m
        alertname: JdwillmsenMinecraftMapPasskeyAdded
        exp_alerts: []

  # A second one added.
  - interval: 1m
    input_series:
      - series: 'mcmap_admin_passkeys{namespace="jdwillmsen-prd", pod="map-a", state="active"}'
        values: '1x60 2x60'
      - series: 'mcmap_admin_passkeys_registered_total{namespace="jdwillmsen-prd", pod="map-a", result="confirmed"}'
        values: '1x60 2x60'
    alert_rule_test:
      - eval_time: 65m
        alertname: JdwillmsenMinecraftMapPasskeyAdded
        exp_alerts:$by_counter$by_gauge

  # Revoke all, then add one: the count ends lower than it was, and only
  # the confirmation fires.
  - interval: 1m
    input_series:
      - series: 'mcmap_admin_passkeys{namespace="jdwillmsen-prd", pod="map-a", state="active"}'
        values: '3x60 0x5 1x55'
      - series: 'mcmap_admin_passkeys_registered_total{namespace="jdwillmsen-prd", pod="map-a", result="confirmed"}'
        values: '3x65 4x55'
    alert_rule_test:
      - eval_time: 70m
        alertname: JdwillmsenMinecraftMapPasskeyAdded
        exp_alerts:$by_counter

  # A Recreate restart with nothing confirmed: the old pod's series goes
  # stale at 61m, nothing is scraped at 62m or 63m, and a new pod reports the
  # same count from 64m, its counter back at zero. Silent throughout.
  - interval: 1m
    input_series:
      - series: 'mcmap_admin_passkeys{namespace="jdwillmsen-prd", pod="map-a", state="active"}'
        values: '2x60 stale'
      - series: 'mcmap_admin_passkeys{namespace="jdwillmsen-prd", pod="map-b", state="active"}'
        values: '_x64 2x60'
      - series: 'mcmap_admin_passkeys_registered_total{namespace="jdwillmsen-prd", pod="map-a", result="confirmed"}'
        values: '2x60 stale'
      - series: 'mcmap_admin_passkeys_registered_total{namespace="jdwillmsen-prd", pod="map-b", result="confirmed"}'
        values: '_x64 0x60'
    alert_rule_test:
      - { eval_time: 62m, alertname: JdwillmsenMinecraftMapPasskeyAdded, exp_alerts: [] }
      - { eval_time: 66m, alertname: JdwillmsenMinecraftMapPasskeyAdded, exp_alerts: [] }
      - { eval_time: 80m, alertname: JdwillmsenMinecraftMapPasskeyAdded, exp_alerts: [] }
      - { eval_time: 100m, alertname: JdwillmsenMinecraftMapPasskeyAdded, exp_alerts: [] }

  # The same restart followed by a confirmation.
  - interval: 1m
    input_series:
      - series: 'mcmap_admin_passkeys{namespace="jdwillmsen-prd", pod="map-a", state="active"}'
        values: '2x60 stale'
      - series: 'mcmap_admin_passkeys{namespace="jdwillmsen-prd", pod="map-b", state="active"}'
        values: '_x64 2x10 3x50'
      - series: 'mcmap_admin_passkeys_registered_total{namespace="jdwillmsen-prd", pod="map-a", result="confirmed"}'
        values: '2x60 stale'
      - series: 'mcmap_admin_passkeys_registered_total{namespace="jdwillmsen-prd", pod="map-b", result="confirmed"}'
        values: '_x64 0x10 1x50'
    alert_rule_test:
      - eval_time: 80m
        alertname: JdwillmsenMinecraftMapPasskeyAdded
        exp_alerts:$by_counter$by_gauge

  # Confirmed before the new pod's first scrape: its counter is first seen
  # at 1, which increase() cannot see, and the gauge must fire instead.
  - interval: 1m
    input_series:
      - series: 'mcmap_admin_passkeys{namespace="jdwillmsen-prd", pod="map-a", state="active"}'
        values: '2x60 stale'
      - series: 'mcmap_admin_passkeys{namespace="jdwillmsen-prd", pod="map-b", state="active"}'
        values: '_x64 3x60'
      - series: 'mcmap_admin_passkeys_registered_total{namespace="jdwillmsen-prd", pod="map-a", result="confirmed"}'
        values: '2x60 stale'
      - series: 'mcmap_admin_passkeys_registered_total{namespace="jdwillmsen-prd", pod="map-b", result="confirmed"}'
        values: '_x64 1x60'
    alert_rule_test:
      - eval_time: 70m
        alertname: JdwillmsenMinecraftMapPasskeyAdded
        exp_alerts:$by_gauge

  # A removal.
  - interval: 1m
    input_series:
      - series: 'mcmap_admin_passkeys{namespace="jdwillmsen-prd", pod="map-a", state="active"}'
        values: '2x60 1x60'
      - series: 'mcmap_admin_passkeys_registered_total{namespace="jdwillmsen-prd", pod="map-a", result="confirmed"}'
        values: '2x120'
    alert_rule_test:
      - { eval_time: 65m, alertname: JdwillmsenMinecraftMapPasskeyAdded, exp_alerts: [] }

  # An outage longer than the window, then a restart with nothing
  # confirmed: the window is empty, and nothing fires.
  - interval: 1m
    input_series:
      - series: 'mcmap_admin_passkeys{namespace="jdwillmsen-prd", pod="map-a", state="active"}'
        values: '2x10 stale'
      - series: 'mcmap_admin_passkeys{namespace="jdwillmsen-prd", pod="map-b", state="active"}'
        values: '_x70 2x60'
      - series: 'mcmap_admin_passkeys_registered_total{namespace="jdwillmsen-prd", pod="map-a", result="confirmed"}'
        values: '1x10 stale'
      - series: 'mcmap_admin_passkeys_registered_total{namespace="jdwillmsen-prd", pod="map-b", result="confirmed"}'
        values: '_x70 0x60'
    alert_rule_test:
      - { eval_time: 75m, alertname: JdwillmsenMinecraftMapPasskeyAdded, exp_alerts: [] }
      - { eval_time: 100m, alertname: JdwillmsenMinecraftMapPasskeyAdded, exp_alerts: [] }

  # Each refusal made after the signature pages, one case per result.
  - interval: 1m
    input_series:
      - series: 'mcmap_admin_logins_total{namespace="jdwillmsen-prd", pod="map-a", result="counter"}'
        values: '0x30 1x30'
    alert_rule_test:
      - eval_time: 40m
        alertname: JdwillmsenMinecraftMapPasskeyLoginRefused
        exp_alerts:$(refused counter)
  - interval: 1m
    input_series:
      - series: 'mcmap_admin_logins_total{namespace="jdwillmsen-prd", pod="map-a", result="replayed"}'
        values: '0x30 1x30'
    alert_rule_test:
      - eval_time: 40m
        alertname: JdwillmsenMinecraftMapPasskeyLoginRefused
        exp_alerts:$(refused replayed)
  - interval: 1m
    input_series:
      - series: 'mcmap_admin_logins_total{namespace="jdwillmsen-prd", pod="map-a", result="not_operator"}'
        values: '0x30 1x30'
    alert_rule_test:
      - eval_time: 40m
        alertname: JdwillmsenMinecraftMapPasskeyLoginRefused
        exp_alerts:$(refused not_operator)
  - interval: 1m
    input_series:
      - series: 'mcmap_admin_logins_total{namespace="jdwillmsen-prd", pod="map-a", result="pending"}'
        values: '0x30 1x30'
    alert_rule_test:
      - eval_time: 40m
        alertname: JdwillmsenMinecraftMapPasskeyLoginRefused
        exp_alerts:$(refused pending)

  # Those before the signature are anyone's to make, and do not page.
  - interval: 1m
    input_series:
      - series: 'mcmap_admin_logins_total{namespace="jdwillmsen-prd", pod="map-a", result="bad_assertion"}'
        values: '0x30 9x30'
      - series: 'mcmap_admin_logins_total{namespace="jdwillmsen-prd", pod="map-a", result="unknown_credential"}'
        values: '0x30 9x30'
    alert_rule_test:
      - { eval_time: 40m, alertname: JdwillmsenMinecraftMapPasskeyLoginRefused, exp_alerts: [] }
TESTS

if ! out="$(cd "$work" && promtool test rules tests.yaml 2>&1)"; then
  echo "$out"
  fail "the map admin alerts do not behave as tested"
fi

echo "ok: map admin alerts"
