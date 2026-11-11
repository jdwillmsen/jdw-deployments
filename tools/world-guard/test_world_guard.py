#!/usr/bin/env python3
"""Unit tests for world_guard.py.

The fixtures are real where it matters and synthetic everywhere else:

* fixtures/incident-20261106-MANIFEST-6434688 is the MANIFEST the server wrote at its
  21:33 open on 2026-11-06, after the host power-off, recovered from the incident
  archive. It names 30 compaction outputs (6434658..6434687, level 3, 61,647,259 bytes)
  that the crash left as size-0 files. The tests rebuild that db shape from it (sparse
  files at the sizes the MANIFEST records) and expect exactly those 30 to be found.
* Everything else builds a LevelDB log with the encoder below, so each failure shape is
  one small, readable edit of a healthy db.

Run: python3 tools/world-guard/test_world_guard.py
"""
import contextlib
import io
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import world_guard as wg  # noqa: E402

INCIDENT_MANIFEST = os.path.join(HERE, "fixtures", "incident-20261106-MANIFEST-6434688")
INCIDENT_ZERO = set(range(6434658, 6434688))
FOOTER = struct.pack("<Q", wg.TABLE_MAGIC)


def varint(n):
    out = bytearray()
    while n >= 0x80:
        out.append((n & 0x7F) | 0x80)
        n >>= 7
    out.append(n)
    return bytes(out)


def lenprefixed(b):
    return varint(len(b)) + b


def edit(next_file=None, new=(), deleted=(), extra=b""):
    out = bytearray(varint(1) + lenprefixed(b"leveldb.BytewiseComparator"))
    out += varint(2) + varint(0)
    if next_file is not None:
        out += varint(3) + varint(next_file)
    out += varint(4) + varint(1000)
    for lvl, num in deleted:
        out += varint(6) + varint(lvl) + varint(num)
    for lvl, num, size in new:
        out += varint(7) + varint(lvl) + varint(num) + varint(size) + lenprefixed(b"a" * 12) + lenprefixed(b"z" * 12)
    return bytes(out + extra)


def write_log(path, records, tail_junk=b""):
    """The LevelDB log format: 32 KiB blocks, 7-byte header, records fragmented across blocks."""
    out = bytearray()
    for rec in records:
        first = True
        view = memoryview(rec)
        while True:
            room = wg.BLOCK - (len(out) % wg.BLOCK)
            if room < wg.HEADER:
                out += b"\x00" * room
                room = wg.BLOCK
            avail = room - wg.HEADER
            piece = bytes(view[:avail])
            view = view[avail:]
            last = len(view) == 0
            typ = (1 if last else 2) if first else (4 if last else 3)
            out += struct.pack("<IHB", wg.masked_crc(typ, piece), len(piece), typ) + piece
            first = False
            if last:
                break
    out += tail_junk
    with open(path, "wb") as f:
        f.write(out)


def touch(path):
    with open(path, "wb"):
        pass


def flip(path, index):
    with open(path, "rb") as f:
        data = bytearray(f.read())
    data[index] ^= 0xFF
    with open(path, "wb") as f:
        f.write(data)


def write_table(db, num, size, footer=True):
    path = os.path.join(db, "%06d.ldb" % num)
    with open(path, "wb") as f:
        if size:
            f.truncate(size)
            if footer:
                f.seek(size - 8)
                f.write(FOOTER)


class Db:
    """A throwaway db directory with a healthy default shape."""

    def __init__(self, tables=40, size=4096, manifest_name="MANIFEST-000100"):
        self.dir = tempfile.mkdtemp(prefix="wg-test-")
        self.db = os.path.join(self.dir, "worlds", "FWB", "db")
        os.makedirs(self.db)
        self.manifest_name = manifest_name
        self.tables = {1000 + i: size for i in range(tables)}
        self.next_file = 2000
        self.write_manifest()
        for num, sz in self.tables.items():
            write_table(self.db, num, sz)
        with open(os.path.join(self.db, "CURRENT"), "w") as f:
            f.write(self.manifest_name + "\n")
        with open(os.path.join(self.db, "000099.log"), "wb") as f:
            f.write(b"wal")

    def write_manifest(self, extra_records=(), tail_junk=b""):
        recs = [edit(next_file=self.next_file, new=[(2, n, s) for n, s in sorted(self.tables.items())])]
        recs += list(extra_records)
        write_log(os.path.join(self.db, self.manifest_name), recs, tail_junk)

    def path(self, name):
        return os.path.join(self.db, name)

    def check(self):
        return wg.check_world(self.db)

    def cleanup(self):
        shutil.rmtree(self.dir, ignore_errors=True)


class Base(unittest.TestCase):
    def make(self, **kw):
        d = Db(**kw)
        self.addCleanup(d.cleanup)
        return d

    def kinds(self, report):
        return sorted(p["kind"] for p in report["problems"])


class LogFormat(unittest.TestCase):
    def test_crc32c_known_vector(self):
        self.assertEqual(wg.crc32c(b"123456789"), 0xE3069283)

    def test_varint_roundtrip(self):
        for n in (0, 1, 127, 128, 300, 6434688, 2 ** 40):
            self.assertEqual(wg.read_varint(varint(n), 0)[0], n)

    def test_record_spanning_blocks_is_reassembled(self):
        d = self.enterContext_db(tables=2000)
        live, state, tail, bad = wg.read_manifest(d.path(d.manifest_name))
        self.assertGreater(os.path.getsize(d.path(d.manifest_name)), wg.BLOCK)
        self.assertEqual(len(live), 2000)
        self.assertEqual(bad, [])
        self.assertFalse(tail["truncated"])

    def enterContext_db(self, **kw):
        d = Db(**kw)
        self.addCleanup(d.cleanup)
        return d

    def test_a_block_trailer_shorter_than_a_header_is_skipped(self):
        """A record ending 3 bytes short of a block boundary leaves a trailer LevelDB skips."""
        d = self.enterContext_db(tables=1)
        first = edit(next_file=2000, new=[(2, 1000, 4096)])
        filler = edit(new=[(1, 7000, 10)], extra=b"")
        pad = wg.BLOCK - wg.HEADER - 3 - len(first)
        # a comparator record is the cheapest way to add exact padding to an edit
        n = pad - 1
        while 1 + len(varint(n)) + n > pad:
            n -= 1
        first = first + varint(1) + lenprefixed(b"c" * n)
        self.assertEqual(len(first) + wg.HEADER + 3, wg.BLOCK)
        write_log(d.path(d.manifest_name), [first, filler])
        live, _, tail, bad = wg.read_manifest(d.path(d.manifest_name))
        self.assertEqual((sorted(live), bad, tail["truncated"]), ([1000, 7000], [], False))

    def test_later_edit_deletes_and_adds(self):
        d = self.enterContext_db(tables=3)
        d.write_manifest(extra_records=[edit(new=[(1, 5000, 10)], deleted=[(2, 1000)])])
        live, _, _, _ = wg.read_manifest(d.path(d.manifest_name))
        self.assertNotIn(1000, live)
        self.assertEqual(live[5000], (1, 10))


class Healthy(Base):
    def test_healthy_db_is_clean(self):
        r = self.make().check()
        self.assertEqual(r["status"], "clean", r)
        self.assertEqual(r["live_tables"], 40)
        self.assertEqual(r["problems"], [])

    def test_missing_world_is_absent_not_damage(self):
        self.assertEqual(wg.check_world("/nonexistent/worlds/FWB/db")["status"], "absent")

    def test_empty_db_dir_is_absent(self):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d, True)
        self.assertEqual(wg.check_world(d)["status"], "absent")

    def test_only_lock_and_log_files_is_absent(self):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d, True)
        for n in ("LOCK", "LOG", "000002.log"):
            touch(os.path.join(d, n))
        self.assertEqual(wg.check_world(d)["status"], "absent")


class Damage(Base):
    def test_zero_byte_table_is_found(self):
        d = self.make()
        write_table(d.db, 1003, 0)
        r = d.check()
        self.assertEqual(r["status"], "damaged")
        self.assertEqual([(p["file"], p["kind"]) for p in r["problems"]], [("001003.ldb", "zero-byte")])
        self.assertEqual(r["bad_bytes"], 4096)

    def test_missing_table_is_found(self):
        d = self.make()
        os.remove(d.path("001007.ldb"))
        r = d.check()
        self.assertEqual(r["status"], "damaged")
        self.assertEqual(self.kinds(r), ["missing"])

    def test_truncated_table_is_a_size_mismatch(self):
        d = self.make()
        with open(d.path("001010.ldb"), "r+b") as f:
            f.truncate(2048)
        r = d.check()
        self.assertEqual(self.kinds(r), ["size-mismatch"])
        self.assertEqual(r["problems"][0]["actual"], 2048)

    def test_right_size_wrong_footer(self):
        d = self.make()
        write_table(d.db, 1011, 4096, footer=False)
        self.assertEqual(self.kinds(d.check()), ["bad-footer"])

    def test_missing_current_with_data_present(self):
        d = self.make()
        os.remove(d.path("CURRENT"))
        r = d.check()
        self.assertEqual(r["status"], "damaged")
        self.assertEqual(self.kinds(r), ["current-missing"])

    def test_empty_current(self):
        d = self.make()
        touch(d.path("CURRENT"))
        self.assertEqual(self.kinds(d.check()), ["current-invalid"])

    def test_current_without_newline(self):
        d = self.make()
        with open(d.path("CURRENT"), "w") as f:
            f.write("MANIFEST-0001")
        self.assertEqual(self.kinds(d.check()), ["current-invalid"])

    def test_current_naming_a_missing_manifest(self):
        d = self.make()
        os.remove(d.path(d.manifest_name))
        self.assertEqual(self.kinds(d.check()), ["manifest-missing"])

    def test_empty_manifest(self):
        d = self.make()
        touch(d.path(d.manifest_name))
        self.assertEqual(self.kinds(d.check()), ["manifest-empty"])

    def test_corrupt_record_before_the_end_is_damage(self):
        d = self.make()
        d.write_manifest(extra_records=[edit(new=[(1, 7000, 10)]), edit(new=[(1, 7001, 10)])])
        path = d.path(d.manifest_name)
        flip(path, wg.HEADER + 5)  # inside the first (snapshot) record
        r = d.check()
        self.assertEqual(r["status"], "damaged")
        self.assertEqual(self.kinds(r), ["manifest-checksum"])

    def test_bad_checksum_on_the_last_record_is_damage_too(self):
        """LevelDB fails the open on a bad record wherever it is, and the server then repairs."""
        d = self.make()
        d.write_manifest(extra_records=[edit(new=[(1, 7000, 10)])])
        flip(d.path(d.manifest_name), -2)
        r = d.check()
        self.assertEqual(r["status"], "damaged")
        self.assertEqual(self.kinds(r), ["manifest-checksum"])
        self.assertTrue(r["problems"][0]["last"])

    def test_zero_byte_table_is_still_found_behind_a_torn_header(self):
        """A record header whose length runs past the end of the file must not hide the tables."""
        for tail in (struct.pack("<IHB", 123, 0xFFFF, 1) + b"abc", struct.pack("<IHB", 5, 0, 0)):
            d = self.make()
            d.write_manifest(tail_junk=tail)
            write_table(d.db, 1003, 0)
            r = d.check()
            self.assertEqual((r["status"], self.kinds(r)), ("damaged", ["zero-byte"]), tail)

    def test_many_bad_tables_are_all_counted_but_few_listed_in_the_log(self):
        d = self.make(tables=100)
        for n in range(1000, 1040):
            write_table(d.db, n, 0)
        r = d.check()
        self.assertEqual(r["bad_tables"], 40)
        self.assertEqual(len(wg._summary(r)["problems"]), wg.MAX_LISTED)
        self.assertEqual(wg._summary(r)["kinds"], {"zero-byte": 40})


class Tolerated(Base):
    """Shapes leveldb itself accepts. None of them may hold the server."""

    def test_torn_manifest_tail_is_a_warning(self):
        d = self.make()
        d.write_manifest(extra_records=[edit(new=[(1, 7000, 10)])])
        path = d.path(d.manifest_name)
        with open(path, "r+b") as f:
            f.truncate(os.path.getsize(path) - 6)
        r = d.check()
        self.assertEqual(r["status"], "clean", r)
        self.assertIn("manifest-torn-tail", [w["kind"] for w in r["warnings"]])

    def test_zero_filled_tail_is_a_warning(self):
        d = self.make()
        d.write_manifest(tail_junk=b"\x00" * 5000)
        r = d.check()
        self.assertEqual(r["status"], "clean", r)
        self.assertIn("manifest-zero-tail", [w["kind"] for w in r["warnings"]])


    def test_zero_byte_orphan_is_a_warning_because_leveldb_deletes_it(self):
        d = self.make()
        write_table(d.db, 1999, 0)
        r = d.check()
        self.assertEqual(r["status"], "clean", r)
        self.assertEqual([w["kind"] for w in r["warnings"]], ["orphan-zero-byte"])

    def test_orphan_newer_than_the_manifest_is_a_warning(self):
        d = self.make()
        write_table(d.db, 2050, 4096)
        r = d.check()
        self.assertEqual(r["status"], "clean", r)
        self.assertEqual([w["kind"] for w in r["warnings"]], ["orphan-newer-than-manifest"])

    def test_lost_directory_is_noted_and_ignored(self):
        d = self.make()
        os.makedirs(d.path("lost"))
        touch(d.path("lost/000001.ldb"))
        r = d.check()
        self.assertEqual(r["status"], "clean", r)
        self.assertEqual([w["kind"] for w in r["warnings"]], ["repair-evidence"])


class Inconclusive(Base):
    def test_unknown_edit_tag_does_not_block(self):
        d = self.make()
        d.write_manifest(extra_records=[edit(extra=varint(42) + varint(1))])
        r = d.check()
        self.assertEqual(r["status"], "inconclusive")
        self.assertEqual(r["warnings"][0]["kind"], "manifest-unparsed")

    def test_truncated_varint_does_not_block(self):
        d = self.make()
        d.write_manifest(extra_records=[b"\x07\x02"])
        self.assertEqual(d.check()["status"], "inconclusive")

    def test_a_manifest_too_large_to_read_safely_does_not_block(self):
        d = self.make()
        original = wg.MAX_MANIFEST_BYTES
        wg.MAX_MANIFEST_BYTES = 10
        self.addCleanup(setattr, wg, "MAX_MANIFEST_BYTES", original)
        r = d.check()
        self.assertEqual(r["status"], "inconclusive")
        self.assertEqual(r["warnings"][0]["kind"], "manifest-too-large")

    def test_unreadable_directory_does_not_block(self):
        if os.geteuid() == 0:
            self.skipTest("root reads everything")
        d = self.make()
        os.chmod(d.db, 0)
        self.addCleanup(os.chmod, d.db, 0o755)
        self.assertEqual(d.check()["status"], "inconclusive")


class Incident20261106(unittest.TestCase):
    """The shape the 2026-11-06 power-off left, rebuilt from the real MANIFEST."""

    def build(self, zero):
        live, state, tail, bad = wg.read_manifest(INCIDENT_MANIFEST)
        self.assertEqual((bad, tail["truncated"]), ([], False))
        root = tempfile.mkdtemp(prefix="wg-incident-")
        self.addCleanup(shutil.rmtree, root, True)
        db = os.path.join(root, "worlds", "FWB", "db")
        os.makedirs(db)
        shutil.copy(INCIDENT_MANIFEST, os.path.join(db, "MANIFEST-6434688"))
        with open(os.path.join(db, "CURRENT"), "w") as f:
            f.write("MANIFEST-6434688\n")
        for num, (_lvl, size) in live.items():
            write_table(db, num, 0 if num in zero else size)
        return root, db, live

    def test_manifest_names_the_thirty_tables(self):
        live, _, _, _ = wg.read_manifest(INCIDENT_MANIFEST)
        gone = {n: live[n] for n in INCIDENT_ZERO}
        self.assertEqual(len(gone), 30)
        self.assertEqual({lvl for lvl, _ in gone.values()}, {3})
        self.assertEqual(sum(s for _, s in gone.values()), 61647259)
        self.assertEqual(len(live), 451)

    def test_crashed_world_is_damaged_with_exactly_the_thirty(self):
        _, db, _ = self.build(INCIDENT_ZERO)
        r = wg.check_world(db)
        self.assertEqual(r["status"], "damaged")
        self.assertEqual(r["bad_tables"], 30)
        self.assertEqual(r["bad_bytes"], 61647259)
        self.assertEqual({p["kind"] for p in r["problems"]}, {"zero-byte"})
        self.assertEqual({int(p["file"][:6 + 1]) for p in r["problems"]}, INCIDENT_ZERO)

    def test_same_db_with_the_tables_intact_is_clean(self):
        _, db, _ = self.build(set())
        self.assertEqual(wg.check_world(db)["status"], "clean")

    def test_a_single_lost_table_is_enough(self):
        _, db, _ = self.build({6434670})
        r = wg.check_world(db)
        self.assertEqual((r["status"], r["bad_tables"]), ("damaged", 1))

    def test_check_is_fast(self):
        _, db, _ = self.build(INCIDENT_ZERO)
        self.assertLess(wg.check_world(db)["seconds"], 2.0)

    def test_the_check_changes_nothing_on_disk(self):
        root, db, _ = self.build(INCIDENT_ZERO)

        def snapshot():
            return sorted((n, os.path.getsize(os.path.join(db, n)), os.stat(os.path.join(db, n)).st_mtime_ns)
                          for n in os.listdir(db))

        before = snapshot()
        wg.check_world(db)
        self.assertEqual(before, snapshot())
        self.assertEqual(sorted(os.listdir(root)), ["worlds"])


class GuardLoop(Base):
    def run_guard(self, d, mode, sleep=None, recheck=3, extra_env=None):
        env = {"DATA_DIR": d.dir, "LEVEL_NAME": "FWB", "GUARD_MODE": mode, "RECHECK_SECONDS": str(recheck)}
        env.update(extra_env or {})
        # DATA_DIR is the volume root: worlds/FWB/db sits under it, as in the pod.
        buf = io.StringIO()
        sleeps = []

        def fake_sleep(s):
            sleeps.append(s)
            if sleep:
                sleep(len(sleeps))

        with contextlib.redirect_stdout(buf):
            rc = wg.guard(env, sleep=fake_sleep)
        events = [json.loads(line[len("world-guard: "):]) for line in buf.getvalue().splitlines()]
        return rc, events, sleeps

    def accept_path(self, d):
        return os.path.join(d.dir, ".world-guard-accept")

    def report_path(self, d):
        return os.path.join(d.dir, ".world-guard", "report.json")

    def test_clean_world_exits_at_once(self):
        d = self.make()
        rc, ev, sleeps = self.run_guard(d, "enforce")
        self.assertEqual((rc, [e["event"] for e in ev], sleeps), (0, ["clean"], []))

    def test_first_boot_without_a_world_exits_at_once(self):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d, True)
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = wg.guard({"DATA_DIR": d, "LEVEL_NAME": "FWB", "GUARD_MODE": "enforce"})
        self.assertEqual(rc, 0)
        self.assertIn('"event": "absent"', buf.getvalue())

    def test_warn_mode_reports_what_it_would_hold_and_lets_the_server_start(self):
        d = self.make()
        write_table(d.db, 1001, 0)
        write_table(d.db, 1002, 0)
        rc, ev, sleeps = self.run_guard(d, "warn")
        self.assertEqual(rc, 0)
        self.assertEqual([e["event"] for e in ev], ["would_hold"])
        self.assertEqual(ev[0]["bad_tables"], 2)
        self.assertEqual(sleeps, [])
        with open(self.report_path(d)) as f:
            self.assertEqual(json.load(f)["bad_tables"], 2)

    def test_unset_or_unknown_mode_is_warn(self):
        d = self.make()
        write_table(d.db, 1001, 0)
        for mode in ("", "ENFORCE", "block"):
            rc, ev, _ = self.run_guard(d, mode)
            self.assertEqual((rc, ev[0]["event"], ev[0]["mode"]), (0, "would_hold", "warn"))

    def test_enforce_holds_and_rechecks_until_the_world_is_repaired(self):
        d = self.make()
        write_table(d.db, 1001, 0)

        def repair_after_five_seconds(n):
            if n == 5:
                write_table(d.db, 1001, 4096)

        rc, ev, sleeps = self.run_guard(d, "enforce", sleep=repair_after_five_seconds, recheck=3)
        self.assertEqual(rc, 0)
        self.assertEqual([e["event"] for e in ev], ["held", "held", "released"])
        self.assertEqual(len(sleeps), 6)
        self.assertEqual(ev[-1]["status"], "clean")

    def test_a_recheck_that_cannot_decide_does_not_release_the_hold(self):
        d = self.make()
        write_table(d.db, 1001, 0)
        original = wg.check_world
        calls = []

        def flaky(db):
            calls.append(1)
            if len(calls) in (2, 3):
                return {"db": db, "status": "inconclusive", "problems": [], "warnings": [{"kind": "unreadable"}]}
            if len(calls) == 4:
                return {"db": db, "status": "absent", "problems": [], "warnings": []}
            if len(calls) >= 5:
                write_table(d.db, 1001, 4096)
            return original(db)

        wg.check_world = flaky
        self.addCleanup(setattr, wg, "check_world", original)
        rc, ev, _ = self.run_guard(d, "enforce", recheck=1)
        self.assertEqual(rc, 0)
        self.assertEqual([e["event"] for e in ev], ["held"] * 4 + ["released"])
        self.assertEqual([e.get("reason") for e in ev[1:4]], ["recheck was inconclusive"] * 2 + ["recheck was absent"])

    def test_enforce_accept_file_lets_the_server_open_and_is_consumed(self):
        d = self.make()
        write_table(d.db, 1001, 0)

        def accept_on_second_poll(n):
            if n == 2:
                touch(self.accept_path(d))

        rc, ev, sleeps = self.run_guard(d, "enforce", sleep=accept_on_second_poll)
        self.assertEqual(rc, 0)
        self.assertEqual([e["event"] for e in ev], ["held", "accepted"])
        self.assertEqual(len(sleeps), 2)
        self.assertFalse(os.path.exists(self.accept_path(d)))

    def test_accept_file_already_present_skips_the_hold(self):
        d = self.make()
        write_table(d.db, 1001, 0)
        touch(self.accept_path(d))
        rc, ev, sleeps = self.run_guard(d, "enforce")
        self.assertEqual((rc, [e["event"] for e in ev], sleeps), (0, ["accepted"], []))
        self.assertFalse(os.path.exists(self.accept_path(d)))

    def test_a_stale_accept_file_does_not_wave_through_a_later_crash(self):
        d = self.make()
        touch(self.accept_path(d))
        rc, ev, _ = self.run_guard(d, "enforce")
        self.assertEqual([e["event"] for e in ev], ["accept_discarded", "clean"])
        self.assertFalse(os.path.exists(self.accept_path(d)))
        write_table(d.db, 1001, 0)

        def stop_after_two(n):
            if n == 2:
                touch(self.accept_path(d))

        _, ev, _ = self.run_guard(d, "enforce", sleep=stop_after_two)
        self.assertEqual(ev[0]["event"], "held")

    def test_guard_failure_never_holds_the_server(self):
        d = self.make()
        original = wg.check_world
        wg.check_world = lambda db: (_ for _ in ()).throw(RuntimeError("boom"))
        self.addCleanup(setattr, wg, "check_world", original)
        rc, ev, sleeps = self.run_guard(d, "enforce")
        self.assertEqual((rc, ev[0]["event"], sleeps), (0, "inconclusive", []))
        self.assertIn("RuntimeError", json.dumps(ev[0]))

    def test_unparseable_manifest_fails_open_even_in_enforce(self):
        d = self.make()
        d.write_manifest(extra_records=[edit(extra=varint(42) + varint(1))])
        rc, ev, _ = self.run_guard(d, "enforce")
        self.assertEqual((rc, ev[0]["event"]), (0, "inconclusive"))

    @unittest.skipUnless(hasattr(__import__("signal"), "SIGALRM"), "needs SIGALRM")
    def test_a_hung_check_times_out_and_fails_open(self):
        d = self.make()
        original = wg.check_world
        wg.check_world = lambda db: __import__("time").sleep(30)
        self.addCleanup(setattr, wg, "check_world", original)
        rc, ev, _ = self.run_guard(d, "enforce", extra_env={"CHECK_TIMEOUT": "1"})
        self.assertEqual((rc, ev[0]["event"]), (0, "inconclusive"))
        self.assertIn("CheckTimeout", json.dumps(ev[0]))

    def test_a_directory_named_like_the_accept_file_is_not_an_accept(self):
        d = self.make()
        write_table(d.db, 1001, 0)
        os.mkdir(self.accept_path(d))

        def stop_after_two(n):
            if n == 2:
                os.rmdir(self.accept_path(d))
                touch(self.accept_path(d))

        _, ev, _ = self.run_guard(d, "enforce", sleep=stop_after_two)
        self.assertEqual([e["event"] for e in ev], ["held", "accepted"])

    def test_garbage_settings_fall_back_to_defaults(self):
        d = self.make()
        rc, ev, _ = self.run_guard(d, "enforce", extra_env={"RECHECK_SECONDS": "soon", "CHECK_TIMEOUT": ""})
        self.assertEqual((rc, ev[0]["event"]), (0, "clean"))

    def test_main_never_exits_nonzero_on_a_crash(self):
        original = wg.guard
        self.addCleanup(setattr, wg, "guard", original)
        for exc in (MemoryError("boom"), KeyboardInterrupt(), RuntimeError("x")):
            wg.guard = lambda env, exc=exc: (_ for _ in ()).throw(exc)
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                rc = wg.main(["world_guard.py"])
            self.assertEqual(rc, 0, exc)
            self.assertIn(type(exc).__name__, buf.getvalue())

    def test_the_timeout_is_not_an_oserror(self):
        """The per-table handlers catch OSError; a timeout that were one would be swallowed there."""
        self.assertFalse(issubclass(wg.CheckTimeout, OSError))

    def test_missing_level_name_fails_open(self):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            self.assertEqual(wg.guard({"DATA_DIR": "/nonexistent"}), 0)
        self.assertIn("LEVEL_NAME", buf.getvalue())

    def test_unwritable_state_dir_does_not_stop_the_hold(self):
        d = self.make()
        write_table(d.db, 1001, 0)
        touch(os.path.join(d.dir, ".world-guard"))  # a file where the directory goes
        rc, ev, _ = self.run_guard(d, "warn")
        self.assertEqual(rc, 0)
        self.assertEqual([e["event"] for e in ev], ["report_write_failed", "would_hold"])

    def test_every_log_line_is_one_json_object_after_the_prefix(self):
        d = self.make()
        write_table(d.db, 1001, 0)
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            wg.guard({"DATA_DIR": d.dir, "LEVEL_NAME": "FWB", "GUARD_MODE": "warn"})
        lines = buf.getvalue().splitlines()
        self.assertEqual(len(lines), 1)
        self.assertTrue(lines[0].startswith("world-guard: {"))


class Cli(Base):
    def run_cli(self, *args):
        return subprocess.run([sys.executable, "-I", os.path.join(HERE, "world_guard.py"), *args],
                              capture_output=True, text=True)

    def test_exit_codes(self):
        d = self.make()
        self.assertEqual(self.run_cli("check", d.db).returncode, 0)
        write_table(d.db, 1001, 0)
        p = self.run_cli("check", d.db)
        self.assertEqual(p.returncode, 1)
        self.assertEqual(json.loads(p.stdout)["bad_tables"], 1)
        d.write_manifest(extra_records=[edit(extra=varint(42) + varint(1))])
        self.assertEqual(self.run_cli("check", d.db).returncode, 2)
        self.assertEqual(self.run_cli("check").returncode, 64)

    def test_runs_as_python_dash_c_with_isolated_mode(self):
        """The init container runs the file's text through `python3 -I -c`."""
        d = self.make()
        with open(os.path.join(HERE, "world_guard.py")) as f:
            src = f.read()
        env = {"PATH": os.environ.get("PATH", ""), "DATA_DIR": d.dir, "LEVEL_NAME": "FWB", "GUARD_MODE": "enforce"}
        p = subprocess.run([sys.executable, "-I", "-c", src], env=env, capture_output=True, text=True, timeout=60)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn('"event": "clean"', p.stdout)


class RealEvidence(unittest.TestCase):
    """Optional: point WORLD_GUARD_EVIDENCE at a directory holding the manifests recovered from the archives."""

    @unittest.skipUnless(os.environ.get("WORLD_GUARD_EVIDENCE"), "set WORLD_GUARD_EVIDENCE to a directory of real MANIFEST files")
    def test_every_real_manifest_parses_with_valid_checksums(self):
        root = os.environ["WORLD_GUARD_EVIDENCE"]
        names = [n for n in os.listdir(root) if n.startswith("MANIFEST-")]
        self.assertTrue(names)
        for n in names:
            live, _, tail, bad = wg.read_manifest(os.path.join(root, n))
            self.assertTrue(live, n)
            self.assertEqual(bad, [], n)
            self.assertFalse(tail["truncated"], n)


if __name__ == "__main__":
    unittest.main(verbosity=1)
