#!/usr/bin/env bash
# Renders the crew-lab chart and checks the nightly field rebuild: off unless
# the overlay turns it on, RBAC limited to the lab server's pod, a CronJob that
# cannot overlap itself, and non-human player patterns that match the chart's
# units and its load-test bots.
set -euo pipefail

here="$(cd "$(dirname "$0")/../.." && pwd)"
chart="$here/charts/crew-lab"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

render() { helm template jdwillmsen-crew-lab-prd "$chart" --namespace jdwillmsen-prd "$@"; }

render -f "$chart/values.yaml" > "$work/base.yaml"
if grep -q 'lab-field-rebuild' "$work/base.yaml"; then
  fail "the rebuild renders without the overlay enabling it"
fi

render -f "$chart/values.yaml" -f "$chart/values-prd.yaml" > "$work/prd.yaml"

python3 - "$work/prd.yaml" <<'PY' || fail "the lab rebuild is not rendered as expected"
import sys, yaml

docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
named = lambda kind: [d for d in docs if d.get("kind") == kind and d["metadata"]["name"] == "lab-field-rebuild"]

(cj,), (role,), (rb,), (sa,) = named("CronJob"), named("Role"), named("RoleBinding"), named("ServiceAccount")

spec = cj["spec"]
assert spec["concurrencyPolicy"] == "Forbid"
assert spec["schedule"] == "15 8 * * *", spec["schedule"]
assert spec["startingDeadlineSeconds"] > 0
job = spec["jobTemplate"]["spec"]
assert job["backoffLimit"] == 0
assert 0 < job["activeDeadlineSeconds"] <= 3600, job["activeDeadlineSeconds"]
pod = job["template"]["spec"]
assert pod["serviceAccountName"] == "lab-field-rebuild"

server = "jdwillmsen-crew-lab-prd-minecraft-bedrock-0"
for rule in role["rules"]:
    assert rule["apiGroups"] == [""], rule
    assert rule["resourceNames"] == [server], rule
allowed = {(r, v) for rule in role["rules"] for r in rule["resources"] for v in rule["verbs"]}
assert allowed == {("pods", "get"), ("pods/exec", "create"), ("pods/log", "get")}, allowed
assert rb["roleRef"]["name"] == "lab-field-rebuild"
assert rb["subjects"] == [{"kind": "ServiceAccount", "name": "lab-field-rebuild", "namespace": "jdwillmsen-prd"}]

crew = [d for d in docs if d.get("kind") == "Deployment"
        and d["metadata"].get("labels", {}).get("app.kubernetes.io/component") == "crew"]
(init,) = pod["initContainers"]
(main,) = pod["containers"]
img = [c["image"] for c in [d["spec"]["template"]["spec"]["containers"][0] for d in crew]]
assert init["image"] in img, "the plans come from a different image than the units run"
assert init["command"][:3] == ["/labcourses", "-o", "/work"] and init["command"][3:] == ["grounds", "courses", "trees", "works"], init["command"]

env = {e["name"]: e["value"] for e in main["env"]}
assert env["FIELDS"] == "grounds courses trees works"
assert env["LAB"] == f"k8s:jdwillmsen-prd/{server}", env["LAB"]
units = {e["value"] for d in crew for e in d["spec"]["template"]["spec"]["containers"][0]["env"] if e["name"] == "MC_USERNAME"}
assert set(env["NON_HUMAN"].split()) == units | {"load-*"} and len(units) == 22, env["NON_HUMAN"]
assert main["command"] == ["/work/nightly.sh"]

for c in (init, main):
    sc = c["securityContext"]
    assert sc["readOnlyRootFilesystem"] and sc["allowPrivilegeEscalation"] is False
    assert sc["capabilities"]["drop"] == ["ALL"]
    assert c["resources"]["limits"]["memory"] and c["resources"]["requests"]["memory"], c["name"]
assert pod["securityContext"]["runAsNonRoot"] is True
# The quota's memory limits are nearly spent; the job must stay small.
mem = sum(int(c["resources"]["limits"]["memory"][:-2]) for c in (init, main))
assert mem <= 256, f"limits.memory totals {mem}Mi"
PY

echo "PASS: lab field rebuild"
