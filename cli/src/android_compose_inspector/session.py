from __future__ import annotations

import asyncio
import time
from dataclasses import dataclass, replace
from typing import Any

from google.protobuf.message import DecodeError

from .adb import AndroidBridge, BootstrapResult
from .errors import InspectorConnectionError, InspectorError, ProtocolError
from .generated import compose_layout_inspection_minimal_pb2 as compose_pb
from .protocol import COMPOSE_INSPECTOR_ID, VIEW_INSPECTOR_ID, InspectorConnection
from .resolver import resolve_compose_inspector

SYSTEM_CREATED_FLAG = 0x1
SYSTEM_LEAVES_VISIBLE_IN_APP_TREE = frozenset({"Text", "Image"})


@dataclass(frozen=True)
class Counter:
    recompositions: int
    skips: int


class InspectorSession:
    def __init__(self, bridge: AndroidBridge, package_name: str, device: str | None) -> None:
        self.bridge = bridge
        self.package_name = package_name
        self.requested_device = device
        self.bootstrap: BootstrapResult | None = None
        self.forwarded_port: int | None = None
        self.connection: InspectorConnection | None = None
        self.tracking = False
        self._last_counts: dict[tuple[int, int], Counter] = {}
        self._state_lock = asyncio.Lock()
        self._snapshot_lock = asyncio.Lock()
        self._recovery_generation = 0

    async def attach(self) -> dict[str, Any]:
        async with self._state_lock:
            if self.connection is not None:
                return self.status()
            await self._attach_locked()
            return self.status()

    async def _attach_locked(self) -> None:
        self.bootstrap = await self.bridge.bootstrap(
            package_name=self.package_name,
            device=self.requested_device,
        )
        self.forwarded_port = await self.bridge.forward(
            self.bootstrap.serial,
            self.bootstrap.socket_name,
        )
        step = "connecting to the UI Inspector agent"
        try:
            self.connection = await InspectorConnection.connect("127.0.0.1", self.forwarded_port)
            step = "creating the View inspector"
            await self.connection.create_inspector(
                VIEW_INSPECTOR_ID, self.bootstrap.view_inspector_path
            )
            step = "querying active root views"
            root_view_ids = await self.connection.query_root_view_ids()
            step = "reading the Compose runtime version"
            compose_version = await self.connection.get_compose_version()
            compose_jar = await resolve_compose_inspector(compose_version)
            step = "staging the Compose inspector"
            compose_path = await self.bridge.stage_file(
                self.bootstrap.serial,
                self.package_name,
                self.bootstrap.app_data_dir,
                compose_jar,
                f"compose-inspector-{compose_version}.jar",
            )
            step = "creating the Compose inspector"
            await self.connection.create_inspector(COMPOSE_INSPECTOR_ID, compose_path)
            self.bootstrap = replace(
                self.bootstrap,
                root_view_ids=root_view_ids,
                compose_version=compose_version,
            )
        except Exception as exc:
            if self.connection is not None:
                try:
                    await self.connection.close()
                except Exception:
                    pass
                self.connection = None
            await self.bridge.remove_forward(self.bootstrap.serial, self.forwarded_port)
            self.forwarded_port = None
            if isinstance(exc, InspectorConnectionError):
                raise InspectorConnectionError(f"Failed while {step}: {exc}") from exc
            raise

    def status(self) -> dict[str, Any]:
        info = self.bootstrap
        return {
            "attached": self.connection is not None,
            "tracking": self.tracking,
            "device": info.serial if info else self.requested_device,
            "package": self.package_name,
            "pid": info.pid if info else None,
            "abi": info.abi if info else None,
            "compose_version": info.compose_version if info else None,
            "reused_agent": info.reused_agent if info else False,
            "root_view_ids": list(info.root_view_ids) if info else [],
            "recovery_generation": self._recovery_generation,
        }

    async def start_tracking(self, reset: bool = True) -> dict[str, Any]:
        await self._update_settings(enabled=True, reset=reset)
        self.tracking = True
        if reset:
            self._last_counts.clear()
        return self.status()

    async def stop_tracking(self) -> dict[str, Any]:
        await self._update_settings(enabled=False, reset=False)
        self.tracking = False
        return self.status()

    async def reset_counts(self) -> dict[str, Any]:
        await self._update_settings(enabled=self.tracking, reset=True)
        self._last_counts.clear()
        return self.status()

    async def _update_settings(self, enabled: bool, reset: bool) -> None:
        connection = self._require_connection()
        inner = compose_pb.Command()
        settings = inner.update_settings_command
        settings.include_recompose_counts = enabled
        settings.keep_recompose_counts = not reset
        settings.delay_parameter_extractions = True
        settings.reduce_child_nesting = False
        settings.state_read_settings.none.SetInParent()

        response = await connection.send_compose(inner)
        kind = response.WhichOneof("specialized")
        if kind == "unknown_command_response":
            raise ProtocolError(
                "The app's Compose inspector does not support recomposition settings"
            )
        if kind != "update_settings_response":
            raise ProtocolError(f"Unexpected settings response: {kind}")

    async def snapshot(
        self,
        *,
        app_only: bool = True,
        changed_only: bool = False,
        update_baseline: bool = True,
    ) -> dict[str, Any]:
        async with self._snapshot_lock:
            recovered = False
            if self.connection is None:
                await self._reconnect()
                recovered = True
            try:
                result = await self._snapshot_once(
                    app_only=app_only,
                    changed_only=changed_only,
                    update_baseline=update_baseline,
                )
            except InspectorConnectionError:
                await self._reconnect()
                recovered = True
                result = await self._snapshot_once(
                    app_only=app_only,
                    changed_only=changed_only,
                    update_baseline=update_baseline,
                )
            result["status"] = self.status()
            result["recovered"] = recovered
            return result

    async def _snapshot_once(
        self,
        *,
        app_only: bool,
        changed_only: bool,
        update_baseline: bool,
    ) -> dict[str, Any]:
        connection = self._require_connection()
        bootstrap = self._require_bootstrap()
        captured: list[dict[str, Any]] = []

        root_view_ids = await connection.query_root_view_ids()
        if root_view_ids != bootstrap.root_view_ids:
            bootstrap = replace(bootstrap, root_view_ids=root_view_ids)
            self.bootstrap = bootstrap

        for root_view_id in root_view_ids:
            command = compose_pb.Command()
            request = command.get_composables_command
            request.root_view_id = root_view_id
            request.skip_system_composables = False
            request.generation = 0
            request.extract_all_parameters = False
            request.allow_empty_if_unchanged = False

            try:
                response = await connection.send_compose(command)
            except DecodeError:
                # protobuf refuses to parse messages nested past a fixed depth
                # (100 levels). Trees with many framework wrapper composables
                # (e.g. a busy LazyColumn) can exceed that. Retry with system
                # composables dropped on-device to shorten the tree instead of
                # failing the whole snapshot.
                request.skip_system_composables = True
                response = await connection.send_compose(command)

            kind = response.WhichOneof("specialized")
            if kind == "unknown_command_response":
                raise ProtocolError("The app's Compose inspector rejected GetComposables")
            if kind != "get_composables_response":
                raise ProtocolError(f"Unexpected composables response: {kind}")
            captured.extend(
                parse_composable_response(
                    response.get_composables_response,
                    root_view_id=root_view_id,
                    app_only=app_only,
                )
            )

        for tree_index, node in enumerate(captured):
            node["tree_index"] = tree_index

        result: list[dict[str, Any]] = []
        # Keep baselines for temporarily absent nodes. Navigation often removes a
        # Compose root for a few frames; dropping its baseline creates a false
        # cumulative delta when the node returns.
        next_counts = dict(self._last_counts)
        for node in captured:
            anchor = node["anchor_hash"]
            current = Counter(node["recompositions"], node["skips"])
            if anchor != 0:
                counter_key = (node["root_view_id"], anchor)
                previous = self._last_counts.get(counter_key, Counter(0, 0))
                delta_recompositions = current.recompositions - previous.recompositions
                delta_skips = current.skips - previous.skips
                if delta_recompositions < 0:
                    delta_recompositions = current.recompositions
                if delta_skips < 0:
                    delta_skips = current.skips
                next_counts[counter_key] = current
            else:
                delta_recompositions = 0
                delta_skips = 0

            node["recomposition_delta"] = delta_recompositions
            node["skip_delta"] = delta_skips
            if not changed_only or delta_recompositions or delta_skips:
                result.append(node)

        if update_baseline:
            self._last_counts = next_counts

        result.sort(
            key=lambda item: (
                item["recomposition_delta"] + item["skip_delta"],
                item["recompositions"],
            ),
            reverse=True,
        )
        return {
            "captured_at_unix_ms": int(time.time() * 1000),
            "device": bootstrap.serial,
            "package": bootstrap.package_name,
            "pid": bootstrap.pid,
            "tracking": self.tracking,
            "nodes": result,
        }

    async def _reconnect(self) -> None:
        async with self._state_lock:
            was_tracking = self.tracking
            old_pid = self.bootstrap.pid if self.bootstrap is not None else None
            await self._disconnect(stop_tracking=False)
            await self._attach_locked()
            new_pid = self.bootstrap.pid if self.bootstrap is not None else None
            if old_pid != new_pid:
                self._last_counts.clear()
            if was_tracking:
                await self._update_settings(enabled=True, reset=False)
                self.tracking = True
            self._recovery_generation += 1

    async def observe(
        self,
        *,
        duration_ms: int,
        sample_interval_ms: int,
        app_only: bool,
        limit: int,
    ) -> dict[str, Any]:
        if not self.tracking:
            raise InspectorError("Recomposition tracking is not started for this session")
        duration_ms = max(100, min(duration_ms, 30_000))
        sample_interval_ms = max(100, min(sample_interval_ms, 5_000))
        limit = max(1, min(limit, 500))

        deadline = asyncio.get_running_loop().time() + duration_ms / 1000
        aggregate: dict[tuple[int, int], dict[str, Any]] = {}
        samples = 0
        while True:
            snapshot = await self.snapshot(app_only=app_only, changed_only=True)
            samples += 1
            for node in snapshot["nodes"]:
                counter_key = (node["root_view_id"], node["anchor_hash"])
                existing = aggregate.get(counter_key)
                if existing is None:
                    aggregate[counter_key] = dict(node)
                else:
                    existing["recomposition_delta"] += node["recomposition_delta"]
                    existing["skip_delta"] += node["skip_delta"]
                    existing["recompositions"] = node["recompositions"]
                    existing["skips"] = node["skips"]
            remaining = deadline - asyncio.get_running_loop().time()
            if remaining <= 0:
                break
            await asyncio.sleep(min(sample_interval_ms / 1000, remaining))

        nodes = sorted(
            aggregate.values(),
            key=lambda item: item["recomposition_delta"] + item["skip_delta"],
            reverse=True,
        )[:limit]
        bootstrap = self._require_bootstrap()
        return {
            "duration_ms": duration_ms,
            "sample_interval_ms": sample_interval_ms,
            "samples": samples,
            "device": bootstrap.serial,
            "package": bootstrap.package_name,
            "pid": bootstrap.pid,
            "changed_nodes": nodes,
        }

    async def close(self) -> None:
        async with self._state_lock:
            await self._disconnect(stop_tracking=True)
            self.tracking = False
            self._last_counts.clear()

    async def _disconnect(self, *, stop_tracking: bool) -> None:
        if self.connection is not None:
            if stop_tracking and self.tracking:
                try:
                    await self.stop_tracking()
                except Exception:
                    pass
            try:
                await self.connection.close()
            except Exception:
                pass
            self.connection = None
        if self.bootstrap is not None and self.forwarded_port is not None:
            await self.bridge.remove_forward(self.bootstrap.serial, self.forwarded_port)
        self.forwarded_port = None

    def _require_connection(self) -> InspectorConnection:
        if self.connection is None:
            raise InspectorError("Inspector session is not attached")
        return self.connection

    def _require_bootstrap(self) -> BootstrapResult:
        if self.bootstrap is None:
            raise InspectorError("Inspector session is not attached")
        return self.bootstrap


def parse_composable_response(
    response: compose_pb.GetComposablesResponse,
    *,
    root_view_id: int,
    app_only: bool,
) -> list[dict[str, Any]]:
    strings = {entry.id: entry.str for entry in response.strings}
    result: list[dict[str, Any]] = []

    def visit(
        node: compose_pb.ComposableNode,
        parent_anchor: int | None,
        parent_path: str,
        visible_depth: int,
    ) -> None:
        name = strings.get(node.name, "<unknown composable>")
        path = f"{parent_path}/{name}" if parent_path else name
        is_system = bool(node.flags & SYSTEM_CREATED_FLAG)
        is_visible = not app_only or not is_system or name in SYSTEM_LEAVES_VISIBLE_IN_APP_TREE
        if is_visible:
            bounds = node.bounds.layout
            result.append(
                {
                    "id": node.id,
                    "anchor_hash": node.anchor_hash,
                    "parent_anchor_hash": parent_anchor,
                    "tree_index": len(result),
                    "depth": visible_depth,
                    "name": name,
                    "path": path,
                    "file": strings.get(node.filename) if node.filename else None,
                    "line": node.line_number or None,
                    "root_view_id": root_view_id,
                    "recompositions": node.recompose_count,
                    "skips": node.recompose_skips,
                    "is_system": is_system,
                    "bounds": {
                        "x": bounds.x,
                        "y": bounds.y,
                        "width": bounds.w,
                        "height": bounds.h,
                    },
                }
            )
        next_parent = node.anchor_hash if is_visible and node.anchor_hash else parent_anchor
        next_depth = visible_depth + 1 if is_visible else visible_depth
        for child in node.children:
            visit(child, next_parent, path, next_depth)

    for root in response.roots:
        for node in root.nodes:
            visit(node, None, "", 0)
    return result
