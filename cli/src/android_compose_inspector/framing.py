from __future__ import annotations

import asyncio
import struct

from .errors import ProtocolError

HEADER = b"UIINSPCT"
MAX_PAYLOAD_BYTES = 64 * 1024 * 1024


def encode_frame(payload: bytes) -> bytes:
    if len(payload) > MAX_PAYLOAD_BYTES:
        raise ProtocolError(f"Inspector payload is too large: {len(payload)} bytes")
    return HEADER + struct.pack(">I", len(payload)) + payload


async def read_frame(reader: asyncio.StreamReader) -> bytes:
    header = await reader.readexactly(len(HEADER))
    if header != HEADER:
        raise ProtocolError(f"Invalid inspector frame header: {header!r}")
    length = struct.unpack(">I", await reader.readexactly(4))[0]
    if length > MAX_PAYLOAD_BYTES:
        raise ProtocolError(f"Inspector payload exceeds limit: {length} bytes")
    return await reader.readexactly(length)
