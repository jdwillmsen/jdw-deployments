#!/usr/bin/env bash
# Backup retention and the chunk-count archive alert, on the November 2026 loss.
#
# Until this existed retention kept the newest 14 archives by age. A loss of
# 12,321 chunks on 2026-11-17 went unnoticed, and on 2026-11-30 the run would
# have deleted the last good archive (2026-11-16, 162,882 chunks). The cases:
#
#  - that exact set: the 16th of November survives whether or not anything is
#    held, and age-only retention (the control) would have deleted it;
#  - the protections and the holds, one at a time;
#  - the chunk-drop alert does not clear by itself as the loss ages, which the
#    median-based ArchiveShrank did on 2026-11-20.
#
# The script and the rules are taken from the rendered chart, so the cases
# cannot drift from what ships.
set -euo pipefail

here="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

helm template minecraft-fwb "$here/charts/minecraft-fwb" --namespace jdwillmsen-prd \
  -f "$here/charts/minecraft-fwb/values.yaml" > "$work/rendered.yaml"

python3 - "$work" <<'PY'
import sys, yaml
work = sys.argv[1]
for d in yaml.safe_load_all(open(work + "/rendered.yaml")):
    if not d:
        continue
    if d["kind"] == "ConfigMap" and d["metadata"]["name"].endswith("-backup-retention"):
        open(work + "/retention.py", "w").write(d["data"]["backup-retention.py"])
    if d["kind"] == "PrometheusRule" and d["metadata"]["name"].endswith("-world-integrity"):
        open(work + "/rules.yaml", "w").write(yaml.safe_dump({"groups": d["spec"]["groups"]}, sort_keys=False))
PY
[ -s "$work/retention.py" ] || fail "the chart does not ship the retention script"
cmp -s "$work/retention.py" "$here/charts/minecraft-fwb/scripts/backup-retention.py" || fail "the shipped ConfigMap differs from scripts/backup-retention.py"

python3 -I - "$work/retention.py" <<'PY' || fail "retention decided wrongly"
import datetime, os, subprocess, sys, tempfile

SCRIPT = sys.argv[1]

def make(counts, quiesced=None):
    """counts: {date: chunks or None}. Returns a directory of archives."""
    d = tempfile.mkdtemp()
    for day, chunks in counts.items():
        name = "fwb-%sT040059Z.tar.gz" % day
        open(os.path.join(d, name), "wb").write(b"x" * 10)
        meta = ["quiesced=%d" % (quiesced or {}).get(day, 1)]
        if chunks is not None:
            meta.append("chunks=%d" % chunks)
        open(os.path.join(d, name + ".meta"), "w").write("\n".join(meta) + "\n")
    return d

def run(d, *extra, keep=14, hard_max=20):
    p = subprocess.run([sys.executable, "-I", SCRIPT, "trim", "--dir", d, "--keep", str(keep), "--hard-max", str(hard_max),
                        "--metrics-out", d + "/m.txt", *extra], capture_output=True, text=True)
    assert p.returncode == 0, p.stderr
    left = sorted(f[4:12] for f in os.listdir(d) if f.endswith(".tar.gz"))
    return left, p.stdout + p.stderr, open(d + "/m.txt").read()

def days(first, n):
    base = datetime.date(2026, 11, first)
    return [(base + datetime.timedelta(days=i)).strftime("%Y%m%d") for i in range(n)]

# The incident, as it stood on 2026-11-30 at the moment of trimming: the new
# archive is in the directory, so there are 15 -- the 16th of November and the
# 14 after it. Counts are the real ones from 11-16 on.
nov = {d: 150564 for d in days(17, 14)}
nov["20261116"] = 162882
# What the job would have done before this change, as the control.
oldest = sorted(nov)[: len(nov) - 14]
assert oldest == ["20261116"], oldest

left, out, m = run(make(nov), "--lost", "14119")
assert "20261116" in left and len(left) == 15, ("held by the ledger, nothing is deleted", left)
assert "world-loss-ledger" in out

left, out, m = run(make(nov))
assert "20261116" in left and len(left) == 15, ("held by the regression alone", left)
assert "chunk-regression" in out
assert 'backup_retention_held{backup_job="backup",artifact="world",reason="chunk-regression"} 1' in m
assert 'backup_archive_chunks_max{backup_job="backup",artifact="world"} 162882' in m
assert 'backup_last_artifact_chunks{backup_job="backup",artifact="world"} 150564' in m
assert 'backup_archive_protected{backup_job="backup",artifact="world",archive="20261116T040059Z"} 1' in m

# Not held (the world recovered): the highest-count archive is protected from
# age on its own merits, and the rest trims as before. 20 archives, so 6 are
# beyond the window, one of them the 16th.
rec = {d: 150000 + i for i, d in enumerate(days(17, 19))}
rec["20261116"] = 162882
rec[days(17, 20)[-1]] = 162000          # recovered to within 1% of the max
left, out, m = run(make(rec, quiesced={"20261116": 0}))
assert "20261116" in left, ("the highest count survives even as a cold copy", left)
assert len(left) == 15, left            # 14 by age + the highest
assert days(17, 20)[-1] in left

# (b) The highest is a cold copy (quiesced=0); the newest quiesced archive
# within 1% of it is kept too, and a quiesced one more than 1% under is not.
# The newer archives are all lower, so retention is held and only the overflow
# past hard-max (here the window) is deleted -- which is where a protection
# is tested, since a hold alone would keep everything.
q = {d: 100000 for d in days(1, 20)}
q["20261105"] = 120000                      # the max, cold
q["20261103"] = 119000                      # quiesced, 0.83% under: protected
q["20261102"] = 118000                      # older, quiesced, 1.7% under: not protected
left, out, m = run(make(q, quiesced={"20261105": 0}), hard_max=14)
assert "20261105" in left, left
assert "20261103" in left, ("newest quiesced within 1% of the max is kept", left)
assert "20261102" not in left, left
assert "20261101" not in left and len(left) == 16, left  # 14 + the two protected

# A quiesced archive more than 1% under the max is not a substitute.
q2 = dict(q); q2["20261103"] = 118000
left, _, _ = run(make(q2, quiesced={"20261105": 0}), hard_max=14)
assert "20261103" not in left, left

# Healthy world, nothing special: trims by age exactly as before.
ok = {d: 150000 + 100 * i for i, d in enumerate(days(1, 20))}
left, out, m = run(make(ok))
assert left == days(7, 14), left            # the newest is the max, so the 14 newest remain
assert 'reason="chunk-regression"} 0' in m and 'reason="world-loss-ledger"} 0' in m

# No chunk count on the newest archive holds, and says why.
unk = dict(ok); unk[days(1, 20)[-1]] = None
left, out, m = run(make(unk))
assert len(left) == 20 and "chunks-unknown" in out, left

# Held for good is bounded by the claim: the overflow past hard-max goes,
# oldest first, and the protected archive never does.
many = {d: 150564 for d in days(1, 22)}
many["20261101"] = 162882
left, out, m = run(make(many), "--lost", "5", hard_max=20)
assert len(left) == 20 and "20261101" in left, left
assert "20261102" not in left and "20261103" not in left, left

# Archives taken before counts were recorded: an operator backfills the one
# that matters, and it is then protected like any other.
legacy = {d: None for d in nov}
legacy.update({d: 150564 for d in days(18, 13)})
d = make(legacy)
open(d + "/backfill", "w").write("20261116T040059Z=162882\n")
left, out, m = run(d, "--backfill", d + "/backfill")
assert "20261116" in left, left
# A recorded count outranks a backfilled one.
d = make({**nov, "20261117": 150000})
open(d + "/backfill", "w").write("20261117T040059Z=999999\n")
left, out, m = run(d, "--backfill", d + "/backfill")
assert 'backup_archive_chunks{backup_job="backup",artifact="world",archive="20261117T040059Z"} 150000' in m

# An acknowledged baseline stops the old archives counting, so the hold lifts
# and the 16th can age out -- the documented way to accept a loss.
left, out, m = run(make(nov), "--baseline", "20261117T000000Z")
assert "20261116" not in left and len(left) == 14, left
assert "held=no" in out

# The unprotected ones have no meta, and a malformed baseline is refused.
p = subprocess.run([sys.executable, "-I", SCRIPT, "trim", "--dir", make(nov), "--keep", "14", "--hard-max", "20", "--baseline", "nope"], capture_output=True, text=True)
assert p.returncode != 0

# Census reading: stale or absent counts yield nothing, never a guess.
import importlib.util
spec = importlib.util.spec_from_file_location("r", SCRIPT); r = importlib.util.module_from_spec(spec); spec.loader.exec_module(r)
text = ('mcmap_world_chunks{dimension="overworld"} 135698\nmcmap_world_chunks{dimension="end"} 5520\n'
        'mcmap_world_chunks_lost{dimension="overworld"} 10\nmcmap_world_census_last_success_timestamp_seconds 1000\n')
assert r.census(text, 3600, 1100) == "chunks=141218 lost=10"
assert r.census(text, 3600, 9000) == ""
assert r.census("", 3600, 1100) == ""
print("retention cases pass")
PY

if ! command -v promtool >/dev/null 2>&1; then
  echo "SKIP: promtool not on PATH; chunk-drop alert not verified"
  exit 0
fi
promtool check rules "$work/rules.yaml" >/dev/null || fail "promtool rejected the rendered rules"

# The series are the ones the exporter serves: the highest count among the
# archives on disk and the newest archive's count, as the job writes them.
# Annotations are read from the rendered rule so the test pins behaviour, not
# prose.
python3 -I - "$work" <<'PY'
import sys, yaml
work = sys.argv[1]
ann = {}
for g in yaml.safe_load(open(work + "/rules.yaml"))["groups"]:
    for r in g["rules"]:
        if r.get("alert") == "JdwillmsenMinecraftWorldArchiveChunksDropped":
            ann = r["annotations"]
L = 'namespace="jdwillmsen-prd",backup_job="minecraft-fwb-backup",artifact="world"'
firing = [{"exp_labels": {"severity": "critical", "namespace": "jdwillmsen-prd", "backup_job": "minecraft-fwb-backup", "artifact": "world"},
           "exp_annotations": ann}]
name = "alertname"
def at(t, alerts):
    return {"eval_time": t, "alertname": "JdwillmsenMinecraftWorldArchiveChunksDropped", "exp_alerts": alerts}
def series(s, v):
    return {"series": s + "{" + L + "}", "values": v}
tests = [
    # 11-16 is the high-water mark; 11-17 on is 7.6% under it. ArchiveShrank's
    # median resolved on 11-20. This must still be firing on day 18 because
    # retention kept the 16th, so the max has not moved.
    {"interval": "1d", "name": "the loss is still an alert two weeks later",
     "input_series": [series("backup_archive_chunks_max", "162882+0x20"),
                      series("backup_last_artifact_chunks", "162882 150564+0x19"),
                      series("backup_state_reported", "1+0x20")],
     "alert_rule_test": [at("1d", []), at("3d", firing), at("18d", firing)]},
    # A newer archive back within 2% of the best clears it.
    {"interval": "1d", "name": "recovery clears it",
     "input_series": [series("backup_archive_chunks_max", "162882+0x10"),
                      series("backup_last_artifact_chunks", "150564+0x4 161500+0x5"),
                      series("backup_state_reported", "1+0x10")],
     "alert_rule_test": [at("4d", firing), at("8d", [])]},
    {"interval": "1d", "name": "a growing world and a placeholder state are quiet",
     "input_series": [series("backup_archive_chunks_max", "150000+100x10"),
                      series("backup_last_artifact_chunks", "150000+100x10"),
                      series("backup_state_reported", "1+0x10")],
     "alert_rule_test": [at("9d", [])]},
    {"interval": "1d", "name": "placeholder zeros from a producer that has not reported do not fire",
     "input_series": [series("backup_archive_chunks_max", "162882+0x10"),
                      series("backup_last_artifact_chunks", "0+0x10"),
                      series("backup_state_reported", "0+0x10")],
     "alert_rule_test": [at("5d", [])]},
]
with open(work + "/tests.yaml", "w") as f:
    yaml.safe_dump({"rule_files": ["rules.yaml"], "evaluation_interval": "1d", "tests": tests}, f, sort_keys=False)
PY
(cd "$work" && promtool test rules tests.yaml) > "$work/promtool.log" 2>&1 || { cat "$work/promtool.log"; fail "chunk-drop alert cases failed"; }
echo "PASS: test-backup-retention"
