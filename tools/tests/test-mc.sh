#!/usr/bin/env bash
# Exercises tools/mc against a fake kubectl, so it runs in CI with no cluster.
#
# The interesting surface is the tellraw payload: it is built from arbitrary
# operator input and travels through two layers of quoting before a server
# parses it. The shim records what was actually sent so the encoding can be
# asserted rather than eyeballed.
set -euo pipefail

here="$(cd "$(dirname "$0")/../.." && pwd)"
mc="$here/tools/mc"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

mkdir -p "$work/bin"
cat > "$work/bin/kubectl" <<'SHIM'
#!/usr/bin/env bash
case "$1" in
  get)  printf '%s' "${FAKE_GET:-server-0}" ;;
  exec) shift; while [[ "$1" != "--" ]]; do shift; done; shift 2; printf '%s\n' "$*" >> "$CAPTURE" ;;
  logs)
    # FAKE_BINARY prepends a real NUL. It cannot come in through FAKE_LOGS:
    # bash discards null bytes in command substitution, so a fixture built
    # that way silently loses the very byte the test is about.
    [[ -n "${FAKE_BINARY:-}" ]] && printf 'noise \x00\x1b[0m binary\n'
    printf '%s\n' "${FAKE_LOGS:-There are 0/10 players online:}"
    ;;
esac
exit 0
SHIM
chmod +x "$work/bin/kubectl"

# --- the payload encoding -------------------------------------------------
# Shell metacharacters must arrive as literal text. If the message were
# interpolated into the JSON as a string, this input would either break the
# payload or execute.
: > "$work/sent"
# shellcheck disable=SC2016  # literal $(...) is the input under test
hostile='he said "hi" \ then $(whoami) `id` } {'
env PATH="$work/bin:$PATH" CAPTURE="$work/sent" MC_NAMESPACE=test-ns \
    FAKE_LOGS="No targets matched selector" bash "$mc" announce "$hostile" >/dev/null || true

payload="$(grep '^tellraw' "$work/sent" | tail -1 | sed 's/^tellraw @a //')"
[ -n "$payload" ] || fail "no tellraw payload was sent"
python3 -c "
import json, sys
p = json.loads(sys.argv[1])
assert 'rawtext' in p, 'Bedrock requires a top-level rawtext wrapper, got: %r' % p
text = p['rawtext'][0]['text']
assert '\$(whoami)' in text, 'shell substitution was not preserved literally: %r' % text
assert 'he said \"hi\"' in text, 'quotes were mangled: %r' % text
" "$payload" || fail "tellraw payload is not valid Bedrock rawtext"
echo "  ok: hostile input encodes to valid rawtext, literally"

# --- definitive outcomes --------------------------------------------------
out="$(env PATH="$work/bin:$PATH" CAPTURE="$work/sent" MC_NAMESPACE=test-ns \
       FAKE_LOGS="No targets matched selector" bash "$mc" announce hello)"
grep -q "delivered: no" <<<"$out" || fail "an unreceived announce must not report success"
grep -q "nobody was online" <<<"$out" || fail "the reason for non-delivery must be stated"
echo "  ok: announce with no recipients reports why"

out="$(env PATH="$work/bin:$PATH" CAPTURE="$work/sent" MC_NAMESPACE=test-ns \
       FAKE_LOGS='Syntax error: Unexpected ""' bash "$mc" announce hello || true)"
grep -q "the server rejected the payload" <<<"$out" || fail "a rejected payload must be reported as rejected"
echo "  ok: rejected payload is surfaced"

out="$(env PATH="$work/bin:$PATH" CAPTURE="$work/sent" MC_NAMESPACE=test-ns \
       FAKE_LOGS="There are 0/10 players online:" bash "$mc" players)"
grep -q "online: none" <<<"$out" || fail "an empty player list must say so rather than print nothing"
echo "  ok: empty player list is explicit"

# The Bedrock console log carries binary bytes. grep treats a stream with any
# as binary and prints "binary file matches" instead of the matching lines, so
# every parse built on it silently yields nothing -- observed live on
# 2026-09-08 as `players: 0` while four people were online. Intermittent by
# nature: it depends on whether the tail window happens to contain one, which
# is exactly why it needs a deterministic test rather than a live check.
out="$(env PATH="$work/bin:$PATH" CAPTURE="$work/sent" MC_NAMESPACE=test-ns \
       FAKE_BINARY=1 FAKE_LOGS="$(printf 'There are 3/10 players online:\nAlice, Bob, Carol')" \
       bash "$mc" players)"
grep -q "players: 3" <<<"$out" || fail "a log containing binary bytes must still parse the player count"
grep -q "Alice" <<<"$out" || fail "a log containing binary bytes must still list players"
echo "  ok: a binary-bearing console log still parses"

# --- errors ---------------------------------------------------------------
out="$(env PATH="$work/bin:$PATH" MC_NAMESPACE=test-ns bash "$mc" say 2>&1 || true)"
grep -q "^error:" <<<"$out" || fail "say with no message must error"
grep -q "^hint:" <<<"$out" || fail "an error must carry a next step"
echo "  ok: missing arguments error with a hint"

env PATH="$work/bin:$PATH" MC_NAMESPACE=test-ns bash "$mc" nonsense >/dev/null 2>&1 \
  && fail "an unknown command must exit non-zero"
echo "  ok: unknown command exits non-zero"

out="$(env PATH="$work/bin:$PATH" CAPTURE="$work/sent" MC_NAMESPACE=test-ns bash "$mc")"
grep -q "^pod:" <<<"$out" || fail "the default command must print live state"
grep -q "^help:" <<<"$out" || fail "the default command must offer next steps"
echo "  ok: no-args prints live state and next steps"

echo "PASS"
