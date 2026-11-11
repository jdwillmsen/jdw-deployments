#!/usr/bin/env python3
"""Does a `sync -f /data` loop beside the Bedrock server cost TPS? An A/B/A/B measurement.

Runs against a TEST server (proving-grounds): it adds four ticking areas far from spawn and
fills them with blocks the whole time, so the server keeps writing chunks to its LevelDB the way
a played-in world does, and flips an in-pod `sync -f /data` loop on and off in alternating phases.
The load is identical in every phase; only the loop changes.

  tps-ab.py --phase-minutes 15 --out samples.csv        # off, on, off, on
  tps-ab.py --summary samples.csv                       # print the table again

TPS is the server's own game clock: `time query gametime` twice, game ticks over the wall-clock
seconds between the two log lines. Dirty/Writeback are the node's (/proc/meminfo is not
namespaced), so they show whether the loop did its job; PSI io is the stall time the pod's
node saw. This is a rehearsal rig, not a fixture: it modifies the world it runs on.
"""
import argparse
import csv
import datetime
import random
import re
import statistics
import subprocess
import sys
import threading
import time

NS = "jdwillmsen-prd"
POD = "jdwillmsen-proving-grounds-prd-minecraft-bedrock-0"
CTR = "jdwillmsen-proving-grounds-prd-minecraft-bedrock"
FIND = 'proc=$(find /proc -mindepth 2 -maxdepth 2 -name exe -lname "/data/bedrock_server-*" -printf "%h" -quit); '
GAMETIME = re.compile(r"\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}):(\d{3}) INFO\] Gametime is (\d+)")
AREAS = [(2000 + 200 * i, 2000) for i in range(4)]
BLOCKS = ["stone", "glass", "dirt", "gold_block", "air", "sand"]


def kx(*args, stdin=None, timeout=60):
    return subprocess.run(["kubectl", "-n", NS, "exec", *(["-i"] if stdin else []), POD, "-c", CTR, "--", *args],
                          input=stdin, capture_output=True, text=True, timeout=timeout)


def console(line):
    kx("sh", "-c", FIND + 'echo "$1" > $proc/fd/0', "sh", line)


def start_load(rate):
    """A feeder thread that keeps one long-lived exec writing to the console, reopening it when kubectl drops it.

    Returns (state, stop_event); state["proc"] is the live exec. The first run adds the ticking areas.
    """
    script = FIND + '[ -n "$proc" ] || exit 2; while IFS= read -r l; do echo "$l" > "$proc/fd/0"; done'
    state = {"proc": None, "restarts": 0}
    stop = threading.Event()

    def open_exec():
        return subprocess.Popen(["kubectl", "-n", NS, "exec", "-i", POD, "-c", CTR, "--", "sh", "-c", script],
                                stdin=subprocess.PIPE, text=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def send(line):
        for _ in range(5):
            try:
                if state["proc"] is None or state["proc"].poll() is not None:
                    state["proc"] = open_exec()
                    state["restarts"] += 1
                state["proc"].stdin.write(line + "\n")
                state["proc"].stdin.flush()
                return
            except (BrokenPipeError, ValueError, OSError):
                state["proc"] = None
                time.sleep(2)

    def feed():
        rnd = random.Random(341)
        for i, (x, z) in enumerate(AREAS):
            send("tickingarea add %d -64 %d %d -50 %d jdw341_%d" % (x, z, x + 63, z + 63, i))
            time.sleep(8)
        while not stop.is_set():
            x, z = rnd.choice(AREAS)
            x1, z1 = x + rnd.randint(0, 31), z + rnd.randint(0, 31)
            y1 = rnd.randint(-64, -58)
            send("fill %d %d %d %d %d %d %s" % (x1, y1, z1, x1 + 31, y1 + 6, z1 + 31, rnd.choice(BLOCKS)))
            time.sleep(1.0 / rate)

    threading.Thread(target=feed, daemon=True).start()
    return state, stop


def set_sync(on):
    # Idempotent: a second `on` phase in a row must not start a second loop (halving the interval).
    kill = ('[ -f /data/.tps-ab-sync.pid ] && kill $(cat /data/.tps-ab-sync.pid) 2>/dev/null; rm -f /data/.tps-ab-sync.pid; '
            'for p in /proc/[0-9]*; do grep -qa "sync -f /dat[a]; sleep 2" $p/cmdline 2>/dev/null && kill ${p#/proc/} 2>/dev/null; done; true')
    kx("sh", "-c", kill)
    if on:
        kx("sh", "-c", 'setsid sh -c \'while :; do sync -f /data; sleep 2; done\' >/dev/null 2>&1 < /dev/null & echo $! > /data/.tps-ab-sync.pid')


def sync_running():
    p = kx("sh", "-c", 'n=0; for p in /proc/[0-9]*; do grep -qa "sync -f /dat[a]; sleep 2" $p/cmdline 2>/dev/null && n=$((n+1)); done; echo $n')
    return int((p.stdout or "0").strip() or 0)


def node_state():
    p = kx("sh", "-c", "grep -E '^(Dirty|Writeback):' /proc/meminfo; cat /proc/pressure/io")
    out = {}
    for ln in p.stdout.splitlines():
        m = re.match(r"(Dirty|Writeback):\s+(\d+) kB", ln)
        if m:
            out[m.group(1).lower()] = int(m.group(2))
        m = re.match(r"(some|full) avg10=([\d.]+) avg60=([\d.]+) avg300=([\d.]+) total=(\d+)", ln)
        if m:
            out["psi_" + m.group(1) + "_avg10"] = float(m.group(2))
            out["psi_" + m.group(1) + "_total"] = int(m.group(5))
    return out


def gametime():
    console("time query gametime")
    time.sleep(2.5)
    p = subprocess.run(["kubectl", "-n", NS, "logs", POD, "-c", CTR, "--since=15s"], capture_output=True, text=True, errors="replace")
    hits = GAMETIME.findall(p.stdout)
    if not hits:
        return None
    ts, ms, g = hits[-1]
    t = datetime.datetime.strptime(ts, "%Y-%m-%d %H:%M:%S").replace(tzinfo=datetime.timezone.utc).timestamp() + int(ms) / 1000
    return t, int(g)


def summarize(path):
    rows = list(csv.DictReader(open(path)))
    phases = []
    for r in rows:
        key = (r["phase_no"], r["sync"])
        if not phases or phases[-1][0] != key:
            phases.append((key, []))
        phases[-1][1].append(r)
    print("%-8s %-5s %5s %7s %7s %7s %6s %12s %12s %10s" % ("phase", "sync", "n", "tps_mean", "tps_p5", "tps_min", "<19.6", "dirty_kB_mean", "dirty_kB_max", "psi_full10"))
    agg = {"off": [], "on": [], "real": []}
    for (no, sync), rs in phases:
        tps = [float(r["tps"]) for r in rs if r["tps"]]
        if not tps:
            continue
        dirty = [int(r["dirty_kb"]) for r in rs if r["dirty_kb"]]
        psi = [float(r["psi_full_avg10"]) for r in rs if r["psi_full_avg10"]]
        agg[sync] += tps
        q = sorted(tps)
        print("%-8s %-5s %5d %7.3f %7.3f %7.3f %5d%% %12.0f %12d %10.2f" % (
            no, sync, len(tps), statistics.mean(tps), q[max(0, int(len(q) * 0.05) - 1)], q[0],
            100 * sum(t < 19.6 for t in tps) // len(tps), statistics.mean(dirty or [0]), max(dirty or [0]), statistics.mean(psi or [0])))
    means = [(no, sync, statistics.mean([float(r["tps"]) for r in rs if r["tps"]])) for (no, sync), rs in phases
             if any(r["tps"] for r in rs)]
    offs = [m for _, sy, m in means if sy == "off"]
    ons = [m for _, sy, m in means if sy == "on"]
    pairs = [on - off for off, on in zip(offs, ons)]
    if len(pairs) >= 2:
        d = statistics.mean(pairs)
        se = statistics.stdev(pairs) / len(pairs) ** 0.5
        print("\npaired phase means (on - off), %d pairs: mean %+.3f TPS (%+.2f%%), standard error %.3f TPS, 95%% bound on the loss %.2f%%" % (
            len(pairs), d, 100 * d / statistics.mean(offs), se, 100 * (d - 2 * se) / statistics.mean(offs)))
    for label in ("on", "real"):
        if agg["off"] and agg[label]:
            off, on = statistics.mean(agg["off"]), statistics.mean(agg[label])
            print("\noff mean %.3f  %s mean %.3f  change %+.2f%%  (revert threshold: -2%%)" % (off, label, on, 100 * (on - off) / off))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--phase-minutes", type=float, default=15)
    ap.add_argument("--sequence", default="off,on,off,on")
    ap.add_argument("--rate", type=float, default=2.0, help="fill commands per second")
    ap.add_argument("--warmup-minutes", type=float, default=3)
    ap.add_argument("--interval", type=int, default=30)
    ap.add_argument("--out", default="samples.csv")
    ap.add_argument("--summary")
    a = ap.parse_args()
    if a.summary:
        summarize(a.summary)
        return 0
    if "real" not in a.sequence:
        names = subprocess.run(["kubectl", "-n", NS, "get", "pod", POD, "-o", "jsonpath={.spec.containers[*].name}"],
                               capture_output=True, text=True).stdout.split()
        if "world-sync" in names:
            # The sidecar is a different container: set_sync cannot see or stop it, so an "off" phase would sync too.
            sys.exit("the pod runs the world-sync sidecar; set global.worldSync.enabled=false for an off/on A/B, or use 'real' phases")
        set_sync(False)
    load, stop = start_load(a.rate)
    time.sleep(len(AREAS) * 8 + 5)
    print("warming up %.0f min under load" % a.warmup_minutes, flush=True)
    time.sleep(a.warmup_minutes * 60)
    fields = ["ts", "phase_no", "sync", "sync_procs", "gametime", "tps", "dirty_kb", "writeback_kb", "psi_some_avg10", "psi_full_avg10", "psi_full_total"]
    with open(a.out, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=fields)
        w.writeheader()
        try:
            for no, ph in enumerate(a.sequence.split(","), 1):
                if ph != "real":  # "real": the chart's own world-sync sidecar is in the pod; leave it alone
                    set_sync(ph == "on")
                time.sleep(5)
                procs = sync_running()
                if ph != "real":
                    assert (procs > 0) == (ph == "on"), "sync loop state is %d for phase %s" % (procs, ph)
                print("phase %d: sync %s (loops running: %d)" % (no, ph, procs), flush=True)
                prev = None
                end = time.time() + a.phase_minutes * 60
                while time.time() < end:
                    t0 = time.time()
                    g = gametime()
                    ns = node_state()
                    tps = None
                    if g and prev and g[0] > prev[0]:
                        tps = round((g[1] - prev[1]) / (g[0] - prev[0]), 3)
                    if g:
                        prev = g
                    w.writerow({"ts": int(time.time()), "phase_no": no, "sync": ph, "sync_procs": procs,
                                "gametime": g[1] if g else "", "tps": tps if tps is not None else "",
                                "dirty_kb": ns.get("dirty", ""), "writeback_kb": ns.get("writeback", ""),
                                "psi_some_avg10": ns.get("psi_some_avg10", ""), "psi_full_avg10": ns.get("psi_full_avg10", ""),
                                "psi_full_total": ns.get("psi_full_total", "")})
                    fh.flush()
                    time.sleep(max(0, a.interval - (time.time() - t0)))
        finally:
            if "real" not in a.sequence:
                set_sync(False)
            stop.set()
            time.sleep(2)
            for i in range(len(AREAS)):
                console("tickingarea remove jdw341_%d" % i)
                time.sleep(1)
            if load["proc"] is not None:
                load["proc"].terminate()
            print("load restarts: %d" % load["restarts"], flush=True)
    summarize(a.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
