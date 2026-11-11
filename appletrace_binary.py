#!/usr/bin/env python3
"""AppleTrace binary trace fragment format (encoder + decoder).

The runtime can emit events as fixed-layout binary records instead of JSON
lines, keeping all string formatting off the hot path. Each unique event name is
interned once as a string-definition record; subsequent events reference it by
id. The exporter (``merge.py``) decodes these fragments back into the same
Chrome/Perfetto JSON events it produces for text fragments.

Format (little-endian)::

    header:
        magic   : 8 bytes  = b"APLTRC01"
        pid     : uint32

    then a stream of tagged records:
        0x00            -> end / zero padding (stop decoding)
        0x01            -> string definition: name_id(uint32) len(uint32) utf8[len]
        ASCII phase     -> event: name_id(uint32) tid(uint64) ts(uint64) arg(uint64)

    phase is one of 'B' 'E' 'i' 'C' 'b' 'e' 'M' 'T'; ``arg`` is phase-specific:
        'C'        -> IEEE-754 double bits of the counter value
        'b' / 'e'  -> async id
        'M'        -> name_id of the metadata value string (args.name)
        others     -> 0 (unused)
"""

from __future__ import annotations

import struct
from typing import Dict, Iterable, Iterator

MAGIC = b"APLTRC01"

TAG_END = 0x00
TAG_STRING = 0x01

_HEADER = struct.Struct("<I")          # pid (follows magic)
_STRING_HEADER = struct.Struct("<II")  # name_id, byte length
_EVENT = struct.Struct("<IQQQ")        # name_id, tid, ts, arg

_CAT = "appletrace"
_PHASES_WITH_CAT = frozenset({"B", "E", "i", "C", "b", "e"})


def is_binary_fragment(data: bytes) -> bool:
    return data[: len(MAGIC)] == MAGIC


class Encoder:
    """Builds a binary fragment. Used by tests and as the reference producer."""

    def __init__(self, pid: int) -> None:
        self._buffer = bytearray(MAGIC)
        self._buffer += _HEADER.pack(pid)
        self._ids: Dict[str, int] = {}

    def _intern(self, name: str) -> int:
        existing = self._ids.get(name)
        if existing is not None:
            return existing
        name_id = len(self._ids)
        self._ids[name] = name_id
        encoded = name.encode("utf-8")
        self._buffer.append(TAG_STRING)
        self._buffer += _STRING_HEADER.pack(name_id, len(encoded))
        self._buffer += encoded
        return name_id

    def _event(self, phase: str, name: str, tid: int, ts: int, arg: int) -> None:
        name_id = self._intern(name)
        self._buffer.append(ord(phase))
        self._buffer += _EVENT.pack(name_id, tid, ts, arg)

    def section(self, phase: str, name: str, tid: int, ts: int) -> None:
        if phase not in ("B", "E"):
            raise ValueError(f"section phase must be B or E, got {phase!r}")
        self._event(phase, name, tid, ts, 0)

    def instant(self, name: str, tid: int, ts: int) -> None:
        self._event("i", name, tid, ts, 0)

    def counter(self, name: str, tid: int, ts: int, value: float) -> None:
        (bits,) = struct.unpack("<Q", struct.pack("<d", value))
        self._event("C", name, tid, ts, bits)

    def async_event(self, phase: str, name: str, tid: int, ts: int, async_id: int) -> None:
        if phase not in ("b", "e"):
            raise ValueError(f"async phase must be b or e, got {phase!r}")
        self._event(phase, name, tid, ts, async_id)

    def task(self, task_name: str, tid: int, ts: int, async_id: int) -> None:
        """Names the task of the async begin that follows on the same thread."""
        self._event("T", task_name, tid, ts, async_id)

    def metadata(self, name: str, tid: int, value: str) -> None:
        value_id = self._intern(value)
        self._event("M", name, tid, 0, value_id)

    def to_bytes(self) -> bytes:
        return bytes(self._buffer)


def decode(data: bytes, *, names: Dict[int, str] | None = None) -> Iterator[dict]:
    """Yield Chrome/Perfetto JSON event dicts from a binary fragment.

    Decoding stops at a 0x00 tag or when the buffer is exhausted/truncated, so
    zero padding left by a crashed process is tolerated like the text path.

    Pass a shared ``names`` dict across the fragments of one run: a thread emits
    a name's string definition only once, so after fragment rollover a later
    fragment may reference an id defined in an earlier one.
    """
    if not is_binary_fragment(data):
        raise ValueError("not an AppleTrace binary fragment")

    offset = len(MAGIC)
    (pid,) = _HEADER.unpack_from(data, offset)
    offset += _HEADER.size

    if names is None:
        names = {}
    size = len(data)
    # 'T' records name the task of the next async begin with the same
    # (tid, async id).
    pending_tasks: Dict[tuple, str] = {}

    while offset < size:
        tag = data[offset]
        offset += 1

        if tag == TAG_END:
            break

        if tag == TAG_STRING:
            if offset + _STRING_HEADER.size > size:
                break
            name_id, length = _STRING_HEADER.unpack_from(data, offset)
            offset += _STRING_HEADER.size
            if offset + length > size:
                break
            names[name_id] = data[offset : offset + length].decode("utf-8", errors="replace")
            offset += length
            continue

        if offset + _EVENT.size > size:
            break
        name_id, tid, ts, arg = _EVENT.unpack_from(data, offset)
        offset += _EVENT.size

        phase = chr(tag)
        name = names.get(name_id)
        if name is None:
            raise ValueError(f"event references undefined string id {name_id}")

        if phase == "T":
            pending_tasks[(tid, arg)] = name
            continue

        event: dict = {"name": name, "ph": phase, "pid": pid, "tid": tid}
        if phase in _PHASES_WITH_CAT:
            event["cat"] = _CAT
            event["ts"] = ts

        if phase == "i":
            event["s"] = "t"
        elif phase == "C":
            (value,) = struct.unpack("<d", struct.pack("<Q", arg))
            event["args"] = {"value": int(value) if value.is_integer() else value}
        elif phase in ("b", "e"):
            event["id"] = arg
            if phase == "b":
                task = pending_tasks.pop((tid, arg), None)
                if task is not None:
                    event["args"] = {"task": task}
        elif phase == "M":
            value = names.get(arg)
            if value is None:
                raise ValueError(f"metadata references undefined string id {arg}")
            event["args"] = {"name": value}

        # Order keys to match the text producer (name, cat, ph, ...).
        ordered = {"name": event["name"]}
        if "cat" in event:
            ordered["cat"] = event["cat"]
        ordered["ph"] = event["ph"]
        if "id" in event:
            ordered["id"] = event["id"]
        ordered["pid"] = event["pid"]
        ordered["tid"] = event["tid"]
        if "ts" in event:
            ordered["ts"] = event["ts"]
        if "s" in event:
            ordered["s"] = event["s"]
        if "args" in event:
            ordered["args"] = event["args"]
        yield ordered


def decode_all(data: bytes) -> Iterable[dict]:
    return list(decode(data))
