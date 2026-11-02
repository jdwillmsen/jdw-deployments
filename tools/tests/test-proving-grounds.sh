#!/usr/bin/env bash
# Pins what makes proving-grounds a test server of its own: NetherNet only, its
# own world, no crew, packs installed from the lab-packs image, and ports that
# collide with neither the lab nor the main server.
set -euo pipefail

here="$(cd "$(dirname "$0")/../.." && pwd)"
fail() { echo "FAIL: $1"; exit 1; }

pg="$(helm template pg "$here/charts/proving-grounds" -f "$here/charts/proving-grounds/values.yaml")"

grep -q 'name: TRANSPORT' <<<"$pg" || fail "no TRANSPORT env"
[[ "$(yq '.minecraft-bedrock.extraEnv.TRANSPORT' "$here/charts/proving-grounds/values.yaml")" == nethernet ]] || fail "not NetherNet"
grep -q 'name: pg-nethernet' <<<"$pg" || fail "no NetherNet Service"
grep -q 'publishNotReadyAddresses: true' <<<"$pg" || fail "NetherNet Service must publish not-ready addresses"
grep -q 'name: install-lab-packs' <<<"$pg" || fail "packs are not installed"
grep -q '/data/worlds/proving-grounds' <<<"$pg" || fail "installer targets the wrong world"
grep -q 'LEVEL_NAME' <<<"$pg" || fail "no level name"
grep -q 'kind: CronJob' <<<"$pg" || fail "no listener watchdog"
if grep -q -i 'crew' <<<"$pg"; then fail "crew objects leaked into the test server"; fi

# Every NodePort here must be unused by the other Minecraft charts.
ports() { helm template x "$here/charts/$1" -f "$here/charts/$1/values.yaml" 2>/dev/null | grep -E '^\s+nodePort:' | awk '{print $2}'; }
mine="$(ports proving-grounds | sort -u)"
[ -n "$mine" ] || fail "no NodePorts rendered"
for other in crew-lab minecraft-fwb; do
  clash="$(comm -12 <(echo "$mine") <(ports "$other" | sort -u))" || true
  [ -z "$clash" ] || fail "NodePort clash with $other: $clash"
done
# A Service rendered with the same port number on TCP and UDP is fine; the
# apiserver rejects the same nodePort twice within one protocol, and the signaling
# port deliberately differs from the server port.
[[ "$(yq '.netherNet.signalingNodePort' "$here/charts/proving-grounds/values.yaml")" != "$(yq '.minecraft-bedrock.minecraftServer.nodePort' "$here/charts/proving-grounds/values.yaml")" ]] \
  || fail "signaling nodePort equals the server nodePort"

grep -q 'name: proving-grounds-prd' "$here/argocd/prd/config.yaml" || fail "no Argo app"
echo "PASS: proving-grounds"
