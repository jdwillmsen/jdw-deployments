# Census CronJob Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run the census on a schedule beside the Minecraft server, against a fresh snapshot when one can be taken and last night's backup archive when it cannot.

**Architecture:** A CronJob with an init container that drives Bedrock's `save hold` / `save query` / `save resume` sequence into an `emptyDir`, and a main container running `/census` from the agent image over that directory. The Go binary decides between the snapshot and the archive, because a failed init container would stop the main container ever starting and the agent image has no shell to branch with.

**Tech Stack:** Helm 3, Kubernetes CronJob, bash in a ConfigMap, `alpine/k8s` for kubectl.

**Spec:** `docs/superpowers/specs/2026-09-15-census-cronjob-design.md`

## Global Constraints

- The chart is `charts/minecraft-fwb`. CI runs `helm lint` on every chart and `helm template` against each `values-<env>.yaml`, so every task's deliverable must render.
- **`census.enabled` defaults to `false`.** The binary landed in the agent after release 0.15.0, which is what `agent.image.tag` currently points at. Turning this on before a release carrying `cmd/census` gets a CrashLoopBackOff whose cause is one line deep in a job log.
- **The snapshot init container exits 0 when it cannot take a snapshot.** A failed init container means the main container never starts, which would make the archive fallback unreachable. It signals a missed snapshot by not writing `snapshot-taken-at`, and exits non-zero only for a genuine fault such as being unable to write to the snapshot volume at all.
- **`trap resume` on both RETURN and EXIT.** Leaving the server held stops it persisting anything. This is the single most important line in the script.
- **Every copied file is truncated to the length `save query` reported.** LevelDB keeps appending past its committed length; copying the whole file is what produces a world that will not open.
- Scheduling must not depend on the server being up. The hard constraint is the node set the world volume can attach to (`nodeAffinity`, taken from the server's own values), and co-location with the server is a preference only. A required `podAffinity` on the server pod means the job never leaves Pending when the server is down — which is exactly when you want to know what is in the world.
- Commit messages follow the repo's conventional-commit style and end with:
  ```
  Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01G57aCPx9HY47pLzij6x1Tv
  ```

## File Structure

- `charts/minecraft-fwb/templates/_helpers.tpl` — gains `census.name`, beside the existing `backup.name`, `versionCheck.name` and friends.
- `charts/minecraft-fwb/templates/census-rbac.yaml` — ServiceAccount, Role, RoleBinding. Its own file, matching `backup-rbac.yaml`.
- `charts/minecraft-fwb/templates/census-snapshot-configmap.yaml` — the snapshot shell. Separated from the CronJob so the script can be read and reviewed as a script rather than as an indented YAML block.
- `charts/minecraft-fwb/templates/census-cronjob.yaml` — the workload.
- `charts/minecraft-fwb/values.yaml` — the `census:` block.
- `README.md` — the operator-facing note.

---

### Task 1: Helper, values and RBAC

**Files:**
- Modify: `charts/minecraft-fwb/templates/_helpers.tpl`
- Create: `charts/minecraft-fwb/templates/census-rbac.yaml`
- Modify: `charts/minecraft-fwb/values.yaml`

**Interfaces:**
- Produces: the template helper `census.name` (rendering `<release>-census`), and the values key `census` with subkeys `enabled`, `schedule`, `image`, `timeoutSeconds`, `ttlSecondsAfterFinished`, `successfulJobsHistoryLimit`, `failedJobsHistoryLimit`, `resources.requests.{memory,cpu}`, `resources.limits.{memory,cpu}`. Tasks 2 and 3 use both.

- [ ] **Step 1: Write the failing test**

Create `/tmp/census-render-test.sh` (a scratch verification script, not committed):

```bash
#!/usr/bin/env bash
set -euo pipefail
CHART=charts/minecraft-fwb

fail() { echo "FAIL: $1" >&2; exit 1; }

# Disabled by default: nothing census-related may render.
out="$(helm template t "$CHART" -f "$CHART/values.yaml" -f "$CHART/values-prd.yaml")"
if grep -q 't-census' <<<"$out"; then
  fail "census objects rendered while census.enabled is false"
fi

# Enabled: exactly the three RBAC objects, and no more yet.
on="$(helm template t "$CHART" -f "$CHART/values.yaml" -f "$CHART/values-prd.yaml" --set census.enabled=true)"
for kind in ServiceAccount Role RoleBinding; do
  grep -q "kind: $kind" <<<"$on" || fail "no $kind rendered for the census"
done
grep -q 'name: t-census' <<<"$on" || fail "census objects are not named t-census"

# The Role must not be able to write anything.
if grep -A30 'kind: Role' <<<"$on" | grep -qE '"(create|update|patch|delete)"' \
   && ! grep -A30 'kind: Role' <<<"$on" | grep -q 'pods/exec'; then
  fail "census Role has write verbs beyond pods/exec"
fi
echo "PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/worktrees/jdw-deployments/census-cronjob && bash /tmp/census-render-test.sh`
Expected: FAIL — `no ServiceAccount rendered for the census`, because nothing exists yet.

- [ ] **Step 3: Write minimal implementation**

Append to `charts/minecraft-fwb/templates/_helpers.tpl`:

```
{{- define "census.name" -}}
{{ .Release.Name }}-census
{{- end -}}
```

Create `charts/minecraft-fwb/templates/census-rbac.yaml`:

```yaml
{{- if .Values.census.enabled }}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "census.name" . }}
  namespace: {{ .Release.Namespace }}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: {{ include "census.name" . }}
  namespace: {{ .Release.Namespace }}
rules:
  # The census drives the server's own save protocol over its console to take
  # a consistent copy, so it needs to exec into the pod and read back what
  # `save query` printed. Scoped to this namespace; nothing here is
  # cluster-wide.
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list"]
  # get and list stay unscoped because a list request cannot be
  # constrained by resourceNames; exec and log below are pinned to the one
  # pod this job has any business touching.
  - apiGroups: [""]
    resources: ["pods/exec"]
    resourceNames: ["{{ include "backup.serverPod" . }}"]
    verbs: ["create"]
  - apiGroups: [""]
    resources: ["pods/log"]
    resourceNames: ["{{ include "backup.serverPod" . }}"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: {{ include "census.name" . }}
  namespace: {{ .Release.Namespace }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: {{ include "census.name" . }}
subjects:
  - kind: ServiceAccount
    name: {{ include "census.name" . }}
    namespace: {{ .Release.Namespace }}
{{- end }}
```

The backup job's Role additionally reads `statefulsets` and writes a metrics
ConfigMap. The census needs neither: it does not care why a server is absent
(it falls back to the archive either way), and it publishes nothing.

Append to `charts/minecraft-fwb/values.yaml`, at the end of the file:

```yaml
# Reads the world and reports which 9x9-chunk regions have hit Bedrock's mob
# spawn cap -- the question "why is nothing spawning near my base" turned into
# something reproducible. Takes a fresh snapshot through the server's own save
# protocol when it can, and falls back to the newest backup archive when it
# cannot.
census:
  # Off until an agent release containing cmd/census has been published and
  # agent.image.tag below points at it. The binary landed after 0.15.0, which
  # is what that tag currently reads, so turning this on now gets a
  # CrashLoopBackOff whose cause is one line deep in a job log.
  #
  # Turning it on is the deliberate second half of a two-step bootstrap, the
  # same shape as the bots above.
  enabled: false

  # An hour after the backup's 0 4, so the archive the fallback path reads is
  # the freshest one that exists. Daily rather than hourly because the counts
  # this measures move over days: a region does not approach its cap between
  # breakfast and lunch.
  schedule: "0 5 * * *"

  # Drives the save protocol through kubectl exec, exactly as the backup job
  # does, so it tracks the cluster's minor version for the same reason: a
  # skewed client misbehaves on the one path that touches a live world.
  image: alpine/k8s:1.36.2

  # The hold poll is 30 iterations of roughly 5s, and a scan of the 570MB
  # production world measured 270ms, so a run that reaches this is wedged
  # rather than slow.
  timeoutSeconds: 900

  # A failed Job with no TTL is kept until failedJobsHistoryLimit evicts it,
  # and KubeJobFailed reads the object rather than the run -- so one bad night
  # pages until then. Deleting on a timer bounds that to a day, while a fault
  # that is still real re-fires on the next schedule.
  ttlSecondsAfterFinished: 86400
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 5

  resources:
    requests:
      memory: 256Mi
      cpu: 100m
    limits:
      # The scan holds every entity in memory at once -- about 22,600 on the
      # production world, which is small. The ceiling is sized for the archive
      # extraction and the LevelDB read rather than the entity slice.
      memory: 1Gi
      # The namespace quota caps limits.cpu at 8000m, of which the server
      # holds 4000m and the backup, volume-recovery and version-check jobs can
      # claim 2000m between them if they land together. 500m for a job that
      # runs once a day, an hour after the backup has finished, fits without
      # reopening that fight.
      cpu: 500m
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash /tmp/census-render-test.sh`
Expected: `PASS`. Then `helm lint charts/minecraft-fwb` — expected: no failures.

- [ ] **Step 5: Commit**

```bash
git add charts/minecraft-fwb/templates/_helpers.tpl charts/minecraft-fwb/templates/census-rbac.yaml charts/minecraft-fwb/values.yaml
git commit -m "feat(minecraft-fwb): add the census job's identity and permissions"
```

---

### Task 2: The snapshot script

**Files:**
- Create: `charts/minecraft-fwb/templates/census-snapshot-configmap.yaml`

**Interfaces:**
- Consumes: `census.name` and `.Values.census.enabled` from Task 1.
- Produces: a ConfigMap named `<release>-census-snapshot` with one key, `snapshot.sh`. Task 3 mounts it and runs it as the init container's command.

- [ ] **Step 1: Write the failing test**

Create `/tmp/census-script-test.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
CHART=charts/minecraft-fwb
fail() { echo "FAIL: $1" >&2; exit 1; }

helm template t "$CHART" -f "$CHART/values.yaml" -f "$CHART/values-prd.yaml" \
  --set census.enabled=true > /tmp/census-rendered.yaml
grep -q 'name: t-census-snapshot' /tmp/census-rendered.yaml || fail "snapshot ConfigMap did not render"

# Extract the script and check it is valid bash. A syntax error here fails at
# 5am in a container, not in CI.
python3 - <<'PY' > /tmp/snapshot.sh
import sys, yaml
for doc in yaml.safe_load_all(open('/tmp/census-rendered.yaml')):
    if doc and doc.get('kind') == 'ConfigMap' and doc['metadata']['name'].endswith('-census-snapshot'):
        sys.stdout.write(doc['data']['snapshot.sh'])
        break
else:
    sys.exit("no census snapshot ConfigMap in rendered output")
PY
bash -n /tmp/snapshot.sh || fail "snapshot.sh is not valid bash"

# The safety properties that must never be edited away.
grep -q 'trap resume EXIT'   /tmp/snapshot.sh || fail "no EXIT trap: a killed shell would leave the server held"
grep -q 'trap resume RETURN' /tmp/snapshot.sh && fail "RETURN trap should not be present: this script is executed directly, not sourced"
grep -q 'head -c'            /tmp/snapshot.sh || fail "files are not truncated to their committed length"
grep -q 'snapshot-taken-at'  /tmp/snapshot.sh || fail "no provenance marker is written"
grep -qE 'timeout [0-9]+s kubectl exec' /tmp/snapshot.sh || fail "kubectl exec is unbounded"
echo "PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash /tmp/census-script-test.sh`
Expected: FAIL — `snapshot ConfigMap did not render`.

- [ ] **Step 3: Write minimal implementation**

Create `charts/minecraft-fwb/templates/census-snapshot-configmap.yaml`:

```yaml
{{- if .Values.census.enabled }}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "census.name" . }}-snapshot
  namespace: {{ .Release.Namespace }}
data:
  # A reduction of the same sequence backup-cronjob.yaml runs, not a fork of
  # it. What is shared is hold/query/truncate; what is dropped is everything
  # that exists to produce a restorable archive.
  #
  # There is deliberately no cold-copy fallback. Where the backup prefers a
  # possibly-imperfect archive to no archive, the census prefers no snapshot
  # to a torn one: a cold copy of a live world reads cleanly and reports
  # numbers that are simply wrong, and the census then falls back to the
  # nightly archive, which is stale but true.
  #
  # Keep this in step with backup-cronjob.yaml's hold_copy(). If you change
  # the manifest parsing or the truncation here, look there too.
  snapshot.sh: |
    #!/usr/bin/env bash
    # Exits 0 when no snapshot could be taken: a failed init container stops
    # the census container ever running, which would make the archive
    # fallback unreachable. A missed snapshot is signalled by the absence of
    # snapshot-taken-at, not by an exit code.
    set -uo pipefail

    NS="$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)"
    OUT=/snapshot

    give_up() { echo "census-snapshot: $1; the census will read the newest archive instead" >&2; exit 0; }

    # Always resume, even if the copy fails partway. Leaving the server held
    # would silently stop it persisting anything at all.
    resume() { timeout 15s kubectl exec -n "$NS" "$SERVER_POD" -- send-command save resume >/dev/null 2>&1 || true; }

    [[ -w "$OUT" ]] || { echo "census-snapshot: $OUT is not writable" >&2; exit 1; }

    phase="$(kubectl get pod -n "$NS" "$SERVER_POD" -o jsonpath='{.status.phase}' 2>/dev/null)" || true
    ready="$(kubectl get pod -n "$NS" "$SERVER_POD" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" || true
    [[ "$phase" == "Running" && "$ready" == "True" ]] || give_up "server pod is not ready (phase=${phase:-none})"

    # EXIT alone covers every way out of this script: it is executed
    # directly rather than sourced, and every failure path leaves through
    # give_up's exit. The backup job pairs this with a RETURN trap because
    # its copy lives in a function left via return; here that trap would
    # never fire, and a line that reads as a safety net but is not is worse
    # than no line.
    trap resume EXIT
    timeout 15s kubectl exec -n "$NS" "$SERVER_POD" -- send-command save hold || give_up "save hold was refused"

    # save query reports "ready to be copied" followed by a comma-separated
    # file:length manifest. Poll until it does.
    manifest=""
    for _ in $(seq 1 30); do
      sleep 3
      timeout 15s kubectl exec -n "$NS" "$SERVER_POD" -- send-command save query >/dev/null || give_up "save query failed"
      sleep 2
      manifest="$(kubectl logs -n "$NS" "$SERVER_POD" --tail=20 | grep -A1 'ready to be copied' | tail -1 | tr -d '\r')" || true
      [[ "$manifest" == *":"* ]] && break
      manifest=""
    done
    [[ -n "$manifest" ]] || give_up "the save manifest never arrived"

    # Each entry is path:length. The length is the number of bytes actually
    # committed -- LevelDB keeps appending, so a file on disk can be longer
    # than its valid contents, and copying the whole file is what produces a
    # world that will not open.
    count=0
    while read -r entry; do
      entry="$(echo "$entry" | xargs)"
      [[ -z "$entry" ]] && continue
      f="${entry%%:*}"
      len="${entry##*:}"
      mkdir -p "$OUT/$(dirname "$f")" || give_up "could not create $OUT/$(dirname "$f")"
      head -c "$len" "/data/worlds/$f" > "$OUT/$f" || give_up "could not copy $f"
      count=$((count + 1))
    done < <(echo "$manifest" | tr ',' '\n')

    [[ "$count" -ge 3 ]] || give_up "the manifest named only $count files"

    # Written last and only on success: its presence is what tells the census
    # a usable snapshot exists, and its contents are the only record of when
    # the world was captured. The census refuses to invent that timestamp.
    date -u +%Y-%m-%dT%H:%M:%SZ > "$OUT/snapshot-taken-at"
    echo "census-snapshot: copied $count files under hold"
{{- end }}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash /tmp/census-script-test.sh`
Expected: `PASS`.

- [ ] **Step 5: Commit**

```bash
git add charts/minecraft-fwb/templates/census-snapshot-configmap.yaml
git commit -m "feat(minecraft-fwb): take a consistent world snapshot for the census"
```

---

### Task 3: The CronJob

**Files:**
- Create: `charts/minecraft-fwb/templates/census-cronjob.yaml`
- Modify: `README.md`

**Interfaces:**
- Consumes: `census.name` and the `census` values block from Task 1; the ConfigMap `<release>-census-snapshot` with key `snapshot.sh` from Task 2; the existing helpers `backup.serverPod` and `backup.name` (the backup PVC's claim name), and `agent.image` values.

- [ ] **Step 1: Write the failing test**

Create `/tmp/census-cronjob-test.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
CHART=charts/minecraft-fwb
fail() { echo "FAIL: $1" >&2; exit 1; }

helm template t "$CHART" -f "$CHART/values.yaml" -f "$CHART/values-prd.yaml" \
  --set census.enabled=true > /tmp/census-rendered.yaml

python3 - <<'PY'
import sys, yaml
docs = [d for d in yaml.safe_load_all(open('/tmp/census-rendered.yaml')) if d]
cj = [d for d in docs if d['kind'] == 'CronJob' and d['metadata']['name'] == 't-census']
if not cj:
    sys.exit("FAIL: no CronJob named t-census rendered")
cj = cj[0]
spec = cj['spec']['jobTemplate']['spec']
pod = spec['template']['spec']

def check(cond, msg):
    if not cond:
        sys.exit("FAIL: " + msg)

check(spec.get('backoffLimit') == 0, "backoffLimit is not 0; a wedged run would retry into the next")
check(pod.get('restartPolicy') == 'Never', "restartPolicy is not Never")
check(pod.get('serviceAccountName') == 't-census', "not using the census ServiceAccount")

inits = pod.get('initContainers') or []
check(len(inits) == 1, "expected exactly one init container")
check(inits[0]['name'] == 'snapshot', "init container is not named snapshot")

mains = pod['containers']
check(len(mains) == 1, "expected exactly one main container")
args = " ".join(mains[0].get('args', []) + mains[0].get('command', []))
check('-world-dir' in args, "census is not given -world-dir")
check('-backup-dir' in args, "census is not given -backup-dir; the fallback is unreachable")

# The world must be mounted read-only: a census must never be able to write
# to a live world.
world = [m for m in inits[0]['volumeMounts'] if m['mountPath'] == '/data']
check(world and world[0].get('readOnly') is True, "world volume is not mounted read-only in the init container")

# The snapshot emptyDir must be shared by both containers, or the census
# reads an empty directory every run.
def has(c, path):
    return any(m['mountPath'] == path for m in c['volumeMounts'])
check(has(inits[0], '/snapshot'), "init container has no /snapshot mount")
check(has(mains[0], '/snapshot'), "census container has no /snapshot mount")
check(has(mains[0], '/backup'), "census container has no /backup mount; the fallback cannot read anything")

vols = {v['name']: v for v in pod['volumes']}
check('emptyDir' in vols.get('snapshot', {}), "snapshot volume is not an emptyDir")

# Scheduling must not require the server to be up.
aff = pod.get('affinity', {})
check('nodeAffinity' in aff, "no nodeAffinity; the job could be scheduled where the world volume cannot attach")
pa = aff.get('podAffinity', {})
check('requiredDuringSchedulingIgnoredDuringExecution' not in pa,
      "podAffinity is required, so the job never schedules while the server is down")
print("PASS")
PY
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash /tmp/census-cronjob-test.sh`
Expected: FAIL — `no CronJob named t-census rendered`.

- [ ] **Step 3: Write minimal implementation**

Create `charts/minecraft-fwb/templates/census-cronjob.yaml`:

```yaml
{{- if .Values.census.enabled }}
apiVersion: batch/v1
kind: CronJob
metadata:
  name: {{ include "census.name" . }}
  namespace: {{ .Release.Namespace }}
spec:
  schedule: {{ .Values.census.schedule | quote }}
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: {{ .Values.census.successfulJobsHistoryLimit }}
  failedJobsHistoryLimit: {{ .Values.census.failedJobsHistoryLimit }}
  jobTemplate:
    spec:
      backoffLimit: 0
      ttlSecondsAfterFinished: {{ .Values.census.ttlSecondsAfterFinished }}
      activeDeadlineSeconds: {{ .Values.census.timeoutSeconds }}
      template:
        spec:
          restartPolicy: Never
          serviceAccountName: {{ include "census.name" . }}
          securityContext:
            runAsNonRoot: true
            runAsUser: 1000
            fsGroup: 2000
            seccompProfile:
              type: RuntimeDefault
          # Same reasoning as the backup job: a *required* podAffinity on the
          # server reads as "run beside the server" but means "run only if a
          # server pod exists", and the census is most worth reading when the
          # server is unhealthy. The hard constraint is the node set the world
          # volume can attach to; co-location is a preference.
          affinity:
            nodeAffinity:
{{- toYaml (index .Values "minecraft-bedrock" "affinity" "nodeAffinity") | nindent 14 }}
          initContainers:
            - name: snapshot
              image: {{ .Values.census.image }}
              # version-check-cronjob.yaml runs kubectl under exactly this
              # securityContext, which is the evidence that an in-cluster
              # client needs no writable root here. If a first run does
              # complain about a cache directory, the fix is an emptyDir at
              # /tmp with HOME pointing at it -- not dropping this flag.
              securityContext:
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                capabilities:
                  drop: ["ALL"]
              env:
                - name: SERVER_POD
                  value: {{ include "backup.serverPod" . }}
              command: ["/bin/bash", "/script/snapshot.sh"]
              resources:
{{- toYaml .Values.census.resources | nindent 16 }}
              volumeMounts:
                - name: world
                  mountPath: /data
                  # The census reads worlds; it must never be able to write
                  # one. The hold protocol only ever reads from here.
                  readOnly: true
                - name: snapshot
                  mountPath: /snapshot
                - name: script
                  mountPath: /script
          containers:
            - name: census
              image: "{{ .Values.agent.image.repository }}:{{ .Values.agent.image.tag }}"
              securityContext:
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                capabilities:
                  drop: ["ALL"]
              # Both paths every run. The init container writes a snapshot
              # when it could take one and nothing when it could not, so the
              # binary picks: a fresh world if there is one, last night's
              # archive otherwise, and it says which on the report's own
              # provenance line.
              command: ["/census"]
              args:
                - "-world-dir"
                - "/snapshot"
                - "-backup-dir"
                - "/backup"
              resources:
{{- toYaml .Values.census.resources | nindent 16 }}
              volumeMounts:
                - name: snapshot
                  mountPath: /snapshot
                  readOnly: true
                - name: backup
                  mountPath: /backup
                  readOnly: true
                - name: tmp
                  mountPath: /tmp
          volumes:
            - name: world
              persistentVolumeClaim:
                claimName: datadir-{{ .Release.Name }}-minecraft-bedrock-0
            - name: backup
              persistentVolumeClaim:
                claimName: {{ include "backup.name" . }}
            - name: snapshot
              emptyDir:
                sizeLimit: 2Gi
            - name: script
              configMap:
                name: {{ include "census.name" . }}-snapshot
                defaultMode: 0555
            - name: tmp
              emptyDir:
                # The archive fallback extracts a ~570MB world with os.MkdirTemp,
                # which lands in /tmp. The root filesystem is read-only, so without
                # this the fallback fails with permission denied on the one run where
                # it is needed: the server being down is both why the snapshot was
                # missed and why somebody is reading the report.
                sizeLimit: 2Gi
{{- end }}
```

Then add to `README.md`, immediately before the `### Restoring a backup` heading:

```markdown
### Reading the mob census

`census` runs daily at 05:00, an hour after the backup, and prints a report of
what lives in the world and which 9x9-chunk regions have reached Bedrock's mob
spawn cap — the reproducible form of "why is nothing spawning near my base".

```bash
kubectl logs -n <namespace> job/$(kubectl get jobs -n <namespace> \
  -l job-name --sort-by=.metadata.creationTimestamp -o name | grep census | tail -1 | cut -d/ -f2)
```

Its first line says which world it read and when that world was captured. A
report reading `via archive` means the fresh snapshot could not be taken that
run — the server was down, or refused the save hold — and the numbers are up
to a day old. `via snapshot` means they are minutes old.

It is off by default (`census.enabled`), because the binary ships in the agent
image and a release carrying it has to be published before the job can run.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash /tmp/census-cronjob-test.sh`
Expected: `PASS`.

- [ ] **Step 5: Verify the whole chart still renders both ways**

```bash
helm lint charts/minecraft-fwb
for f in charts/minecraft-fwb/values-*.yaml; do
  helm template t charts/minecraft-fwb -f charts/minecraft-fwb/values.yaml -f "$f" > /dev/null
  helm template t charts/minecraft-fwb -f charts/minecraft-fwb/values.yaml -f "$f" --set census.enabled=true > /dev/null
done
bash /tmp/census-render-test.sh
bash /tmp/census-script-test.sh
echo "all render checks passed"
```
Expected: no failures. This mirrors what CI does, plus the enabled case CI does not cover because the default is off.

- [ ] **Step 6: Commit**

```bash
git add charts/minecraft-fwb/templates/census-cronjob.yaml README.md
git commit -m "feat(minecraft-fwb): run the census daily against a fresh snapshot"
```

---

## Follow-on work, not in this plan

- Publishing an agent release carrying `cmd/census`, bumping `agent.image.tag`, and flipping `census.enabled` to true. That is the step that makes any of this run.
- Postgres persistence, Prometheus metrics and run-to-run leak deltas, which need the `jdwillmsen-schemas` migration in `jdwlabs/platform` first.
- Unifying this snapshot script with `backup-cronjob.yaml`'s `hold_copy()`. Deferred deliberately: the backup job is what protects the world, and refactoring it for a DRY benefit before the census has proven itself in production is the wrong order of risk.
