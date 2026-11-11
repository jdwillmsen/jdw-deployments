#!/usr/bin/env bash
# tools/world-restore: what its pods may touch, and the refusals that need no cluster.
#
#  - the copy pod must never mount the live world, and the only pod that does (promote)
#    is pinned to the node holding that volume;
#  - the map's volume is mounted read-only, in the pod and in the container;
#  - nothing references a Secret: the tool never reads a credential.
set -euo pipefail

here="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

# World-restore: render its pods and check what they may touch.
tools="$here/tools/world-restore"
"$tools" --release jdwillmsen-minecraft-fwb-prd --level FWB --source generation:a --print-manifests > "$work/gen.jsonl"
"$tools" --release jdwillmsen-proving-grounds-prd --level proving-grounds --source scratch:good --print-manifests > "$work/scratch.jsonl"
python3 - "$work/gen.jsonl" "$work/scratch.jsonl" <<'PY' || fail "world-restore's pods are not safe"
import json, sys

def claims(pod):
    return {v["name"]: v["persistentVolumeClaim"] for v in pod["spec"]["volumes"] if "persistentVolumeClaim" in v}

for path, kind in ((sys.argv[1], "generation"), (sys.argv[2], "scratch")):
    pods = {m["metadata"]["name"]: m for m in map(json.loads, open(path))}
    rel = "jdwillmsen-minecraft-fwb-prd" if kind == "generation" else "jdwillmsen-proving-grounds-prd"
    assert set(pods) == {f"{rel}-restore-copy", f"{rel}-restore-verify", f"{rel}-restore-promote"}, f"pods are named for their release: {set(pods)}"
    pods = {n.rsplit("-restore-", 1)[1]: p for n, p in pods.items()}
    for name, pod in pods.items():
        sc = pod["spec"]["securityContext"]
        assert sc["runAsNonRoot"] is True and sc["runAsUser"] == 1000, (name, sc)
        text = json.dumps(pod)
        assert "secret" not in text.lower(), f"{name} mentions a secret"
        for c in pod["spec"]["containers"] + pod["spec"].get("initContainers", []):
            assert c["securityContext"]["allowPrivilegeEscalation"] is False, (name, c["name"])
    world = [n for n, p in pods.items() if any("datadir-" in c["claimName"] for c in claims(p).values())]
    assert world == ["promote"], f"only the promote pod may mount the live world: {world}"
    assert pods["promote"]["spec"]["nodeSelector"] == {"kubernetes.io/hostname": "NODE"}, "promote must be pinned to the world's node"
    cmd = pods["promote"]["spec"]["containers"][0]["command"]
    assert cmd[:2] == ["bash", "-c"] and "PROMOTED" in cmd[2], "the promote script must be the pod's own command, so a dropped session cannot stop it mid-swap"
    copy = claims(pods["copy"])
    if kind == "generation":
        assert copy["mapdata"]["claimName"].endswith("-map") and copy["mapdata"]["readOnly"] is True, "the map's volume must be read-only"
        mount = next(m for m in pods["copy"]["spec"]["containers"][0]["volumeMounts"] if m["name"] == "mapdata")
        assert mount["readOnly"] is True, mount
    else:
        assert set(copy) == {"scratch"}, copy
    assert set(claims(pods["verify"])) == {"scratch"}, "verify boots a copy on scratch only"
    v = pods["verify"]["spec"]["containers"][0]
    assert any(e["name"] == "LEVEL_NAME" and e["value"].endswith("-verify") for e in v["env"]), "verify must open a copy, never the staged world"
PY

# Refusals that must not need a cluster.
if "$tools" --release r --level L --source bogus --print-manifests >/dev/null 2>&1; then
  fail "world-restore accepted a source it does not understand"
fi
"$tools" --release r --level L --source generation:../etc --print-manifests >"$work/refused.log" 2>&1 && fail "world-restore accepted a path-shaped source"
grep -q 'plain directory name' "$work/refused.log" || fail "world-restore refused a path-shaped source for the wrong reason: $(cat "$work/refused.log")"
"$tools" --release r --level '../x' --source scratch:a --print-manifests >"$work/refused.log" 2>&1 && fail "world-restore accepted a path-shaped level"
grep -q 'plain world name' "$work/refused.log" || fail "world-restore refused a path-shaped level for the wrong reason"

# The two scripts that touch volumes, run for real against temporary directories (they
# take their roots from SCRATCH, WORLD and MAPDATA).
python3 - "$tools" "$work" <<'PY' || fail "the copy or promote script misbehaves"
import importlib.machinery, importlib.util, json, os, shutil, subprocess, sys, tempfile

loader = importlib.machinery.SourceFileLoader("world_restore", sys.argv[1])
spec = importlib.util.spec_from_loader("world_restore", loader)
wr = importlib.util.module_from_spec(spec)
loader.exec_module(wr)

def run(script, args, env):
    p = subprocess.run(["bash", "-c", script, "script", *args], env={**os.environ, **env}, capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr

def write(path, text="x"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)

def world(root, level, tag):
    write(f"{root}/{level}/db/CURRENT", "MANIFEST-1\n")
    write(f"{root}/{level}/db/000001.ldb", tag)
    write(f"{root}/{level}/behavior_packs/my pack/manifest.json", tag)  # a space in a name
    write(f"{root}/{level}/level.dat", tag)

base = tempfile.mkdtemp()
try:
    scratch, mapdata, vol = f"{base}/scratch", f"{base}/map", f"{base}/vol"
    env = {"SCRATCH": scratch, "MAPDATA": mapdata, "WORLD": vol}
    os.makedirs(scratch)
    # --- copy from a generation
    world(f"{mapdata}/generations/a", "FWB", "good")
    write(f"{mapdata}/generations/a/generation.json", '{"takenAt":"2026-01-01T00:00:00Z"}')
    rc, out = run(wr.COPY_SCRIPT, ["FWB", "generation", "a", "2026-01-01T00:00:00Z", "false"], env)
    assert rc == 0 and os.path.isfile(f"{scratch}/FWB/db/000001.ldb"), out
    rc, out = run(wr.COPY_SCRIPT, ["FWB", "generation", "a", "", "false"], env)
    assert rc != 0 and "already exists" in out, "an existing staged world must not be overwritten silently"
    rc, out = run(wr.COPY_SCRIPT, ["FWB", "generation", "a", "2030-01-01T00:00:00Z", "true"], env)
    assert rc != 0 and "no longer holds" in out and os.path.isdir(f"{scratch}/FWB"), "a slot that changed must be refused before anything is removed"
    rc, out = run(wr.COPY_SCRIPT, ["FWB", "generation", "nope", "", "true"], env)
    assert rc != 0 and "not a complete generation" in out, out
    # --- copy from scratch:DIR
    shutil.rmtree(f"{scratch}/FWB")
    world(f"{scratch}/good", "FWB", "good")
    rc, out = run(wr.COPY_SCRIPT, ["FWB", "scratch", "good", "", "false"], env)
    assert rc == 0 and os.path.isdir(f"{scratch}/FWB/db"), out
    # --- promote
    world(f"{vol}/worlds", "FWB", "damaged")
    rc, out = run(wr.PROMOTE_SCRIPT, ["FWB", "T1"], env)
    assert rc == 0 and out.rstrip().endswith("PROMOTED"), out
    assert open(f"{vol}/worlds/FWB/db/000001.ldb").read() == "good"
    assert open(f"{vol}/worlds/FWB/behavior_packs/my pack/manifest.json").read() == "good"
    aside = f"{scratch}/FWB-damaged-T1"
    assert open(f"{aside}/db/000001.ldb").read() == "damaged", "the damaged world must be kept"
    assert not os.path.exists(f"{vol}/worlds/FWB-outgoing") and not os.path.exists(f"{vol}/worlds/FWB-incoming")
    # --- a second promote with the same stamp refuses and touches nothing
    rc, out = run(wr.PROMOTE_SCRIPT, ["FWB", "T1"], env)
    assert rc != 0 and "already exists" in out and open(f"{vol}/worlds/FWB/db/000001.ldb").read() == "good", out
    # --- a stale outgoing directory means an earlier swap stopped half way: refuse
    os.makedirs(f"{vol}/worlds/FWB-outgoing")
    rc, out = run(wr.PROMOTE_SCRIPT, ["FWB", "T2"], env)
    assert rc != 0 and "Do not re-run" in out, out
    # --- a files-with-spaces difference must show up in the manifest comparison
    shutil.rmtree(f"{vol}/worlds/FWB-outgoing")
    write(f"{scratch}/FWB/behavior_packs/my pack/manifest.json", "good")
    rc, out = run(wr.PROMOTE_SCRIPT, ["FWB", "T3"], env)
    assert rc == 0 and "PROMOTED" in out, out
finally:
    shutil.rmtree(base, ignore_errors=True)

# The same scripts with a hand in the way: a wrapper around cp that damages what it just
# copied, one that fails sha256sum, and one that rewrites the generation marker mid-copy.
# Each must stop the script with the live world untouched. Without these, deleting the
# comparisons they guard would leave every other test green.
bin_dir = tempfile.mkdtemp()
try:
    with open(f"{bin_dir}/cp", "w") as f:
        f.write("""#!/bin/sh
/bin/cp "$@" || exit $?
for d; do :; done
if [ -n "${CORRUPT_GLOB:-}" ]; then case "$d" in $CORRUPT_GLOB) echo junk >> "$d/db/000001.ldb";; esac; fi
if [ -n "${TOUCH_MARKER:-}" ]; then echo changed >> "$TOUCH_MARKER"; fi
""")
    with open(f"{bin_dir}/sha256sum", "w") as f:
        f.write('#!/bin/sh\n[ -n "${FAIL_SHA:-}" ] && exit 1\nexec /usr/bin/sha256sum "$@"\n')
    with open(f"{bin_dir}/mv", "w") as f:
        f.write("""#!/bin/sh
/bin/mv "$@" || exit $?
for d; do :; done
if [ -n "${MV_CORRUPT:-}" ]; then case "$d" in *-outgoing) echo junk >> "$d/db/000001.ldb";; esac; fi
""")
    os.chmod(f"{bin_dir}/mv", 0o755)
    os.chmod(f"{bin_dir}/cp", 0o755)
    os.chmod(f"{bin_dir}/sha256sum", 0o755)

    def fresh():
        base = tempfile.mkdtemp()
        scratch, vol, mapdata = f"{base}/scratch", f"{base}/vol", f"{base}/map"
        world(scratch, "FWB", "good")
        world(f"{vol}/worlds", "FWB", "damaged")
        world(f"{mapdata}/generations/a", "FWB", "good")
        write(f"{mapdata}/generations/a/generation.json", '{"takenAt":"T"}')
        env = {"SCRATCH": scratch, "WORLD": vol, "MAPDATA": mapdata, "PATH": bin_dir + ":" + os.environ["PATH"]}
        return base, scratch, vol, mapdata, env

    def live_untouched(vol):
        return (open(f"{vol}/worlds/FWB/db/000001.ldb").read() == "damaged"
                and not os.path.exists(f"{vol}/worlds/FWB-outgoing"))

    for glob_, expect in (("*-damaged-*", "differs from the live world"), ("*-incoming", "does not match the restored copy")):
        base, scratch, vol, mapdata, env = fresh()
        try:
            rc, out = run(wr.PROMOTE_SCRIPT, ["FWB", "T1"], {**env, "CORRUPT_GLOB": glob_})
            assert rc != 0 and expect in out and live_untouched(vol), (glob_, out)
            assert "PROMOTED" not in out
        finally:
            shutil.rmtree(base, ignore_errors=True)

    base, scratch, vol, mapdata, env = fresh()
    try:
        rc, out = run(wr.PROMOTE_SCRIPT, ["FWB", "T1"], {**env, "MV_CORRUPT": "1"})
        assert rc != 0 and "keeping" in out and os.path.isdir(f"{vol}/worlds/FWB-outgoing"), \
            "the outgoing world must be kept when it no longer matches the aside copy: " + out
        assert open(f"{vol}/worlds/FWB/db/000001.ldb").read() == "good"
    finally:
        shutil.rmtree(base, ignore_errors=True)

    base, scratch, vol, mapdata, env = fresh()
    try:
        rc, out = run(wr.PROMOTE_SCRIPT, ["FWB", "T1"], {**env, "FAIL_SHA": "1"})
        assert rc != 0 and live_untouched(vol) and "PROMOTED" not in out, "a failing sha256sum must stop the promotion (pipefail)"
    finally:
        shutil.rmtree(base, ignore_errors=True)

    base, scratch, vol, mapdata, env = fresh()
    try:
        shutil.rmtree(f"{scratch}/FWB")
        rc, out = run(wr.COPY_SCRIPT, ["FWB", "generation", "a", "", "false"], {**env, "TOUCH_MARKER": f"{mapdata}/generations/a/generation.json"})
        assert rc != 0 and "changed while it was being copied" in out and not os.path.exists(f"{scratch}/FWB"), out
    finally:
        shutil.rmtree(base, ignore_errors=True)
finally:
    shutil.rmtree(bin_dir, ignore_errors=True)
PY

# The orchestration, against a fake kubectl that logs every call and answers from a scenario.
# What matters is which calls were made, and which were not.
cat > "$work/kubectl" <<'FAKE'
#!/usr/bin/env python3
import json, os, sys

state_dir = os.environ["FAKE_DIR"]
sc = json.load(open(f"{state_dir}/scenario.json"))
args = sys.argv[1:]
if args[:1] == ["-n"]:
    args = args[2:]
stdin = sys.stdin.read() if ("-i" in args or args[:2] == ["create", "-f"]) else ""
with open(f"{state_dir}/calls.log", "a") as f:
    f.write(json.dumps(args) + "\n")
replicas_file = f"{state_dir}/replicas"
if not os.path.exists(replicas_file):
    open(replicas_file, "w").write("1")
replicas = open(replicas_file).read()
verb = args[0]
joined = " ".join(args)

def out(text="", rc=0):
    sys.stdout.write(text)
    sys.exit(rc)

if verb == "scale":
    if "--replicas=1" in joined and sc.get("scale_up_fails"):
        sys.stderr.write("api blip\n"); sys.exit(1)
    if "sts" in args:
        open(replicas_file, "w").write(args[-1].split("=")[1])
    out()
if verb in ("wait", "delete"):
    out()
if verb == "create":
    out()
if verb == "get":
    kind, name = args[1], args[2]
    jp = next((a for a in args if a.startswith("jsonpath=") or a == "json"), "")
    if "-o" in args and args[args.index("-o") + 1] == "json":
        out(json.dumps({"spec": {"template": {"spec": {"containers": [{"name": "srv", "image": "img:1", "env": [{"name": "VERSION", "value": "1.2.3"}], "resources": {"limits": {"cpu": "1", "memory": "1Gi"}}}],
                                                      "affinity": {"nodeAffinity": {"requiredDuringSchedulingIgnoredDuringExecution": {"nodeSelectorTerms": [{"matchExpressions": [{"key": "kubernetes.io/hostname", "operator": "In", "values": ["node1"]}]}]}}}}}}}))
    path = jp.split("=", 1)[1] if jp else ""
    if kind == "sts":
        out(name if path == "{.metadata.name}" else replicas)
    if kind == "pvc":
        out("Bound")
    if kind == "deploy":
        out("1")
    if kind == "pod":
        if args[2] == "-l":
            out("node1")
        if path == "{.metadata.name}":
            out(name if replicas != "0" or "promote" in name else "", 0 if (replicas != "0" or "promote" in name) else 1)
        if path == "{.spec.nodeName}":
            out("node1")
        if path == "{.status.phase}":
            out(sc.get("promote_phase", "Succeeded") if "promote" in name else "Running")
    out()
if verb == "logs":
    name = args[1]
    if "promote" in name:
        out(sc.get("promote_log", "== before\n== swapping\nPROMOTED\n"))
    if "verify" in name:
        out(sc.get("verify_log", "[INFO] Server started.\n"))
    if "-c" in args and args[args.index("-c") + 1] == "world-guard":
        out(sc.get("guard_log", 'world-guard: {"event": "clean"}\n'))
    out(sc.get("server_log", "[INFO] Server started.\n"))
if verb == "exec":
    if "python3" in args:
        out(json.dumps(sc.get("check", {"status": "clean", "live_tables": 5, "problems": []})), sc.get("check_rc", 0))
    out("copied\n", sc.get("copy_rc", 0))
out()
FAKE
chmod +x "$work/kubectl"

python3 - "$tools" "$work" <<'PY' || fail "the restore orchestration does the wrong thing"
import json, os, subprocess, sys, tempfile

tools, work = sys.argv[1:3]

def run(scenario, *extra):
    d = tempfile.mkdtemp()
    json.dump(scenario, open(f"{d}/scenario.json", "w"))
    env = {**os.environ, "PATH": work + ":" + os.environ["PATH"], "FAKE_DIR": d}
    p = subprocess.run([tools, "--release", "rel", "--level", "FWB", "--source", "scratch:good", "--verify-timeout", "1",
                        "--up-timeout", "1", "--promote-timeout", "1", *extra], env=env, capture_output=True, text=True, timeout=120)
    calls = [json.loads(l) for l in open(f"{d}/calls.log")]
    return p.returncode, p.stdout, calls

def created(calls, what):
    return [c for c in calls if c[:2] == ["create", "-f"]] and False

def made(calls, word):
    # pods are created by name through `create -f -`; the fake logs the verb only, so look at deletes
    # (create_pod deletes the name first) and at the exec/logs/wait calls that follow
    return any(word in " ".join(c) for c in calls)

# plan only: nothing is scaled or created
rc, out, calls = run({})
assert rc == 0 and "plan (nothing changed)" in out and not any(c[0] in ("scale", "create") for c in calls), out

# happy path
rc, out, calls = run({}, "--yes")
assert rc == 0 and "RESTORED" in out, out
scales = [c for c in calls if c[0] == "scale"]
assert scales[0][-1] == "--replicas=0" and scales[-1][-1] == "--replicas=1", scales

# the source is not a clean database: stop before the verify boot and the promote
rc, out, calls = run({"check": {"status": "absent", "problems": []}}, "--yes")
assert rc == 1 and "not a clean, non-empty database" in out and not made(calls, "rel-restore-promote") and not made(calls, "rel-restore-verify"), out
assert "scaled to 0" in out, "must say the server was left scaled down"
rc, out, calls = run({"check": {"status": "damaged", "live_tables": 3, "problems": [{"kind": "zero-byte"}]}, "check_rc": 1}, "--yes")
assert rc == 1 and not made(calls, "rel-restore-promote"), out

# the copy script refuses
rc, out, calls = run({"copy_rc": 1}, "--yes")
assert rc == 1 and not made(calls, "rel-restore-verify") and not made(calls, "rel-restore-promote"), out

# the verify boot logs corruption or never starts: nothing is promoted
for log in ("[INFO] LevelDB worlds/FWB-verify/db status NOT OK(Corruption: 3 missing files). Trying repair.\n", "[INFO] Version: 1.2.3\n"):
    rc, out, calls = run({"verify_log": log}, "--yes")
    assert rc == 1 and not made(calls, "rel-restore-promote"), out

# a failure to scale up AFTER the swap must not claim the live world is untouched
rc, out, calls = run({"scale_up_fails": True}, "--yes")
assert rc == 2 and "may have been replaced" in out and "has not been touched" not in out, out

# the server comes back but the guard did not call the world clean
rc, out, calls = run({"guard_log": 'world-guard: {"event": "held"}\\n'}, "--yes")
assert rc == 2 and "not 'clean'" in out, out

# a promote that logs FATAL after starting the swap
rc, out, calls = run({"promote_phase": "Failed", "promote_log": "== before\n== swapping\nFATAL: live world does not match\n"}, "--yes")
assert rc == 2 and "Do not re-run" in out, out

# a promote pod that never starts is removed, and the live world is said to be untouched
rc, out, calls = run({"promote_phase": "Pending", "promote_log": ""}, "--yes")
assert rc == 1 and "never started" in out and "has not been touched" in out, out
assert any(c[0] == "delete" and "rel-restore-promote" in c for c in calls[-6:]), calls[-6:]

# a promote pod still running at the deadline: say do not scale up
rc, out, calls = run({"promote_phase": "Running", "promote_log": "== before\n"}, "--yes")
assert rc == 2 and "STILL RUNNING" in out, out

# refusals at the argument level
for bad in ("scratch:FWB", "scratch:FWB-verify", "scratch:FWB-damaged-T1"):
    d = tempfile.mkdtemp()
    json.dump({}, open(f"{d}/scenario.json", "w"))
    p = subprocess.run([tools, "--release", "rel", "--level", "FWB", "--source", bad, "--yes"],
                       env={**os.environ, "PATH": work + ":" + os.environ["PATH"], "FAKE_DIR": d}, capture_output=True, text=True)
    assert p.returncode == 1 and "manages" in p.stdout, (bad, p.stdout)
PY

echo "PASS: assisted restore"
