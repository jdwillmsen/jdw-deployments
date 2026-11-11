#!/usr/bin/env python3
"""World guard: refuse to let the Bedrock server open a LevelDB it can already tell is damaged.

Two entry points, one file, standard library only (it also runs as `python3 -I -c "$(cat ...)"`
inside an init container with a read-only root filesystem):

  world_guard.py check DB_DIR      print the report as JSON; exit 0 clean, 1 damaged, 2 inconclusive
  world_guard.py                   run the guard from the environment (init container)

Why it exists: a host that loses power takes the guest page cache with it. The
compaction output tables the MANIFEST already names can then be size-0 files, the
inputs are already unlinked, and the server opens the db without complaint (tables
are opened lazily) and only repairs, by dropping them, when something first reads one.
Everything here is read-only against the db; it only ever writes two markers under
DATA_DIR (the report and, on an accept, it removes the operator's accept file).

Only a positive finding blocks. A parser surprise, an unreadable directory, a timeout or
a missing world is reported and the guard exits 0: the guard's own bug must never be
what keeps a world offline.

Environment (guard mode):
  DATA_DIR            volume mount, default /data
  LEVEL_NAME          world directory under DATA_DIR/worlds, required
  GUARD_MODE          "enforce" holds the server; anything else only reports (default warn)
  RECHECK_SECONDS     seconds between checks while held, default 30
  CHECK_TIMEOUT       seconds before a check is abandoned as inconclusive, default 120
"""
import json
import os
import signal
import struct
import sys
import time

TABLE_MAGIC = 0xDB4775248B80FB57
BLOCK = 32768
HEADER = 7
TABLE_SUFFIXES = (".ldb", ".sst")
MAX_LISTED = 5
MAX_MANIFEST_BYTES = 48 * 1024 * 1024


class CheckTimeout(Exception):
    """Not an OSError: the per-table handlers catch OSError and must not swallow the alarm."""


class ParseError(Exception):
    """The MANIFEST could not be decoded; the finding is inconclusive, not damage."""


def _crc32c_table():
    table = []
    for i in range(256):
        c = i
        for _ in range(8):
            c = (c >> 1) ^ 0x82F63B78 if c & 1 else c >> 1
        table.append(c)
    return table


_CRC = _crc32c_table()


def crc32c(data, crc=0):
    crc ^= 0xFFFFFFFF
    for b in data:
        crc = _CRC[(crc ^ b) & 0xFF] ^ (crc >> 8)
    return crc ^ 0xFFFFFFFF


def masked_crc(typ, payload):
    c = crc32c(payload, crc32c(bytes([typ])))
    return (((c >> 15) | (c << 17)) + 0xA282EAD8) & 0xFFFFFFFF


def read_varint(buf, i):
    result = shift = 0
    while True:
        if i >= len(buf):
            raise ParseError("varint runs off the end of a record")
        c = buf[i]
        i += 1
        result |= (c & 0x7F) << shift
        if not c & 0x80:
            return result, i
        shift += 7
        if shift > 63:
            raise ParseError("varint longer than 64 bits")


def _scan(data, tail):
    """Walk the LevelDB log format, yielding (payload, crc_ok) per complete record.

    Streamed, so a large MANIFEST is decoded edit by edit instead of held as a list of
    payloads. `tail` is filled in as facts about how the file ends, which a power loss
    shapes: `truncated` (a record header or body runs off the end), `zero_bytes` (zero
    padding after the last record) and `pending_fragment`.
    """
    pos = 0
    frag = None
    frag_ok = True
    size = len(data)
    while pos < size:
        left_in_block = BLOCK - (pos % BLOCK)
        if left_in_block < HEADER:
            pos += left_in_block
            continue
        if pos + HEADER > size:
            tail["truncated"] = True
            break
        crc, length, typ = struct.unpack_from("<IHB", data, pos)
        if typ == 0 and length == 0:
            # LevelDB's reader skips a zero-type, zero-length header whatever its checksum
            # (preallocated or zero-padded space) and goes on to the next block.
            tail["zero_bytes"] += min(left_in_block, size - pos)
            pos += left_in_block
            continue
        body_start = pos + HEADER
        if body_start + length > size:
            # A record that runs past the end of the file is the torn tail of a write that
            # never finished; LevelDB treats it as end of file, and so must this, or the
            # table check below would be skipped on exactly the db a power loss produced.
            tail["truncated"] = True
            break
        if length > left_in_block - HEADER:
            raise ParseError("record at %d crosses a block boundary" % pos)
        payload = data[body_start:body_start + length]
        ok = masked_crc(typ, payload) == crc
        pos = body_start + length
        if typ == 1:
            yield payload, ok
        elif typ == 2:
            frag, frag_ok = bytearray(payload), ok
        elif typ == 3:
            if frag is None:
                raise ParseError("middle fragment with no first fragment")
            frag += payload
            frag_ok = frag_ok and ok
        elif typ == 4:
            if frag is None:
                raise ParseError("last fragment with no first fragment")
            frag += payload
            done, done_ok = bytes(frag), frag_ok and ok
            frag, frag_ok = None, True
            yield done, done_ok
        else:
            raise ParseError("unknown record type %d at %d" % (typ, pos))
    if frag is not None:
        tail["pending_fragment"] = True


def decode_edit(rec, live, state):
    """Apply one VersionEdit to the live-table map. Tags are LevelDB's version_edit.cc."""
    i = 0
    while i < len(rec):
        tag, i = read_varint(rec, i)
        if tag == 1:  # comparator name
            n, i = read_varint(rec, i)
            i += n
        elif tag in (2, 9):  # log number, previous log number
            _, i = read_varint(rec, i)
        elif tag == 3:  # next file number
            state["next_file"], i = read_varint(rec, i)
        elif tag == 4:  # last sequence
            _, i = read_varint(rec, i)
        elif tag == 5:  # compact pointer: level, internal key
            _, i = read_varint(rec, i)
            n, i = read_varint(rec, i)
            i += n
        elif tag == 6:  # deleted file: level, number
            _, i = read_varint(rec, i)
            num, i = read_varint(rec, i)
            live.pop(num, None)
        elif tag == 7:  # new file: level, number, size, smallest, largest
            lvl, i = read_varint(rec, i)
            num, i = read_varint(rec, i)
            size, i = read_varint(rec, i)
            for _ in range(2):
                n, i = read_varint(rec, i)
                i += n
            live[num] = (lvl, size)
        else:
            raise ParseError("unknown VersionEdit tag %d" % tag)
        if i > len(rec):
            raise ParseError("VersionEdit field runs off the end of its record")


def read_manifest(path):
    """Return (live, state, tail, interior_bad). live maps table number to (level, size)."""
    with open(path, "rb") as f:
        data = f.read()
    tail = {"truncated": False, "zero_bytes": 0, "pending_fragment": False}
    live = {}
    state = {"next_file": 0}
    crc_bad = []
    count = 0
    for payload, ok in _scan(data, tail):
        if ok:
            decode_edit(payload, live, state)
        else:
            crc_bad.append(count)
        count += 1
    del data
    # LevelDB's recovery fails the open on a record whose checksum does not match,
    # wherever it sits, and the server answers that by repairing. So any bad record is
    # damage; the position is kept only so the report can say whether it was the last.
    tail["crc_bad_last"] = bool(crc_bad) and crc_bad[-1] == count - 1
    return live, state, tail, crc_bad


def _table_name(num, db):
    for suffix in TABLE_SUFFIXES:
        name = "%06d%s" % (num, suffix)
        if os.path.lexists(os.path.join(db, name)):
            return name
    return "%06d.ldb" % num


def check_world(db):
    """Check one db directory. Returns a report dict with status clean, damaged, absent or inconclusive."""
    t0 = time.time()
    report = {"db": db, "status": "clean", "problems": [], "warnings": []}

    def done(status):
        report["status"] = status
        report["seconds"] = round(time.time() - t0, 3)
        return report

    try:
        names = os.listdir(db)
    except FileNotFoundError:
        return done("absent")
    except OSError as e:
        report["warnings"].append({"kind": "unreadable", "error": str(e)})
        return done("inconclusive")

    def is_data(n):
        if n.endswith(TABLE_SUFFIXES) or n.startswith("MANIFEST-"):
            return True
        return n.endswith(".log") and os.path.getsize(os.path.join(db, n)) > 0

    try:
        has_data = any(is_data(n) for n in names)
    except OSError as e:
        report["warnings"].append({"kind": "unreadable", "error": str(e)})
        return done("inconclusive")
    if not has_data:
        return done("absent")

    def problem(file, kind, **extra):
        p = {"file": file, "kind": kind}
        p.update(extra)
        report["problems"].append(p)

    cur_path = os.path.join(db, "CURRENT")
    try:
        with open(cur_path, "rb") as f:
            cur = f.read()
    except FileNotFoundError:
        problem("CURRENT", "current-missing")
        return done("damaged")
    except OSError as e:
        report["warnings"].append({"kind": "unreadable", "file": "CURRENT", "error": str(e)})
        return done("inconclusive")
    if not cur.endswith(b"\n") or not cur.strip():
        problem("CURRENT", "current-invalid", bytes=len(cur))
        return done("damaged")
    manifest = cur.decode("utf-8", "replace").strip()
    report["manifest"] = manifest
    if "/" in manifest or not manifest.startswith("MANIFEST-"):
        problem("CURRENT", "current-invalid", content=manifest[:40])
        return done("damaged")
    mpath = os.path.join(db, manifest)
    try:
        msize = os.path.getsize(mpath)
    except FileNotFoundError:
        problem(manifest, "manifest-missing")
        return done("damaged")
    if msize == 0:
        problem(manifest, "manifest-empty")
        return done("damaged")

    if msize > MAX_MANIFEST_BYTES:
        # The whole file is read into memory, and the container has 256Mi: past this the
        # kernel would kill it, which is not a fail-open exit. LevelDB only starts a new
        # MANIFEST when the db is reopened, so a long-running server can get here.
        report["warnings"].append({"kind": "manifest-too-large", "bytes": msize})
        return done("inconclusive")
    try:
        live, state, tail, interior_bad = read_manifest(mpath)
    except (ParseError, struct.error, OSError) as e:
        report["warnings"].append({"kind": "manifest-unparsed", "error": str(e)})
        return done("inconclusive")
    report["live_tables"] = len(live)
    if interior_bad:
        problem(manifest, "manifest-checksum", records=interior_bad[:MAX_LISTED], last=tail["crc_bad_last"])
        # What the rest of this MANIFEST says cannot be trusted, so stop here.
        return done("damaged")
    if tail["truncated"] or tail["pending_fragment"]:
        report["warnings"].append({"kind": "manifest-torn-tail"})
    if tail["zero_bytes"]:
        report["warnings"].append({"kind": "manifest-zero-tail", "bytes": tail["zero_bytes"]})

    bad_bytes = 0
    for num, (_lvl, want) in sorted(live.items()):
        name = _table_name(num, db)
        path = os.path.join(db, name)
        try:
            st = os.stat(path)
        except FileNotFoundError:
            problem(name, "missing", expected=want)
            bad_bytes += want
            continue
        except OSError as e:
            report["warnings"].append({"kind": "unreadable", "file": name, "error": str(e)})
            continue
        if st.st_size == 0:
            problem(name, "zero-byte", expected=want, mtime=int(st.st_mtime))
            bad_bytes += want
        elif st.st_size != want:
            problem(name, "size-mismatch", expected=want, actual=st.st_size, mtime=int(st.st_mtime))
            bad_bytes += want
        else:
            try:
                with open(path, "rb") as f:
                    f.seek(-8, 2)
                    magic = struct.unpack("<Q", f.read(8))[0]
            except OSError as e:
                report["warnings"].append({"kind": "unreadable", "file": name, "error": str(e)})
                continue
            if magic != TABLE_MAGIC:
                problem(name, "bad-footer", expected=want, mtime=int(st.st_mtime))
                bad_bytes += want

    orphans, orphan_zero = [], []
    for n in names:
        if not n.endswith(TABLE_SUFFIXES):
            continue
        try:
            num = int(n.split(".")[0])
        except ValueError:
            continue
        if num in live:
            continue
        try:
            sz = os.path.getsize(os.path.join(db, n))
        except OSError:
            continue
        if sz == 0:
            orphan_zero.append(n)
        elif state["next_file"] and num >= state["next_file"]:
            orphans.append(n)
    # An unreferenced table is something leveldb deletes when it opens the db, so
    # neither kind loses data on its own. They are the mark of a half-finished
    # compaction or a MANIFEST that lost its tail, which is why they are reported.
    if orphan_zero:
        report["warnings"].append({"kind": "orphan-zero-byte", "count": len(orphan_zero), "files": sorted(orphan_zero)[:MAX_LISTED]})
    if orphans:
        report["warnings"].append({"kind": "orphan-newer-than-manifest", "count": len(orphans), "files": sorted(orphans)[:MAX_LISTED]})
    if os.path.isdir(os.path.join(db, "lost")):
        report["warnings"].append({"kind": "repair-evidence", "dir": "lost"})

    if report["problems"]:
        report["bad_tables"] = len(report["problems"])
        report["bad_bytes"] = bad_bytes
        mt = [p["mtime"] for p in report["problems"] if "mtime" in p]
        if mt:
            report["bad_mtime_first"], report["bad_mtime_last"] = min(mt), max(mt)
        return done("damaged")
    return done("clean")


def _summary(report):
    """The report cut down to what one log line should carry."""
    out = {k: report[k] for k in ("status", "db", "manifest", "live_tables", "bad_tables", "bad_bytes", "seconds",
                                  "bad_mtime_first", "bad_mtime_last") if k in report}
    if report["problems"]:
        out["problems"] = report["problems"][:MAX_LISTED]
        kinds = {}
        for p in report["problems"]:
            kinds[p["kind"]] = kinds.get(p["kind"], 0) + 1
        out["kinds"] = kinds
    if report["warnings"]:
        out["warnings"] = report["warnings"][:MAX_LISTED]
    return out


def emit(event, **fields):
    fields["event"] = event
    fields["ts"] = int(time.time())
    print("world-guard: " + json.dumps(fields, sort_keys=True), flush=True)


def _timeout(_signum, _frame):
    raise CheckTimeout("check exceeded its time limit")


def safe_check(db, limit):
    """check_world, but any failure of the guard itself is inconclusive rather than fatal."""
    if hasattr(signal, "SIGALRM"):
        signal.signal(signal.SIGALRM, _timeout)
        signal.alarm(limit)
    try:
        return check_world(db)
    except Exception as e:  # noqa: BLE001 - the guard must not take the world down with it
        return {"db": db, "status": "inconclusive", "problems": [],
                "warnings": [{"kind": "guard-error", "error": "%s: %s" % (type(e).__name__, e)}]}
    finally:
        if hasattr(signal, "SIGALRM"):
            signal.alarm(0)


def write_report(state_dir, report):
    try:
        os.makedirs(state_dir, exist_ok=True)
        tmp = os.path.join(state_dir, "report.json.new")
        with open(tmp, "w") as f:
            json.dump(report, f, indent=1, sort_keys=True)
        os.replace(tmp, os.path.join(state_dir, "report.json"))
        return True
    except OSError as e:
        emit("report_write_failed", error=str(e))
        return False


def _accepted(path):
    """Only a regular file counts: a directory by that name would never be consumed."""
    return os.path.isfile(path)


def _int(env, key, default):
    try:
        return max(1, int(env.get(key, default)))
    except (TypeError, ValueError):
        return default


def guard(env, sleep=time.sleep, now=time.time):
    """The init-container loop. Returns the process exit code (always 0: see module doc)."""
    data = env.get("DATA_DIR", "/data")
    level = env.get("LEVEL_NAME", "")
    mode = "enforce" if env.get("GUARD_MODE") == "enforce" else "warn"
    recheck = _int(env, "RECHECK_SECONDS", 30)
    limit = _int(env, "CHECK_TIMEOUT", 120)
    if not level:
        emit("inconclusive", mode=mode, reason="LEVEL_NAME is not set")
        return 0
    db = os.path.join(data, "worlds", level, "db")
    state_dir = os.path.join(data, ".world-guard")
    accept = os.path.join(data, ".world-guard-accept")
    held_since = None
    while True:
        report = safe_check(db, limit)
        status = report["status"]
        if status != "damaged" and held_since is not None and status != "clean":
            # A positive finding is already on record, so an undecided recheck (a timeout, a
            # transient read error) or a world that has gone missing mid-repair must not
            # release the hold: only a clean check, or an operator's accept, ends it.
            if _accepted(accept):
                _remove(accept)
                emit("accepted", mode=mode, reason="recheck was %s" % status, **_summary(report))
                return 0
            emit("held", mode=mode, held_seconds=int(now() - held_since), recheck_seconds=recheck,
                 reason="recheck was %s" % status, **_summary(report))
            for _ in range(max(recheck, 1)):
                if _accepted(accept):
                    break
                sleep(1)
            continue
        if status != "damaged":
            if os.path.lexists(accept):
                # An accept is for the damage it was given for; leaving it would
                # wave through the next, different one.
                _remove(accept)
                emit("accept_discarded", mode=mode, reason="world is not damaged")
            event = {"clean": "clean", "absent": "absent"}.get(status, "inconclusive")
            if held_since is not None:
                emit("released", mode=mode, held_seconds=int(now() - held_since), **_summary(report))
            else:
                emit(event, mode=mode, **_summary(report))
            return 0
        report["mode"] = mode
        report["checked_at"] = int(now())
        write_report(state_dir, report)
        if _accepted(accept):
            _remove(accept)
            emit("accepted", mode=mode, **_summary(report))
            return 0
        if mode != "enforce":
            emit("would_hold", mode=mode, **_summary(report))
            return 0
        if held_since is None:
            held_since = now()
        emit("held", mode=mode, held_seconds=int(now() - held_since), recheck_seconds=recheck, **_summary(report))
        for _ in range(max(recheck, 1)):
            if _accepted(accept):
                break
            sleep(1)


def _remove(path):
    try:
        os.remove(path)
    except OSError as e:
        emit("accept_remove_failed", error=str(e))


def main(argv):
    if len(argv) >= 2 and argv[1] == "check":
        if len(argv) != 3:
            print("usage: world_guard.py check DB_DIR", file=sys.stderr)
            return 64
        report = check_world(argv[2])
        print(json.dumps(report, indent=1, sort_keys=True))
        return {"clean": 0, "absent": 0, "damaged": 1}.get(report["status"], 2)
    try:
        return guard(os.environ)
    except BaseException as e:  # noqa: BLE001 - the guard failing must never be what holds the world
        emit("inconclusive", reason="guard crashed: %s: %s" % (type(e).__name__, e))
        return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
