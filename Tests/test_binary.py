from __future__ import annotations

import json
import struct
import tempfile
import unittest
from pathlib import Path

from appletrace_binary import MAGIC, Encoder, decode, is_binary_fragment
from merge import merge_trace_directory


def build(pid: int = 7):
    return Encoder(pid)


class BinaryDecodeTests(unittest.TestCase):
    def test_is_binary_fragment(self) -> None:
        self.assertTrue(is_binary_fragment(MAGIC + b"\x00\x00\x00\x00"))
        self.assertFalse(is_binary_fragment(b'{"name":"A"}'))

    def test_section_pair_roundtrip(self) -> None:
        enc = build(pid=42)
        enc.section("B", "work", tid=3, ts=10)
        enc.section("E", "work", tid=3, ts=25)
        events = list(decode(enc.to_bytes()))
        self.assertEqual(
            events,
            [
                {"name": "work", "cat": "appletrace", "ph": "B", "pid": 42, "tid": 3, "ts": 10},
                {"name": "work", "cat": "appletrace", "ph": "E", "pid": 42, "tid": 3, "ts": 25},
            ],
        )

    def test_instant_has_thread_scope(self) -> None:
        enc = build()
        enc.instant("mark", tid=0, ts=5)
        (event,) = list(decode(enc.to_bytes()))
        self.assertEqual(event["ph"], "i")
        self.assertEqual(event["s"], "t")

    def test_counter_integral_and_float(self) -> None:
        enc = build()
        enc.counter("fps", tid=0, ts=1, value=60.0)
        enc.counter("mem", tid=0, ts=2, value=142.5)
        events = list(decode(enc.to_bytes()))
        self.assertEqual(events[0]["args"], {"value": 60})
        self.assertIsInstance(events[0]["args"]["value"], int)
        self.assertEqual(events[1]["args"], {"value": 142.5})

    def test_async_events_carry_id(self) -> None:
        enc = build()
        enc.async_event("b", "load", tid=1, ts=1, async_id=99)
        enc.async_event("e", "load", tid=2, ts=9, async_id=99)
        events = list(decode(enc.to_bytes()))
        self.assertEqual([e["ph"] for e in events], ["b", "e"])
        self.assertEqual({e["id"] for e in events}, {99})

    def test_metadata_has_args_name_and_no_cat(self) -> None:
        enc = build(pid=5)
        enc.metadata("thread_name", tid=0, value="Main Thread")
        (event,) = list(decode(enc.to_bytes()))
        self.assertEqual(
            event,
            {"name": "thread_name", "ph": "M", "pid": 5, "tid": 0, "args": {"name": "Main Thread"}},
        )
        self.assertNotIn("cat", event)
        self.assertNotIn("ts", event)

    def test_string_table_is_shared(self) -> None:
        enc = build()
        for _ in range(3):
            enc.section("B", "loop", tid=0, ts=1)
            enc.section("E", "loop", tid=0, ts=2)
        # The name bytes appear once (interned) despite six events referencing it.
        self.assertEqual(enc.to_bytes().count(b"loop"), 1)
        events = list(decode(enc.to_bytes()))
        self.assertEqual(len(events), 6)
        self.assertTrue(all(e["name"] == "loop" for e in events))

    def test_trailing_zero_padding_stops_cleanly(self) -> None:
        enc = build()
        enc.section("B", "x", tid=0, ts=1)
        enc.section("E", "x", tid=0, ts=2)
        padded = enc.to_bytes() + b"\x00" * 4096  # simulate crash mmap padding
        events = list(decode(padded))
        self.assertEqual(len(events), 2)

    def test_undefined_string_id_raises(self) -> None:
        # Header + an event referencing string id 0 that was never defined.
        data = MAGIC + struct.pack("<I", 1) + bytes([ord("B")]) + struct.pack("<IQQQ", 0, 0, 0, 0)
        with self.assertRaises(ValueError):
            list(decode(data))


class BinaryCrossFragmentTests(unittest.TestCase):
    def test_shared_names_decode_id_defined_in_earlier_fragment(self) -> None:
        # Fragment 0 defines "loop" (id 0) and uses it; fragment 1 reuses id 0
        # without re-defining it (a thread emits a string def only once).
        first = build(pid=1)
        first.section("B", "loop", tid=0, ts=1)
        second_id = first._intern("loop")  # already defined -> id 0

        second = bytearray(MAGIC)
        second += struct.pack("<I", 1)  # pid header
        second += bytes([ord("E")]) + struct.pack("<IQQQ", second_id, 0, 5, 0)

        shared: dict = {}
        events = list(decode(first.to_bytes(), names=shared))
        events += list(decode(bytes(second), names=shared))
        self.assertEqual([e["ph"] for e in events], ["B", "E"])
        self.assertTrue(all(e["name"] == "loop" for e in events))

    def test_separate_names_dict_cannot_resolve_later_fragment(self) -> None:
        second = bytearray(MAGIC)
        second += struct.pack("<I", 1)
        second += bytes([ord("E")]) + struct.pack("<IQQQ", 0, 0, 5, 0)
        with self.assertRaises(ValueError):
            list(decode(bytes(second)))  # id 0 never defined in this fragment


class BinaryMergeTests(unittest.TestCase):
    def test_merge_decodes_binary_fragment(self) -> None:
        enc = build(pid=1)
        enc.metadata("process_name", tid=0, value="Demo")
        enc.section("B", "A", tid=0, ts=1)
        enc.section("E", "A", tid=0, ts=4)
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            (directory / "trace.appletracebin").write_bytes(enc.to_bytes())

            output = merge_trace_directory(directory, complete_events=False)
            events = json.loads(output.read_text(encoding="utf-8"))

        self.assertEqual([e["name"] for e in events], ["process_name", "A", "A"])

    def test_merge_collapses_binary_pairs_by_default(self) -> None:
        enc = build(pid=1)
        enc.section("B", "A", tid=0, ts=1)
        enc.section("E", "A", tid=0, ts=6)
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            (directory / "trace.appletracebin").write_bytes(enc.to_bytes())

            output = merge_trace_directory(directory)
            events = json.loads(output.read_text(encoding="utf-8"))

        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["ph"], "X")
        self.assertEqual(events[0]["dur"], 5)


if __name__ == "__main__":
    unittest.main()
