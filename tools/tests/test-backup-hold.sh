#!/usr/bin/env bash
# Runs the backup job's own script against a fake server whose console is as
# busy as the real one.
#
# The script finds out which files to copy by sending `save query` and reading
# the server's reply off the console. That console is shared: the map's live
# layer writes several lines a second, and on 2026-10-06 the reply was no
# longer in the 20 lines the script read, so the hold was abandoned and the
# cold copy that followed failed. The fake honours --tail and --since as the
# real kubectl does, which is the property that failure depended on: the reply
# is FAKE_REPLY_AGE seconds old, the map's lines are newer, and a reader gets
# only what its window reaches.
set -euo pipefail

here="$(cd "$(dirname "$0")/../.." && pwd)"
chart="$here/charts/minecraft-fwb"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

helm template jdwillmsen-minecraft-fwb-prd "$chart" -n jdwillmsen-prd \
  -f "$chart/values.yaml" -f "$chart/values-prd.yaml" \
  -f "$chart/values-console-bridge.yaml" > "$work/rendered.yaml"

# The script and its environment as the CronJob carries them.
python3 - "$work/rendered.yaml" "$work" <<'PY' || fail "could not extract the backup script from the chart"
import shlex, sys, yaml
for doc in yaml.safe_load_all(open(sys.argv[1])):
    if doc and doc.get("kind") == "CronJob" and doc["metadata"]["name"].endswith("-backup"):
        c = doc["spec"]["jobTemplate"]["spec"]["template"]["spec"]["containers"][0]
        open(sys.argv[2] + "/backup.sh", "w").write(c["args"][0])
        with open(sys.argv[2] + "/env", "w") as env:
            for e in c.get("env", []):
                if "value" in e:
                    env.write("export %s=%s\n" % (e["name"], shlex.quote(str(e["value"]))))
        break
else:
    sys.exit("no backup CronJob rendered")
PY

# Staged outside the container's own paths, so the suite needs no root and no
# volume.
mkdir -p "$work/sa" "$work/backup" "$work/bin"
echo -n "test-ns" > "$work/sa/namespace"
sed -i -e "s|/var/run/secrets/kubernetes.io/serviceaccount/namespace|$work/sa/namespace|" \
       -e "s|/data/worlds|$work/worlds|g" -e "s|/backup|$work/backup|g" \
       -e "s|/tmp/metrics.txt|$work/metrics.txt|g" "$work/backup.sh"

# shellcheck disable=SC1091  # written above from the rendered chart
. "$work/env"
level="${LEVEL_NAME:?the backup CronJob names no level}"
mkdir -p "$work/worlds/$level/db"
head -c 4096 /dev/urandom > "$work/worlds/$level/db/000001.ldb"
head -c 4096 /dev/urandom > "$work/worlds/$level/db/MANIFEST-000001"
head -c 2048 /dev/urandom > "$work/worlds/$level/level.dat"
# The server commits fewer bytes than the first file holds on disk, as it does
# for a file LevelDB is still appending to.
manifest="$level/db/000001.ldb:1000, $level/db/MANIFEST-000001:4096, $level/level.dat:2048"

cat > "$work/bin/kubectl" <<'SHIM'
#!/usr/bin/env bash
case "$1" in
  get)
    case "$*" in
      *statefulset*) printf 1 ;;
      *phase*)       printf Running ;;
      *Ready*)       printf True ;;
    esac ;;
  exec)
    shift; while [[ "$1" != "--" ]]; do shift; done; shift 2
    printf '%s\n' "$*" >> "$CAPTURE" ;;
  logs)
    tail="" since=""
    for arg in "$@"; do
      [[ "$arg" == --tail=* ]] && tail="${arg#--tail=}"
      [[ "$arg" == --since=* ]] && since="${arg#--since=}"
    done
    since="${since%s}"
    # The script sleeps two seconds between asking and reading, and each call
    # takes time of its own, so the reply is some seconds old when it is read.
    age="${FAKE_REPLY_AGE:-5}"
    {
      if [[ -z "$since" || "$age" -le "$since" ]]; then
        printf 'noise \x00 binary\n'
        echo '[2026-10-06 04:00:09:480 INFO] Data saved. Files are now ready to be copied.'
        echo "$FAKE_MANIFEST"
      fi
      for _ in $(seq 1 "${FAKE_NOISE:-0}"); do
        echo '[2026-10-06 04:00:10:607 INFO] [Scripting] MCMAP1 {"gen":28230,"kind":"tick","players":3,"mobs":362}'
      done
    } > "$CAPTURE.console"
    if [[ -n "$tail" ]]; then tail -n "$tail" "$CAPTURE.console"; else cat "$CAPTURE.console"; fi ;;
esac
exit 0
SHIM
chmod +x "$work/bin/kubectl"

rc=0
run() {
  : > "$work/sent"; rm -rf "$work/backup"; mkdir -p "$work/backup"
  rc=0
  out="$(env PATH="$work/bin:$PATH" CAPTURE="$work/sent" FAKE_MANIFEST="$manifest" MIN_BYTES=1 \
    timeout 120 bash "$work/backup.sh" 2>&1)" || rc=$?
}

# --- the reply is found however much else the console says ------------------
FAKE_NOISE=100 run
grep -q 'copied 3 files under hold' <<<"$out" || fail "the manifest was not read off a busy console: $out"
grep -q 'falling back to a cold copy' <<<"$out" && fail "a server that answered was treated as one that did not: $out"
[ "$rc" -eq 0 ] || fail "a held backup exited $rc: $out"
archive="$(find "$work/backup" -name 'fwb-*.tar.gz' | head -1)"
[ -n "$archive" ] || fail "no archive was written: $out"
size="$(tar xzf "$archive" -O "./$level/db/000001.ldb" | wc -c)"
[ "$size" -eq 1000 ] || fail "the archive holds $size bytes of a file the server committed 1000 of"
grep -q '^save hold$' "$work/sent" || fail "the server was never asked to hold"
[ "$(tail -1 "$work/sent")" = "save resume" ] || fail "the server was left held: $(tr '\n' ';' < "$work/sent")"
echo "  ok: a held backup reads its manifest through a console the map is writing to"

# --- and on a quiet console, as before --------------------------------------
run
grep -q 'copied 3 files under hold' <<<"$out" || fail "the manifest was not read off a quiet console: $out"
[ "$rc" -eq 0 ] || fail "a held backup on a quiet console exited $rc: $out"
echo "  ok: a quiet console still works"

echo "PASS"
