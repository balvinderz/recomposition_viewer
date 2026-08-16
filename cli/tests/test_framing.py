import asyncio

import pytest

from android_compose_inspector.errors import ProtocolError
from android_compose_inspector.framing import encode_frame, read_frame


@pytest.mark.asyncio
async def test_frame_round_trip() -> None:
    reader = asyncio.StreamReader()
    reader.feed_data(encode_frame(b"compose"))
    reader.feed_eof()

    assert await read_frame(reader) == b"compose"


@pytest.mark.asyncio
async def test_rejects_wrong_header() -> None:
    reader = asyncio.StreamReader()
    reader.feed_data(b"NOTFRAME" + b"\x00\x00\x00\x00")
    reader.feed_eof()

    with pytest.raises(ProtocolError, match="Invalid inspector frame header"):
        await read_frame(reader)
