#!/usr/bin/env python3
"""Merge AppleTrace raw trace fragments into a Chrome trace JSON array."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Iterable, List

from appletrace_binary import decode as decode_binary_fragment, is_binary_fragment


TRACE_FILE_RE = re.compile(r"^trace(?:_(\d+))?\.appletrace(bin)?$")


def list_trace_files(directory: Path) -> List[Path]:
    """Return trace fragments sorted by their numeric suffix."""
    trace_files = []
    for path in directory.iterdir():
        if not path.is_file():
            continue

        match = TRACE_FILE_RE.match(path.name)
        if not match:
            continue

        suffix = int(match.group(1) or 0)
        trace_files.append((suffix, path))

    return [path for _, path in sorted(trace_files, key=lambda item: item[0])]


def iter_events(trace_files: Iterable[Path]) -> Iterable[dict]:
    """Yield events from AppleTrace fragments (text JSON-lines or binary)."""
    binary_names: dict = {}  # shared across this run's binary fragments
    for file_path in trace_files:
        print(file_path)
        data = file_path.read_bytes()
        if is_binary_fragment(data):
            yield from decode_binary_fragment(data, names=binary_names)
        else:
            yield from _iter_text_events(file_path, data)


def _iter_text_events(file_path: Path, data: bytes) -> Iterable[dict]:
    text = data.decode("utf-8", errors="replace")
    lines = text.split("\n")
    for line_number, line in enumerate(lines, start=1):
        raw_line = line.strip()
        if not raw_line:
            continue

        if not raw_line.startswith("{"):
            break

        try:
            event = json.loads(raw_line)
        except json.JSONDecodeError as exc:
            # A record cut off mid-write by a killed process has no trailing
            # newline (only mmap zero padding); tolerate that, reject a
            # complete line that is corrupt.
            unterminated = line_number == len(lines)
            if "\x00" in raw_line or unterminated:
                break
            raise ValueError(
                f"Invalid JSON in {file_path}:{line_number}: {exc.msg}"
            ) from exc

        if not isinstance(event, dict):
            raise ValueError(
                f"Unexpected non-object event in {file_path}:{line_number}"
            )

        yield event


def iter_complete_events(events: Iterable[dict]) -> Iterable[dict]:
    """Collapse matched begin/end (`B`/`E`) pairs into `X` complete events.

    A complete event carries an explicit duration, so this roughly halves the
    number of section events. Pairing is LIFO per `(pid, tid)`, matching the
    nested begin/end model AppleTrace emits. Non-section events pass through
    untouched, and unmatched begins are emitted as raw `B` events (viewers
    auto-close them at the end of the trace).
    """
    open_stacks: dict[tuple, List[dict]] = {}
    for event in events:
        phase = event.get("ph")
        if phase == "B":
            key = (event.get("pid"), event.get("tid"))
            open_stacks.setdefault(key, []).append(event)
        elif phase == "E":
            key = (event.get("pid"), event.get("tid"))
            stack = open_stacks.get(key)
            if stack:
                begin = stack.pop()
                complete = dict(begin)
                complete["ph"] = "X"
                begin_ts = begin.get("ts", 0)
                complete["dur"] = event.get("ts", begin_ts) - begin_ts
                if "args" in event:
                    merged = dict(begin.get("args", {}))
                    merged.update(event["args"])
                    complete["args"] = merged
                yield complete
            else:
                yield event
        else:
            yield event

    for stack in open_stacks.values():
        for begin in stack:
            yield begin


def merge_trace_directory(
    directory: Path,
    output_path: Path | None = None,
    complete_events: bool = True,
) -> Path:
    """Merge all trace fragments under a directory into `trace.json`."""
    if not directory.exists():
        raise FileNotFoundError(f"Trace directory does not exist: {directory}")
    if not directory.is_dir():
        raise NotADirectoryError(f"Trace path is not a directory: {directory}")

    trace_files = list_trace_files(directory)
    if not trace_files:
        raise FileNotFoundError(f"No trace fragments found in {directory}")

    target = output_path or directory / "trace.json"
    source: Iterable[dict] = iter_events(trace_files)
    if complete_events:
        source = iter_complete_events(source)

    with target.open("w", encoding="utf-8") as handle:
        handle.write("[")
        first = True
        for event in source:
            if not first:
                handle.write(",")
            handle.write(json.dumps(event, ensure_ascii=False, separators=(",", ":")))
            first = False
        handle.write("]\n")

    return target


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Merge AppleTrace .appletrace fragments into trace.json."
    )
    parser.add_argument(
        "-d",
        "--dir",
        dest="directory",
        required=True,
        help="Directory containing trace.appletrace fragments.",
    )
    parser.add_argument(
        "-o",
        "--output",
        dest="output",
        help="Optional output JSON path. Defaults to <dir>/trace.json.",
    )
    parser.add_argument(
        "--raw",
        dest="raw",
        action="store_true",
        help="Emit raw begin/end events instead of collapsing into X complete events.",
    )
    return parser


def main() -> int:
    args = build_parser().parse_args()
    directory = Path(args.directory).expanduser().resolve()
    output_path = Path(args.output).expanduser().resolve() if args.output else None

    try:
        merged_path = merge_trace_directory(directory, output_path, not args.raw)
    except (FileNotFoundError, NotADirectoryError, ValueError) as exc:
        print(f"error: {exc}")
        return 1

    print(f"Wrote merged trace to {merged_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
