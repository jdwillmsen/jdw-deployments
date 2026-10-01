#!/usr/bin/env bash
# Pins the two things about the map that nothing else would notice breaking.
#
# First, the quiet windows. The backup and the census pause world saving
# themselves, over kubectl exec, where the console bridge cannot see it. The
# map pauses and resumes saving for its own snapshots, so a snapshot that
# overlapped one of those jobs could resume saving under that job's copy and
# leave a backup that is silently inconsistent. The map is kept away by the
# clock (map.quietUTC), and a schedule and a window are two values in two
# places: move the backup to 03:00 and everything still renders, syncs and
# looks healthy. This fails instead.
#
# Second, the staleness alert, which is built on a gauge the map only sets on
# success -- the same shape that shipped unable to fire in the tick-rate rule.
#
# Read from the rendered chart with the value files production applies, so an
# override from any layer is what gets checked.
set -euo pipefail

here="$(cd "$(dirname "$0")/../.." && pwd)"
chart="$here/charts/minecraft-fwb"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

helm template minecraft-fwb "$chart" \
  --namespace jdwillmsen-prd \
  -f "$chart/values.yaml" \
  -f "$chart/values-prd.yaml" \
  -f "$chart/values-console-bridge.yaml" > "$work/rendered.yaml"

# Ten minutes before each job starts, because a snapshot that began just
# before it must be finished and resumed by then: the bridge caps one hold at
# five minutes.
MARGIN_BEFORE_MINUTES=10 python3 - "$work/rendered.yaml" <<'PY' || fail "the map's quiet windows do not cover the jobs that pause saving"
import os, sys, yaml

docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
by = lambda kind, suffix: next(d for d in docs if d["kind"] == kind and d["metadata"]["name"].endswith(suffix))

env = {e["name"]: e.get("value") for e in by("Deployment", "-map")["spec"]["template"]["spec"]["containers"][0]["env"]}
windows = []
for part in env["QUIET_UTC"].split(","):
    start, end = (int(t[:2]) * 60 + int(t[3:]) for t in part.strip().split("-"))
    windows.append((start, end))

def quiet(minute):
    minute %= 1440
    return any((s <= minute < e) if s < e else (minute >= s or minute < e) for s, e in windows)

margin = int(os.environ["MARGIN_BEFORE_MINUTES"])
bad = False
for suffix in ("-backup", "-census"):
    job = by("CronJob", suffix)
    minute, hour, *rest = job["spec"]["schedule"].split()
    if not (minute.isdigit() and hour.isdigit() and rest == ["*", "*", "*"]):
        print(f"{suffix[1:]}: schedule {job['spec']['schedule']!r} is not a single daily time; this check needs extending")
        bad = True
        continue
    start = int(hour) * 60 + int(minute)
    deadline = job["spec"]["jobTemplate"]["spec"]["activeDeadlineSeconds"]
    # Every minute from the margin before the start to the job's deadline:
    # the job may hold saving at any point in its run.
    uncovered = [m for m in range(start - margin, start + -(-deadline // 60) + 1) if not quiet(m)]
    if uncovered:
        first = uncovered[0] % 1440
        print(f"{suffix[1:]} runs {int(hour):02d}:{int(minute):02d} UTC for up to {deadline}s, "
              f"but {first // 60:02d}:{first % 60:02d} UTC is outside map.quietUTC ({env['QUIET_UTC']})")
        bad = True
sys.exit(1 if bad else 0)
PY

if ! command -v promtool >/dev/null 2>&1; then
  # Loud rather than silent: a skipped alert test is an untested alert. CI
  # installs promtool, so this branch is never taken there.
  echo "SKIP: promtool not on PATH; map alert rules not verified"
  exit 0
fi

python3 - "$work/rendered.yaml" > "$work/rules.yaml" <<'PY'
import sys, yaml
for doc in yaml.safe_load_all(open(sys.argv[1])):
    if doc and doc.get("kind") == "PrometheusRule" and doc["metadata"]["name"].endswith("-map"):
        print(yaml.safe_dump({"groups": doc["spec"]["groups"]}, sort_keys=False))
PY
[ -s "$work/rules.yaml" ] || fail "could not extract the map rules from the chart"
promtool check rules "$work/rules.yaml" >/dev/null || fail "promtool rejected the rendered map rules"

# promtool's clock starts at unix 0. A timestamp series counting 60 per minute
# reads back the evaluation time, so `time() - series` is zero: rendered just
# now. One held at 0 makes that difference the evaluation time: a render that
# happened once and never again.
cat > "$work/tests.yaml" <<'TESTS'
rule_files:
  - rules.yaml
evaluation_interval: 1m
tests:
  # Rendering every cycle: nothing to say, however long it has been running.
  - interval: 1m
    input_series:
      - series: 'mcmap_render_last_success_timestamp_seconds{namespace="jdwillmsen-prd", dimension="overworld"}'
        values: '0+60x300'
    alert_rule_test:
      - eval_time: 5h
        alertname: JdwillmsenMinecraftMapStale
        exp_alerts: []
      - eval_time: 5h
        alertname: JdwillmsenMinecraftMapNeverRendered
        exp_alerts: []

  # Rendered once at the start and never again. Quiet through a normal night's
  # quiet windows, then firing once it is past the limit and the `for`.
  - interval: 1m
    input_series:
      - series: 'mcmap_render_last_success_timestamp_seconds{namespace="jdwillmsen-prd", dimension="overworld"}'
        values: '0+0x300'
    alert_rule_test:
      - eval_time: 1h45m
        alertname: JdwillmsenMinecraftMapStale
        exp_alerts: []
      - eval_time: 2h15m
        alertname: JdwillmsenMinecraftMapStale
        exp_alerts:
          - exp_labels:
              severity: warning
              namespace: jdwillmsen-prd
              dimension: overworld
            exp_annotations:
              summary: "The Minecraft FWB map has stopped refreshing"
              description: "The map has not finished rendering the overworld for more than 2h. It still serves the tiles it has, so the page looks fine and only its \"updated\" time gives it away. mcmap_snapshots_total by result says whether the bridge is refusing (busy), the copy is failing (failed), or the cycle is not running at all."

  # Never rendered at all: the gauge does not exist, the staleness rule has
  # nothing to subtract, and the absence rule is the only one that can speak.
  - interval: 1m
    input_series:
      - series: 'up{namespace="jdwillmsen-prd"}'
        values: '1+0x300'
    alert_rule_test:
      - eval_time: 2h15m
        alertname: JdwillmsenMinecraftMapStale
        exp_alerts: []
      - eval_time: 2h15m
        alertname: JdwillmsenMinecraftMapNeverRendered
        exp_alerts:
          - exp_labels:
              severity: warning
              namespace: jdwillmsen-prd
              dimension: overworld
            exp_annotations:
              summary: "The Minecraft FWB map has never rendered"
              description: "No overworld render has succeeded since the map pod started, or the pod is not being scraped. A first render on a fresh volume takes minutes, not 2h."

  # A snapshot in progress: owed for a few minutes, then paid. Normal.
  - interval: 1m
    input_series:
      - series: 'mc_console_bridge_snapshot_resume_owed{namespace="jdwillmsen-prd"}'
        values: '0+0x10 1+0x5 0+0x30'
    alert_rule_test:
      - eval_time: 16m
        alertname: JdwillmsenMinecraftSaveResumeOwed
        exp_alerts: []
      - eval_time: 30m
        alertname: JdwillmsenMinecraftSaveResumeOwed
        exp_alerts: []

  # Owed and never paid: every scrape for ten minutes reads 1.
  - interval: 1m
    input_series:
      - series: 'mc_console_bridge_snapshot_resume_owed{namespace="jdwillmsen-prd"}'
        values: '0+0x10 1+0x40'
    alert_rule_test:
      - eval_time: 15m
        alertname: JdwillmsenMinecraftSaveResumeOwed
        exp_alerts: []
      - eval_time: 25m
        alertname: JdwillmsenMinecraftSaveResumeOwed
        exp_alerts:
          - exp_labels:
              severity: critical
              namespace: jdwillmsen-prd
            exp_annotations:
              summary: "Minecraft FWB may have world saving paused"
              description: "The console bridge paused saving for a map snapshot and the server has not confirmed the resume for ten minutes. The bridge keeps retrying and refuses new snapshots meanwhile. Check the server log for \"Changes to the world are resumed\"; if it is missing, run `save resume` from the console. The nightly backup also resumes saving when it finishes."
TESTS

if ! out="$(cd "$work" && promtool test rules tests.yaml 2>&1)"; then
  echo "$out"
  fail "the map alert rules do not behave as specified"
fi

echo "PASS: map quiet windows cover the backup and census, and the map alerts fire when they should"
