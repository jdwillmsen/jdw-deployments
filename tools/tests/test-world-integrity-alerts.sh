#!/usr/bin/env bash
# Proves the world-integrity alerts fire on data loss and stay quiet on
# everything a played-in world does by itself.
#
# Two failure modes these cases exist for, both of which this repo has already
# shipped once:
#
#  1. An alert held by `for:` needs the condition true at *every* evaluation in
#     the window. The signals here go absent -- a map pod restart takes the
#     chunk gauges away, and the corruption line is followed by the server
#     shutting down and taking the bridge with it -- so the window has to live
#     inside the expression. The cases below assert the page survives the thing
#     that measured it disappearing.
#  2. A baseline computed per series resets itself when the series' identity
#     changes. JdwillmsenMinecraftWorldArchiveShrank shipped that way and went
#     quiet on 2026-10-03 with the archive still 3.8% short, because the new
#     exporter pod's only history was the value being tested. The
#     baseline-reset case runs the old expression beside the new one on the
#     same fixture and asserts the old one says nothing -- otherwise the fix is
#     untested and the next rule of this shape repeats it.
#
# The rules are extracted from the rendered chart rather than copied here, so
# the cases cannot drift away from what actually ships.
set -euo pipefail

here="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

if ! command -v promtool >/dev/null 2>&1; then
  # Loud rather than silent: a skipped alert test is an untested alert. CI
  # installs promtool so this branch is never taken there; locally it lets the
  # rest of the suite run on a machine without it.
  echo "SKIP: promtool not on PATH; world-integrity rules not verified"
  exit 0
fi

# Rendered into the production namespace because every rule stamps
# `namespace: {{ .Release.Namespace }}` as a label and pins the same value
# inside its expression. Rendering into helm's default would test a namespace
# that never ships.
helm template minecraft-fwb "$here/charts/minecraft-fwb" \
  --namespace jdwillmsen-prd \
  -f "$here/charts/minecraft-fwb/values.yaml" \
  | python3 -c "
import sys, yaml
for doc in yaml.safe_load_all(sys.stdin):
    if doc and doc.get('kind') == 'PrometheusRule' and doc['metadata']['name'].endswith('-world-integrity'):
        print(yaml.safe_dump({'groups': doc['spec']['groups']}, sort_keys=False))
" > "$work/rules.yaml"
[ -s "$work/rules.yaml" ] || fail "could not extract the world-integrity rules from the chart"

promtool check rules "$work/rules.yaml" >/dev/null || fail "promtool rejected the rendered rules"

# The expression the archive alert shipped with, kept here and nowhere else: it
# is the control for the baseline-reset case below and must never be a rule
# this repo deploys. The only edit is the job name, which follows the release
# name the chart is rendered under above.
cat > "$work/legacy.yaml" <<'EOF'
groups:
  - name: legacy-world-archive
    rules:
      - alert: LegacyWorldArchiveShrank
        expr: |
          (
            backup_last_artifact_bytes{backup_job="minecraft-fwb-backup", artifact="world"}
              < quantile_over_time(0.5, backup_last_artifact_bytes{backup_job="minecraft-fwb-backup", artifact="world"}[7d]) * 0.98
          )
          and (backup_last_artifact_bytes{backup_job="minecraft-fwb-backup", artifact="world"} > 0)
          and (backup_state_reported{backup_job="minecraft-fwb-backup", artifact="world"} == 1)
        for: 15m
        labels:
          severity: critical
EOF

# The chunk, corruption and census cases. Evaluated every minute because that
# is the scrape interval of the map's metrics endpoint, and because the point of
# the missing-chunk rule is that it fires at the first evaluation after a loss
# rather than some number of minutes later.
#
# A timestamp series counting 60 per minute reads back the evaluation time in
# seconds, so `time() - series` is zero: a measurement taken right now. Holding
# it at 0 instead makes that difference the evaluation time, i.e. arbitrarily
# stale.
cat > "$work/tests-chunks.yaml" <<'EOF'
rule_files:
  - rules.yaml
evaluation_interval: 1m
tests:
  # The 2026-10-02 loss, in the numbers it actually had: 4,753 overworld,
  # 1,413 nether and 294 end. The census lands at minute 15 and the alert is
  # expected at minute 15, not at minute 20 -- there is no `for:` to wait out,
  # which is the whole requirement.
  - interval: 1m
    name: a chunk that disappears pages at the first evaluation after the census
    input_series:
      - series: 'mcmap_world_chunks_missing{namespace="jdwillmsen-prd",dimension="overworld",instance="10.244.6.148:9090"}'
        values: '0+0x14 4753+0x45'
      - series: 'mcmap_world_chunks_missing{namespace="jdwillmsen-prd",dimension="nether",instance="10.244.6.148:9090"}'
        values: '0+0x14 1413+0x45'
      - series: 'mcmap_world_chunks_missing{namespace="jdwillmsen-prd",dimension="end",instance="10.244.6.148:9090"}'
        values: '0+0x14 294+0x45'
    alert_rule_test:
      - eval_time: 14m
        alertname: JdwillmsenMinecraftWorldChunksMissing
        exp_alerts: []
      - eval_time: 15m
        alertname: JdwillmsenMinecraftWorldChunksMissing
        exp_alerts:
          - exp_labels:
              severity: critical
              namespace: jdwillmsen-prd
            exp_annotations:
              summary: "Minecraft FWB is missing 6460 world chunks"
              description: "The map's census found 6460 chunks that this world has held before and does not hold now. A Bedrock world never deletes a chunk in normal play, so treat this as data loss until proven otherwise, and do not let tonight's backup rotate away the last good archive. The dimension split and the block coordinates are on the world integrity dashboard and in the map pod's log. Restore procedure: charts/minecraft-fwb/README.md, \"World chunk loss\"."
              runbook_url: "https://github.com/jdwillmsen/jdw-deployments/blob/main/charts/minecraft-fwb/README.md#world-chunk-loss"

  # THE REGRESSION CASE FOR THE WINDOW.
  #
  # The map pod goes away five minutes after reporting the loss -- an OOM kill
  # during the render that follows the census, a node drain, a chart sync. The
  # gauges go with it, and an expression that read them instantaneously would
  # resolve the page at the moment the only evidence disappeared. Replacing the
  # window with a `for:` of any length turns this case red.
  - interval: 1m
    name: the map pod taking the gauges away does not resolve the page
    input_series:
      - series: 'mcmap_world_chunks_missing{namespace="jdwillmsen-prd",dimension="overworld",instance="10.244.6.148:9090"}'
        values: '0+0x14 4753+0x5'
      - series: 'mcmap_world_chunks_missing{namespace="jdwillmsen-prd",dimension="nether",instance="10.244.6.148:9090"}'
        values: '0+0x14 1413+0x5'
      - series: 'mcmap_world_chunks_missing{namespace="jdwillmsen-prd",dimension="end",instance="10.244.6.148:9090"}'
        values: '0+0x14 294+0x5'
    alert_rule_test:
      # Twenty minutes after the last sample the series has been absent four
      # times longer than Prometheus' staleness delta, and the alert is still up.
      - eval_time: 40m
        alertname: JdwillmsenMinecraftWorldChunksMissing
        exp_alerts:
          - exp_labels:
              severity: critical
              namespace: jdwillmsen-prd
            exp_annotations:
              summary: "Minecraft FWB is missing 6460 world chunks"
              description: "The map's census found 6460 chunks that this world has held before and does not hold now. A Bedrock world never deletes a chunk in normal play, so treat this as data loss until proven otherwise, and do not let tonight's backup rotate away the last good archive. The dimension split and the block coordinates are on the world integrity dashboard and in the map pod's log. Restore procedure: charts/minecraft-fwb/README.md, \"World chunk loss\"."
              runbook_url: "https://github.com/jdwillmsen/jdw-deployments/blob/main/charts/minecraft-fwb/README.md#world-chunk-loss"
      # Past the window. Nothing has measured the world for half an hour, which
      # is JdwillmsenMinecraftWorldNotCensused's to say, not this rule's.
      - eval_time: 47m
        alertname: JdwillmsenMinecraftWorldChunksMissing
        exp_alerts: []

  # A world being played in. The count rises every census, nothing is missing,
  # and the measurement is current: all three rules have nothing to say. This
  # is the case a baseline built from a minimum over a window would page on,
  # every time anyone explored.
  - interval: 1m
    name: a world that is only growing pages nothing
    input_series:
      - series: 'mcmap_world_chunks{namespace="jdwillmsen-prd",dimension="overworld",instance="10.244.6.148:9090"}'
        values: '128032+1x60'
      - series: 'mcmap_world_chunks_missing{namespace="jdwillmsen-prd",dimension="overworld",instance="10.244.6.148:9090"}'
        values: '0+0x60'
      - series: 'mcmap_world_census_last_success_timestamp_seconds{namespace="jdwillmsen-prd",instance="10.244.6.148:9090"}'
        values: '0+60x60'
    alert_rule_test:
      - eval_time: 55m
        alertname: JdwillmsenMinecraftWorldChunksMissing
        exp_alerts: []
      - eval_time: 55m
        alertname: JdwillmsenMinecraftWorldChunkCountDropped
        exp_alerts: []
      - eval_time: 55m
        alertname: JdwillmsenMinecraftWorldNotCensused
        exp_alerts: []

  # The count rule's reason for existing. The map's ledger lives on its volume,
  # so a fresh or restored volume leaves it with no memory: the first census on
  # a damaged world reports nothing missing, because it has nothing to compare
  # against. The count is then the only evidence, and it is below its own
  # recent maximum.
  - interval: 1m
    name: a count that falls pages even when the ledger has nothing to compare against
    input_series:
      - series: 'mcmap_world_chunks{namespace="jdwillmsen-prd",dimension="overworld",instance="10.244.6.148:9090"}'
        values: '128032+0x59 123279+0x30'
      - series: 'mcmap_world_chunks_missing{namespace="jdwillmsen-prd",dimension="overworld",instance="10.244.6.148:9090"}'
        values: '0+0x90'
    alert_rule_test:
      - eval_time: 59m
        alertname: JdwillmsenMinecraftWorldChunkCountDropped
        exp_alerts: []
      # Inside `for: 5m`. Pending, not firing.
      - eval_time: 62m
        alertname: JdwillmsenMinecraftWorldChunkCountDropped
        exp_alerts: []
      - eval_time: 70m
        alertname: JdwillmsenMinecraftWorldChunkCountDropped
        exp_alerts:
          - exp_labels:
              severity: critical
              namespace: jdwillmsen-prd
            exp_annotations:
              summary: "Minecraft FWB holds fewer world chunks than it recently did"
              description: "The world's chunk count is 123279, below its own maximum over the last 24h. A played-in Bedrock world only gains chunks. This fires instead of the missing-chunk alert when the map has no ledger to compare against -- a fresh map volume, or one that was restored -- so the count is the only evidence. It also fires after a deliberate restore to an older backup, which is a real statement about the world and clears once the baseline window rolls past it. Restore procedure: charts/minecraft-fwb/README.md, \"World chunk loss\"."
              runbook_url: "https://github.com/jdwillmsen/jdw-deployments/blob/main/charts/minecraft-fwb/README.md#world-chunk-loss"
      # Nothing is missing against the ledger, so the other rule is right to
      # stay quiet. The two are not redundant; they answer different questions.
      - eval_time: 70m
        alertname: JdwillmsenMinecraftWorldChunksMissing
        exp_alerts: []

  # THE SAME SHAPE AS THE ARCHIVE BUG, ASSERTED NOT TO RECUR.
  #
  # The map pod is replaced at minute 40 and comes back on a fresh volume with
  # a short world. The new pod is a new series, so a baseline taken after the
  # aggregation would be the damaged count vouching for itself. Taking each
  # series' own maximum first means the pod that saw the full world still
  # supplies the number.
  - interval: 1m
    name: a map pod replacement does not let a damaged world become its own baseline
    input_series:
      - series: 'mcmap_world_chunks{namespace="jdwillmsen-prd",dimension="overworld",instance="10.244.6.148:9090"}'
        values: '128032+0x39'
      - series: 'mcmap_world_chunks{namespace="jdwillmsen-prd",dimension="overworld",instance="10.244.7.31:9090"}'
        values: '_x40 123279+0x30'
    alert_rule_test:
      # The old pod's last sample is still inside the staleness delta, so both
      # series answer and the larger is the current count.
      - eval_time: 44m
        alertname: JdwillmsenMinecraftWorldChunkCountDropped
        exp_alerts: []
      - eval_time: 52m
        alertname: JdwillmsenMinecraftWorldChunkCountDropped
        exp_alerts:
          - exp_labels:
              severity: critical
              namespace: jdwillmsen-prd
            exp_annotations:
              summary: "Minecraft FWB holds fewer world chunks than it recently did"
              description: "The world's chunk count is 123279, below its own maximum over the last 24h. A played-in Bedrock world only gains chunks. This fires instead of the missing-chunk alert when the map has no ledger to compare against -- a fresh map volume, or one that was restored -- so the count is the only evidence. It also fires after a deliberate restore to an older backup, which is a real statement about the world and clears once the baseline window rolls past it. Restore procedure: charts/minecraft-fwb/README.md, \"World chunk loss\"."
              runbook_url: "https://github.com/jdwillmsen/jdw-deployments/blob/main/charts/minecraft-fwb/README.md#world-chunk-loss"

  # The server's own report, and the reason its window is six hours. The
  # run-time form of this line shuts the server down; the bridge is a sidecar
  # in that pod, so the gauge is gone within a minute of the only evidence
  # appearing, and the replacement pod reports a clean zero.
  - interval: 1m
    name: a corruption line keeps paging across the restart it causes
    input_series:
      - series: 'mc_console_bridge_world_corruption_detected{namespace="jdwillmsen-prd",instance="10.244.5.10:9102"}'
        values: '0+0x9 1+0x5'
      - series: 'mc_console_bridge_world_corruption_detected{namespace="jdwillmsen-prd",instance="10.244.5.11:9102"}'
        values: '_x20 0+0x400'
    alert_rule_test:
      - eval_time: 5m
        alertname: JdwillmsenMinecraftWorldCorruptionReported
        exp_alerts: []
      - eval_time: 12m
        alertname: JdwillmsenMinecraftWorldCorruptionReported
        exp_alerts:
          - exp_labels:
              severity: critical
              namespace: jdwillmsen-prd
            exp_annotations:
              summary: "Minecraft FWB reported its world database corrupt"
              description: "The server logged either \"status NOT OK(Corruption: N missing files)\" at world open or \"Level corruption detected\" at run time within the last 6h. The repair it runs afterwards drops the records it cannot find, so the server coming back up is not the world being intact. Check the map's chunk count for how much went, and stop the backup before it rotates the last good archive away. Restore procedure: charts/minecraft-fwb/README.md, \"World chunk loss\"."
              runbook_url: "https://github.com/jdwillmsen/jdw-deployments/blob/main/charts/minecraft-fwb/README.md#world-chunk-loss"
      # Two hours later the pod that saw the line is long gone and its
      # replacement is reporting zero. Still paging.
      - eval_time: 120m
        alertname: JdwillmsenMinecraftWorldCorruptionReported
        exp_alerts:
          - exp_labels:
              severity: critical
              namespace: jdwillmsen-prd
            exp_annotations:
              summary: "Minecraft FWB reported its world database corrupt"
              description: "The server logged either \"status NOT OK(Corruption: N missing files)\" at world open or \"Level corruption detected\" at run time within the last 6h. The repair it runs afterwards drops the records it cannot find, so the server coming back up is not the world being intact. Check the map's chunk count for how much went, and stop the backup before it rotates the last good archive away. Restore procedure: charts/minecraft-fwb/README.md, \"World chunk loss\"."
              runbook_url: "https://github.com/jdwillmsen/jdw-deployments/blob/main/charts/minecraft-fwb/README.md#world-chunk-loss"
      # Past the window, with a bridge that has reported clean the whole time.
      # Pinned so that widening the window stays a deliberate edit.
      - eval_time: 376m
        alertname: JdwillmsenMinecraftWorldCorruptionReported
        exp_alerts: []

  # A bridge that has never seen corruption says so, rather than saying
  # nothing: the rule must not read a healthy gauge as a raised one.
  - interval: 1m
    name: a clean bridge does not page
    input_series:
      - series: 'mc_console_bridge_world_corruption_detected{namespace="jdwillmsen-prd",instance="10.244.5.10:9102"}'
        values: '0+0x60'
    alert_rule_test:
      - eval_time: 55m
        alertname: JdwillmsenMinecraftWorldCorruptionReported
        exp_alerts: []

  # The measurement stopping entirely. Every other rule here is a comparison,
  # and a comparison never matches a series nobody is producing, so without
  # this arm a map that cannot read the world reads as the healthiest state of
  # all.
  - interval: 1m
    name: a census metric that is not there at all is noticed
    input_series: []
    alert_rule_test:
      - eval_time: 10m
        alertname: JdwillmsenMinecraftWorldNotCensused
        exp_alerts: []
      - eval_time: 20m
        alertname: JdwillmsenMinecraftWorldNotCensused
        exp_alerts:
          - exp_labels:
              severity: warning
              namespace: jdwillmsen-prd
            exp_annotations:
              summary: "Minecraft FWB world chunks are not being counted"
              description: "No chunk census has succeeded for more than 2h, or the metric is gone entirely, so the chunk-loss alerts cannot fire whatever the world is doing. The census runs inside the map pod after each snapshot, so this usually means the map or the console bridge is down rather than the world. mcmap_world_census_failures_total and the map pod's log say which."
              runbook_url: "https://github.com/jdwillmsen/jdw-deployments/blob/main/charts/minecraft-fwb/README.md#world-chunk-loss"

  # The other shape: the metric is published and frozen. The map holds its last
  # successful census time rather than clearing it, so a census that keeps
  # failing leaves a number that no longer describes the world.
  - interval: 1m
    name: a census timestamp that stops advancing is noticed
    input_series:
      - series: 'mcmap_world_census_last_success_timestamp_seconds{namespace="jdwillmsen-prd",instance="10.244.6.148:9090"}'
        values: '0+0x140'
    alert_rule_test:
      # An hour stale. Inside the quiet windows the map legitimately leaves the
      # world alone for 80 minutes, so this must not page.
      - eval_time: 60m
        alertname: JdwillmsenMinecraftWorldNotCensused
        exp_alerts: []
      # Two hours and ten minutes: past the bound, inside the `for`.
      - eval_time: 130m
        alertname: JdwillmsenMinecraftWorldNotCensused
        exp_alerts: []
      - eval_time: 140m
        alertname: JdwillmsenMinecraftWorldNotCensused
        exp_alerts:
          - exp_labels:
              severity: warning
              namespace: jdwillmsen-prd
            exp_annotations:
              summary: "Minecraft FWB world chunks are not being counted"
              description: "No chunk census has succeeded for more than 2h, or the metric is gone entirely, so the chunk-loss alerts cannot fire whatever the world is doing. The census runs inside the map pod after each snapshot, so this usually means the map or the console bridge is down rather than the world. mcmap_world_census_failures_total and the map pod's log say which."
              runbook_url: "https://github.com/jdwillmsen/jdw-deployments/blob/main/charts/minecraft-fwb/README.md#world-chunk-loss"
EOF

( cd "$work" && promtool test rules tests-chunks.yaml ) || fail "chunk, corruption and census alert tests did not pass"

# The archive cases. The rule looks back seven days, so a fixture has to carry a
# week of continuous samples: anything sparser than Prometheus' 5m lookback
# delta goes stale between points and the rule silently evaluates against
# nothing. Four-minute samples, evaluated every fifteen, which is the rule's own
# `for` and keeps a 170-hour fixture to a few hundred evaluations.
#
# The sizes are archives this backup actually produced, not invented numbers:
# the question this rule got wrong is which real movements are losses.
cat > "$work/tests-archive.yaml" <<'EOF'
rule_files:
  - rules.yaml
  - legacy.yaml
evaluation_interval: 15m
tests:
  # THE BASELINE-RESET CASE.
  #
  # A week of archives at 759,548,865 bytes, then the 2026-10-02 loss brings the
  # next one in at 730,898,848 -- 3.8% down -- at the same moment the exporter
  # pod is replaced. That coincidence is not contrived: the exporter is restarted
  # by the same chart syncs that follow an incident, and it is what actually
  # happened.
  #
  # The new pod is a new series whose entire history is the small value, so the
  # old expression compares it against itself and cannot be true. The control
  # rule asserts exactly that, at every time the real rule is firing.
  - interval: 4m
    name: an exporter pod replacing itself at the moment of a loss does not reset the baseline
    input_series:
      - series: 'backup_last_artifact_bytes{namespace="jdwillmsen-prd",backup_job="minecraft-fwb-backup",artifact="world",instance="10.244.6.162:9101"}'
        values: '759548865+0x2519'
      - series: 'backup_state_reported{namespace="jdwillmsen-prd",backup_job="minecraft-fwb-backup",artifact="world",instance="10.244.6.162:9101"}'
        values: '1+0x2519'
      - series: 'backup_last_artifact_bytes{namespace="jdwillmsen-prd",backup_job="minecraft-fwb-backup",artifact="world",instance="10.244.7.139:9101"}'
        values: '_x2520 730898848+0x15'
      - series: 'backup_state_reported{namespace="jdwillmsen-prd",backup_job="minecraft-fwb-backup",artifact="world",instance="10.244.7.139:9101"}'
        values: '_x2520 1+0x15'
    alert_rule_test:
      # The outgoing pod's last sample is still inside the staleness delta, so
      # the largest current report is the old, correct size.
      - eval_time: 168h
        alertname: JdwillmsenMinecraftWorldArchiveShrank
        exp_alerts: []
      # The old series has gone stale and the small value is the only current
      # one. Inside `for: 15m`.
      - eval_time: 168h15m
        alertname: JdwillmsenMinecraftWorldArchiveShrank
        exp_alerts: []
      - eval_time: 168h30m
        alertname: JdwillmsenMinecraftWorldArchiveShrank
        exp_alerts:
          - exp_labels:
              severity: critical
              namespace: jdwillmsen-prd
              backup_job: minecraft-fwb-backup
              artifact: world
            exp_annotations:
              summary: "Minecraft world backup is smaller than its recent typical size"
              description: "The newest world archive is more than 2% smaller than the median of those taken in the past 7d. A world that is played in grows; it does not shrink, and it does not fall below its own recent middle. Treat this as data loss until proven otherwise and do not let the next backup rotate the good one away. A LevelDB compaction does not produce this: it inflates one archive rather than shrinking the next, and the median baseline already absorbs that. The chunk-loss alerts above answer the same question within 15 minutes instead of a day; this one still earns its place because it reads the archive rather than the live world. Restore procedure: charts/minecraft-fwb/README.md, \"World chunk loss\"."
              runbook_url: "https://github.com/jdwillmsen/jdw-deployments/blob/main/charts/minecraft-fwb/README.md#world-chunk-loss"
      # The control. This is the expression the alert shipped with, on the same
      # fixture, saying nothing at the two times above and at the time the real
      # rule is firing.
      - eval_time: 168h30m
        alertname: LegacyWorldArchiveShrank
        exp_alerts: []
      - eval_time: 168h45m
        alertname: LegacyWorldArchiveShrank
        exp_alerts: []

  # THE FALSE POSITIVE THE MEDIAN BASELINE EXISTS FOR, carried over with the
  # rule so that re-homing it into this chart does not quietly lose its cases.
  #
  # Seven consecutive archives across a LevelDB compaction. The sixth caught
  # both generations of the tables being merged on disk and came out 2.6% larger
  # than the fifth; the seventh held one generation and read 2.7% under that
  # peak, which is what paged critical for a day over a world that had lost
  # nothing. Against the median the seventh is not a drop at all.
  - interval: 4m
    name: an archive that shrank only against a compaction-inflated peak does not page
    input_series:
      - series: 'backup_last_artifact_bytes{namespace="jdwillmsen-prd",backup_job="minecraft-fwb-backup",artifact="world",instance="10.244.7.245:9101"}'
        values: '394585604+0x359 394387039+0x359 394481069+0x359 398803255+0x359 399655669+0x359 410041241+0x359 398973244+0x359'
      - series: 'backup_state_reported{namespace="jdwillmsen-prd",backup_job="minecraft-fwb-backup",artifact="world",instance="10.244.7.245:9101"}'
        values: '1+0x2519'
    alert_rule_test:
      - eval_time: 140h
        alertname: JdwillmsenMinecraftWorldArchiveShrank
        exp_alerts: []
      - eval_time: 150h
        alertname: JdwillmsenMinecraftWorldArchiveShrank
        exp_alerts: []
      - eval_time: 167h
        alertname: JdwillmsenMinecraftWorldArchiveShrank
        exp_alerts: []

  # THE TRUE POSITIVE THE BASELINE MUST NOT COST.
  #
  # 2026-08-30: 394,585,604 -> 372,064,563, restored before the next backup ran.
  # It lived in exactly one archive, which is why "require the shrink to persist
  # across two archives" was rejected -- it would have bought silence on the
  # compaction above by going silent on this.
  - interval: 4m
    name: a single archive 5.5% under the weekly median still pages critical
    input_series:
      - series: 'backup_last_artifact_bytes{namespace="jdwillmsen-prd",backup_job="minecraft-fwb-backup",artifact="world",instance="10.244.7.245:9101"}'
        values: '386039110+0x359 386049005+0x359 391234063+0x359 391368573+0x359 392504624+0x359 393604306+0x359 394585604+0x359 372064563+0x59'
      - series: 'backup_state_reported{namespace="jdwillmsen-prd",backup_job="minecraft-fwb-backup",artifact="world",instance="10.244.7.245:9101"}'
        values: '1+0x2579'
    alert_rule_test:
      # The loss lands here. Inside `for: 15m`.
      - eval_time: 168h
        alertname: JdwillmsenMinecraftWorldArchiveShrank
        exp_alerts: []
      - eval_time: 168h30m
        alertname: JdwillmsenMinecraftWorldArchiveShrank
        exp_alerts:
          - exp_labels:
              severity: critical
              namespace: jdwillmsen-prd
              backup_job: minecraft-fwb-backup
              artifact: world
            exp_annotations:
              summary: "Minecraft world backup is smaller than its recent typical size"
              description: "The newest world archive is more than 2% smaller than the median of those taken in the past 7d. A world that is played in grows; it does not shrink, and it does not fall below its own recent middle. Treat this as data loss until proven otherwise and do not let the next backup rotate the good one away. A LevelDB compaction does not produce this: it inflates one archive rather than shrinking the next, and the median baseline already absorbs that. The chunk-loss alerts above answer the same question within 15 minutes instead of a day; this one still earns its place because it reads the archive rather than the live world. Restore procedure: charts/minecraft-fwb/README.md, \"World chunk loss\"."
              runbook_url: "https://github.com/jdwillmsen/jdw-deployments/blob/main/charts/minecraft-fwb/README.md#world-chunk-loss"

  # A producer that has not reported is not a world that shrank. The exporter
  # came up with no state and published placeholder zeros for 19h on 2026-08-27;
  # zero against a week of real archives is a 100% drop. BackupStateNeverReported
  # owns that, which is what the state guard defers to.
  - interval: 4m
    name: placeholder zeros from an exporter with no state do not page this rule
    input_series:
      - series: 'backup_last_artifact_bytes{namespace="jdwillmsen-prd",backup_job="minecraft-fwb-backup",artifact="world",instance="10.244.7.245:9101"}'
        values: '394585604+0x359 394387039+0x359 394481069+0x359 398803255+0x359 399655669+0x359 400041241+0x359 400973244+0x359 0+0x284'
      - series: 'backup_state_reported{namespace="jdwillmsen-prd",backup_job="minecraft-fwb-backup",artifact="world",instance="10.244.7.245:9101"}'
        values: '1+0x2519 0+0x284'
    alert_rule_test:
      - eval_time: 168h30m
        alertname: JdwillmsenMinecraftWorldArchiveShrank
        exp_alerts: []
      - eval_time: 180h
        alertname: JdwillmsenMinecraftWorldArchiveShrank
        exp_alerts: []

  # A steady week with nothing wrong, so that "fires" above is a statement about
  # the fixture rather than about the rule being unconditional.
  - interval: 4m
    name: a week of archives at their own median pages nothing
    input_series:
      - series: 'backup_last_artifact_bytes{namespace="jdwillmsen-prd",backup_job="minecraft-fwb-backup",artifact="world",instance="10.244.7.245:9101"}'
        values: '400000000+0x2519'
      - series: 'backup_state_reported{namespace="jdwillmsen-prd",backup_job="minecraft-fwb-backup",artifact="world",instance="10.244.7.245:9101"}'
        values: '1+0x2519'
    alert_rule_test:
      - eval_time: 168h
        alertname: JdwillmsenMinecraftWorldArchiveShrank
        exp_alerts: []
EOF

( cd "$work" && promtool test rules tests-archive.yaml ) || fail "world-archive alert tests did not pass"

echo "PASS: chunk loss pages within one census and survives the map pod going away, the server's corruption line outlives the restart it causes, a growing world pages nothing, and the archive baseline no longer resets when the exporter pod moves"
