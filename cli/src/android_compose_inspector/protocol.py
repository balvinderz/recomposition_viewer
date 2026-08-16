from __future__ import annotations

import asyncio

from .errors import InspectorConnectionError, ProtocolError
from .framing import encode_frame, read_frame
from .generated import compose_layout_inspection_minimal_pb2 as compose_pb
from .generated import ui_inspector_minimal_pb2 as ui_pb
from .generated import view_inspector_minimal_pb2 as view_pb

COMPOSE_INSPECTOR_ID = "layoutinspector.compose.inspection"
VIEW_INSPECTOR_ID = "ui.inspector.inspectors.view.inspector"
COMPOSE_UI_LIBRARY_ID = "androidx.compose.ui:ui"


class InspectorConnection:
    """A serialized request/response connection to the injected AOSP agent."""

    def __init__(
        self,
        reader: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
        *,
        command_timeout: float = 8.0,
        startup_timeout: float = 30.0,
    ) -> None:
        self._reader = reader
        self._writer = writer
        self._next_command_id = 1
        self._lock = asyncio.Lock()
        self._command_timeout = command_timeout
        self._startup_timeout = startup_timeout
        self.events: list[ui_pb.Event] = []

    @classmethod
    async def connect(
        cls,
        host: str,
        port: int,
        *,
        command_timeout: float = 8.0,
        startup_timeout: float = 30.0,
    ) -> InspectorConnection:
        reader, writer = await asyncio.open_connection(host, port)
        return cls(
            reader,
            writer,
            command_timeout=command_timeout,
            startup_timeout=startup_timeout,
        )

    async def send_compose(self, command: compose_pb.Command) -> compose_pb.Response:
        payload = await self.send_inspector(COMPOSE_INSPECTOR_ID, command.SerializeToString())
        return compose_pb.Response.FromString(payload)

    async def query_root_view_ids(self) -> tuple[int, ...]:
        command = view_pb.Command()
        command.dump_views_command.include_attributes = False
        command.dump_views_command.include_resolution_stack = False
        payload = await self.send_inspector(VIEW_INSPECTOR_ID, command.SerializeToString())
        response = view_pb.Response.FromString(payload)
        if response.WhichOneof("specialized") != "dump_views_response":
            raise ProtocolError("View inspector did not return a hierarchy")
        root_ids = tuple(
            window.root.id
            for window in response.dump_views_response.windows
            if window.HasField("root")
        )
        if not root_ids:
            raise ProtocolError("View inspector returned no active window roots")
        return root_ids

    async def create_inspector(self, inspector_id: str, dex_path: str) -> None:
        async with self._lock:
            command = self._new_command()
            command.create_inspector.inspector_id = inspector_id
            command.create_inspector.dex_path = dex_path
            response = await self._send_with_timeout_locked(command, timeout=self._startup_timeout)
            if response.WhichOneof("specialized") != "create_inspector":
                raise ProtocolError("Agent did not acknowledge inspector creation")

    async def get_compose_version(self) -> str:
        async with self._lock:
            command = self._new_command()
            command.get_version.library_ids.append(COMPOSE_UI_LIBRARY_ID)
            response = await self._send_with_timeout_locked(command, timeout=self._startup_timeout)
            if response.WhichOneof("specialized") != "get_version":
                raise ProtocolError("Agent did not return a library-version response")
            version = response.get_version.versions.get(COMPOSE_UI_LIBRARY_ID)
            if not version:
                raise ProtocolError("Jetpack Compose was not detected in the target process")
            return version

    async def send_inspector(self, inspector_id: str, payload: bytes) -> bytes:
        async with self._lock:
            envelope = self._new_command()
            envelope.inspector_message.inspector_id = inspector_id
            envelope.inspector_message.payload = payload

            response = await self._send_with_timeout_locked(envelope)
            if response.WhichOneof("specialized") != "inspector_message":
                raise ProtocolError("Agent response did not contain an inspector payload")
            if response.inspector_message.inspector_id != inspector_id:
                raise ProtocolError(
                    "Response came from an unexpected inspector: "
                    f"{response.inspector_message.inspector_id}"
                )
            return response.inspector_message.payload

    def _new_command(self) -> ui_pb.Command:
        command = ui_pb.Command(command_id=self._next_command_id)
        self._next_command_id += 1
        return command

    async def _send_with_timeout_locked(
        self, envelope: ui_pb.Command, *, timeout: float | None = None
    ) -> ui_pb.Response:
        effective_timeout = timeout or self._command_timeout
        try:
            return await asyncio.wait_for(
                self._send_outer_locked(envelope), timeout=effective_timeout
            )
        except TimeoutError as exc:
            raise InspectorConnectionError(
                f"Inspector command timed out after {effective_timeout:g} seconds"
            ) from exc
        except (asyncio.IncompleteReadError, ConnectionError, OSError) as exc:
            raise InspectorConnectionError(f"Inspector connection was lost: {exc}") from exc

    async def _send_outer_locked(self, envelope: ui_pb.Command) -> ui_pb.Response:
        command_id = envelope.command_id
        self._writer.write(encode_frame(envelope.SerializeToString()))
        await self._writer.drain()

        while True:
            payload = await read_frame(self._reader)
            agent_message = ui_pb.AgentMessage.FromString(payload)
            kind = agent_message.WhichOneof("specialized")
            if kind == "event":
                self.events.append(agent_message.event)
                if agent_message.event.WhichOneof("specialized") == "crash":
                    crash = agent_message.event.crash
                    raise ProtocolError(
                        f"UI Inspector agent crashed: {crash.error_message}\n{crash.stack_trace}"
                    )
                continue
            if kind != "response":
                raise ProtocolError(f"Unexpected agent message: {kind}")

            response = agent_message.response
            if response.command_id != command_id:
                raise ProtocolError(
                    f"Response command id {response.command_id} does not match {command_id}"
                )
            if response.status != ui_pb.Response.SUCCESS:
                raise ProtocolError(response.error_message or "Inspector command failed")
            return response

    async def close(self) -> None:
        self._writer.close()
        await self._writer.wait_closed()
