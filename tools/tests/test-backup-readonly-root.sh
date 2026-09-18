#!/usr/bin/env bash
# Pins the read-only root filesystem on the backup and restore jobs, and the
# staging path that makes it survivable.
#
# These are a pair, and the failure when they come apart is silent until the
# next backup runs. readOnlyRootFilesystem stops the container writing to the
# image, so the backup's staging copy -- the whole world, larger than the
# archive it produces -- has to live on the backup claim. `mktemp -d` with no
# argument puts it under /tmp instead, which is either a read-only failure or,
# if someone "fixes" that by enlarging the emptyDir, a world-sized write to node
# ephemeral storage by the job whose whole purpose is protecting that node's
# server.
#
# Neither half is wrong on its own, and nothing else notices: helm renders a
# bare mktemp just as happily, ArgoCD syncs it, and the CronJob only fails at
# 04:00 the next morning.
#
# Read from the rendered chart rather than the values file, so an override from
# any layer is caught rather than the one layer this was written against.
set -euo pipefail

here="$(cd "$(dirname "$0")/../.." && pwd)"
chart="$here/charts/minecraft-fwb"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

helm template minecraft-fwb "$chart" \
  -f "$chart/values.yaml" \
  -f "$chart/values-prd.yaml" > "$work/rendered.yaml"
[ -s "$work/rendered.yaml" ] || fail "the chart rendered nothing"

cat > "$work/check-readonly.py" <<'CHECK'
import sys, yaml

docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
jobs = {}
for d in docs:
    if d.get("kind") != "CronJob":
        continue
    name = d["metadata"]["name"]
    if not (name.endswith("-backup") or name.endswith("-restore")):
        continue
    jobs[name] = d["spec"]["jobTemplate"]["spec"]["template"]["spec"]

assert jobs, "no backup or restore CronJob rendered, so this suite checks nothing"

for name, spec in jobs.items():
    for c in spec["containers"]:
        sc = c.get("securityContext") or {}
        assert sc.get("readOnlyRootFilesystem") is True, (
            f"{name}: readOnlyRootFilesystem is {sc.get('readOnlyRootFilesystem')!r}; "
            "the container may write to its image"
        )

        mounts = {m["mountPath"]: m["name"] for m in c.get("volumeMounts") or []}
        volumes = {v["name"]: v for v in spec.get("volumes") or []}

        # A read-only root and a script that writes anywhere outside a mount is
        # a job that fails on its next run, so every writable path it uses has
        # to be backed by something.
        script = " ".join(c.get("args") or [])

        if "mktemp -d" in script:
            assert "mktemp -d /backup/" in script, (
                f"{name}: stages through a bare `mktemp -d`, which lands on /tmp. "
                "The staging copy is the whole world; it belongs on the backup claim"
            )

        if "/tmp/" in script:
            assert "/tmp" in mounts, (
                f"{name}: writes under /tmp with a read-only root and nothing mounted there"
            )
            vol = volumes.get(mounts["/tmp"], {})
            assert "emptyDir" in vol, (
                f"{name}: /tmp is backed by {sorted(set(vol) - {'name'})}, expected an emptyDir"
            )
            # Bounded on purpose. Unbounded, a regression that put the world
            # here instead of on the claim would fill the node rather than fail
            # the job.
            assert vol["emptyDir"].get("sizeLimit"), (
                f"{name}: the /tmp emptyDir has no sizeLimit, so a staging regression "
                "would consume node ephemeral storage instead of failing"
            )

print("  ok: backup and restore run read-only, and stage where they have room")
CHECK

python3 "$work/check-readonly.py" "$work/rendered.yaml" || fail "the rendered chart does not satisfy the check"

# Negative controls. A check that cannot fail is not a check, and each mutation
# below is a shape this has to reject by name rather than by accident.
mutate() {
  local which="$1"
  local dst="$work/mutant-$which.yaml"
  python3 - "$work/rendered.yaml" "$dst" "$which" <<'MUTATE'
import sys, yaml

src, dst, which = sys.argv[1], sys.argv[2], sys.argv[3]
docs = [d for d in yaml.safe_load_all(open(src)) if d]
touched = 0
for doc in docs:
    if doc.get("kind") != "CronJob":
        continue
    name = doc["metadata"]["name"]
    if not name.endswith("-backup"):
        continue
    spec = doc["spec"]["jobTemplate"]["spec"]["template"]["spec"]
    c = spec["containers"][0]
    if which == "writable-root":
        c["securityContext"]["readOnlyRootFilesystem"] = False
        touched += 1
    if which == "bare-mktemp":
        c["args"] = [a.replace("mktemp -d /backup/.fwb-stage-XXXXXX", "mktemp -d") for a in c["args"]]
        touched += 1
    if which == "tmp-unmounted":
        c["volumeMounts"] = [m for m in c["volumeMounts"] if m["mountPath"] != "/tmp"]
        touched += 1
    if which == "tmp-unbounded":
        for v in spec["volumes"]:
            if v["name"] == "tmp":
                v["emptyDir"] = {}
        touched += 1
assert touched == 1, f"mutation {which} matched {touched} places, so it is not the mutation it claims"
with open(dst, "w") as fh:
    yaml.safe_dump_all(docs, fh)
MUTATE
}

for mutation in writable-root bare-mktemp tmp-unmounted tmp-unbounded; do
  mutate "$mutation"
  if python3 "$work/check-readonly.py" "$work/mutant-$mutation.yaml" >/dev/null 2>&1; then
    fail "the check passes a render mutated to $mutation, so it does not check that"
  fi
  echo "  ok: the check rejects $mutation"
done

echo "PASS"
