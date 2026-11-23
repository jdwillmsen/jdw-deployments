#!/usr/bin/env python3
"""Retention and per-archive metrics for the FWB nightly archives.

Age alone is not a safe reason to delete a world backup: a loss that goes
unnoticed for longer than the window rotates the last good archive out. This
decides what may go from what each archive holds, not only how old it is.

Subcommands:
  census   read the map's /metrics on stdin, print "chunks=N lost=M"
  trim     decide, delete (unless --dry-run) and write the Prometheus text
"""
import argparse
import glob
import os
import re
import sys
import time

ARCHIVE_RE = re.compile(r"^fwb-(\d{8}T\d{6}Z)\.tar\.gz$")
STAMP_RE = re.compile(r"^\d{8}T\d{6}Z$")
SAMPLE_RE = re.compile(r"^([a-zA-Z_:][a-zA-Z0-9_:]*)(\{[^}]*\})?\s+(\S+)")
HOLD_REASONS = ("world-loss-ledger", "chunk-regression", "chunks-unknown")


def census(text, max_age, now):
    chunks = lost = 0
    seen_chunks = False
    stamp = None
    for line in text.splitlines():
        m = SAMPLE_RE.match(line)
        if not m:
            continue
        name, _, value = m.groups()
        try:
            v = float(value)
        except ValueError:
            continue
        if name == "mcmap_world_chunks":
            chunks += int(v)
            seen_chunks = True
        elif name == "mcmap_world_chunks_lost":
            lost += int(v)
        elif name == "mcmap_world_census_last_success_timestamp_seconds":
            stamp = v
    # A count the census took hours ago describes some other world. Better no
    # number than a plausible wrong one: retention treats "unknown" as a reason
    # to keep everything.
    if not seen_chunks or stamp is None or now - stamp > max_age:
        return ""
    return "chunks=%d lost=%d" % (chunks, lost)


def read_meta(path):
    meta = {}
    try:
        with open(path) as f:
            for line in f:
                k, sep, v = line.strip().partition("=")
                if sep:
                    meta[k] = v
    except OSError:
        pass
    return meta


def as_int(v):
    return int(v) if v is not None and re.fullmatch(r"\d+", v) else None


def load(dirpath, backfill):
    archives = []
    for path in glob.glob(os.path.join(dirpath, "fwb-????????T??????Z.tar.gz")):
        m = ARCHIVE_RE.match(os.path.basename(path))
        if not m:
            continue
        meta = read_meta(path + ".meta")
        q = meta.get("quiesced")
        a = {
            "stamp": m.group(1),
            "path": path,
            "bytes": os.path.getsize(path),
            "quiesced": int(q) if q in ("0", "1") else None,
            # A recorded count wins over a backfilled one: the job measured it
            # the night it was taken, an operator's figure is for archives that
            # predate the measurement.
            "chunks": as_int(meta.get("chunks")),
            "ldb_files": as_int(meta.get("ldb_files")),
            "ldb_bytes": as_int(meta.get("ldb_bytes")),
            "ldb_zero": as_int(meta.get("ldb_zero")),
        }
        if a["chunks"] is None:
            a["chunks"] = backfill.get(a["stamp"])
        archives.append(a)
    archives.sort(key=lambda a: a["stamp"], reverse=True)
    return archives


def decide(archives, keep, hard_max, protect_pct, regress_pct, lost, baseline):
    """Returns (delete, protected, held_reasons, max_chunks).

    Integer arithmetic throughout: chunk counts are integers and a float
    threshold would make "within 1%" depend on rounding at the boundary.
    """
    counted = [a for a in archives if a["chunks"] is not None and (not baseline or a["stamp"] >= baseline)]
    max_chunks = max((a["chunks"] for a in counted), default=None)
    protected = {}
    if max_chunks is not None:
        for a in counted:
            if a["chunks"] == max_chunks:
                protected[a["stamp"]] = "highest-chunk-count"
        # Newest first, so the first match is the newest.
        for a in counted:
            if a["quiesced"] == 1 and a["chunks"] * 100 >= max_chunks * (100 - protect_pct):
                protected.setdefault(a["stamp"], "newest-quiesced-near-max")
                break

    held = []
    if lost:
        held.append("world-loss-ledger")
    if archives:
        newest = archives[0]
        if newest["chunks"] is None:
            held.append("chunks-unknown")
        elif max_chunks is not None and newest["chunks"] * 100 < max_chunks * (100 - regress_pct):
            held.append("chunk-regression")

    delete = []
    # Oldest first, from the beyond-window tail only.
    tail = [a for a in archives[keep:] if a["stamp"] not in protected]
    if not held:
        delete = tail[::-1]
    else:
        # Disk is finite and a full volume fails every backup, which is worse
        # than losing an unprotected old archive. Under a hold only the
        # overflow past hard_max goes, and never a protected archive.
        excess = len(archives) - hard_max
        delete = tail[::-1][:max(excess, 0)]
    return delete, protected, held, max_chunks


def metrics(archives, protected, held, max_chunks, deleted_count, lost, job):
    L = 'backup_job="%s",artifact="world"' % job
    out = []

    def gauge(name, help_, rows):
        if not rows:
            return
        out.append("# HELP %s %s" % (name, help_))
        out.append("# TYPE %s gauge" % name)
        out.extend("%s{%s} %d" % (name, labels, v) for labels, v in rows)

    def per(key, name, help_):
        gauge(name, help_, [('%s,archive="%s"' % (L, a["stamp"]), a[key]) for a in archives if a[key] is not None])

    per("bytes", "backup_archive_bytes", "Size in bytes of each retained archive.")
    per("chunks", "backup_archive_chunks", "Chunks the map counted in the world when each retained archive was taken. Absent where unknown.")
    per("quiesced", "backup_archive_quiesced", "1 if nothing was writing the world when that archive was copied.")
    per("ldb_files", "backup_archive_ldb_files", "LevelDB table files in each archive. A proxy for chunk count when the map's was unavailable.")
    per("ldb_bytes", "backup_archive_ldb_bytes", "Bytes of LevelDB table files in each archive.")
    per("ldb_zero", "backup_archive_ldb_zero_files", "Zero-byte LevelDB tables in each archive, the signature of a crash that lost written data.")
    gauge("backup_archive_protected",
          "1 if retention will not delete that archive for age: highest chunk count, or newest quiesced within the protect margin of it.",
          [('%s,archive="%s"' % (L, a["stamp"]), 1 if a["stamp"] in protected else 0) for a in archives])
    if max_chunks is not None:
        gauge("backup_archive_chunks_max",
              "Highest chunk count among retained archives at or after the acknowledged baseline. Falls only when that archive is deleted or a baseline is acknowledged.",
              [(L, max_chunks)])
    if archives and archives[0]["chunks"] is not None:
        gauge("backup_last_artifact_chunks", "Chunks the map counted when the newest archive was taken.", [(L, archives[0]["chunks"])])
    if lost is not None:
        gauge("backup_world_lost_chunks", "Chunks in the map's loss ledger when the newest archive was taken. Cleared only by an operator's acknowledgement in the map.", [(L, lost)])
    gauge("backup_retention_held",
          "1 if retention is deleting nothing for age, by reason.",
          [('%s,reason="%s"' % (L, r), 1 if r in held else 0) for r in HOLD_REASONS])
    gauge("backup_retention_archives", "Archives on disk after this run's trim.", [(L, len(archives))])
    gauge("backup_retention_deleted", "Archives this run deleted.", [(L, deleted_count)])
    return "\n".join(out) + "\n"


def parse_backfill(path):
    out = {}
    if path and os.path.exists(path):
        with open(path) as f:
            for line in f:
                k, sep, v = line.strip().partition("=")
                if sep and STAMP_RE.match(k) and v.isdigit():
                    out[k] = int(v)
    return out


def main(argv):
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("census")
    c.add_argument("--max-age", type=int, default=3600)
    t = sub.add_parser("trim")
    t.add_argument("--dir", required=True)
    t.add_argument("--keep", type=int, required=True)
    t.add_argument("--hard-max", type=int, required=True)
    t.add_argument("--protect-pct", type=int, default=1)
    t.add_argument("--regress-pct", type=int, default=2)
    t.add_argument("--lost", default="", help="ledger total at backup time, empty if unknown")
    t.add_argument("--baseline", default="", help="acknowledged baseline stamp; older archives stop counting")
    t.add_argument("--backfill", default="", help="file of STAMP=COUNT for archives taken before counts were recorded")
    t.add_argument("--job", default="backup")
    t.add_argument("--metrics-out", default="")
    t.add_argument("--dry-run", action="store_true")
    a = p.parse_args(argv)

    if a.cmd == "census":
        print(census(sys.stdin.read(), a.max_age, time.time()))
        return 0

    if a.baseline and not STAMP_RE.match(a.baseline):
        print("FATAL: baseline %r is not a YYYYmmddTHHMMSSZ stamp" % a.baseline, file=sys.stderr)
        return 1
    if a.keep < 1 or a.hard_max < a.keep:
        print("FATAL: need 1 <= keep <= hard-max", file=sys.stderr)
        return 1
    lost = as_int(a.lost)
    archives = load(a.dir, parse_backfill(a.backfill))
    delete, protected, held, max_chunks = decide(archives, a.keep, a.hard_max, a.protect_pct, a.regress_pct, lost, a.baseline)

    for ar in archives:
        status = "delete" if ar in delete else "keep"
        why = protected.get(ar["stamp"], "")
        print("%s %s chunks=%s quiesced=%s%s" % (status, os.path.basename(ar["path"]), ar["chunks"], ar["quiesced"], " (%s)" % why if why else ""))
    print("max_chunks=%s held=%s" % (max_chunks, ",".join(held) or "no"))
    if held:
        print("WARNING: retention held (%s); deleting only what exceeds %d archives" % (",".join(held), a.hard_max), file=sys.stderr)

    if not a.dry_run:
        for ar in delete:
            os.remove(ar["path"])
            try:
                os.remove(ar["path"] + ".meta")
            except FileNotFoundError:
                pass
    if a.metrics_out:
        remaining = [ar for ar in archives if ar not in delete]
        text = metrics(remaining, protected, held, max_chunks, len(delete), lost, a.job)
        with open(a.metrics_out, "w") as f:
            f.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
