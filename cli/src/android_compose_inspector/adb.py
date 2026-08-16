from __future__ import annotations

import asyncio
import hashlib
import os
import re
import shlex
import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .errors import PrerequisiteError

PACKAGE_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+$")
SAFE_FILE_RE = re.compile(r"^[A-Za-z0-9_.+-]+$")
ARTIFACT_DIR = Path(__file__).resolve().parent / "artifacts"
MINIMUM_API = 29


@dataclass(frozen=True)
class BootstrapResult:
    serial: str
    package_name: str
    pid: int
    socket_name: str
    root_view_ids: tuple[int, ...]
    app_data_dir: str
    view_inspector_path: str
    abi: str
    compose_version: str | None = None
    reused_agent: bool = False


class AndroidBridge:
    def __init__(self, adb: str | None = None) -> None:
        self.adb = adb or os.environ.get("ADB") or shutil.which("adb") or ""

    def prerequisite_status(self) -> dict[str, Any]:
        supported_abis = (
            sorted(path.name for path in ARTIFACT_DIR.iterdir() if path.is_dir())
            if ARTIFACT_DIR.is_dir()
            else []
        )
        required = (
            ARTIFACT_DIR / "lib_ui_inspector_service.jar",
            ARTIFACT_DIR / "lib_ui_inspector_payload.jar",
            ARTIFACT_DIR / "view-inspector.jar",
        )
        artifacts_ready = bool(supported_abis) and all(path.is_file() for path in required)
        return {
            "adb": self.adb or None,
            "agent_artifacts": str(ARTIFACT_DIR) if artifacts_ready else None,
            "supported_abis": supported_abis,
            "ready": bool(self.adb and artifacts_ready),
        }

    async def run(self, *args: str, timeout: float = 30.0) -> str:
        if not self.adb:
            raise PrerequisiteError("adb was not found on PATH; install Android platform-tools")
        return await _run_process(self.adb, *args, timeout=timeout)

    async def resolve_serial(self, requested: str | None) -> str:
        output = await self.run("devices")
        online = []
        for line in output.splitlines()[1:]:
            fields = line.split()
            if len(fields) >= 2 and fields[1] == "device":
                online.append(fields[0])
        if requested:
            if requested not in online:
                raise PrerequisiteError(
                    f"Device {requested!r} is not online; online devices: {online or 'none'}"
                )
            return requested
        if len(online) != 1:
            raise PrerequisiteError(
                "Exactly one online device is required when device is omitted; "
                f"found {online or 'none'}"
            )
        return online[0]

    async def bootstrap(self, package_name: str, device: str | None = None) -> BootstrapResult:
        if not PACKAGE_RE.fullmatch(package_name):
            raise PrerequisiteError(f"Invalid Android package name: {package_name!r}")

        serial = await self.resolve_serial(device)
        pids = await self._package_pids(serial, package_name)
        if not pids:
            raise PrerequisiteError(
                f"{package_name} is not running on {serial}; launch its debuggable build first"
            )
        await self._verify_foreground(serial, package_name)

        api_text = (
            await self.run("-s", serial, "shell", "getprop", "ro.build.version.sdk")
        ).strip()
        try:
            api = int(api_text)
        except ValueError as exc:
            raise PrerequisiteError(f"Device returned an invalid API level: {api_text!r}") from exc
        if api < MINIMUM_API:
            raise PrerequisiteError(
                f"UI Inspector requires Android API {MINIMUM_API}+; device is API {api}"
            )

        abi = (await self.run("-s", serial, "shell", "getprop", "ro.product.cpu.abi")).strip()
        native_agent = ARTIFACT_DIR / abi / "lib_ui_inspector_agent.so"
        if not native_agent.is_file():
            supported = self.prerequisite_status()["supported_abis"]
            raise PrerequisiteError(
                f"Device ABI {abi!r} is unsupported by this plugin build; supported: {supported}"
            )

        try:
            app_data_dir = (
                await self.run("-s", serial, "shell", "run-as", package_name, "pwd")
            ).strip()
        except PrerequisiteError as exc:
            raise PrerequisiteError(
                f"run-as failed for {package_name}; the installed app must be debuggable"
            ) from exc
        if not app_data_dir.startswith("/data/"):
            raise PrerequisiteError(f"Unexpected app data directory: {app_data_dir!r}")

        existing = await self._find_inspector_socket(serial, pids, required=False)
        reused_agent = existing is not None
        if existing is None:
            pid = pids[0]
            native_path = await self.stage_file(
                serial, package_name, app_data_dir, native_agent, "lib_ui_inspector_agent.so"
            )
            service_path = await self.stage_file(
                serial,
                package_name,
                app_data_dir,
                ARTIFACT_DIR / "lib_ui_inspector_service.jar",
                "lib_ui_inspector_service.jar",
            )
            payload_path = await self.stage_file(
                serial,
                package_name,
                app_data_dir,
                ARTIFACT_DIR / "lib_ui_inspector_payload.jar",
                "lib_ui_inspector_payload.jar",
            )
            token = f"{pid}_mcp"
            await self._attach_agent(
                serial,
                package_name,
                f"{native_path}={service_path};{payload_path};{token}",
            )
            socket_name, pid = await self._wait_for_inspector_socket(serial, pids)
        else:
            socket_name, pid = existing

        view_path = await self.stage_file(
            serial,
            package_name,
            app_data_dir,
            ARTIFACT_DIR / "view-inspector.jar",
            "view-inspector.jar",
        )
        return BootstrapResult(
            serial=serial,
            package_name=package_name,
            pid=pid,
            socket_name=socket_name,
            root_view_ids=(),
            app_data_dir=app_data_dir,
            view_inspector_path=view_path,
            abi=abi,
            reused_agent=reused_agent,
        )

    async def stage_file(
        self,
        serial: str,
        package_name: str,
        app_data_dir: str,
        local_path: Path,
        remote_name: str,
    ) -> str:
        if not local_path.is_file():
            raise PrerequisiteError(f"Inspector artifact is missing: {local_path}")
        if not SAFE_FILE_RE.fullmatch(remote_name):
            raise PrerequisiteError(f"Unsafe inspector artifact name: {remote_name!r}")
        digest = hashlib.sha256(local_path.read_bytes()).hexdigest()[:12]
        remote_path = Path(remote_name)
        deployed_name = f"{remote_path.stem}-{digest}{remote_path.suffix}"
        staging_dir = "/data/local/tmp/android-compose-inspector"
        app_artifact_dir = f"{app_data_dir}/code_cache/android-compose-inspector"
        staged_path = f"{staging_dir}/{deployed_name}"
        app_path = f"{app_artifact_dir}/{deployed_name}"
        await self.run(
            "-s",
            serial,
            "shell",
            "run-as",
            package_name,
            "mkdir",
            "-p",
            app_artifact_dir,
        )
        try:
            await self.run("-s", serial, "shell", "run-as", package_name, "test", "-f", app_path)
            return app_path
        except PrerequisiteError:
            pass
        await self.run("-s", serial, "shell", "mkdir", "-p", staging_dir)
        await self.run("-s", serial, "push", str(local_path), staged_path, timeout=90.0)
        await self.run("-s", serial, "shell", "run-as", package_name, "cp", staged_path, app_path)
        await self.run("-s", serial, "shell", "run-as", package_name, "chmod", "444", app_path)
        return app_path

    async def forward(self, serial: str, socket_name: str) -> int:
        output = await self.run("-s", serial, "forward", "tcp:0", f"localabstract:{socket_name}")
        try:
            return int(output.strip())
        except ValueError as exc:
            raise PrerequisiteError(f"adb did not return an allocated port: {output!r}") from exc

    async def remove_forward(self, serial: str, port: int) -> None:
        try:
            await self.run("-s", serial, "forward", "--remove", f"tcp:{port}")
        except Exception:
            pass

    async def _package_pids(self, serial: str, package_name: str) -> list[int]:
        try:
            output = await self.run("-s", serial, "shell", "pidof", package_name)
        except PrerequisiteError:
            return []
        return [int(value) for value in output.split() if value.isdigit()]

    async def _verify_foreground(self, serial: str, package_name: str) -> None:
        output = await self.run("-s", serial, "shell", "dumpsys", "activity", "activities")
        resumed_lines = [
            line
            for line in output.splitlines()
            if "mResumedActivity" in line or "topResumedActivity" in line
        ]
        if resumed_lines and not any(package_name in line for line in resumed_lines):
            raise PrerequisiteError(
                f"{package_name} is not the foreground app. "
                "Bring it to the foreground before attaching."
            )

    async def _attach_agent(self, serial: str, package_name: str, specification: str) -> None:
        command = (
            f"cmd activity attach-agent {shlex.quote(package_name)} {shlex.quote(specification)}"
        )
        await self.run("-s", serial, "shell", command, timeout=45.0)

    async def _wait_for_inspector_socket(self, serial: str, pids: list[int]) -> tuple[str, int]:
        for _ in range(60):
            candidate = await self._find_inspector_socket(serial, pids, required=False)
            if candidate is not None:
                return candidate
            await asyncio.sleep(0.25)
        raise PrerequisiteError(
            "Attached the UI Inspector agent, but its socket did not appear within 15 seconds"
        )

    async def _find_inspector_socket(
        self, serial: str, pids: list[int], *, required: bool = True
    ) -> tuple[str, int] | None:
        output = await self.run("-s", serial, "shell", "cat", "/proc/net/unix")
        candidates: list[tuple[str, int]] = []
        for line in output.splitlines():
            match = re.search(r"@?(ui_inspector_([^\s]+))$", line.strip())
            if not match:
                continue
            socket_name = match.group(1)
            token = match.group(2)
            for pid in pids:
                if token == str(pid) or token.startswith(f"{pid}_"):
                    candidates.append((socket_name, pid))
        if candidates:
            return candidates[-1]
        if required:
            raise PrerequisiteError("The UI Inspector agent socket was not found")
        return None


async def _run_process(executable: str, *args: str, timeout: float) -> str:
    process = await asyncio.create_subprocess_exec(
        executable,
        *args,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    try:
        stdout, stderr = await asyncio.wait_for(process.communicate(), timeout=timeout)
    except TimeoutError as error:
        process.kill()
        await process.wait()
        raise PrerequisiteError(f"Command timed out: {executable} {' '.join(args)}") from error
    if process.returncode != 0:
        detail = stderr.decode(errors="replace").strip() or stdout.decode(errors="replace").strip()
        raise PrerequisiteError(
            f"Command failed ({process.returncode}): {executable} {' '.join(args)}\n{detail}"
        )
    return stdout.decode(errors="replace")
