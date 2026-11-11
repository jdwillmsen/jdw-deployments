#!/usr/bin/env bash
# The world guard's two pages fire on the finding they exist for and on nothing else.
#
#  * JdwillmsenMinecraftWorldGuardHeld reads the cluster's state metrics: the guard
#    container is *running* only while it holds. promtool drives it with a clean
#    start (the guard runs for two seconds), a hold, a hold that is released, and a
#    one-off pod that must not raise it.
#  * JdwillmsenMinecraftWorldGuardWouldHold reads the guard's own log line through
#    Loki. promtool cannot evaluate LogQL, so the case that matters is checked the
#    other way round: the line the guard really prints is run through the rule's
#    regular expression, and so are lines it must not match.
set -euo pipefail

here="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

chart="$here/charts/minecraft-fwb"
helm template jdwillmsen-minecraft-fwb-prd "$chart" --namespace jdwillmsen-prd \
  -f "$chart/values.yaml" -f "$chart/values-prd.yaml" > "$work/rendered.yaml"

python3 - "$work/rendered.yaml" "$work" <<'PY' || fail "could not extract the world-guard rules from the chart"
import sys, yaml

docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
prom = [d for d in docs if d["kind"] == "PrometheusRule" and d["metadata"]["name"].endswith("-world-guard")]
loki = [d for d in docs if d["kind"] == "ConfigMap" and d["metadata"]["name"].endswith("-world-guard-loki-rules")]
assert len(prom) == 1 and len(loki) == 1, (len(prom), len(loki))
open(f"{sys.argv[2]}/rules.yaml", "w").write(yaml.safe_dump({"groups": prom[0]["spec"]["groups"]}, sort_keys=False))
inner = yaml.safe_load(next(iter(loki[0]["data"].values())))
open(f"{sys.argv[2]}/loki.yaml", "w").write(yaml.safe_dump(inner, sort_keys=False))
assert loki[0]["metadata"]["labels"] == {"loki_rule": "true"}, loki[0]["metadata"]["labels"]
PY

# The Loki arm: the line the guard prints, against the rule's own expression.
python3 - "$work/loki.yaml" "$here/tools/world-guard" <<'PY' || fail "the would_hold Loki rule does not match the line the guard prints"
import contextlib, io, json, os, re, shutil, sys, tempfile, yaml

rule = yaml.safe_load(open(sys.argv[1]))["groups"][0]["rules"][0]
assert rule["alert"] == "JdwillmsenMinecraftWorldGuardWouldHold" and rule["labels"]["severity"] == "critical", rule
expr = rule["expr"]
m = re.search(r"\{namespace=\"([^\"]+)\", container=\"([^\"]+)\"\} \|= `([^`]+)` \|~ `([^`]+)` \[(\w+)\]", expr)
assert m, expr
ns, container, contains, pattern, window = m.groups()
assert contains == "worlds/FWB/db", contains
assert (ns, container) == ("jdwillmsen-prd", "world-guard"), (ns, container)
assert window.endswith("m") or window.endswith("h"), window

sys.path.insert(0, sys.argv[2])
import world_guard as wg

def line(mode, damaged):
    root = tempfile.mkdtemp()
    try:
        db = os.path.join(root, "worlds", "FWB", "db")
        os.makedirs(db)
        if damaged:
            with open(os.path.join(db, "000005.ldb"), "wb") as f:
                f.write(b"x" * 10)
            with open(os.path.join(db, "CURRENT"), "w") as f:
                f.write("MANIFEST-000001\n")
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            wg.guard({"DATA_DIR": root, "LEVEL_NAME": "FWB", "GUARD_MODE": mode, "RECHECK_SECONDS": "1"}, sleep=lambda s: None)
        return buf.getvalue().splitlines()[0]
    finally:
        shutil.rmtree(root, ignore_errors=True)

rx = re.compile(pattern)
selects = lambda ln: contains in ln and rx.search(ln)
hit = line("warn", True)
assert json.loads(hit.split(": ", 1)[1])["event"] == "would_hold", hit
assert selects(hit), f"the rule's filters miss the real would_hold line: {hit}"
other_world = hit.replace("worlds/FWB/db", "worlds/proving-grounds/db")
for quiet in (line("warn", False), 'chat: <steve> world-guard: {"event": "would_hold"}',
              '[2026-11-11 00:00:00:000 INFO] note "event": "would_hold"', 'world-guard: {"event": "held"}', other_world):
    assert not selects(quiet), f"the rule would page on {quiet!r}"
PY

if ! command -v promtool >/dev/null 2>&1; then
  echo "SKIP: promtool not on PATH; the Held rule is not unit-tested (the Loki arm above ran)"
  echo "PASS: world guard alerts (Loki arm only)"
  exit 0
fi
promtool check rules "$work/rules.yaml" >/dev/null || fail "promtool rejected the rendered rules"

pod='jdwillmsen-minecraft-fwb-prd-minecraft-bedrock-0'
sel() { echo "kube_pod_init_container_status_running{namespace=\"jdwillmsen-prd\",pod=\"$1\",container=\"$2\"}"; }
cat > "$work/test.yaml" <<YAML
rule_files:
  - rules.yaml
evaluation_interval: 1m
tests:
  # A clean start: the guard container runs for a few seconds and is gone.
  - interval: 30s
    name: a clean check does not page
    input_series:
      - series: '$(sel "$pod" world-guard)'
        values: '0 1 0 0 0 0 0 0 0 0 0 0 0 0'
    alert_rule_test:
      - eval_time: 6m
        alertname: JdwillmsenMinecraftWorldGuardHeld
        exp_alerts: []

  # A hold: running and staying running.
  - interval: 30s
    name: a hold pages after the patience
    input_series:
      - series: '$(sel "$pod" world-guard)'
        values: '1x40'
    alert_rule_test:
      - eval_time: 2m
        alertname: JdwillmsenMinecraftWorldGuardHeld
        exp_alerts: []
      - eval_time: 5m
        alertname: JdwillmsenMinecraftWorldGuardHeld
        exp_alerts:
          - exp_labels:
              severity: critical
              namespace: jdwillmsen-prd
            exp_annotations:
              summary: "Minecraft FWB is held before its world opens"
              description: "The world guard found tables the database's MANIFEST names that are missing, empty or the wrong size, and is holding the server in Init so it cannot repair them away. Nobody can join until this is resolved. The guard's log line and /data/.world-guard/report.json name the files and the bytes. Restore a good world with tools/world-restore (preferred), or let the server repair and accept the loss with \`touch /data/.world-guard-accept\` in the world-guard container, and log which on JDW-341. Do not delete the pod. charts/minecraft-fwb/README.md, \"World guard held\"."
              runbook_url: "https://github.com/jdwillmsen/jdw-deployments/blob/main/charts/minecraft-fwb/README.md#world-guard-held"

  # Resolved: the world was restored, the guard passed and exited.
  - interval: 30s
    name: a released hold stops paging
    input_series:
      - series: '$(sel "$pod" world-guard)'
        values: '1x14 0x30'
    alert_rule_test:
      - eval_time: 6m
        alertname: JdwillmsenMinecraftWorldGuardHeld
        exp_alerts:
          - exp_labels:
              severity: critical
              namespace: jdwillmsen-prd
            exp_annotations:
              summary: "Minecraft FWB is held before its world opens"
              description: "The world guard found tables the database's MANIFEST names that are missing, empty or the wrong size, and is holding the server in Init so it cannot repair them away. Nobody can join until this is resolved. The guard's log line and /data/.world-guard/report.json name the files and the bytes. Restore a good world with tools/world-restore (preferred), or let the server repair and accept the loss with \`touch /data/.world-guard-accept\` in the world-guard container, and log which on JDW-341. Do not delete the pod. charts/minecraft-fwb/README.md, \"World guard held\"."
              runbook_url: "https://github.com/jdwillmsen/jdw-deployments/blob/main/charts/minecraft-fwb/README.md#world-guard-held"
      - eval_time: 12m
        alertname: JdwillmsenMinecraftWorldGuardHeld
        exp_alerts: []

  # Another pod's container with the same name (the restore tool's pods, a copy
  # of the release) is not the server.
  - interval: 30s
    name: another pod running a container called world-guard does not page
    input_series:
      - series: '$(sel restore-verify world-guard)'
        values: '1x40'
      - series: '$(sel "$pod" install-map-pack)'
        values: '1x40'
    alert_rule_test:
      - eval_time: 10m
        alertname: JdwillmsenMinecraftWorldGuardHeld
        exp_alerts: []
YAML
cp "$work/rules.yaml" "$work/rules-copy.yaml"
( cd "$work" && promtool test rules test.yaml ) >"$work/promtool.log" 2>&1 \
  || { cat "$work/promtool.log"; fail "promtool: the Held rule does not behave"; }

echo "PASS: world guard alerts"
