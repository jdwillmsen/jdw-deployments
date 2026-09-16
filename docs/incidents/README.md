# Incident knowledge base

Post-incident records for workloads in this repository. The point is not
ceremony — it is that the same failure should not be diagnosed from scratch
twice, and that assumptions proven false in production stop being repeated in
new code.

## Index

| Date | Incident | Workload | Data loss | Status |
|------|----------|----------|-----------|--------|
| 2026-08-30 | [FWB world data loss on node migration](2026-08-30-fwb-world-data-loss.md) | minecraft-fwb | ~29 MB world data, 11 `.ldb` files | Root cause identified, mitigations open |
| 2026-08-31 | [Bedrock server crashes when a player joins](2026-08-31-bedrock-crash-on-player-join.md) | minecraft-fwb | none | Open — upstream defect, no local fix |
| 2026-09-06 | [FWB offline 40 hours on a Vault secret that never existed](2026-09-06-fwb-console-bridge-secret.md) | minecraft-fwb | none | Resolved; Vault document still to be created |
| 2026-09-15 | [Bedrock version checks stopped when Mojang changed the default transport](2026-09-15-fwb-version-check-nethernet.md) | minecraft-fwb | none | Resolved by the version update; a further 104 min of bot downtime was self-inflicted |

## Recording an incident

One file per incident, named `YYYY-MM-DD-short-slug.md`, added to the index
above in the same PR. Copy [`_template.md`](_template.md).

Two rules that matter more than the format:

**Separate what was observed from what was inferred.** Every claim in the
timeline should be traceable to a log line, an event, or a command output that
is quoted in the document. If something is a hypothesis, label it as one. The
2026-08-30 incident had two confident root causes proposed and discarded before
the third was actually evidenced; the discarded ones are recorded there
deliberately, because the reasoning errors are the reusable part.

**Record invalidated assumptions in the register below.** A comment in the code
saying "this is safe because X" is worth nothing once X is disproved, and the
comment will outlive everyone's memory of the incident.

## Register of invalidated assumptions

Assumptions that were written into this repository as fact, and that production
has since disproved. Check this list before relying on a similar argument.

| Assumption | Where it was stated | Reality | Incident |
|------------|---------------------|---------|----------|
| A ReadWriteOnce volume cannot attach to a second node, so a misplaced pod fails safe | `charts/minecraft-fwb/templates/backup-cronjob.yaml` | The attach is refused only transiently; the scheduler and attach/detach controller resolve it by moving the volume, not by failing the pod | 2026-08-30 |
| `RollingUpdate` is safe with a ReadWriteOnce volume because a StatefulSet never runs two writers | `charts/minecraft-fwb/values.yaml` | Correct about writers, wrong about the volume. Pod deletion is not volume detach, and a replacement scheduled onto a different node races the unstage | 2026-08-30 |
| A clean application shutdown means the filesystem was left clean | implicit, several places | `NodeUnstageVolume` returned success while the ext4 journal was still dirty; `fsck` on the receiving node then recovered the journal and corrected errors | 2026-08-30 |
| An alert existing means the failure it names is covered | `loki-rules-node-kernel`, `monitoring` namespace | The three kernel-fault alerts query `{job="integrations/talos/kernel"}`. Exactly one of eight nodes has ever shipped that stream, it is not either node the server runs on, and it stopped on 2026-08-26. The alerts were correct, deployed, and blind | 2026-08-30 |
| A workload's logs reaching Loki means they are queryable where you look | implicit | Tenant workload logs land under the per-tenant Loki tenant (`jdwillmsen`), not `platform`. Querying `platform` returns only `kubernetes-events` and reads as "logs are not collected at all" | 2026-08-30 |
| `RollingUpdate` plus the nightly backup make an auto-merged image bump safe | `renovate.json` | `RollingUpdate` is the mechanism that recreates the pod and migrates the volume — it is the hazard, not the guard. A backup is a recovery path, not a safety net | 2026-08-30 |
| Both of version-check's poll loops are bounded at 60s | `charts/minecraft-fwb/values.yaml` | The mc-monitor loop is `30 × (timeout 15s + sleep 2)` — up to 510s. Written into this repo *while* documenting this incident, which is how easily it happens | 2026-08-30 |
| A sidecar's missing secret can only break the sidecar | `charts/minecraft-fwb/values.yaml` | `minecraft-bedrock.extraEnv` is rendered by plain `toYaml`, never `tpl`, so a secret reference placed there is an unconditional startup dependency for the *game server* container | 2026-09-06 |
| Merging a revert resolves the outage it reverts | implicit | A StatefulSet never replaces a pod that has not become Ready, so a revert of a change that broke pod startup does not apply itself. The revert landed 40 hours before the cluster acted on it | 2026-09-06 |
| An ArgoCD Application with auto-sync converges eventually | implicit | A sync blocked on resource health reports `Running`, never times out, and blocks every later reconcile with `Skipping auto-sync: another operation is in progress` | 2026-09-06 |
| A commit message asserting a manual prerequisite was done is evidence it was done | `44bf487` | It was not, and the corroboration it cited (another ExternalSecret naming the same Vault document) came from a template gated off and never rendered | 2026-09-06 |
| A Bedrock server that logs `Server started.` answers a RakNet status ping | `charts/minecraft-fwb/templates/version-check-cronjob.yaml`, `.github/workflows/ci.yml` | 1.26.51 defaults a freshly generated `server.properties` to `transport=nethernet`, which opens no RakNet listener at all. Both the hourly check and the CI boot gate were written against the ping | 2026-09-15 |
| Production's transport is configured | implicit | Nothing in the chart sets `transport`. Production speaks RakNet only because its PVC still holds a `server.properties` generated by an older build; a restore onto a fresh world would come up NetherNet-only and invisible to every component here | 2026-09-15 |
| A vendor's startup banner describes the release it ships in | `bedrock_server` 1.26.51 | It prints that NetherNet is "the only supported transport type" and that players cannot connect without it. Retail clients join over RakNet on that exact build — it is a deprecation notice written in the present tense | 2026-09-15 |
| Ruling out the evidence you have is evidence for the alternative | implicit | Go clients joining over RakNet were correctly discarded as proof of retail connectivity. The conclusion drawn was "so the banner must be right" rather than "so this is untested", and the test was two minutes of a human's time | 2026-09-15 |

## Conventions

- Times are UTC, matching what the logs emit.
- Quote log lines verbatim in fenced blocks. Do not paraphrase an error.
- Link to the PR that carries each remediation, so the fix and the reasoning
  stay connected.
- Prefer naming the mechanism over naming a culprit.
