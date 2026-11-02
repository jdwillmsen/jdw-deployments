# proving-grounds: NetherNet test server for behaviour packs and mods

Goal: a dedicated Bedrock server, NetherNet only, for trying behaviour packs,
add-ons and mods. Anyone with a retail client can join on the LAN and through
mc.jdwlabs.com. Disposable world, no crew units, no backup.

## Shape
- New chart `charts/proving-grounds` and Argo app `proving-grounds-prd` in
  `argocd/prd/config.yaml`, namespace jdwillmsen-prd. Own app: nothing here can
  sync, restart or reschedule the lab or FWB.
- Subchart minecraft-bedrock 2.9.0, same pin as the lab (1.26.60.6), online
  mode off, creative flat world, cheats on, survival-capable.
- `install-lab-packs` init container installs the wildlife pack from the
  `lab-packs` image into the world (stage-0 mobs and the dragon are not in that
  image; they ship separately, see PR); new packs ship by a tag bump.
- Templates copied from crew-lab: nethernet-service, listener-watchdog.
  No crew, unit-kit, rebuild or version-check.
- Ports: signaling NodePort 31139 (server port 31138), gameplay UDP 31180-31199 (public TCP 19134 -> 31139 and UDP
  19180-19199), free cluster-wide. WAN IP advertised via SERVER_UDP_PORTS.
- Public route: nft rules on the HAProxy VM and gateway Custom Services, as in
  docs/minecraft-nethernet-public-route.md.

## Rollback
Remove the app entry from config.yaml (Argo prunes the app); delete the nft
rules and gateway services. No other service shares a port or volume.

## Who is affected
Only people who choose to join it. Lab, FWB and the VM's existing ports are
untouched; the VM nft change adds rules without editing existing ones.

## Steps
1. Chart plus chart test; render and lint.
2. Argo app entry; PR, CI, Opus review, owner approval (R3: prd, network).
3. After merge: VM nft and gateway forwards (hand-applied, dated backup).
4. Verify: LAN join, remote join, packs in the Pack Stack, script loaded.
5. Run the wildlife safety checklist on it.
