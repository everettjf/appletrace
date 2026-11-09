from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from merge import iter_complete_events, list_trace_files, merge_trace_directory


class MergeTraceDirectoryTests(unittest.TestCase):
    def test_trace_files_are_sorted_by_numeric_suffix(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            for name in ["trace_10.appletrace", "trace.appletrace", "trace_2.appletrace"]:
                (directory / name).write_text("", encoding="utf-8")

            files = list_trace_files(directory)
            self.assertEqual(
                [path.name for path in files],
                ["trace.appletrace", "trace_2.appletrace", "trace_10.appletrace"],
            )

    def test_merge_writes_valid_json_array(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            (directory / "trace.appletrace").write_text(
                '\n'.join(
                    [
                        '{"name":"A","ph":"B","pid":1,"tid":0,"ts":1}',
                        '{"name":"A","ph":"E","pid":1,"tid":0,"ts":2}',
                    ]
                )
                + "\n",
                encoding="utf-8",
            )
            (directory / "trace_1.appletrace").write_text(
                '{"name":"B","ph":"B","pid":1,"tid":1,"ts":3}\n',
                encoding="utf-8",
            )

            output = merge_trace_directory(directory, complete_events=False)
            merged = json.loads(output.read_text(encoding="utf-8"))

            self.assertEqual([event["name"] for event in merged], ["A", "A", "B"])

    def test_merge_defaults_to_complete_events(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            (directory / "trace.appletrace").write_text(
                '\n'.join(
                    [
                        '{"name":"A","ph":"B","pid":1,"tid":0,"ts":1}',
                        '{"name":"A","ph":"E","pid":1,"tid":0,"ts":4}',
                    ]
                )
                + "\n",
                encoding="utf-8",
            )

            output = merge_trace_directory(directory)
            merged = json.loads(output.read_text(encoding="utf-8"))

            self.assertEqual(len(merged), 1)
            self.assertEqual(merged[0]["ph"], "X")
            self.assertEqual(merged[0]["dur"], 3)

    def test_merge_stops_on_non_json_tail(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            (directory / "trace.appletrace").write_text(
                '{"name":"A","ph":"B","pid":1,"tid":0,"ts":1}\ntrailer\n',
                encoding="utf-8",
            )

            output = merge_trace_directory(directory)
            merged = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(len(merged), 1)

    def test_merge_raises_on_invalid_json(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            (directory / "trace.appletrace").write_text(
                '{"name":"A","ph":"B","pid":1,"tid":0,"ts":1\n',
                encoding="utf-8",
            )

            with self.assertRaises(ValueError):
                merge_trace_directory(directory)


    def test_truncated_tail_from_killed_process_is_tolerated(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            data = (
                b'{"name":"A","ph":"B","pid":1,"tid":0,"ts":1}\n'
                b'{"name":"A","ph":"E","pid":1,"tid":0,"ts":3}\n'
                b'{"name":"B","ca' + b"\x00" * 64
            )
            (directory / "trace.appletrace").write_bytes(data)
            merged = json.loads(merge_trace_directory(directory).read_text(encoding="utf-8"))
            self.assertEqual([(e["name"], e["ph"]) for e in merged], [("A", "X")])

    def test_corrupt_line_before_more_events_is_an_error(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            (directory / "trace.appletrace").write_text(
                '{"name":"A","ph":"B","pid":1,"tid":0,"ts":1}\n{"name":\n'
                '{"name":"A","ph":"E","pid":1,"tid":0,"ts":3}\n',
                encoding="utf-8",
            )
            with self.assertRaises(ValueError):
                merge_trace_directory(directory)


class CompleteEventsTests(unittest.TestCase):
    def test_matched_pair_becomes_complete_event(self) -> None:
        events = [
            {"name": "A", "ph": "B", "pid": 1, "tid": 0, "ts": 10},
            {"name": "A", "ph": "E", "pid": 1, "tid": 0, "ts": 25},
        ]
        result = list(iter_complete_events(events))
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]["ph"], "X")
        self.assertEqual(result[0]["dur"], 15)
        self.assertEqual(result[0]["name"], "A")

    def test_nested_pairs_pair_lifo(self) -> None:
        events = [
            {"name": "outer", "ph": "B", "pid": 1, "tid": 0, "ts": 0},
            {"name": "inner", "ph": "B", "pid": 1, "tid": 0, "ts": 5},
            {"name": "inner", "ph": "E", "pid": 1, "tid": 0, "ts": 8},
            {"name": "outer", "ph": "E", "pid": 1, "tid": 0, "ts": 20},
        ]
        result = list(iter_complete_events(events))
        self.assertEqual([(e["name"], e["dur"]) for e in result], [("inner", 3), ("outer", 20)])

    def test_non_section_events_pass_through(self) -> None:
        events = [
            {"name": "thread_name", "ph": "M", "pid": 1, "tid": 0, "args": {"name": "Main"}},
            {"name": "fps", "ph": "C", "pid": 1, "tid": 0, "ts": 1, "args": {"value": 60}},
            {"name": "mark", "ph": "i", "pid": 1, "tid": 0, "ts": 2, "s": "t"},
        ]
        result = list(iter_complete_events(events))
        self.assertEqual(result, events)

    def test_async_events_pass_through(self) -> None:
        events = [
            {"name": "load", "ph": "b", "id": 7, "pid": 1, "tid": 0, "ts": 1},
            {"name": "load", "ph": "e", "id": 7, "pid": 1, "tid": 2, "ts": 9},
        ]
        result = list(iter_complete_events(events))
        self.assertEqual(result, events)

    def test_unmatched_begin_is_preserved(self) -> None:
        events = [{"name": "dangling", "ph": "B", "pid": 1, "tid": 0, "ts": 3}]
        result = list(iter_complete_events(events))
        self.assertEqual(result, events)

    def test_pairs_are_isolated_per_thread(self) -> None:
        events = [
            {"name": "A", "ph": "B", "pid": 1, "tid": 0, "ts": 0},
            {"name": "B", "ph": "B", "pid": 1, "tid": 1, "ts": 1},
            {"name": "A", "ph": "E", "pid": 1, "tid": 0, "ts": 4},
            {"name": "B", "ph": "E", "pid": 1, "tid": 1, "ts": 9},
        ]
        result = list(iter_complete_events(events))
        durations = {e["name"]: e["dur"] for e in result}
        self.assertEqual(durations, {"A": 4, "B": 8})


if __name__ == "__main__":
    unittest.main()
