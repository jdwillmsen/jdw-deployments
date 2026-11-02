# proving-grounds

A disposable NetherNet Bedrock server for trying behaviour packs, add-ons and
mods before they reach the crew lab or the main server. Same pattern as
`crew-lab` and `minecraft-fwb`: its own chart and Argo app, so nothing here can
sync, restart or reschedule another server.

| | |
|---|---|
| World | `proving-grounds`, flat creative, offline mode, nobody is an operator |
| Server | Bedrock 1.26.60.6, `TRANSPORT=nethernet` (retail clients dial nothing else) |
| LAN join | `192.168.1.163:31139` |
| Remote join | `mc.jdwlabs.com:19134` |
| Ports | server 31138/UDP, signaling NodePort 31139/TCP, gameplay UDP 31180-31199 (public TCP 19134, UDP 19180-19199) |
| Backup | none; rebuild from scratch if lost |

## Packs

The `install-lab-packs` init container copies every pack in the `lab-packs`
image (gameops `packs/`) into the world and registers it on every start.
To ship a pack change: release a new `lab-packs` image from gameops, then bump
the tag in `values.yaml`. A new tag restarts the server (players included).

**First deploy needs one extra restart.** The installer skips a world that does
not exist yet, and the server creates it on first boot. After the first boot
delete the pod once (`kubectl -n jdwillmsen-prd delete pod
jdwillmsen-proving-grounds-prd-minecraft-bedrock-0`); an in-place container restart does not re-run init containers.

## Console

`kubectl -n jdwillmsen-prd exec jdwillmsen-proving-grounds-prd-minecraft-bedrock-0 -c jdwillmsen-proving-grounds-prd-minecraft-bedrock -- send-command <cmd>`

## Public route

The VM nft rules and gateway forwards are not in this repo; see
`docs/minecraft-nethernet-public-route.md`. This server uses TCP 19134 -> node
31139 and UDP 19180-19199 -> 31180-31199.

## Rollback

Remove the `proving-grounds-prd` entry from `argocd/prd/config.yaml`; Argo
prunes the app. Then delete the nft rules and gateway services.
