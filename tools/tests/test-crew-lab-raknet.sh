#!/usr/bin/env bash
# Renders the crew-lab chart with and without values-raknet.yaml. Without it the
# lab serves NetherNet and the three warriors join signed in; with it the lab is
# back on RakNet, every unit joins offline at the service address, and nothing
# of the NetherNet setup is left behind. Also checks the overlay is listed after
# values-prd.yaml, which is what makes it win.
set -euo pipefail

here="$(cd "$(dirname "$0")/../.." && pwd)"
chart="$here/charts/crew-lab"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

helm template crew-lab "$chart" --namespace jdwillmsen-prd \
  -f "$chart/values.yaml" -f "$chart/values-prd.yaml" > "$work/nethernet.yaml"
helm template crew-lab "$chart" --namespace jdwillmsen-prd \
  -f "$chart/values.yaml" -f "$chart/values-prd.yaml" -f "$chart/values-raknet.yaml" > "$work/raknet.yaml"

python3 - "$work/nethernet.yaml" "$work/raknet.yaml" "$here/argocd/prd/config.yaml" <<'PY' || fail "the RakNet overlay is not what it should be"
import sys, yaml

def load(path):
    return [d for d in yaml.safe_load_all(open(path)) if d]

def server(docs):
    ss = next(d for d in docs if d["kind"] == "StatefulSet" and d["metadata"]["name"].endswith("-minecraft-bedrock"))
    c = ss["spec"]["template"]["spec"]["containers"][0]
    return c, {e["name"]: e.get("value") for e in c["env"]}

def units(docs):
    out = {}
    for d in docs:
        n = d["metadata"]["name"]
        if d["kind"] == "Deployment" and n.startswith("crew-") and n != "crew-control":
            c = d["spec"]["template"]["spec"]["containers"][0]
            out[n] = {e["name"]: e.get("value") for e in c["env"]}
    return out

base, over, cfg = load(sys.argv[1]), load(sys.argv[2]), sys.argv[3]

# --- without the overlay: NetherNet, as live
c, env = server(base)
assert env["TRANSPORT"] == "nethernet", env["TRANSPORT"]
assert env["SERVER_UDP_PORTS"], "the NetherNet gameplay range is pinned"
assert any(d["kind"] == "Service" and d["metadata"]["name"].endswith("-nethernet") for d in base)
ub = units(base)
for u in ("crew-18", "crew-19", "crew-20"):
    assert ub[u]["MC_HOST"].startswith("http") and ub[u]["MC_OFFLINE"] == "false", (u, ub[u]["MC_HOST"], ub[u]["MC_OFFLINE"])

# --- with the overlay: RakNet, every unit offline at the service address
c, env = server(over)
assert env["TRANSPORT"] == "raknet", env["TRANSPORT"]
# set-property ignores an empty value, so the env var must carry none (a value would rewrite the range)
assert not env.get("SERVER_UDP_PORTS"), env.get("SERVER_UDP_PORTS")
sp = c.get("startupProbe")
assert sp, "the startup probe is back"
assert (sp["initialDelaySeconds"], sp["periodSeconds"], sp["failureThreshold"]) == (30, 10, 60), sp
live = c["livenessProbe"]["initialDelaySeconds"]
assert int(live) == 30, f"liveness delay must be the normal 30s, not a year: {live}"
assert not any(d["kind"] == "Service" and d["metadata"]["name"].endswith("-nethernet") for d in over), "the NetherNet Service goes"
uo = units(over)
assert len(uo) == 22, len(uo)
for u, e in uo.items():
    assert not e["MC_HOST"].startswith("http"), (u, e["MC_HOST"])
    assert e["MC_PORT"] == "31136" and e["MC_OFFLINE"] == "true", (u, e["MC_PORT"], e["MC_OFFLINE"])
# the warriors keep their squad and the training switch mount; only the transport changed
for u in ("crew-18", "crew-19", "crew-20"):
    assert uo[u]["CREW_SQUAD"] == "lab-alpha" and uo[u]["TACTICS_CONTROL_DIR"] == "/etc/crew-tactics-control", u

# --- the overlay is listed after values-prd.yaml for the lab app
apps = yaml.safe_load(open(cfg))["apps"]
vf = next(a for a in apps if a["name"] == "crew-lab-prd")["valueFiles"]
import os
chart_dir = os.path.join(os.path.dirname(os.path.dirname(cfg)), os.pardir, "charts", "crew-lab")
for f in vf:
    assert os.path.exists(os.path.join(chart_dir, f)), f"{f} is listed for crew-lab-prd but does not exist"
if "values-raknet.yaml" in vf:
    assert vf.index("values-raknet.yaml") > vf.index("values-prd.yaml"), vf
print("ok")
PY
echo "PASS"
