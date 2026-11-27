# jdw-deployments — agent map

GitOps for the `jdwillmsen` tenant. Merging to `main` is deploying: the ApplicationSet turns each
`argocd/prd/config.yaml` entry into an Application that auto-syncs with selfHeal. `README.md` is the reference.

## Worlds (namespace `jdwillmsen-prd`, pod `<release>-minecraft-bedrock-0`)

| `--world` | Release / chart | What | Policy |
|---|---|---|---|
| `fwb` | `jdwillmsen-minecraft-fwb-prd` / `minecraft-fwb` | the players' survival world | owner approves; no cheats or creative, ever |
| `lab` | `jdwillmsen-crew-lab-prd` / `crew-lab` | crew lab, NetherNet, bots train here | fine with players online |
| `pg` | `jdwillmsen-proving-grounds-prd` / `proving-grounds` | pack and add-on tests, creative | fine with players online |
| `seed` | `jdwillmsen-fwb-seed-prd` / `fwb-seed` | FWB's seed, hard survival, no cheats | Josh's world: ask as for FWB, warn him before restarts |

## Console: `tools/mc`, never a hand-built `kubectl exec ... send-command`

`tools/mc [--world fwb|lab|seed|pg] status|players|where|locate|say|announce|tell|op|whitelist|run|bots|presence|cull`
(`tools/mc --help`). FWB is the default. `op` and `whitelist add` on fwb or seed need `--confirm` (seed from
[jdwillmsen/jdw-deployments#494](https://github.com/jdwillmsen/jdw-deployments/pull/494)). Presence, bots and cull
are FWB-only; `where` and `locate` read the map pack's frames, which only FWB runs.
Console traps the tool already handles: `grep -a` on console logs, read replies by time not `--tail`, JSON-encode tellraw.

## Rollout

- Change a chart's values or image tag, open a PR, rebase-merge; Argo syncs it. Do not `kubectl apply`, scale or
  edit live objects outside the steps a runbook or `tools/world-restore` performs. Images are built in
  `jdwillmsen/gameops`; Renovate opens the bump PRs here and auto-merges only images that never recreate a server
  pod (`renovate.json` says which).
- Restart FWB with `tools/mc run stop` after a 120 s announce. Never delete its pod or `rollout restart` it: a pod
  that moves takes the world volume with it (`docs/incidents/2026-08-30-fwb-world-data-loss.md`).
- The merge gate is the tier `change-class --pr N` gives; R3 waits for the owner. On 2026-11-09 the owner told
  agents in chat to merge lab and proving-grounds PRs without waiting on him; that is in agent memory only, not
  in `change-risk.toml`, so it never lowers a tier. Players online do not block lab or pg rollouts; FWB's do.

## Runbooks and checks

- `docs/minecraft-fwb-joinability-runbook.md` (nobody can join), `docs/minecraft-fwb-restore-runbook.md`
  (world restore), `docs/minecraft-fwb-agent-reauth-runbook.md` (agent sign-in).
- Before pushing: `tools/ci-local tools-tests` (shellcheck plus every `tools/tests/test-*.sh`).
