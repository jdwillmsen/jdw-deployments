#!/usr/bin/env bash
# Exercises tools/mc's --world selection and the commands built on it (tell,
# op, whitelist, locate, bots) against a fake kubectl, so it runs in CI with
# no cluster. The fake records every call, so which pod a command reached and
# what it sent are asserted rather than assumed.
set -euo pipefail

here="$(cd "$(dirname "$0")/../.." && pwd)"
mc="$here/tools/mc"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

mkdir -p "$work/bin"
cat > "$work/bin/kubectl" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$KUBECTL_LOG"
case "$1" in
  get)
    # The pod is named after the selector it was found by, so a test can see
    # which world a command resolved to from any later call.
    sel=""
    prev=""
    for arg in "$@"; do
      [ "$prev" = "-l" ] && sel="$arg"
      prev="$arg"
    done
    if [ -n "$sel" ]; then printf 'pod[%s]' "$sel"; else printf 'true'; fi ;;
  exec) shift; while [[ "$1" != "--" ]]; do shift; done; shift 2; printf '%s\n' "$*" >> "$CAPTURE" ;;
  logs) [ -n "${FAKE_LOG_FILE:-}" ] && cat "$FAKE_LOG_FILE" ;;
esac
exit 0
SHIM
chmod +x "$work/bin/kubectl"

# run [ENV=VALUE...] -- ARGS: tools/mc against the fake, output in $out and
# exit status in $rc, with the call log and sent commands reset each time.
run() {
  local -a envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  : > "$work/kubectl.log"; : > "$work/sent"
  rc=0
  out="$(env -u MC_WORLD -u MC_SELECTOR -u MC_NAMESPACE -u MC_RELEASE \
    PATH="$work/bin:$PATH" KUBECTL_LOG="$work/kubectl.log" CAPTURE="$work/sent" FAKE_LOG_FILE="$work/console" \
    "${envs[@]}" bash "$mc" "$@" 2>&1)" || rc=$?
}
logs() { printf '%s\n' "$@" > "$work/console"; }
: > "$work/console"

# --- world selection --------------------------------------------------------
run -- players
grep -q -- '-l app=jdwillmsen-minecraft-fwb-prd-minecraft-bedrock' "$work/kubectl.log" \
  || fail "the default world must stay FWB: $(cat "$work/kubectl.log")"
grep -q -- '-n jdwillmsen-prd' "$work/kubectl.log" || fail "the default namespace must be jdwillmsen-prd"

for pair in lab:jdwillmsen-crew-lab-prd seed:jdwillmsen-fwb-seed-prd pg:jdwillmsen-proving-grounds-prd fwb:jdwillmsen-minecraft-fwb-prd; do
  w="${pair%%:*}" release="${pair#*:}"
  run -- --world "$w" players
  [ "$rc" = 0 ] || fail "--world $w failed: $out"
  grep -q -- "-l app=${release}-minecraft-bedrock" "$work/kubectl.log" \
    || fail "--world $w must select app=${release}-minecraft-bedrock: $(cat "$work/kubectl.log")"
  grep -q "pod\[app=${release}-minecraft-bedrock\]" "$work/kubectl.log" \
    || fail "--world $w must exec into the pod it found: $(cat "$work/kubectl.log")"
done
echo "  ok: each world resolves to its own release's server pod"

run MC_WORLD=pg -- players
grep -q 'app=jdwillmsen-proving-grounds-prd-minecraft-bedrock' "$work/kubectl.log" || fail "MC_WORLD must select the world"
run MC_WORLD=pg -- --world=seed players
grep -q 'app=jdwillmsen-fwb-seed-prd-minecraft-bedrock' "$work/kubectl.log" || fail "--world must beat MC_WORLD"
run MC_SELECTOR=app=custom -- --world lab players
grep -q -- '-l app=custom' "$work/kubectl.log" || fail "MC_SELECTOR must still override the world's selector"
echo "  ok: MC_WORLD, --world=, and the MC_SELECTOR override"

run -- --world nope players
[ "$rc" = 2 ] || fail "an unknown world is a usage error (exit 2), got $rc: $out"
grep -q '^error: unknown world: nope' <<<"$out" || fail "an unknown world must be named: $out"
grep -q '^hint: worlds: fwb, lab, seed, pg, empty' <<<"$out" || fail "an unknown world must list the worlds: $out"
[ ! -s "$work/kubectl.log" ] || fail "an unknown world must not reach the cluster"

run -- --world empty players
[ "$rc" = 2 ] || fail "the unverified world must be refused without MC_SELECTOR, got $rc: $out"
grep -q 'unverified' <<<"$out" || fail "the refusal must say the world is unverified: $out"
[ ! -s "$work/kubectl.log" ] || fail "an unverified world must not reach the cluster"
run MC_SELECTOR=app=x -- --world empty players
[ "$rc" = 0 ] || fail "the unverified world must work once MC_SELECTOR names its pod: $out"
echo "  ok: unknown and unverified worlds are refused before any kubectl call"

run -- say --world lab hello
[ "$rc" = 2 ] || fail "--world after the command must be refused, got $rc: $out"
[ ! -s "$work/sent" ] || fail "--world after say was broadcast as text: $(cat "$work/sent")"
echo "  ok: a misplaced --world is refused, not broadcast"

logs "There are 1/10 players online:"
run -- --world lab
grep -q '^world: lab' <<<"$out" || fail "status must say which world it read: $out"

# --- tell -------------------------------------------------------------------
logs "[INFO] nothing to see"
# shellcheck disable=SC2016 # literal $(...) is the input under test
hostile='§cred§r and "quotes" \ $(whoami) } {'
run -- --world lab tell --colour a "Light King" "$hostile"
[ "$rc" = 0 ] || fail "tell failed: $out"
line="$(grep '^tellraw' "$work/sent" | tail -1)"
[[ "$line" == 'tellraw "Light King" {'* ]] || fail "the target must be the quoted gamertag: $line"
python3 -c '
import json, sys
p = json.loads(sys.argv[1].split(" ", 3)[3])
text = p["rawtext"][0]["text"]
assert text == "§a" + sys.argv[2], "text was changed in transit: %r" % text
' "$line" "$hostile" || fail "tell payload must carry colour codes and hostile text literally: $line"
grep -q '^delivered: yes' <<<"$out" || fail "an accepted tell must say delivered: $out"
grep -q '^to: Light King' <<<"$out" || fail "tell must name its recipient: $out"
echo "  ok: tell encodes colour codes and hostile text into valid rawtext"

logs "No targets matched selector"
run -- whisper Bob hi
[ "$rc" = 1 ] || fail "a tell nobody received must exit 1, got $rc: $out"
grep -q '^reason: Bob is not online' <<<"$out" || fail "an offline recipient must be named: $out"
logs 'Syntax error: Unexpected "x"'
run -- tell Bob hi
[ "$rc" = 1 ] || fail "a rejected tell must exit 1"
grep -q '^server: Syntax error' <<<"$out" || fail "a rejected tell must show the server's reason: $out"
echo "  ok: tell reports offline and rejected outcomes"

for bad in '@a' 'Bo"b' ''; do
  run -- tell "$bad" hi
  [ "$rc" = 2 ] || fail "tell to '$bad' must be a usage error, got $rc: $out"
  [ ! -s "$work/sent" ] || fail "tell to '$bad' sent something"
done
run -- tell --colour zz Bob hi
[ "$rc" = 2 ] || fail "a bad colour code must be a usage error"
echo "  ok: selectors, quotes and bad colour codes are refused before sending"

# --- op and whitelist ---------------------------------------------------------
run -- op Alice
[ "$rc" = 2 ] || fail "op on fwb without --confirm must be refused, got $rc: $out"
[ ! -s "$work/sent" ] || fail "op on fwb without --confirm sent: $(cat "$work/sent")"
grep -q -- '--confirm' <<<"$out" || fail "the refusal must say how to proceed: $out"

logs "Opped: Alice"
run -- op Alice --confirm
[ "$(cat "$work/sent")" = 'op "Alice"' ] || fail "op must send the quoted gamertag: $(cat "$work/sent")"
grep -q '^result: replied' <<<"$out" || fail "op must show a reply: $out"
grep -q 'Opped: Alice' <<<"$out" || fail "op must print the server's reply: $out"

run -- --world pg op "Some Name"
[ "$rc" = 0 ] || fail "op on pg needs no --confirm: $out"
[ "$(cat "$work/sent")" = 'op "Some Name"' ] || fail "a gamertag with a space must stay one quoted target"

logs "Could not op (already op or higher): Alice"
run -- --world lab op Alice
[ "$rc" = 1 ] || fail "a refused op must exit 1, got $rc: $out"
grep -q '^result: failed' <<<"$out" || fail "a refused op must say failed: $out"

logs '[Scripting] MCMAP1 {"gen":1,"kind":"tick"}'
run -- --world lab deop Alice
grep -q '^reply: none' <<<"$out" || fail "map lines are not a reply: $out"
grep -q '^result: unconfirmed' <<<"$out" || fail "no reply must read unconfirmed, not success: $out"

run -- --world seed whitelist add "Light King"
[ "$(cat "$work/sent")" = 'allowlist add "Light King"' ] || fail "whitelist add must send allowlist add: $(cat "$work/sent")"
run -- --world seed whitelist list
[ "$(cat "$work/sent")" = 'allowlist list' ] || fail "whitelist list must send allowlist list"
run -- whitelist add 'x"; stop'
[ "$rc" = 2 ] || fail "an injected gamertag must be refused, got $rc"
[ ! -s "$work/sent" ] || fail "an injected gamertag was sent: $(cat "$work/sent")"
echo "  ok: op guards fwb, quotes gamertags, and reads the reply honestly"

# --- locate -------------------------------------------------------------------
# Two samples of the overworld: an old one, and a newer one split over two
# parts. A NUL is in the log because the real console carries binary bytes.
printf '%s\n' \
  '[2026-11-27 10:00:00:001 INFO] [Scripting] MCMAP1 {"gen":5,"dim":"overworld","kind":"mobs","part":0,"parts":1,"more":0,"items":[{"i":"1","t":"sheep","x":999,"y":64,"z":999}]}' \
  '[2026-11-27 10:00:00:002 INFO] [Scripting] MCMAP1 {"gen":6,"dim":"overworld","kind":"players","part":0,"parts":1,"more":0,"items":[{"i":"p1","n":"LightKing0221","x":0,"y":64,"z":0,"r":0},{"i":"p2","n":"Dotablaze","x":500,"y":70,"z":500,"r":0}]}' \
  '[2026-11-27 10:00:00:003 INFO] [Scripting] MCMAP1 {"gen":6,"dim":"overworld","kind":"mobs","part":0,"parts":2,"more":3,"items":[{"i":"2","t":"sheep","x":30,"y":64,"z":40},{"i":"3","t":"cow","x":1,"y":64,"z":1}]}' \
  '[2026-11-27 10:00:00:004 INFO] [Scripting] MCMAP1 {"gen":6,"dim":"overworld","kind":"mobs","part":1,"parts":2,"more":3,"items":[{"i":"4","t":"sheep","n":"Shaun, the sheep","x":-3,"y":65,"z":4},{"i":"5","t":"sheep","x":510,"y":70,"z":500}]}' \
  '[2026-11-27 10:00:00:005 INFO] [Scripting] MCMAP1 {"gen":6,"dim":"nether","kind":"mobs","part":0,"parts":1,"more":0,"items":[{"i":"6","t":"sheep","x":0,"y":40,"z":0}]}' \
  > "$work/console"
printf 'noise \x00 binary\n' >> "$work/console"

run -- locate minecraft:sheep --near lightking0221 --top 2
[ "$rc" = 0 ] || fail "locate failed: $out"
grep -q '^found: 3$' <<<"$out" || fail "locate must count the newest whole sample in the player's dimension: $out"
grep -q '^other_dimensions: 1$' <<<"$out" || fail "mobs in other dimensions must be counted, not listed: $out"
grep -q '^unlisted: 3$' <<<"$out" || fail "the map cap's leftovers must be reported: $out"
grep -q '^mobs\[2\]{dim,x,y,z,name,player,distance,yaw}:$' <<<"$out" || fail "--top must limit the rows: $out"
first="$(grep -A1 '^mobs\[' <<<"$out" | tail -1)"
[ "$first" = '  overworld,-3,65,4,"Shaun, the sheep",LightKing0221,5.0,37' ] \
  || fail "the nearest sheep must come first with a quoted name and a bearing: '$first'"
grep -q '999' <<<"$out" && fail "a sheep from an older sample must not be listed: $out"
grep -q 'locate sheep --top 3' <<<"$out" || fail "a truncated list must say how to see the rest: $out"
grep -q 'tell "LightKing0221"' <<<"$out" || fail "locate must point at tell for the next step: $out"
[ ! -s "$work/sent" ] || fail "locate must send nothing to the server: $(cat "$work/sent")"
echo "  ok: locate reads whole samples, sorts by distance, and sends nothing"

run -- locate sheep
grep -q '^found: 4$' <<<"$out" || fail "without --near, every dimension counts: $out"
run -- locate zombie
[ "$rc" = 0 ] || fail "no matches is an answer, not an error: $out"
grep -q '^mobs: none in loaded chunks' <<<"$out" || fail "no matches must be stated: $out"
run -- locate sheep --near Nobody
[ "$rc" = 1 ] || fail "an unknown --near player must exit 1, got $rc"
grep -q '^error: Nobody is not in the map frames' <<<"$out" || fail "the missing player must be named: $out"
logs "[INFO] Server started."
run -- --world lab locate sheep
[ "$rc" = 1 ] || fail "a world with no map frames must exit 1, got $rc"
grep -q '^error: no map frames' <<<"$out" || fail "no frames must be explained: $out"
run -- locate 'sheep[x=1]'
[ "$rc" = 2 ] || fail "a selector as a mob type must be a usage error"
echo "  ok: locate states empty results and missing frames"

# --- bots and fwb-only commands -------------------------------------------------
for cmd in "bots park --reason x" "presence ls" "cull --types zombie --dry-run"; do
  # shellcheck disable=SC2086 # the command is split on purpose
  run -- --world lab $cmd
  [ "$rc" = 1 ] || fail "$cmd on lab must be refused, got $rc: $out"
  grep -q 'runs only on fwb' <<<"$out" || fail "$cmd on lab must say it is fwb-only: $out"
  [ ! -s "$work/kubectl.log" ] || fail "$cmd on lab reached the cluster: $(cat "$work/kubectl.log")"
done
run -- bots park
[ "$rc" = 2 ] || fail "bots park must require --reason, as presence park does, got $rc: $out"
grep -q -- '--reason is required' <<<"$out" || fail "bots park must hand over to presence park: $out"
run -- bots --help
grep -q 'presence park|unpark bots' <<<"$out" || fail "bots --help must say what it wraps: $out"
echo "  ok: bots wraps presence, and fwb-only commands refuse other worlds"

run -- --help
grep -q -- '--world' <<<"$out" || fail "help must document --world"
grep -q 'unverified' <<<"$out" || fail "help must mark the unverified world"

echo "PASS"
