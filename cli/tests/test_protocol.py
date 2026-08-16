import asyncio

import pytest

from android_compose_inspector.errors import InspectorConnectionError
from android_compose_inspector.framing import encode_frame, read_frame
from android_compose_inspector.generated import compose_layout_inspection_minimal_pb2 as compose_pb
from android_compose_inspector.generated import ui_inspector_minimal_pb2 as ui_pb
from android_compose_inspector.generated import view_inspector_minimal_pb2 as view_pb
from android_compose_inspector.protocol import (
    COMPOSE_INSPECTOR_ID,
    VIEW_INSPECTOR_ID,
    InspectorConnection,
)
from android_compose_inspector.session import parse_composable_response


async def inspector_handler(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    payload = await read_frame(reader)
    outer = ui_pb.Command.FromString(payload)
    inner = compose_pb.Command.FromString(outer.inspector_message.payload)

    inner_response = compose_pb.Response()
    if inner.WhichOneof("specialized") == "update_settings_command":
        inner_response.update_settings_response.can_delay_parameter_extractions = True
    else:
        tree = inner_response.get_composables_response
        tree.strings.add(id=1, str="Greeting")
        tree.strings.add(id=2, str="Greeting.kt")
        node = tree.roots.add(view_id=99).nodes.add(
            id=10,
            name=1,
            filename=2,
            line_number=42,
            anchor_hash=1234,
            recompose_count=7,
            recompose_skips=3,
        )
        node.bounds.layout.x = 4
        node.bounds.layout.y = 8
        node.bounds.layout.w = 120
        node.bounds.layout.h = 48

    response = ui_pb.Response(command_id=outer.command_id, status=ui_pb.Response.SUCCESS)
    response.inspector_message.inspector_id = COMPOSE_INSPECTOR_ID
    response.inspector_message.payload = inner_response.SerializeToString()
    agent_message = ui_pb.AgentMessage(response=response)
    writer.write(encode_frame(agent_message.SerializeToString()))
    await writer.drain()
    writer.close()
    await writer.wait_closed()


async def view_inspector_handler(
    reader: asyncio.StreamReader, writer: asyncio.StreamWriter
) -> None:
    payload = await read_frame(reader)
    outer = ui_pb.Command.FromString(payload)
    assert outer.inspector_message.inspector_id == VIEW_INSPECTOR_ID
    command = view_pb.Command.FromString(outer.inspector_message.payload)
    assert command.WhichOneof("specialized") == "dump_views_command"

    view_response = view_pb.Response()
    view_response.dump_views_response.windows.add().root.id = 4567
    response = ui_pb.Response(command_id=outer.command_id, status=ui_pb.Response.SUCCESS)
    response.inspector_message.inspector_id = VIEW_INSPECTOR_ID
    response.inspector_message.payload = view_response.SerializeToString()
    writer.write(encode_frame(ui_pb.AgentMessage(response=response).SerializeToString()))
    await writer.drain()
    writer.close()
    await writer.wait_closed()


async def version_handler(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    payload = await read_frame(reader)
    outer = ui_pb.Command.FromString(payload)
    assert list(outer.get_version.library_ids) == ["androidx.compose.ui:ui"]

    response = ui_pb.Response(command_id=outer.command_id, status=ui_pb.Response.SUCCESS)
    response.get_version.versions["androidx.compose.ui:ui"] = "1.11.2"
    writer.write(encode_frame(ui_pb.AgentMessage(response=response).SerializeToString()))
    await writer.drain()
    writer.close()
    await writer.wait_closed()


async def hanging_handler(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    await read_frame(reader)
    await asyncio.sleep(1)
    writer.close()
    await writer.wait_closed()


@pytest.mark.asyncio
async def test_persistent_protocol_request_response() -> None:
    server = await asyncio.start_server(inspector_handler, "127.0.0.1", 0)
    port = server.sockets[0].getsockname()[1]
    connection = await InspectorConnection.connect("127.0.0.1", port)
    command = compose_pb.Command()
    command.get_composables_command.root_view_id = 99

    response = await connection.send_compose(command)
    await connection.close()
    server.close()
    await server.wait_closed()

    nodes = parse_composable_response(
        response.get_composables_response, root_view_id=99, app_only=True
    )
    assert nodes == [
        {
            "id": 10,
            "anchor_hash": 1234,
            "parent_anchor_hash": None,
            "tree_index": 0,
            "depth": 0,
            "name": "Greeting",
            "path": "Greeting",
            "file": "Greeting.kt",
            "line": 42,
            "root_view_id": 99,
            "recompositions": 7,
            "skips": 3,
            "is_system": False,
            "bounds": {"x": 4, "y": 8, "width": 120, "height": 48},
        }
    ]


@pytest.mark.asyncio
async def test_queries_root_unique_drawing_ids_from_view_inspector() -> None:
    server = await asyncio.start_server(view_inspector_handler, "127.0.0.1", 0)
    port = server.sockets[0].getsockname()[1]
    connection = await InspectorConnection.connect("127.0.0.1", port)

    assert await connection.query_root_view_ids() == (4567,)

    await connection.close()
    server.close()
    await server.wait_closed()


@pytest.mark.asyncio
async def test_queries_compose_version_from_agent() -> None:
    server = await asyncio.start_server(version_handler, "127.0.0.1", 0)
    port = server.sockets[0].getsockname()[1]
    connection = await InspectorConnection.connect("127.0.0.1", port)

    assert await connection.get_compose_version() == "1.11.2"

    await connection.close()
    server.close()
    await server.wait_closed()


@pytest.mark.asyncio
async def test_command_timeout_marks_connection_unusable() -> None:
    server = await asyncio.start_server(hanging_handler, "127.0.0.1", 0)
    port = server.sockets[0].getsockname()[1]
    connection = await InspectorConnection.connect("127.0.0.1", port, command_timeout=0.01)

    with pytest.raises(InspectorConnectionError, match="timed out"):
        await connection.query_root_view_ids()

    await connection.close()
    server.close()
    await server.wait_closed()


def test_app_tree_collapses_hidden_system_layers() -> None:
    response = compose_pb.GetComposablesResponse()
    response.strings.add(id=1, str="SystemRoot")
    response.strings.add(id=2, str="AppParent")
    response.strings.add(id=3, str="SystemBridge")
    response.strings.add(id=4, str="AppChild")

    system_root = response.roots.add(view_id=99).nodes.add(id=1, name=1, anchor_hash=11, flags=1)
    app_parent = system_root.children.add(id=2, name=2, anchor_hash=22)
    system_bridge = app_parent.children.add(id=3, name=3, anchor_hash=33, flags=1)
    system_bridge.children.add(id=4, name=4, anchor_hash=44)

    nodes = parse_composable_response(response, root_view_id=99, app_only=True)

    assert [(node["name"], node["tree_index"], node["depth"]) for node in nodes] == [
        ("AppParent", 0, 0),
        ("AppChild", 1, 1),
    ]
    assert nodes[0]["parent_anchor_hash"] is None
    assert nodes[1]["parent_anchor_hash"] == 22


def test_app_tree_keeps_system_text_and_image_leaves() -> None:
    response = compose_pb.GetComposablesResponse()
    response.strings.add(id=1, str="AppParent")
    response.strings.add(id=2, str="Layout")
    response.strings.add(id=3, str="Text")
    response.strings.add(id=4, str="BasicText")
    response.strings.add(id=5, str="Image")
    response.strings.add(id=6, str="AppChild")

    app_parent = response.roots.add(view_id=99).nodes.add(id=1, name=1, anchor_hash=11)
    layout = app_parent.children.add(id=2, name=2, anchor_hash=22, flags=1)
    text = layout.children.add(id=3, name=3, anchor_hash=33, flags=1)
    text.children.add(id=4, name=4, anchor_hash=44, flags=1)
    layout.children.add(id=5, name=5, anchor_hash=55, flags=1)
    layout.children.add(id=6, name=6, anchor_hash=66)

    nodes = parse_composable_response(response, root_view_id=99, app_only=True)

    assert [(node["name"], node["depth"]) for node in nodes] == [
        ("AppParent", 0),
        ("Text", 1),
        ("Image", 1),
        ("AppChild", 1),
    ]
    assert [node["parent_anchor_hash"] for node in nodes[1:]] == [11, 11, 11]
    assert nodes[1]["is_system"] is True
    assert nodes[2]["is_system"] is True
