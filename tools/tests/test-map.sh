#!/usr/bin/env bash
# Pins the things about the map that nothing else would notice breaking.
#
# First, the quiet windows. The backup and the census pause world saving
# themselves, over kubectl exec, where the console bridge cannot see it. The
# map pauses and resumes saving for its own snapshots, so a snapshot that
# overlapped one of those jobs could resume saving under that job's copy and
# leave a backup that is silently inconsistent. The map is kept away by the
# clock (map.quietUTC), and a schedule and a window are two values in two
# places: move the backup to 03:00 and everything still renders, syncs and
# looks healthy. This fails instead.
#
# Second, what is published: see the exposure check below.
#
# Third, the staleness alert, which is built on a gauge the map only sets on
# success -- the same shape that shipped unable to fire in the tick-rate rule.
#
# Fourth, the init step that installs the map's script pack. It runs ahead of
# the game server in the game server's pod, so it is the one part of the map
# that can keep the world from starting: see the init step check below.
#
# Fifth, the live layer's two alerts, whose gauge reads zero rather than
# absent on a map that has just started.
#
# Sixth, the browser checks of the live map, which bring three things this
# chart did not have: a second way into the map, a credential for it, and a
# browser running beside the game server. Each has to stay exactly as small
# as it was made: see the browser checks below.
#
# Read from the rendered chart with the value files production applies, so an
# override from any layer is what gets checked.
set -euo pipefail

here="$(cd "$(dirname "$0")/../.." && pwd)"
chart="$here/charts/minecraft-fwb"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

helm template minecraft-fwb "$chart" \
  --namespace jdwillmsen-prd \
  -f "$chart/values.yaml" \
  -f "$chart/values-prd.yaml" \
  -f "$chart/values-console-bridge.yaml" -f "$chart/values-map-pack.yaml" > "$work/rendered.yaml"

# Ten minutes before each job starts, because a snapshot that began just
# before it must be finished and resumed by then: the bridge caps one hold at
# five minutes.
MARGIN_BEFORE_MINUTES=10 python3 - "$work/rendered.yaml" <<'PY' || fail "the map's quiet windows do not cover the jobs that pause saving"
import os, sys, yaml

docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
by = lambda kind, suffix: next(d for d in docs if d["kind"] == kind and d["metadata"]["name"].endswith(suffix))

env = {e["name"]: e.get("value") for e in by("Deployment", "-map")["spec"]["template"]["spec"]["containers"][0]["env"]}
windows = []
for part in env["QUIET_UTC"].split(","):
    start, end = (int(t[:2]) * 60 + int(t[3:]) for t in part.strip().split("-"))
    windows.append((start, end))

def quiet(minute):
    minute %= 1440
    return any((s <= minute < e) if s < e else (minute >= s or minute < e) for s, e in windows)

margin = int(os.environ["MARGIN_BEFORE_MINUTES"])
bad = False
for suffix in ("-backup", "-census"):
    job = by("CronJob", suffix)
    minute, hour, *rest = job["spec"]["schedule"].split()
    if not (minute.isdigit() and hour.isdigit() and rest == ["*", "*", "*"]):
        print(f"{suffix[1:]}: schedule {job['spec']['schedule']!r} is not a single daily time; this check needs extending")
        bad = True
        continue
    start = int(hour) * 60 + int(minute)
    deadline = job["spec"]["jobTemplate"]["spec"]["activeDeadlineSeconds"]
    # Every minute from the margin before the start to the job's deadline:
    # the job may hold saving at any point in its run.
    uncovered = [m for m in range(start - margin, start + -(-deadline // 60) + 1) if not quiet(m)]
    if uncovered:
        first = uncovered[0] % 1440
        print(f"{suffix[1:]} runs {int(hour):02d}:{int(minute):02d} UTC for up to {deadline}s, "
              f"but {first // 60:02d}:{first % 60:02d} UTC is outside map.quietUTC ({env['QUIET_UTC']})")
        bad = True
sys.exit(1 if bad else 0)
PY

# The token the agent presents to the map. It is generated once and read by
# two pods at startup; anything that regenerates it under them -- a periodic
# refresh is the default -- leaves the two disagreeing, and every login
# failing, until both happen to restart.
python3 - "$work/rendered.yaml" <<'PY' || fail "the map's internal token would not stay put"
import sys, yaml

docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
named = lambda kind, suffix: [d for d in docs if d["kind"] == kind and d["metadata"]["name"].endswith(suffix)]
bad = []

secrets = named("ExternalSecret", "-map-internal-token")
generators = named("Password", "-map-internal-token")
if len(secrets) != 1 or len(generators) != 1:
    bad.append(f"expected one ExternalSecret and one Password for the map token, found {len(secrets)} and {len(generators)}")
else:
    spec, generator = secrets[0]["spec"], generators[0]
    if spec.get("refreshPolicy") != "CreatedOnce":
        bad.append(f"refreshPolicy is {spec.get('refreshPolicy')!r}; anything but CreatedOnce replaces the token under running pods")
    ref = spec["dataFrom"][0]["sourceRef"]["generatorRef"]
    if (ref["kind"], ref["name"]) != (generator["kind"], generator["metadata"]["name"]):
        bad.append("the ExternalSecret does not point at the generator this chart renders")
    # mcmap refuses to start with a shorter token.
    if generator["spec"]["length"] < 16:
        bad.append(f"a {generator['spec']['length']}-character token is shorter than the map accepts")
    if generator["spec"].get("symbols", 1) != 0:
        bad.append("the token must have no symbols: it travels in an HTTP header")

for line in bad:
    print(line)
sys.exit(1 if bad else 0)
PY

# What the internet can reach. The map has two listeners: the page, login and
# session-gated tiles on one, and metrics plus the API the agent reports
# logins to on the other. The route must only ever name the first, and the
# map must never be published with its login turned off -- it shows where
# every base is. Each of these is one edit away in values.yaml, and helm and
# ArgoCD would apply either without comment.
python3 - "$work/rendered.yaml" <<'PY' || fail "the map's exposure boundary is not what it must be"
import sys, yaml

docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
named = lambda kind, suffix: [d for d in docs if d["kind"] == kind and d["metadata"]["name"].endswith(suffix)]

container = named("Deployment", "-map")[0]["spec"]["template"]["spec"]["containers"][0]
ports = {p["name"]: p["containerPort"] for p in container["ports"]}
env = {e["name"]: e for e in container["env"]}
service = {p["name"]: p["port"] for p in named("Service", "-map")[0]["spec"]["ports"]}
bad = []

routes = named("HTTPRoute", "-map")
if len(routes) != 1:
    bad.append(f"expected exactly one HTTPRoute for the map, found {len(routes)}")
for route in routes:
    if [r.get("sectionName") for r in route["spec"]["parentRefs"]] != ["https"]:
        bad.append("the map route must attach to the gateway's https listener only")
    for rule in route["spec"]["rules"]:
        for ref in rule["backendRefs"]:
            if ref["port"] != service["http"] or ref["port"] == service["internal"]:
                bad.append(f"the map route sends traffic to port {ref['port']}; only the public port {service['http']} may be published")
    # Published, so the login has to be on and able to work.
    if (env.get("AUTH_DISABLED") or {}).get("value", "false").lower() == "true":
        bad.append("the map is published with AUTH_DISABLED=true")
    # The token is a login as any player, so it must be the one generated
    # for this and held by nothing else -- not a credential borrowed from
    # another service that has its own holders.
    generated = named("ExternalSecret", "-map-internal-token")[0]["spec"]["target"]["name"]
    source = (env.get("INTERNAL_TOKEN") or {}).get("valueFrom", {}).get("secretKeyRef", {})
    if source.get("name") != generated:
        bad.append(f"the map's INTERNAL_TOKEN must come from the generated secret {generated}, not {source.get('name')!r}")
    key = named("Password", "-map-internal-token")[0]["spec"]["secretKeys"][0]
    if source.get("key") != key:
        bad.append(f"the map reads key {source.get('key')!r} from its token secret, which holds {key!r}")

if ports["http"] == ports["internal"]:
    bad.append("the map's public and internal ports are the same port")
if env["INTERNAL_ADDR"]["value"] != f":{ports['internal']}":
    bad.append("INTERNAL_ADDR does not match the container's internal port")

monitor = named("ServiceMonitor", "-map")[0]
if [e["port"] for e in monitor["spec"]["endpoints"]] != ["internal"]:
    bad.append("the map's metrics must be scraped from the internal port; the public one does not serve them")

agent = {e["name"]: e for e in named("Deployment", "-server-agent")[0]["spec"]["template"]["spec"]["containers"][0]["env"]}
if not agent.get("MAP_URL", {}).get("value", "").endswith(f":{service['internal']}"):
    bad.append("the agent's MAP_URL must be the map's internal port, where the claims API is")
if routes and agent.get("MAP_PUBLIC_URL", {}).get("value") != "https://" + routes[0]["spec"]["hostnames"][0]:
    bad.append("the address !map tells players to open is not the address the route publishes")
# Both ends must present and expect the same credential.
if agent.get("MAP_TOKEN", {}).get("valueFrom") != env["INTERNAL_TOKEN"].get("valueFrom"):
    bad.append("the agent's MAP_TOKEN and the map's INTERNAL_TOKEN do not come from the same secret key")

for line in bad:
    print(line)
sys.exit(1 if bad else 0)
PY

# The live staleness limit is written as a duration and rendered as seconds,
# and the rule it feeds has no `for`. A value the conversion misreads as zero
# -- anything with a fraction, or no number at all -- would be a rule that
# fires on every evaluation, so the render has to refuse it.
for bad in 1.5h 15.0m 0m m 90s 15; do
  if helm template minecraft-fwb "$chart" --namespace jdwillmsen-prd \
      -f "$chart/values.yaml" -f "$chart/values-prd.yaml" -f "$chart/values-console-bridge.yaml" -f "$chart/values-map-pack.yaml" \
      --set-string "map.live.alert.staleAfter=$bad" >/dev/null 2>&1; then
    fail "map.live.alert.staleAfter=$bad rendered; only whole hours or minutes may"
  fi
done

# The init step that installs the script pack. Anything it needs, the game
# server needs first: on 2026-09-06 a sidecar's reference to a secret that did
# not exist held the server down for 40 hours. The installer is built to fail
# open, and each rule here is a way the pod spec around it could take that
# back -- a secret that does not resolve, a second volume that does not
# attach, a wrapper or a probe that can fail where the installer would not, a
# user the volume refuses, or a pack from a different release than the map
# that parses it. initContainers is rendered by plain toYaml, so none of it
# can be derived from another value and every one is a hand-kept literal.
python3 - "$work/rendered.yaml" <<'PY' || fail "the pack's init step could hold the game server or would not install the pack, or the map's live settings are out of range"
import sys, yaml

docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
named = lambda kind, suffix: [d for d in docs if d["kind"] == kind and d["metadata"]["name"].endswith(suffix)]
bad = []

server = named("StatefulSet", "-minecraft-bedrock")[0]
pod = server["spec"]["template"]["spec"]
game = pod["containers"][0]
map_container = named("Deployment", "-map")[0]["spec"]["template"]["spec"]["containers"][0]

inits = pod.get("initContainers") or []
if [c["name"] for c in inits] != ["install-map-pack"]:
    bad.append(f"expected exactly one init container, install-map-pack, found {[c['name'] for c in inits]}")
    inits = []

# Volumes the pod template declares, plus the claim templates a StatefulSet
# turns into volumes of the same name.
volumes = {v["name"]: v for v in pod.get("volumes") or []}
claims = {c["metadata"]["name"] for c in server["spec"].get("volumeClaimTemplates") or []}

def effective(container, key):
    return (container.get("securityContext") or {}).get(key, (pod.get("securityContext") or {}).get(key))

def secret_refs(node):
    # Every key anywhere under the container that reads from a Secret.
    found = []
    if isinstance(node, dict):
        for key, value in node.items():
            if key in ("secretKeyRef", "secretRef", "secret"):
                found.append(key)
            found += secret_refs(value)
    elif isinstance(node, list):
        for item in node:
            found += secret_refs(item)
    return found

for init in inits:
    if secret_refs(init):
        bad.append(f"the init step reads from a Secret ({', '.join(secret_refs(init))}); a secret that does not resolve holds the server")
    if "envFrom" in init:
        bad.append("the init step has envFrom; a missing ConfigMap or Secret holds the server")
    if any("valueFrom" in e for e in init.get("env") or []):
        bad.append("the init step has an env var with valueFrom; every value must be a literal that cannot fail to resolve")

    mounts = init.get("volumeMounts") or []
    if [(m["name"], m["mountPath"]) for m in mounts] != [("datadir", "/data")]:
        bad.append(f"the init step must mount the world's volume at /data and nothing else, found {[(m['name'], m['mountPath']) for m in mounts]}")
    for mount in mounts:
        if mount.get("readOnly"):
            bad.append("the init step mounts the world's volume read-only; the installer would skip every run")
        if mount["name"] in volumes:
            bad.append(f"the init step's volume {mount['name']!r} is a pod volume of kind {sorted(set(volumes[mount['name']]) - {'name'})}, not the world's claim")
        elif mount["name"] not in claims:
            bad.append(f"the init step mounts {mount['name']!r}, which the pod does not define")
    if init.get("volumeDevices"):
        bad.append("the init step has volumeDevices; it mounts the world's volume and nothing else")
    # The game server must see the same volume at the same path, or the pack
    # is installed somewhere the server never reads.
    if not any((m["name"], m["mountPath"]) == ("datadir", "/data") and not m.get("readOnly") for m in game["volumeMounts"]):
        bad.append("the game server no longer mounts datadir at /data, which is where the init step installs the pack")

    # Same repository, and a tag no newer than the map's: an older pack is
    # read by a newer parser, a newer pack is not. Equal tags are not
    # required, because moving this one restarts the game server.
    def release(image):
        repo, _, tag = image.rpartition(":")
        try:
            return repo, tuple(int(part) for part in tag.split("."))
        except ValueError:
            return repo, None
    (init_repo, init_tag), (map_repo, map_tag) = release(init["image"]), release(map_container["image"])
    if init_repo != map_repo:
        bad.append(f"the init step runs {init['image']}, the map runs {map_container['image']}; the pack must come from the map's own image")
    elif init_tag is None or map_tag is None or len(init_tag) != 3 or len(map_tag) != 3:
        bad.append(f"the init step runs {init['image']} and the map {map_container['image']}; both need a plain x.y.z tag to be compared")
    elif init_tag > map_tag:
        bad.append(f"the init step runs {init['image']}, newer than the map's {map_container['image']}; a pack newer than its parser has its records dropped")

    # The image's entrypoint is the installer's binary. A command replaces
    # it, and a shell wrapper in a distroless image fails before the
    # installer can fail open.
    if "command" in init:
        bad.append("the init step sets command; it must run the image's own entrypoint")
    if init.get("args") not in (["install-pack"], ["uninstall-pack"]):
        bad.append(f"the init step's args are {init.get('args')!r}; only install-pack or uninstall-pack")
    for hook in ("livenessProbe", "readinessProbe", "startupProbe", "lifecycle"):
        if hook in init:
            bad.append(f"the init step has a {hook}; nothing may be able to fail it but the installer")
    # A restartPolicy turns it into a sidecar that never completes.
    if "restartPolicy" in init:
        bad.append("the init step has a restartPolicy; it must run once and exit")

    env = {e["name"]: e.get("value") for e in init.get("env") or []}
    if set(env) != {"DATA_DIR", "LEVEL_NAME", "PACK_MOB_CAP"}:
        bad.append(f"the init step's environment is {sorted(env)}; the installer reads DATA_DIR, LEVEL_NAME and PACK_MOB_CAP")
    if env.get("DATA_DIR") != "/data":
        bad.append(f"DATA_DIR is {env.get('DATA_DIR')!r}, but the world's volume is mounted at /data")
    level = {e["name"]: e.get("value") for e in game["env"]}["LEVEL_NAME"]
    if env.get("LEVEL_NAME") != level:
        bad.append(f"the init step installs into world {env.get('LEVEL_NAME')!r}, the server runs {level!r}")
    # The installer refuses nothing, it clamps: a cap outside 1..5000 would
    # run with a different number from the one written here.
    cap = env.get("PACK_MOB_CAP") or ""
    if not (cap.isdigit() and 1 <= int(cap) <= 5000):
        bad.append(f"PACK_MOB_CAP is {cap!r}; the pack supports 1 to 5000")

    # Only the server's own user can write into the world's directories.
    uid, gid = effective(init, "runAsUser"), effective(init, "runAsGroup")
    if uid != 1000:
        bad.append(f"the init step runs as uid {uid!r}; the world's files belong to 1000 and its directories are not group-writable")
    if (uid, gid) != (effective(game, "runAsUser"), effective(game, "runAsGroup")):
        bad.append(f"the init step runs as {uid}:{gid}, the game server as {effective(game, 'runAsUser')}:{effective(game, 'runAsGroup')}; the pack must be written as the user that reads it")
    if (pod.get("securityContext") or {}).get("fsGroup") != 2000:
        bad.append(f"the pod's fsGroup is {(pod.get('securityContext') or {}).get('fsGroup')!r}; the world's files are group 2000")
    if effective(init, "runAsNonRoot") is not True:
        bad.append("the init step does not set runAsNonRoot")
    context = init.get("securityContext") or {}
    if context.get("readOnlyRootFilesystem") is not True:
        bad.append("the init step's root filesystem is writable")
    if context.get("allowPrivilegeEscalation") is not False:
        bad.append("the init step allows privilege escalation")
    if (context.get("capabilities") or {}).get("drop") != ["ALL"] or (context.get("capabilities") or {}).get("add"):
        bad.append("the init step must drop every capability and add none")
    if context.get("privileged"):
        bad.append("the init step is privileged")

    # The namespace's quota counts limits, so a container without them is a
    # pod the quota refuses -- which here is a server that never starts.
    resources = init.get("resources") or {}
    for kind in ("requests", "limits"):
        if set(resources.get(kind) or {}) != {"cpu", "memory"}:
            bad.append(f"the init step has no cpu and memory {kind}")

# The live settings. The map has two listeners and the stream belongs on the
# public one, behind the session; a LIVE_* variable that named an address or a
# port would be a way to serve it somewhere else without touching the route
# checked above. So the set is closed: a new one has to be added here, by
# someone who has read what it does.
live = {e["name"]: e.get("value") for e in map_container["env"] if e["name"].startswith("LIVE_")}
if set(live) != {"LIVE_ENABLED", "LIVE_POLL_WAIT", "LIVE_TTL", "LIVE_MAX_ENTITIES", "LIVE_KEEPALIVE"}:
    bad.append(f"the map's live settings are {sorted(live)}; this check knows LIVE_ENABLED, LIVE_POLL_WAIT, LIVE_TTL, LIVE_MAX_ENTITIES and LIVE_KEEPALIVE")
internal = str(next(p["containerPort"] for p in map_container["ports"] if p["name"] == "internal"))
for name, value in live.items():
    if value is None:
        bad.append(f"{name} does not have a literal value")
    elif ":" in value or internal in value:
        bad.append(f"{name}={value} looks like an address, or names the map's internal port")

def seconds(text):
    units = {"ms": 0.001, "s": 1, "m": 60, "h": 3600}
    for suffix in ("ms", "s", "m", "h"):
        if text.endswith(suffix) and text[: -len(suffix)].replace(".", "", 1).isdigit():
            return float(text[: -len(suffix)]) * units[suffix]
    return None

# The load balancer cuts a connection idle for 30 seconds. The map itself
# stops at 20, so between 20 and 30 this is a map that will not start and
# from 30 up it would be one whose every quiet stream is dropped.
keepalive = seconds(live.get("LIVE_KEEPALIVE") or "")
if keepalive is None or not 1 <= keepalive <= 20:
    bad.append(f"LIVE_KEEPALIVE is {live.get('LIVE_KEEPALIVE')!r}; it must be a single duration from 1s to 20s, under the load balancer's 30s idle limit")
poll = seconds(live.get("LIVE_POLL_WAIT") or "")
if poll is None or not 0.1 <= poll <= 25:
    bad.append(f"LIVE_POLL_WAIT is {live.get('LIVE_POLL_WAIT')!r}; the bridge holds a request for at most 25s")
ttl = seconds(live.get("LIVE_TTL") or "")
if ttl is None or not 2 <= ttl <= 600:
    bad.append(f"LIVE_TTL is {live.get('LIVE_TTL')!r}; the map accepts 2s to 10m")
entities = live.get("LIVE_MAX_ENTITIES") or ""
if not (entities.isdigit() and 1 <= int(entities) <= 10000):
    bad.append(f"LIVE_MAX_ENTITIES is {entities!r}; the map accepts 1 to 10000")
if live.get("LIVE_ENABLED") not in ("true", "false"):
    bad.append(f"LIVE_ENABLED is {live.get('LIVE_ENABLED')!r}; it must be true or false")

# The map leaves biomes and trails off unless it is told otherwise, so that a
# new image alone adds no pass over the world. A chart that stopped saying
# which it wants would switch them off without anyone having decided to.
switches = {e["name"]: e.get("value") for e in map_container["env"] if e["name"] in ("BIOMES_ENABLED", "TRAILS_ENABLED")}
for name in ("BIOMES_ENABLED", "TRAILS_ENABLED"):
    if switches.get(name) not in ("true", "false"):
        bad.append(f"{name} is {switches.get(name)!r}; the chart must set it to true or false")
# Trails are made of the live layer's positions: on without it they are a
# layer the page offers and nothing ever fills.
if switches.get("TRAILS_ENABLED") == "true" and live.get("LIVE_ENABLED") != "true":
    bad.append("TRAILS_ENABLED is true while LIVE_ENABLED is not")

# The map refuses to start on a trail limit outside what it accepts, so one
# that is wrong here is a map that never comes up.
import re
env = {e["name"]: e.get("value") for e in map_container["env"]}
# ASCII digits only: the map parses these in Go, which takes no others.
age = re.fullmatch(r"([0-9]+)(m|h)", env.get("TRAILS_MAX_AGE") or "")
minutes = int(age.group(1)) * (60 if age.group(2) == "h" else 1) if age else 0
if not 1 <= minutes <= 168 * 60:
    bad.append(f"TRAILS_MAX_AGE is {env.get('TRAILS_MAX_AGE')!r}; the map accepts 1m to 168h, in whole minutes or hours")
points = env.get("TRAILS_MAX_POINTS") or ""
if not (re.fullmatch(r"[0-9]+", points) and 10 <= int(points) <= 50000):
    bad.append(f"TRAILS_MAX_POINTS is {points!r}; the map accepts 10 to 50000")

# History is off in the map unless it is told otherwise, and what it keeps
# cannot be rebuilt. On, it must be on a claim of its own: left to its
# default it would sit on the data claim, which is not kept and which it
# would fill. That claim stops being rendered when history is switched off,
# and the Application prunes what is not rendered, so it must be marked to
# be left alone or the days go with the switch.
if env.get("HISTORY_ENABLED") not in ("true", "false"):
    bad.append(f"HISTORY_ENABLED is {env.get('HISTORY_ENABLED')!r}; the chart must set it to true or false")
if env.get("HISTORY_ENABLED") == "true":
    map_pod = named("Deployment", "-map")[0]["spec"]["template"]["spec"]
    claim_of = {v["name"]: (v.get("persistentVolumeClaim") or {}).get("claimName") for v in map_pod.get("volumes") or []}
    mounted = {m["mountPath"]: claim_of.get(m["name"]) for m in map_container.get("volumeMounts") or []}
    where = env.get("HISTORY_DIR")
    if not mounted.get(where):
        bad.append(f"HISTORY_DIR is {where!r}, which is not where a claim is mounted")
    elif mounted[where] == mounted.get("/data"):
        bad.append("the map's history is on the same claim as its data")
    else:
        claims = [d for d in docs if d["kind"] == "PersistentVolumeClaim" and d["metadata"]["name"] == mounted[where]]
        if not claims:
            bad.append(f"the map's history is on the claim {mounted[where]}, which the chart does not make")
        else:
            options = (claims[0]["metadata"].get("annotations") or {}).get("argocd.argoproj.io/sync-options") or ""
            if "Prune=false" not in [o.strip() for o in options.split(",")]:
                bad.append(f"the claim {mounted[where]} is not marked Prune=false, so switching history off would have it pruned")

for line in bad:
    print(line)
sys.exit(1 if bad else 0)
PY

# History switched off. The map must still be told so, because its own
# default is what would decide otherwise, and nothing of history may be left
# behind: a mount whose claim is gone is a map that never starts, and the
# map exports the history gauge whether history is on or not, as 0 when it
# is off, which the alert takes as very old and so would fire for good.
helm template minecraft-fwb "$chart" \
  --namespace jdwillmsen-prd \
  -f "$chart/values.yaml" \
  -f "$chart/values-prd.yaml" \
  -f "$chart/values-console-bridge.yaml" -f "$chart/values-map-pack.yaml" \
  --set map.history.enabled=false > "$work/rendered-history-off.yaml"

python3 - "$work/rendered-history-off.yaml" <<'PY' || fail "switching the map's history off does not take all of it away"
import sys, yaml

docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
named = lambda kind, suffix: [d for d in docs if d["kind"] == kind and d["metadata"]["name"].endswith(suffix)]
map_pod = named("Deployment", "-map")[0]["spec"]["template"]["spec"]
map_container = map_pod["containers"][0]
env = {e["name"]: e.get("value") for e in map_container["env"]}

bad = []
if env.get("HISTORY_ENABLED") != "false":
    bad.append(f"HISTORY_ENABLED is {env.get('HISTORY_ENABLED')!r} with history off; the chart must set it to false")
if "HISTORY_DIR" in env:
    bad.append(f"HISTORY_DIR is still set, to {env['HISTORY_DIR']!r}")
if named("PersistentVolumeClaim", "-map-history"):
    bad.append("the chart still makes the history claim")
made = {d["metadata"]["name"] for d in docs if d["kind"] == "PersistentVolumeClaim"}
volumes = {v["name"]: v for v in map_pod.get("volumes") or []}
for volume in volumes.values():
    claim = (volume.get("persistentVolumeClaim") or {}).get("claimName")
    if claim and claim not in made:
        bad.append(f"the map pod still names the claim {claim}, which the chart no longer makes")
for mount in map_container.get("volumeMounts") or []:
    if mount["name"] not in volumes:
        bad.append(f"the map still mounts {mount['name']} at {mount['mountPath']}, which is no volume of its pod")
    elif mount["mountPath"] == "/history":
        bad.append("the map still has a mount at /history")
alerts = [r.get("alert") for d in named("PrometheusRule", "-map") for g in d["spec"]["groups"] for r in g["rules"]]
if not alerts:
    bad.append("the map's rules did not render")
if "JdwillmsenMinecraftMapHistoryMissed" in alerts:
    bad.append("JdwillmsenMinecraftMapHistoryMissed is still there, on a gauge the map no longer sets")

for line in bad:
    print(line)
sys.exit(1 if bad else 0)
PY

# The browser checks. They are off as production runs today, and what they
# add when on is held to here.
#
# A made-up digest stands in for the image's: this renders the chart and
# pulls nothing.
checks_on=(--set map.checks.secret.create=true --set map.checks.enabled=true
  --set map.checks.image.tag=1.0.0 --set "map.checks.image.digest=sha256:$(printf 'a%.0s' $(seq 64))")
render() {
  helm template minecraft-fwb "$chart" \
    --namespace jdwillmsen-prd \
    -f "$chart/values.yaml" \
    -f "$chart/values-prd.yaml" \
    -f "$chart/values-console-bridge.yaml" -f "$chart/values-map-pack.yaml" "$@"
}
render --set map.checks.secret.create=true > "$work/checks-secret.yaml"
render "${checks_on[@]}" > "$work/checks-on.yaml"

# Wiring a workload to a Secret in the step that first creates it is how this
# chart got its 40-hour outage, so the order is enforced and not only
# written down. And the image holds a session on the live map: a tag alone,
# which can be moved, is refused.
if render --set map.checks.enabled=true >/dev/null 2>&1; then
  fail "the browser checks can be enabled without their Secret being generated first"
fi
if render --set map.checks.secret.create=true --set map.checks.enabled=true --set map.checks.image.tag=1.0.0 >/dev/null 2>&1; then
  fail "the browser checks can be enabled with an image that is not pinned by digest"
fi

python3 - "$work/rendered.yaml" "$work/checks-secret.yaml" "$work/checks-on.yaml" <<'PY' || fail "the browser checks are not as contained as they were made"
import re, sys, yaml

load = lambda path: [d for d in yaml.safe_load_all(open(path)) if d]
off, staged, on = (load(p) for p in sys.argv[1:4])
text = {"off": open(sys.argv[1]).read(), "on": open(sys.argv[3]).read()}
named = lambda docs: {(d["kind"], d["metadata"]["name"]) for d in docs}
by = lambda docs, kind, suffix: next(d for d in docs if d["kind"] == kind and d["metadata"]["name"].endswith(suffix))
map_env = lambda docs: {e["name"]: e for e in by(docs, "Deployment", "-map")["spec"]["template"]["spec"]["containers"][0]["env"]}
bad = []

# Off, as production is: nothing of it anywhere.
if any("map-checks" in name for _, name in named(off)):
    bad.append("production's values render a browser-checks resource; they are meant to be off until the owner turns them on")
if "SERVICE_SESSION" in text["off"]:
    bad.append("production's values give the map a service-session setting; the exchange is meant to be off")

# Step one adds the generator and nothing that reads it.
added = named(staged) - named(off)
if added != {("Password", "minecraft-fwb-map-checks-secret"), ("ExternalSecret", "minecraft-fwb-map-checks-secret")}:
    bad.append(f"map.checks.secret.create alone adds {sorted(added)}; it should add the generator and its ExternalSecret only")
if "SERVICE_SESSION_SECRET" in map_env(staged):
    bad.append("the map reads the checks' Secret as soon as it is generated; that is step two")

# The secret is generated in the cluster, once, and is a literal nowhere.
password = by(on, "Password", "-map-checks-secret")
external = by(on, "ExternalSecret", "-map-checks-secret")
if password["spec"]["length"] < 32:
    bad.append(f"the checks' secret is {password['spec']['length']} characters; the map refuses one under 32")
if external["spec"].get("refreshPolicy") != "CreatedOnce":
    bad.append("the checks' Secret would be regenerated under a running map, which reads it once at startup")
sources = external["spec"].get("dataFrom") or []
if external["spec"].get("data") or len(sources) != 1 or (sources[0].get("sourceRef") or {}).get("generatorRef", {}).get("kind") != "Password":
    bad.append("the checks' Secret is not made by the in-cluster generator alone")
if any(d["kind"] == "Secret" for d in on if "map-checks" in d["metadata"]["name"]):
    bad.append("the chart renders the checks' Secret itself, which puts its value in git")
secret_env = map_env(on).get("SERVICE_SESSION_SECRET") or {}
ref = (secret_env.get("valueFrom") or {}).get("secretKeyRef") or {}
if "value" in secret_env or ref.get("name") != external["spec"]["target"]["name"] or ref.get("key") not in password["spec"]["secretKeys"]:
    bad.append("the map's SERVICE_SESSION_SECRET is not read from the generated Secret")
if ref.get("optional") is not True:
    bad.append("the map waits on the checks' Secret; a Secret that is late would keep the map from starting")
if ref.get("name") == (map_env(on)["INTERNAL_TOKEN"]["valueFrom"]["secretKeyRef"]["name"]):
    bad.append("the checks share the agent's token, which can log in as any player")

# The exchange is on the map's internal port, and the route still publishes
# only the public one: turning the checks on moves nothing into reach.
service = by(on, "Service", "-map")
ports = {p["name"]: p["port"] for p in service["spec"]["ports"]}
for route in (d for d in on if d["kind"] == "HTTPRoute"):
    for rule in route["spec"]["rules"]:
        for backend in rule["backendRefs"]:
            if "map-checks" in backend["name"] or (backend["name"] == service["metadata"]["name"] and backend["port"] != ports["http"]):
                bad.append(f"HTTPRoute {route['metadata']['name']} publishes {backend['name']}:{backend['port']}; the exchange must stay unreachable from outside")
if named(on) - named(staged) != {
        ("PersistentVolumeClaim", "minecraft-fwb-map-checks"), ("CronJob", "minecraft-fwb-map-checks"), ("NetworkPolicy", "minecraft-fwb-map-checks"),
        ("PrometheusRule", "minecraft-fwb-map-checks"), ("Deployment", "minecraft-fwb-map-checks-exporter"),
        ("Service", "minecraft-fwb-map-checks-exporter"), ("ServiceMonitor", "minecraft-fwb-map-checks-exporter")}:
    bad.append(f"map.checks.enabled adds {sorted(named(on) - named(staged))}; anything new here needs a reason and a line in this test")

# The job: a browser, beside the game server, holding a session.
job = by(on, "CronJob", "-map-checks")
spec = job["spec"]["jobTemplate"]["spec"]
pod = spec["template"]["spec"]
if len(pod["containers"]) != 1 or pod.get("initContainers"):
    bad.append("the checks' pod runs more than the one container")
c = pod["containers"][0]
ctx, pctx = c.get("securityContext") or {}, pod.get("securityContext") or {}
if pod.get("automountServiceAccountToken") is not False or pod.get("serviceAccountName"):
    bad.append("the checks' pod holds a service account token; it asks nothing of the cluster and runs a browser")
if pctx.get("runAsNonRoot") is not True or pctx.get("runAsUser", 0) == 0 or (pctx.get("seccompProfile") or {}).get("type") != "RuntimeDefault":
    bad.append("the checks' pod is not held to a non-root user under the default seccomp profile")
if ctx.get("readOnlyRootFilesystem") is not True or ctx.get("allowPrivilegeEscalation") is not False or (ctx.get("capabilities") or {}).get("drop") != ["ALL"] or ctx.get("privileged"):
    bad.append("the checks' container is not read-only, unprivileged and without capabilities")
if pod.get("hostNetwork") or pod.get("hostPID") or pod.get("hostIPC") or any("hostPath" in v for v in pod["volumes"]):
    bad.append("the checks' pod reaches into its node")
if not re.fullmatch(r"ghcr\.io/jdwillmsen/minecraft-map-checks(:[\w.-]+)?@sha256:[0-9a-f]{64}", c["image"]):
    bad.append(f"the checks' image {c['image']} is not pinned by digest")

def quantity(v):
    v = str(v)
    for suffix, scale in (("Gi", 2**30), ("Mi", 2**20), ("m", 0.001)):
        if v.endswith(suffix):
            return float(v[:-len(suffix)]) * scale
    return float(v)
limits, requests = (c.get("resources") or {}).get("limits") or {}, (c.get("resources") or {}).get("requests") or {}
if "cpu" not in limits or "memory" not in limits or "cpu" not in requests or "memory" not in requests:
    bad.append("the checks have no limit on CPU or memory, on the nodes the game server runs on")
elif quantity(limits["cpu"]) > 2 or quantity(limits["memory"]) > 2 * 2**30:
    bad.append(f"the checks may take {limits['cpu']} CPU and {limits['memory']}; past 2 and 2Gi is more than a browser needs and enough to be felt by the game server")
tmp = next((v for v in pod["volumes"] if v["name"] == "tmp"), {})
if "sizeLimit" not in (tmp.get("emptyDir") or {}):
    bad.append("the checks' scratch directory has no size limit on the node's disk")
if job["spec"].get("concurrencyPolicy") != "Forbid" or spec.get("backoffLimit") != 0 or not 0 < spec.get("activeDeadlineSeconds", 0) <= 1800:
    bad.append("the checks may run twice at once, retry, or run without end")

# The secret reaches the runner as a file and as nothing else.
if any("valueFrom" in e or "SECRET" in e["name"].upper() for e in c.get("env") or []) or c.get("envFrom"):
    bad.append("the checks' secret is in the container's environment, which `kubectl describe` prints")
volume = next((v for v in pod["volumes"] if "secret" in v), None)
if not volume or volume["secret"]["secretName"] != external["spec"]["target"]["name"] or len(volume["secret"].get("items") or []) != 1:
    bad.append("the checks' pod does not mount exactly the one key of the generated Secret")
elif not any(m["name"] == volume["name"] and m.get("readOnly") is True for m in c["volumeMounts"]):
    bad.append("the checks' secret is not mounted read-only")
if len([v for v in pod["volumes"] if "secret" in v]) != 1:
    bad.append("the checks' pod mounts a Secret that is not its own")

# The browser goes the way a player's does; only the exchange goes inside.
args = dict(zip(c["args"][::2], c["args"][1::2]))
hosts = [h for d in on if d["kind"] == "HTTPRoute" for h in d["spec"]["hostnames"]]
if args.get("--public-url") not in [f"https://{h}" for h in hosts]:
    bad.append(f"the checks drive the browser at {args.get('--public-url')}, which is not the hostname the route publishes over https")
if args.get("--internal-url") != f"http://{service['metadata']['name']}.jdwillmsen-prd.svc.cluster.local:{ports['internal']}":
    bad.append(f"the checks exchange their secret at {args.get('--internal-url')}, not the map's internal port")
if any(flag in args for flag in ("--secret-from-kube", "--port-forward", "--insecure-local-tls")):
    bad.append("the scheduled checks are given an option that is for a run from outside the cluster or against a harness")

# What the pod may reach.
policy = by(on, "NetworkPolicy", "-map-checks")["spec"]
if policy["podSelector"].get("matchLabels") != spec["template"]["metadata"]["labels"]:
    bad.append("the network policy does not select the checks' pods")
if set(policy.get("policyTypes") or []) != {"Ingress", "Egress"} or policy.get("ingress"):
    bad.append("something may connect to the checks' pod")
peers = []
for rule in policy.get("egress") or []:
    for to in rule.get("to") or [{}]:
        peers.append((to, rule.get("ports") or []))
map_label = by(on, "Deployment", "-map")["spec"]["template"]["metadata"]["labels"]
for to, rule_ports in peers:
    if not to or "ipBlock" in to and to["ipBlock"]["cidr"].endswith("/0"):
        bad.append("the checks' pod may reach anywhere")
    elif (to.get("podSelector") or {}).get("matchLabels") == map_label and "namespaceSelector" not in to:
        if [p.get("port") for p in rule_ports] != [ports["internal"]]:
            bad.append("the checks' pod may reach the map on something other than its internal port; the page has to be reached through the gateway")
    elif "namespaceSelector" in to:
        where = to["namespaceSelector"].get("matchLabels", {}).get("kubernetes.io/metadata.name")
        if where not in ("kube-system", "nginx-gateway") or (where == "kube-system" and "podSelector" not in to):
            bad.append(f"the checks' pod may reach namespace {where}")
    elif "ipBlock" not in to:
        bad.append(f"the checks' pod may reach {to}")
if not any((to.get("podSelector") or {}).get("matchLabels") == map_label for to, _ in peers):
    bad.append("the checks' pod cannot reach the map's internal port for the exchange")

# The schedule keeps off the hours the map is not expected to be itself.
minutes, hours, *rest = job["spec"]["schedule"].split()
def expand(field, top):
    out = set()
    for part in field.split(","):
        if part == "*":
            out |= set(range(top))
        elif "-" in part:
            lo, hi = part.split("-")
            out |= set(range(int(lo), int(hi) + 1))
        else:
            out.add(int(part))
    return out
if rest != ["*", "*", "*"] or job["spec"].get("timeZone") != "Etc/UTC" or not re.fullmatch(r"[0-9,*-]+ [0-9,*-]+", f"{minutes} {hours}"):
    bad.append(f"the checks' schedule {job['spec']['schedule']!r} is not a daily list of times in UTC; this check needs extending")
else:
    busy = []
    for part in map_env(on)["QUIET_UTC"]["value"].split(","):
        start, end = (int(t[:2]) * 60 + int(t[3:]) for t in part.strip().split("-"))
        busy.append(("the map's quiet window", start, end))
    for suffix, what, before in (("-backup", "the backup", 10), ("-census", "the census", 10), ("-scheduled-restart", "the daily restart", 15)):
        other = by(on, "CronJob", suffix)
        m, h, *_ = other["spec"]["schedule"].split()
        start = int(h) * 60 + int(m)
        busy.append((what, start - before, start + -(-other["spec"]["jobTemplate"]["spec"]["activeDeadlineSeconds"] // 60)))
    length = -(-spec["activeDeadlineSeconds"] // 60)
    for h in sorted(expand(hours, 24)):
        for m in sorted(expand(minutes, 60)):
            run = range(h * 60 + m, h * 60 + m + length + 1)
            for what, start, end in busy:
                if any(start <= minute % 1440 < end or start <= minute % 1440 + 1440 < end for minute in run):
                    bad.append(f"a run of the checks at {h:02d}:{m:02d} UTC can overlap {what}")

# The exporter reads the results and can change nothing.
exporter = by(on, "Deployment", "-map-checks-exporter")["spec"]["template"]["spec"]
e = exporter["containers"][0]
claim = next(v for v in exporter["volumes"] if "persistentVolumeClaim" in v)
if exporter.get("automountServiceAccountToken") is not False or (e["securityContext"]).get("readOnlyRootFilesystem") is not True:
    bad.append("the checks' exporter holds a token or a writable root")
if claim["persistentVolumeClaim"].get("readOnly") is not True or not all(m.get("readOnly") for m in e["volumeMounts"] if m["name"] == claim["name"]):
    bad.append("the checks' exporter can write to the volume the evidence is on")
if any("secret" in v for v in exporter["volumes"]):
    bad.append("the checks' exporter mounts a Secret")

for line in dict.fromkeys(bad):
    print(line)
sys.exit(1 if bad else 0)
PY

if ! command -v promtool >/dev/null 2>&1; then
  # Loud rather than silent: a skipped alert test is an untested alert. CI
  # installs promtool, so this branch is never taken there.
  echo "SKIP: promtool not on PATH; map alert rules not verified"
  exit 0
fi

python3 - "$work/rendered.yaml" > "$work/rules.yaml" <<'PY'
import sys, yaml
for doc in yaml.safe_load_all(open(sys.argv[1])):
    if doc and doc.get("kind") == "PrometheusRule" and doc["metadata"]["name"].endswith("-map"):
        print(yaml.safe_dump({"groups": doc["spec"]["groups"]}, sort_keys=False))
PY
[ -s "$work/rules.yaml" ] || fail "could not extract the map rules from the chart"
promtool check rules "$work/rules.yaml" >/dev/null || fail "promtool rejected the rendered map rules"

# The obvious way to write the live staleness rule, kept here and nowhere
# else. It is the control for the map-restart case below: it must fire there,
# or that case is not exercising the zero a fresh map pod exports and the
# shipped rule staying quiet proves nothing.
cat > "$work/naive.yaml" <<'EOF'
groups:
  - name: naive-live
    rules:
      - alert: NaiveLiveStale
        expr: (time() - mcmap_live_last_frame_timestamp_seconds{namespace="jdwillmsen-prd"}) > 900
EOF

# promtool's clock starts at unix 0. A timestamp series counting 60 per minute
# reads back the evaluation time, so `time() - series` is zero: rendered just
# now. One held at 0 makes that difference the evaluation time: a render that
# happened once and never again.
cat > "$work/tests.yaml" <<'TESTS'
rule_files:
  - rules.yaml
  - naive.yaml
evaluation_interval: 1m
tests:
  # Rendering every cycle: nothing to say, however long it has been running.
  - interval: 1m
    input_series:
      - series: 'mcmap_render_last_success_timestamp_seconds{namespace="jdwillmsen-prd", dimension="overworld"}'
        values: '0+60x300'
    alert_rule_test:
      - eval_time: 5h
        alertname: JdwillmsenMinecraftMapStale
        exp_alerts: []
      - eval_time: 5h
        alertname: JdwillmsenMinecraftMapNeverRendered
        exp_alerts: []

  # Rendered once at the start and never again. Quiet through a normal night's
  # quiet windows, then firing once it is past the limit and the `for`.
  - interval: 1m
    input_series:
      - series: 'mcmap_render_last_success_timestamp_seconds{namespace="jdwillmsen-prd", dimension="overworld"}'
        values: '0+0x300'
    alert_rule_test:
      - eval_time: 1h45m
        alertname: JdwillmsenMinecraftMapStale
        exp_alerts: []
      - eval_time: 2h15m
        alertname: JdwillmsenMinecraftMapStale
        exp_alerts:
          - exp_labels:
              severity: warning
              namespace: jdwillmsen-prd
              dimension: overworld
            exp_annotations:
              summary: "The Minecraft FWB map has stopped refreshing"
              description: "The map has not finished rendering the overworld for more than 2h. It still serves the tiles it has, so the page looks fine and only its \"updated\" time gives it away. mcmap_snapshots_total by result says whether the bridge is refusing (busy), the copy is failing (failed), or the cycle is not running at all."

  # Never rendered at all: the gauge does not exist, the staleness rule has
  # nothing to subtract, and the absence rule is the only one that can speak.
  - interval: 1m
    input_series:
      - series: 'up{namespace="jdwillmsen-prd"}'
        values: '1+0x300'
    alert_rule_test:
      - eval_time: 2h15m
        alertname: JdwillmsenMinecraftMapStale
        exp_alerts: []
      - eval_time: 2h15m
        alertname: JdwillmsenMinecraftMapNeverRendered
        exp_alerts:
          - exp_labels:
              severity: warning
              namespace: jdwillmsen-prd
              dimension: overworld
            exp_annotations:
              summary: "The Minecraft FWB map has never rendered"
              description: "No overworld render has succeeded since the map pod started, or the pod is not being scraped. A first render on a fresh volume takes minutes, not 2h."

  # A snapshot in progress: owed for a few minutes, then paid. Normal.
  - interval: 1m
    input_series:
      - series: 'mc_console_bridge_snapshot_resume_owed{namespace="jdwillmsen-prd"}'
        values: '0+0x10 1+0x5 0+0x30'
    alert_rule_test:
      - eval_time: 16m
        alertname: JdwillmsenMinecraftSaveResumeOwed
        exp_alerts: []
      - eval_time: 30m
        alertname: JdwillmsenMinecraftSaveResumeOwed
        exp_alerts: []

  # Owed and never paid: every scrape for ten minutes reads 1.
  - interval: 1m
    input_series:
      - series: 'mc_console_bridge_snapshot_resume_owed{namespace="jdwillmsen-prd"}'
        values: '0+0x10 1+0x40'
    alert_rule_test:
      - eval_time: 15m
        alertname: JdwillmsenMinecraftSaveResumeOwed
        exp_alerts: []
      - eval_time: 25m
        alertname: JdwillmsenMinecraftSaveResumeOwed
        exp_alerts:
          - exp_labels:
              severity: critical
              namespace: jdwillmsen-prd
            exp_annotations:
              summary: "Minecraft FWB may have world saving paused"
              description: "The console bridge paused saving for a map snapshot and the server has not confirmed the resume for ten minutes. The bridge keeps retrying and refuses new snapshots meanwhile. Check the server log for \"Changes to the world are resumed\"; if it is missing, run `save resume` from the console. The nightly backup also resumes saving when it finishes."

  # History. A map that keeps its days has a gauge no more than a day and a
  # cycle behind the clock; one tracking the clock is the limit of that.
  - interval: 1m
    name: a map keeping its days says nothing
    input_series:
      - series: 'mcmap_history_last_success_timestamp_seconds{namespace="jdwillmsen-prd"}'
        values: '0+60x2500'
    alert_rule_test:
      - eval_time: 40h
        alertname: JdwillmsenMinecraftMapHistoryMissed
        exp_alerts: []

  # A gauge held at 0 is both cases at once: a day kept at the start and
  # none since, and a map that has never kept one. Quiet through the day
  # that is allowed and the hour after it, then firing.
  - interval: 1m
    name: a day that is missed is noticed within three hours
    input_series:
      - series: 'mcmap_history_last_success_timestamp_seconds{namespace="jdwillmsen-prd"}'
        values: '0+0x1700'
    alert_rule_test:
      - eval_time: 26h50m
        alertname: JdwillmsenMinecraftMapHistoryMissed
        exp_alerts: []
      - eval_time: 27h10m
        alertname: JdwillmsenMinecraftMapHistoryMissed
        exp_alerts:
          - exp_labels:
              severity: warning
              namespace: jdwillmsen-prd
            exp_annotations:
              summary: "The Minecraft FWB map is not keeping its daily history"
              description: "The map has kept no day of history for more than 26 hours. A day that is missed cannot be kept later. The map's log says \"map history not kept\" with the reason; a full history volume is the likely one, and a render failing every cycle is the other, since a day is only kept from a cycle that drew all three dimensions."

  # The live layer. A record every second, heartbeats included, so the
  # timestamp tracks the clock whether or not anyone is online.
  - interval: 1m
    name: a live layer receiving records says nothing
    input_series:
      - series: 'mcmap_live_last_frame_timestamp_seconds{namespace="jdwillmsen-prd", instance="10.244.6.253:9090"}'
        values: '0+60x180'
    alert_rule_test:
      - eval_time: 3h
        alertname: JdwillmsenMinecraftMapLiveStale
        exp_alerts: []
      - eval_time: 3h
        alertname: JdwillmsenMinecraftMapLiveNeverStarted
        exp_alerts: []

  # The path breaks at minute 30 with the map still up, so the gauge holds
  # the time of the last record. Quiet at exactly the limit, firing at the
  # first evaluation past it: there is no `for` to wait out.
  - interval: 1m
    name: records that stop arriving are noticed a quarter of an hour later
    input_series:
      - series: 'mcmap_live_last_frame_timestamp_seconds{namespace="jdwillmsen-prd", instance="10.244.6.253:9090"}'
        values: '0+60x30 1800+0x90'
    alert_rule_test:
      - eval_time: 45m
        alertname: JdwillmsenMinecraftMapLiveStale
        exp_alerts: []
      - eval_time: 46m
        alertname: JdwillmsenMinecraftMapLiveStale
        exp_alerts:
          - exp_labels:
              severity: warning
              namespace: jdwillmsen-prd
            exp_annotations:
              summary: "The Minecraft FWB map's live players and mobs have stopped updating"
              description: "The map last accepted a position record from the game server 16m 0s ago; the pack sends one every second even with nobody online, and a server restart is over well inside 15m. The page shows no markers meanwhile and nothing else is affected. Work down the path: mcmap_live_frames_total and mcmap_live_polls_total by result on the map, mc_console_bridge_script_records_total on the bridge, then the server log for [Scripting] lines. charts/minecraft-fwb/README.md, \"Live layer\"."
              runbook_url: "https://github.com/jdwillmsen/jdw-deployments/blob/main/charts/minecraft-fwb/README.md#live-layer"
      # Stale is not never-started: the layer worked, and says when.
      - eval_time: 46m
        alertname: JdwillmsenMinecraftMapLiveNeverStarted
        exp_alerts: []

  # A SERVER RESTART MUST STAY QUIET, and that is a decision rather than an
  # accident of the numbers. The pack stops with the server and starts when
  # the world has loaded; nine minutes is the longest any part of this stack
  # has been seen to take coming back from one (the agent, rejoining), and
  # the server itself answers again in two to five. The server restarts on a
  # schedule and on every change to its pod, the layer recovers by itself,
  # and a server that does not come back is reported by alerts that say so.
  # An alert here would be a daily page about a map being briefly blank.
  - interval: 1m
    name: nine minutes without records across a server restart is not an outage
    input_series:
      - series: 'mcmap_live_last_frame_timestamp_seconds{namespace="jdwillmsen-prd", instance="10.244.6.253:9090"}'
        values: '0+60x30 1800+0x8 2400+60x60'
    alert_rule_test:
      - eval_time: 39m
        alertname: JdwillmsenMinecraftMapLiveStale
        exp_alerts: []
      - eval_time: 46m
        alertname: JdwillmsenMinecraftMapLiveStale
        exp_alerts: []
      - eval_time: 90m
        alertname: JdwillmsenMinecraftMapLiveStale
        exp_alerts: []
      - eval_time: 90m
        alertname: JdwillmsenMinecraftMapLiveNeverStarted
        exp_alerts: []

  # THE REGRESSION CASE FOR THE ZERO.
  #
  # The map pod is replaced at minute 30. The new one exports zero from
  # minute 33 until its first record at minute 43 -- ten minutes, as when it
  # comes up before the bridge will answer. Read on its own that zero is the
  # whole of the clock stale, and the control rule fires on it. The pod it
  # replaced had a record at minute 30, so the layer is thirteen minutes
  # behind at worst and the shipped rule says nothing. Taking the
  # max_over_time out of the expression turns this case red.
  - interval: 1m
    name: a restarted map that has no record yet is not a stale layer
    input_series:
      - series: 'mcmap_live_last_frame_timestamp_seconds{namespace="jdwillmsen-prd", instance="10.244.6.253:9090"}'
        values: '0+60x30 stale'
      - series: 'mcmap_live_last_frame_timestamp_seconds{namespace="jdwillmsen-prd", instance="10.244.6.31:9090"}'
        values: '_x33 0+0x9 2580+60x120'
    alert_rule_test:
      - eval_time: 34m
        alertname: NaiveLiveStale
        exp_alerts:
          - exp_labels:
              namespace: jdwillmsen-prd
              instance: 10.244.6.31:9090
      - eval_time: 34m
        alertname: JdwillmsenMinecraftMapLiveStale
        exp_alerts: []
      - eval_time: 42m
        alertname: JdwillmsenMinecraftMapLiveStale
        exp_alerts: []
      - eval_time: 42m
        alertname: JdwillmsenMinecraftMapLiveNeverStarted
        exp_alerts: []
      # Past the lookback, when only the new pod's history is left.
      - eval_time: 150m
        alertname: JdwillmsenMinecraftMapLiveStale
        exp_alerts: []
      - eval_time: 150m
        alertname: JdwillmsenMinecraftMapLiveNeverStarted
        exp_alerts: []

  # The path breaks at minute 30 and the map pod is replaced at minute 36,
  # before anything has fired. The new pod only ever says zero. The outage
  # must still be reported on time, from the old pod's last record -- which
  # is what map.live.alert.lookback being longer than staleAfter buys.
  #
  # An hour after that pod's last sample there is no record left to be stale
  # against, and the same outage becomes the never-started alert once its
  # `for` has run. The quarter of an hour between the two is the one gap in
  # this pair, in a double fault that has already been reported for an hour.
  - interval: 1m
    name: a map restart during an outage does not forget the outage
    input_series:
      - series: 'mcmap_live_last_frame_timestamp_seconds{namespace="jdwillmsen-prd", instance="10.244.6.253:9090"}'
        values: '0+60x30 1800+0x5 stale'
      - series: 'mcmap_live_last_frame_timestamp_seconds{namespace="jdwillmsen-prd", instance="10.244.6.31:9090"}'
        values: '_x38 0+0x120'
    alert_rule_test:
      - eval_time: 46m
        alertname: JdwillmsenMinecraftMapLiveStale
        exp_alerts:
          - exp_labels:
              severity: warning
              namespace: jdwillmsen-prd
            exp_annotations:
              summary: "The Minecraft FWB map's live players and mobs have stopped updating"
              description: "The map last accepted a position record from the game server 16m 0s ago; the pack sends one every second even with nobody online, and a server restart is over well inside 15m. The page shows no markers meanwhile and nothing else is affected. Work down the path: mcmap_live_frames_total and mcmap_live_polls_total by result on the map, mc_console_bridge_script_records_total on the bridge, then the server log for [Scripting] lines. charts/minecraft-fwb/README.md, \"Live layer\"."
              runbook_url: "https://github.com/jdwillmsen/jdw-deployments/blob/main/charts/minecraft-fwb/README.md#live-layer"
      - eval_time: 46m
        alertname: JdwillmsenMinecraftMapLiveNeverStarted
        exp_alerts: []
      - eval_time: 97m
        alertname: JdwillmsenMinecraftMapLiveStale
        exp_alerts: []
      - eval_time: 105m
        alertname: JdwillmsenMinecraftMapLiveNeverStarted
        exp_alerts: []
      - eval_time: 112m
        alertname: JdwillmsenMinecraftMapLiveNeverStarted
        exp_alerts:
          - exp_labels:
              severity: warning
              namespace: jdwillmsen-prd
            exp_annotations:
              summary: "The Minecraft FWB map's live layer has no data"
              description: "The map has not accepted a single position record from the game server in the last 1h, or is not being scraped. Either the script pack is not running in the world or its records are not reaching the map. The server pod's logs say which: the init container install-map-pack logs why it skipped, the server's pack stack line names \"mcmap live positions\" when the pack loaded, and [Scripting] MCMAP1 lines are the records themselves. The pack only loads when the server starts. charts/minecraft-fwb/README.md, \"Live layer\"."
              runbook_url: "https://github.com/jdwillmsen/jdw-deployments/blob/main/charts/minecraft-fwb/README.md#live-layer"

  # The pack never installed, or the bridge never passed a record on. The
  # map is up and its gauge is there, reading zero, which is why the rule
  # asks for a time above zero and not for the series: a bare absent() says
  # nothing here. The staleness rule has no record to be stale against.
  - interval: 1m
    name: a layer that never produced a record is reported, and not as stale
    input_series:
      - series: 'mcmap_live_last_frame_timestamp_seconds{namespace="jdwillmsen-prd", instance="10.244.6.253:9090"}'
        values: '0+0x120'
    alert_rule_test:
      - eval_time: 14m
        alertname: JdwillmsenMinecraftMapLiveNeverStarted
        exp_alerts: []
      - eval_time: 16m
        alertname: JdwillmsenMinecraftMapLiveNeverStarted
        exp_alerts:
          - exp_labels:
              severity: warning
              namespace: jdwillmsen-prd
            exp_annotations:
              summary: "The Minecraft FWB map's live layer has no data"
              description: "The map has not accepted a single position record from the game server in the last 1h, or is not being scraped. Either the script pack is not running in the world or its records are not reaching the map. The server pod's logs say which: the init container install-map-pack logs why it skipped, the server's pack stack line names \"mcmap live positions\" when the pack loaded, and [Scripting] MCMAP1 lines are the records themselves. The pack only loads when the server starts. charts/minecraft-fwb/README.md, \"Live layer\"."
              runbook_url: "https://github.com/jdwillmsen/jdw-deployments/blob/main/charts/minecraft-fwb/README.md#live-layer"
      - eval_time: 2h
        alertname: JdwillmsenMinecraftMapLiveStale
        exp_alerts: []

  # No series at all: a map image from before the live layer, or a map that
  # is not being scraped. This is production at the moment these rules are
  # first applied.
  - interval: 1m
    name: a map that does not export the gauge is reported too
    input_series:
      - series: 'up{namespace="jdwillmsen-prd"}'
        values: '1+0x120'
    alert_rule_test:
      - eval_time: 14m
        alertname: JdwillmsenMinecraftMapLiveNeverStarted
        exp_alerts: []
      - eval_time: 16m
        alertname: JdwillmsenMinecraftMapLiveNeverStarted
        exp_alerts:
          - exp_labels:
              severity: warning
              namespace: jdwillmsen-prd
            exp_annotations:
              summary: "The Minecraft FWB map's live layer has no data"
              description: "The map has not accepted a single position record from the game server in the last 1h, or is not being scraped. Either the script pack is not running in the world or its records are not reaching the map. The server pod's logs say which: the init container install-map-pack logs why it skipped, the server's pack stack line names \"mcmap live positions\" when the pack loaded, and [Scripting] MCMAP1 lines are the records themselves. The pack only loads when the server starts. charts/minecraft-fwb/README.md, \"Live layer\"."
              runbook_url: "https://github.com/jdwillmsen/jdw-deployments/blob/main/charts/minecraft-fwb/README.md#live-layer"
      - eval_time: 16m
        alertname: JdwillmsenMinecraftMapLiveStale
        exp_alerts: []

  # THE ROLLOUT. The rules arrive in the sync that restarts the server with
  # the pack, so they start with nothing: no series while the new map pod
  # comes up, then its zero, then the first record ten minutes in -- a slow
  # rollout. Neither rule may fire at any point on the way.
  - interval: 1m
    name: the rollout that first turns the layer on does not page
    input_series:
      - series: 'mcmap_live_last_frame_timestamp_seconds{namespace="jdwillmsen-prd", instance="10.244.6.253:9090"}'
        values: '_x6 0+0x3 600+60x120'
    alert_rule_test:
      - eval_time: 0m
        alertname: JdwillmsenMinecraftMapLiveNeverStarted
        exp_alerts: []
      - eval_time: 9m
        alertname: JdwillmsenMinecraftMapLiveNeverStarted
        exp_alerts: []
      - eval_time: 9m
        alertname: JdwillmsenMinecraftMapLiveStale
        exp_alerts: []
      - eval_time: 16m
        alertname: JdwillmsenMinecraftMapLiveNeverStarted
        exp_alerts: []
      - eval_time: 16m
        alertname: JdwillmsenMinecraftMapLiveStale
        exp_alerts: []
      - eval_time: 2h
        alertname: JdwillmsenMinecraftMapLiveNeverStarted
        exp_alerts: []
      - eval_time: 2h
        alertname: JdwillmsenMinecraftMapLiveStale
        exp_alerts: []
TESTS

if ! out="$(cd "$work" && promtool test rules tests.yaml 2>&1)"; then
  echo "$out"
  fail "the map alert rules do not behave as specified"
fi

# The browser checks' rules. promtool's clock starts at unix 0, so a run
# timestamp counting 60 a minute is a run that has just finished, and one
# held still is the last run there was.
python3 - "$work/checks-on.yaml" > "$work/check-rules.yaml" <<'PY'
import sys, yaml
for doc in yaml.safe_load_all(open(sys.argv[1])):
    if doc and doc.get("kind") == "PrometheusRule" and doc["metadata"]["name"].endswith("-map-checks"):
        print(yaml.safe_dump({"groups": doc["spec"]["groups"]}, sort_keys=False))
PY
[ -s "$work/check-rules.yaml" ] || fail "could not extract the browser checks' rules from the chart"
promtool check rules "$work/check-rules.yaml" >/dev/null || fail "promtool rejected the rendered browser checks' rules"

cat > "$work/check-tests.yaml" <<'TESTS'
rule_files:
  - check-rules.yaml
evaluation_interval: 1m
tests:
  # Running and passing, with the job's own exchange once an hour: nothing
  # to say. The exchange counters are at zero from the map's start, which is
  # what lets a first refusal show as an increase at all.
  - interval: 1m
    input_series:
      - series: 'mcmap_e2e_run_success{namespace="jdwillmsen-prd", pod="exporter-a"}'
        values: '1x600'
      - series: 'mcmap_e2e_run_timestamp_seconds{namespace="jdwillmsen-prd", pod="exporter-a"}'
        values: '0+60x600'
      - series: 'mcmap_service_exchanges_total{namespace="jdwillmsen-prd", result="ok", source="private"}'
        values: '0+0x20 1+0x59 2+0x59 3+0x59 4+0x59 5+0x59 6+0x59 7+0x59 8+0x59 9+0x59 10+0x59'
      - series: 'mcmap_service_exchanges_total{namespace="jdwillmsen-prd", result="denied", source="private"}'
        values: '0x600'
      - series: 'mcmap_service_exchanges_total{namespace="jdwillmsen-prd", result="ok", source="loopback"}'
        values: '0x600'
    alert_rule_test:
      - eval_time: 9h
        alertname: JdwillmsenMinecraftMapChecksFailing
        exp_alerts: []
      - eval_time: 9h
        alertname: JdwillmsenMinecraftMapChecksStale
        exp_alerts: []
      - eval_time: 9h
        alertname: JdwillmsenMinecraftMapChecksNeverRan
        exp_alerts: []
      - eval_time: 9h
        alertname: JdwillmsenMinecraftMapServiceExchangeRefused
        exp_alerts: []
      - eval_time: 9h
        alertname: JdwillmsenMinecraftMapServiceExchangeFromOutside
        exp_alerts: []
      - eval_time: 9h
        alertname: JdwillmsenMinecraftMapServiceExchangeRate
        exp_alerts: []

  # A run fails. Told once it has stood ten minutes, and still told when the
  # exporter that reports it is replaced by another pod, as one alert.
  - interval: 1m
    input_series:
      - series: 'mcmap_e2e_run_success{namespace="jdwillmsen-prd", pod="exporter-a"}'
        values: '1x30 0x30 _x200'
      - series: 'mcmap_e2e_run_success{namespace="jdwillmsen-prd", pod="exporter-b"}'
        values: '_x60 0x60 1x100'
      - series: 'mcmap_e2e_run_timestamp_seconds{namespace="jdwillmsen-prd", pod="exporter-a"}'
        values: '0+60x300'
    alert_rule_test:
      - eval_time: 30m
        alertname: JdwillmsenMinecraftMapChecksFailing
        exp_alerts: []
      - eval_time: 36m
        alertname: JdwillmsenMinecraftMapChecksFailing
        exp_alerts: []
      - eval_time: 45m
        alertname: JdwillmsenMinecraftMapChecksFailing
        exp_alerts:
          - exp_labels:
              severity: warning
              namespace: jdwillmsen-prd
            exp_annotations:
              summary: The Minecraft FWB map failed its browser checks
              description: >-
                The last run of the map's browser checks had a failing check.
                mcmap_e2e_check_status says which (0 is failed, -1 skipped) and
                mcmap_e2e_measure what it measured. The job's log has one line a
                check with its own words for what went wrong; a screenshot and a
                trace of the failure are on the checks' volume.
                charts/minecraft-fwb/README.md, "Browser checks".
              runbook_url: "https://github.com/jdwillmsen/jdw-deployments/blob/main/charts/minecraft-fwb/README.md#browser-checks"
      - eval_time: 90m
        alertname: JdwillmsenMinecraftMapChecksFailing
        exp_alerts:
          - exp_labels:
              severity: warning
              namespace: jdwillmsen-prd
            exp_annotations:
              summary: The Minecraft FWB map failed its browser checks
              description: >-
                The last run of the map's browser checks had a failing check.
                mcmap_e2e_check_status says which (0 is failed, -1 skipped) and
                mcmap_e2e_measure what it measured. The job's log has one line a
                check with its own words for what went wrong; a screenshot and a
                trace of the failure are on the checks' volume.
                charts/minecraft-fwb/README.md, "Browser checks".
              runbook_url: "https://github.com/jdwillmsen/jdw-deployments/blob/main/charts/minecraft-fwb/README.md#browser-checks"
      # The next run passed.
      - eval_time: 130m
        alertname: JdwillmsenMinecraftMapChecksFailing
        exp_alerts: []

  # The checks stop running, still passing as far as the last run knows.
  # Quiet through the five hours the schedule leaves each night, told past
  # six.
  - interval: 1m
    input_series:
      - series: 'mcmap_e2e_run_success{namespace="jdwillmsen-prd", pod="exporter-a"}'
        values: '1x600'
      - series: 'mcmap_e2e_run_timestamp_seconds{namespace="jdwillmsen-prd", pod="exporter-a"}'
        values: '0+60x60 3600x540'
    alert_rule_test:
      - eval_time: 6h30m
        alertname: JdwillmsenMinecraftMapChecksStale
        exp_alerts: []
      - eval_time: 6h30m
        alertname: JdwillmsenMinecraftMapChecksFailing
        exp_alerts: []
      - eval_time: 7h5m
        alertname: JdwillmsenMinecraftMapChecksStale
        exp_alerts:
          - exp_labels:
              severity: warning
              namespace: jdwillmsen-prd
            exp_annotations:
              summary: The Minecraft FWB map's browser checks have stopped running
              description: >-
                No run of the map's browser checks has finished for
                6h 5m 0s. Nothing is watching the page
                meanwhile. Check the minecraft-fwb-map-checks CronJob and its
                last Job: a run that could not exchange its secret ends at once and
                says so in its log.
              runbook_url: "https://github.com/jdwillmsen/jdw-deployments/blob/main/charts/minecraft-fwb/README.md#browser-checks"

  # Switched on and never reported at all: the staleness rule has nothing to
  # subtract and says nothing, so this one has to.
  - interval: 1m
    input_series:
      - series: 'up{namespace="jdwillmsen-prd"}'
        values: '1x600'
    alert_rule_test:
      - eval_time: 5h
        alertname: JdwillmsenMinecraftMapChecksNeverRan
        exp_alerts: []
      - eval_time: 7h
        alertname: JdwillmsenMinecraftMapChecksStale
        exp_alerts: []
      - eval_time: 7h
        alertname: JdwillmsenMinecraftMapChecksNeverRan
        exp_alerts:
          - exp_labels:
              severity: warning
              namespace: jdwillmsen-prd
            exp_annotations:
              summary: The Minecraft FWB map's browser checks have never reported
              description: >-
                The checks are switched on and no run has ever published a result,
                or the exporter is not being scraped. Check the
                minecraft-fwb-map-checks CronJob, the
                minecraft-fwb-map-checks-exporter Deployment and its
                ServiceMonitor.
              runbook_url: "https://github.com/jdwillmsen/jdw-deployments/blob/main/charts/minecraft-fwb/README.md#browser-checks"

  # One wrong secret, from inside the cluster: told, and done with a quarter
  # of an hour after it.
  - interval: 1m
    input_series:
      - series: 'mcmap_service_exchanges_total{namespace="jdwillmsen-prd", result="ok", source="private"}'
        values: '0x120'
      - series: 'mcmap_service_exchanges_total{namespace="jdwillmsen-prd", result="denied", source="private"}'
        values: '0x30 1x90'
    alert_rule_test:
      - eval_time: 30m
        alertname: JdwillmsenMinecraftMapServiceExchangeRefused
        exp_alerts: []
      - eval_time: 33m
        alertname: JdwillmsenMinecraftMapServiceExchangeRefused
        exp_alerts:
          - exp_labels:
              severity: warning
              namespace: jdwillmsen-prd
            exp_annotations:
              summary: The Minecraft FWB map refused an exchange for a service session
              description: >-
                The map's internal port was asked for a service session and said no.
                mcmap_service_exchanges_total by result says how: denied is a wrong
                secret, locked is the five minutes after five wrong ones, limited is
                more exchanges than one a minute, malformed is a secret put in an
                address. The map logs each as "map service session refused" with the
                caller's address. If the checks are failing too, the Secret was
                changed without the map being restarted.
              runbook_url: "https://github.com/jdwillmsen/jdw-deployments/blob/main/charts/minecraft-fwb/README.md#browser-checks"
      - eval_time: 33m
        alertname: JdwillmsenMinecraftMapServiceExchangeFromOutside
        exp_alerts: []
      - eval_time: 60m
        alertname: JdwillmsenMinecraftMapServiceExchangeRefused
        exp_alerts: []

  # A session issued over a port-forward: let in, and told all the same.
  - interval: 1m
    input_series:
      - series: 'mcmap_service_exchanges_total{namespace="jdwillmsen-prd", result="ok", source="private"}'
        values: '0x120'
      - series: 'mcmap_service_exchanges_total{namespace="jdwillmsen-prd", result="ok", source="loopback"}'
        values: '0x30 1x90'
    alert_rule_test:
      - eval_time: 33m
        alertname: JdwillmsenMinecraftMapServiceExchangeRefused
        exp_alerts: []
      - eval_time: 33m
        alertname: JdwillmsenMinecraftMapServiceExchangeFromOutside
        exp_alerts:
          - exp_labels:
              severity: warning
              namespace: jdwillmsen-prd
              source: loopback
            exp_annotations:
              summary: A service session for the Minecraft FWB map was asked for from outside the cluster
              description: >-
                An exchange reached the map's internal port from loopback:
                loopback is a kubectl port-forward, other is an address with no
                business there. A run of the checks from a developer's or an agent's
                machine looks like this, and is meant to: it is expected only when the
                owner allowed that run. The map's log line for it carries the caller's
                user agent, which names who said they were allowed.
              runbook_url: "https://github.com/jdwillmsen/jdw-deployments/blob/main/charts/minecraft-fwb/README.md#browser-checks"

  # Five sessions in an hour where the schedule asks for one.
  - interval: 1m
    input_series:
      - series: 'mcmap_service_exchanges_total{namespace="jdwillmsen-prd", result="ok", source="private"}'
        values: '0x10 1x9 2x9 3x9 4x9 5x120'
    alert_rule_test:
      - eval_time: 35m
        alertname: JdwillmsenMinecraftMapServiceExchangeRate
        exp_alerts: []
      - eval_time: 55m
        alertname: JdwillmsenMinecraftMapServiceExchangeRate
        exp_alerts:
          - exp_labels:
              severity: warning
              namespace: jdwillmsen-prd
            exp_annotations:
              summary: More service sessions for the Minecraft FWB map are being issued than its checks ask for
              description: >-
                More than 3 service
                sessions were issued in an hour, and the schedule asks for fewer. Each
                is a "map service session issued" line in the map's log with the
                caller's address. If the callers are not the checks' own pods, rotate
                the Secret: delete minecraft-fwb-map-checks-secret and restart
                the map.
              runbook_url: "https://github.com/jdwillmsen/jdw-deployments/blob/main/charts/minecraft-fwb/README.md#browser-checks"
      - eval_time: 150m
        alertname: JdwillmsenMinecraftMapServiceExchangeRate
        exp_alerts: []
TESTS

if ! out="$(cd "$work" && promtool test rules check-tests.yaml 2>&1)"; then
  echo "$out"
  fail "the browser checks' alert rules do not behave as specified"
fi

# The pack's init step is on the game server's pod and carries the map's
# image, which Renovate merges unattended. Three things together keep that
# update off the game server, and each is easy to undo without noticing: the
# step lives in its own file, Renovate is switched off for that file, and
# the Application still lists it.
python3 - "$here" <<'PY' || fail "the pack's init step is no longer fenced off from unattended image updates"
import json, sys, yaml
here = sys.argv[1]
chart = f"{here}/charts/minecraft-fwb"
bad = []

base = yaml.safe_load(open(f"{chart}/values.yaml"))
if (base.get("minecraft-bedrock") or {}).get("initContainers"):
    bad.append("values.yaml defines minecraft-bedrock.initContainers again; Renovate updates images in that file")

pack = yaml.safe_load(open(f"{chart}/values-map-pack.yaml"))
if len((pack.get("minecraft-bedrock") or {}).get("initContainers") or []) != 1:
    bad.append("values-map-pack.yaml does not hold exactly one init container")
if set(pack) != {"minecraft-bedrock"} or set(pack["minecraft-bedrock"]) != {"initContainers"}:
    bad.append("values-map-pack.yaml holds something besides the init step; whatever else is there stops being updated too")

rules = json.load(open(f"{here}/renovate.json")).get("packageRules") or []
fence = [i for i, r in enumerate(rules)
         if r.get("enabled") is False and r.get("matchFileNames") == ["charts/minecraft-fwb/values-map-pack.yaml"]]
if not fence:
    bad.append("renovate.json has no rule disabling updates in charts/minecraft-fwb/values-map-pack.yaml")
elif fence[-1] != len(rules) - 1:
    bad.append("the rule disabling updates in values-map-pack.yaml is not last, so a later rule can switch them back on")

apps = yaml.safe_load(open(f"{here}/argocd/prd/config.yaml"))["apps"]
listed = next(a for a in apps if a["name"] == "minecraft-fwb-prd")["valueFiles"]
if "values-map-pack.yaml" not in listed:
    bad.append("the production Application does not list values-map-pack.yaml, so the pack is never installed")

for line in bad:
    print(line)
sys.exit(1 if bad else 0)
PY

echo "PASS: map quiet windows cover the backup and census, the internal token is generated once, only the public port is published and only behind the login, the pack's init step cannot hold the server, the map and live alerts fire when they should, and the browser checks are off, contained when on, and tell when they fail or stop"
