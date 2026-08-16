from __future__ import annotations

import asyncio
import json
import re
import sys
from typing import Any

from .adb import AndroidBridge
from .session import InspectorSession


class JsonBridge:
    """Persistent newline-delimited JSON adapter for desktop clients."""

    def __init__(self) -> None:
        self.android = AndroidBridge()
        self.session: InspectorSession | None = None

    async def dispatch(self, request: dict[str, Any]) -> tuple[Any, bool]:
        command = request.get("command")
        arguments = request.get("arguments") or {}
        if command == "prerequisites":
            return self.android.prerequisite_status(), False
        if command == "devices":
            return {"devices": await self._devices()}, False
        if command == "attach":
            await self._close_session()
            package = str(arguments.get("package", ""))
            device = arguments.get("device")
            self.session = InspectorSession(self.android, package, device)
            try:
                return await self.session.attach(), False
            except Exception:
                await self._close_session()
                raise
        if command == "start":
            return await self._require_session().start_tracking(
                reset=bool(arguments.get("reset", True))
            ), False
        if command == "snapshot":
            return await self._require_session().snapshot(
                app_only=bool(arguments.get("app_only", True)),
                changed_only=bool(arguments.get("changed_only", False)),
            ), False
        if command == "reset":
            return await self._require_session().reset_counts(), False
        if command == "stop":
            return await self._require_session().stop_tracking(), False
        if command == "detach":
            await self._close_session()
            return {"detached": True}, False
        if command == "shutdown":
            await self._close_session()
            return {"shutdown": True}, True
        raise ValueError(f"Unknown bridge command: {command!r}")

    async def _devices(self) -> list[dict[str, Any]]:
        output = await self.android.run("devices", "-l")
        devices: list[dict[str, Any]] = []
        for line in output.splitlines()[1:]:
            fields = line.split()
            if len(fields) < 2 or fields[1] != "device":
                continue
            serial = fields[0]
            metadata = {
                key: value
                for field in fields[2:]
                if ":" in field
                for key, value in [field.split(":", 1)]
            }
            foreground = None
            activities = await self.android.run(
                "-s", serial, "shell", "dumpsys", "activity", "activities"
            )
            for activity_line in activities.splitlines():
                if (
                    "topResumedActivity" not in activity_line
                    and "mResumedActivity" not in activity_line
                ):
                    continue
                match = re.search(r"\s([A-Za-z][A-Za-z0-9_.]+)/", activity_line)
                if match:
                    foreground = match.group(1)
                    break
            devices.append(
                {
                    "serial": serial,
                    "model": metadata.get("model", serial).replace("_", " "),
                    "product": metadata.get("product"),
                    "foreground_package": foreground,
                }
            )
        return devices

    def _require_session(self) -> InspectorSession:
        if self.session is None:
            raise ValueError("Attach to an application first")
        return self.session

    async def _close_session(self) -> None:
        if self.session is not None:
            await self.session.close()
            self.session = None


async def run_bridge() -> None:
    bridge = JsonBridge()
    try:
        while True:
            line = await asyncio.to_thread(sys.stdin.readline)
            if not line:
                return
            request_id: Any = None
            should_exit = False
            try:
                request = json.loads(line)
                request_id = request.get("id")
                result, should_exit = await bridge.dispatch(request)
                response = {"id": request_id, "ok": True, "result": result}
            except Exception as exc:
                response = {
                    "id": request_id,
                    "ok": False,
                    "error": {"type": type(exc).__name__, "message": str(exc)},
                }
            sys.stdout.write(json.dumps(response, separators=(",", ":")) + "\n")
            sys.stdout.flush()
            if should_exit:
                return
    finally:
        await bridge._close_session()


def main() -> None:
    asyncio.run(run_bridge())


if __name__ == "__main__":
    main()
