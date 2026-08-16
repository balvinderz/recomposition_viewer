from collections import deque

import pytest
from google.protobuf.message import DecodeError

from android_compose_inspector.adb import BootstrapResult
from android_compose_inspector.generated import compose_layout_inspection_minimal_pb2 as compose_pb
from android_compose_inspector.session import InspectorSession


class FakeBridge:
    async def remove_forward(self, serial: str, port: int) -> None:
        pass


class FakeConnection:
    def __init__(self, roots: list[tuple[int, ...]], frames: list[dict[int, int | None]]):
        self.roots = deque(roots)
        self.frames = deque(frames)

    async def query_root_view_ids(self) -> tuple[int, ...]:
        return self.roots.popleft()

    async def send_compose(self, command: compose_pb.Command) -> compose_pb.Response:
        root_id = command.get_composables_command.root_view_id
        frame = self.frames[0]
        count = frame.get(root_id)
        response = compose_pb.Response()
        tree = response.get_composables_response
        tree.SetInParent()
        if count is not None:
            tree.strings.add(id=1, str=f"Root{root_id}")
            tree.roots.add(view_id=root_id).nodes.add(
                id=root_id,
                name=1,
                anchor_hash=100 + root_id,
                recompose_count=count,
            )
        if root_id == self.roots_for_frame_end(frame):
            self.frames.popleft()
        return response

    @staticmethod
    def roots_for_frame_end(frame: dict[int, int | None]) -> int:
        return list(frame)[-1]

    async def close(self) -> None:
        pass


def make_session(connection: FakeConnection, roots: tuple[int, ...]) -> InspectorSession:
    session = InspectorSession(FakeBridge(), "com.example.app", "pixel")
    session.bootstrap = BootstrapResult(
        serial="pixel",
        package_name="com.example.app",
        pid=10,
        socket_name="ui_inspector_10_mcp",
        root_view_ids=roots,
        app_data_dir="/data/user/0/com.example.app",
        view_inspector_path="/data/view-inspector.jar",
        abi="arm64-v8a",
        compose_version="1.11.2",
    )
    session.forwarded_port = 1234
    session.connection = connection
    return session


@pytest.mark.asyncio
async def test_snapshot_refreshes_root_ids_after_navigation() -> None:
    connection = FakeConnection([(1,), (2,)], [{1: 0}, {2: 0}])
    session = make_session(connection, (1,))

    first = await session.snapshot()
    second = await session.snapshot()

    assert [node["root_view_id"] for node in first["nodes"]] == [1]
    assert [node["root_view_id"] for node in second["nodes"]] == [2]
    assert second["status"]["root_view_ids"] == [2]


@pytest.mark.asyncio
async def test_snapshot_keeps_baseline_while_node_is_temporarily_absent() -> None:
    connection = FakeConnection(
        [(1,), (1,), (1,)],
        [{1: 3}, {1: None}, {1: 5}],
    )
    session = make_session(connection, (1,))

    first = await session.snapshot()
    missing = await session.snapshot()
    returned = await session.snapshot()

    assert first["nodes"][0]["recomposition_delta"] == 3
    assert missing["nodes"] == []
    assert returned["nodes"][0]["recomposition_delta"] == 2


class OverflowingConnection:
    """Fails a too-deeply-nested request once, then succeeds once the caller
    retries with system composables skipped."""

    def __init__(self) -> None:
        self.requests: list[bool] = []

    async def query_root_view_ids(self) -> tuple[int, ...]:
        return (1,)

    async def send_compose(self, command: compose_pb.Command) -> compose_pb.Response:
        request = command.get_composables_command
        self.requests.append(request.skip_system_composables)
        if not request.skip_system_composables:
            raise DecodeError(
                "Error parsing message with type 'layoutinspector.compose.inspection.Response'"
            )
        response = compose_pb.Response()
        tree = response.get_composables_response
        tree.strings.add(id=1, str="Root")
        tree.roots.add(view_id=1).nodes.add(id=1, name=1, anchor_hash=101, recompose_count=1)
        return response

    async def close(self) -> None:
        pass


@pytest.mark.asyncio
async def test_snapshot_retries_with_system_composables_skipped_on_decode_error() -> None:
    connection = OverflowingConnection()
    session = make_session(connection, (1,))

    result = await session.snapshot()

    assert connection.requests == [False, True]
    assert [node["root_view_id"] for node in result["nodes"]] == [1]
