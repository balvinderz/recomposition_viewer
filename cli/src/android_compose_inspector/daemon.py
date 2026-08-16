from __future__ import annotations

import asyncio
import json
import os
import sys
from typing import Any

from .errors import InspectorError
from .registry import SessionRegistry

HOST = "127.0.0.1"
DEFAULT_PORT = 8756


async def _dispatch(registry: SessionRegistry, command: str, params: dict[str, Any]) -> Any:
    if command == "prerequisites":
        return registry.bridge.prerequisite_status()

    if command == "attach":
        session_id, session = await registry.create(params["package"], params.get("device"))
        return {"session_id": session_id, **session.status()}

    if command == "sessions":
        return registry.list_status()

    if command == "shutdown":
        await registry.close_all()
        return {"shutdown": True}

    session_id = params["session_id"]
    session = registry.get(session_id)

    if command == "start-tracking":
        reset = params.get("reset", True)
        return {"session_id": session_id, **(await session.start_tracking(reset=reset))}
    if command == "snapshot":
        return await session.snapshot(
            app_only=params.get("app_only", True),
            changed_only=params.get("changed_only", False),
        )
    if command == "observe":
        return await session.observe(
            duration_ms=params.get("duration_ms", 5_000),
            sample_interval_ms=params.get("sample_interval_ms", 250),
            app_only=params.get("app_only", True),
            limit=params.get("limit", 50),
        )
    if command == "reset-counts":
        return {"session_id": session_id, **(await session.reset_counts())}
    if command == "stop-tracking":
        return {"session_id": session_id, **(await session.stop_tracking())}
    if command == "detach":
        await registry.remove(session_id)
        return {"session_id": session_id, "detached": True}

    raise InspectorError(f"Unknown command: {command}")


class DaemonServer:
    def __init__(self, port: int) -> None:
        self.port = port
        self.registry = SessionRegistry()

    async def handle_client(
        self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter
    ) -> None:
        request: dict[str, Any] = {}
        try:
            line = await reader.readline()
            if not line:
                return
            pretty = False
            try:
                request = json.loads(line)
                pretty = bool(request.get("pretty", False))
                params = request.get("params", {})
                result = await _dispatch(self.registry, request["command"], params)
                payload = {"ok": True, "result": result}
            except Exception as exc:  # noqa: BLE001 - surfaced to the CLI caller as JSON
                payload = {
                    "ok": False,
                    "error": str(exc),
                    "error_type": type(exc).__name__,
                }
            indent = 2 if pretty else None
            writer.write((json.dumps(payload, indent=indent) + "\n").encode())
            await writer.drain()
        finally:
            writer.close()
        if request.get("command") == "shutdown":
            asyncio.get_running_loop().call_later(0.1, os._exit, 0)

    async def serve(self) -> None:
        server = await asyncio.start_server(self.handle_client, HOST, self.port)
        addr = server.sockets[0].getsockname()
        print(json.dumps({"status": f"daemon listening on {addr[0]}:{addr[1]}"}), flush=True)
        async with server:
            await server.serve_forever()


def run(port: int = DEFAULT_PORT) -> None:
    daemon = DaemonServer(port)
    try:
        asyncio.run(daemon.serve())
    except KeyboardInterrupt:
        pass


def main() -> None:
    port = DEFAULT_PORT
    if "--port" in sys.argv:
        port = int(sys.argv[sys.argv.index("--port") + 1])
    run(port)


if __name__ == "__main__":
    main()
