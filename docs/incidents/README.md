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

## Conventions

- Times are UTC, matching what the logs emit.
- Quote log lines verbatim in fenced blocks. Do not paraphrase an error.
- Link to the PR that carries each remediation, so the fix and the reasoning
  stay connected.
- Prefer naming the mechanism over naming a culprit.
