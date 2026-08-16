from __future__ import annotations

import asyncio
import uuid
from typing import Any

from .adb import AndroidBridge
from .session import InspectorSession


class SessionRegistry:
    def __init__(self) -> None:
        self.bridge = AndroidBridge()
        self.sessions: dict[str, InspectorSession] = {}
        self._lock = asyncio.Lock()

    async def create(self, package: str, device: str | None) -> tuple[str, InspectorSession]:
        session_id = uuid.uuid4().hex
        session = InspectorSession(self.bridge, package, device)
        await session.attach()
        async with self._lock:
            self.sessions[session_id] = session
        return session_id, session

    def get(self, session_id: str) -> InspectorSession:
        try:
            return self.sessions[session_id]
        except KeyError as exc:
            raise ValueError(f"Unknown inspector session: {session_id}") from exc

    async def remove(self, session_id: str) -> None:
        async with self._lock:
            session = self.sessions.pop(session_id, None)
        if session is not None:
            await session.close()

    async def close_all(self) -> None:
        async with self._lock:
            sessions = list(self.sessions.values())
            self.sessions.clear()
        await asyncio.gather(*(session.close() for session in sessions), return_exceptions=True)

    def list_status(self) -> dict[str, Any]:
        return {
            "sessions": [
                {"session_id": session_id, **session.status()}
                for session_id, session in self.sessions.items()
            ]
        }
