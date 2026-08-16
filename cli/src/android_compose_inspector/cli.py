from __future__ import annotations

import argparse
import importlib.resources
import json
import socket
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

from .daemon import DEFAULT_PORT, HOST

CONNECT_TIMEOUT = 1.0
SPAWN_TIMEOUT = 8.0
SKILL_INSTALL_PATH = (
    Path.home() / ".compose-inspector" / "skills" / "compose-inspector-cli" / "SKILL.md"
)


def _is_daemon_running(port: int) -> bool:
    try:
        with socket.create_connection((HOST, port), timeout=CONNECT_TIMEOUT):
            return True
    except OSError:
        return False


def _spawn_daemon(port: int) -> None:
    subprocess.Popen(
        [sys.executable, "-m", "android_compose_inspector.daemon", "--port", str(port)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        stdin=subprocess.DEVNULL,
        start_new_session=True,
    )
    deadline = time.monotonic() + SPAWN_TIMEOUT
    while time.monotonic() < deadline:
        if _is_daemon_running(port):
            return
        time.sleep(0.1)
    raise RuntimeError(
        f"Timed out waiting for the compose-inspector daemon to start on port {port}"
    )


def _send(port: int, command: str, params: dict[str, Any], pretty: bool) -> dict[str, Any]:
    if not _is_daemon_running(port):
        _spawn_daemon(port)
    with socket.create_connection((HOST, port), timeout=45.0) as sock:
        request = json.dumps({"command": command, "params": params, "pretty": pretty}) + "\n"
        sock.sendall(request.encode())
        sock.shutdown(socket.SHUT_WR)
        chunks = []
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                break
            chunks.append(chunk)
        return json.loads(b"".join(chunks))


def _install_skill() -> None:
    try:
        source_text = (
            importlib.resources.files("android_compose_inspector")
            .joinpath("skill_data", "SKILL.md")
            .read_text()
        )
    except (FileNotFoundError, ModuleNotFoundError):
        return
    if SKILL_INSTALL_PATH.exists() and SKILL_INSTALL_PATH.read_text() == source_text:
        return
    SKILL_INSTALL_PATH.parent.mkdir(parents=True, exist_ok=True)
    SKILL_INSTALL_PATH.write_text(source_text)


def _print_result(envelope: dict[str, Any], pretty: bool) -> int:
    indent = 2 if pretty else None
    if envelope.get("ok"):
        print(json.dumps(envelope["result"], indent=indent))
        return 0
    error = {"error": envelope.get("error"), "error_type": envelope.get("error_type")}
    print(json.dumps(error, indent=indent))
    return 1


def _run_command(args: argparse.Namespace, command: str, params: dict[str, Any]) -> int:
    envelope = _send(args.port, command, params, args.pretty)
    return _print_result(envelope, args.pretty)


def build_parser() -> argparse.ArgumentParser:
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--port", type=int, default=DEFAULT_PORT, help="Daemon TCP port")
    common.add_argument("--pretty", action="store_true", help="Pretty-print JSON output")

    parser = argparse.ArgumentParser(prog="compose-inspector")
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("prerequisites", parents=[common], help="Check adb and packaged agent artifacts")

    p = sub.add_parser("attach", parents=[common], help="Attach the UI Inspector agent to an app")
    p.add_argument("package", help="Application ID, e.g. com.example.app")
    p.add_argument("--device", help="ADB device serial (when more than one is connected)")

    p = sub.add_parser("start-tracking", parents=[common], help="Enable recomposition counting")
    p.add_argument("session_id")
    p.add_argument("--no-reset", action="store_true", help="Keep counts instead of resetting")

    p = sub.add_parser("snapshot", parents=[common], help="Read current Compose hierarchy/counters")
    p.add_argument("session_id")
    p.add_argument("--all", action="store_true", help="Include framework/system composables")
    p.add_argument("--changed-only", action="store_true", help="Only nodes with a nonzero delta")

    p = sub.add_parser("observe", parents=[common], help="Watch recompositions for a duration")
    p.add_argument("session_id")
    p.add_argument("--duration-ms", type=int, default=5_000)
    p.add_argument("--sample-interval-ms", type=int, default=250)
    p.add_argument("--all", action="store_true", help="Include framework/system composables")
    p.add_argument("--limit", type=int, default=50)

    p = sub.add_parser("reset-counts", parents=[common], help="Reset device/host-side counters")
    p.add_argument("session_id")

    p = sub.add_parser("stop-tracking", parents=[common], help="Stop counting, keep current values")
    p.add_argument("session_id")

    p = sub.add_parser("detach", parents=[common], help="Close the inspector socket + adb forward")
    p.add_argument("session_id")

    sub.add_parser("sessions", parents=[common], help="List active sessions on the daemon")

    p = sub.add_parser("daemon", help="Run the daemon in the foreground (normally auto-spawned)")
    p.add_argument("--port", type=int, default=DEFAULT_PORT, help="Daemon TCP port")

    sub.add_parser("stop", parents=[common], help="Shut down the daemon and detach all sessions")

    return parser


def main(argv: list[str] | None = None) -> None:
    _install_skill()
    args = build_parser().parse_args(argv)

    if args.cmd == "daemon":
        from . import daemon as daemon_module

        daemon_module.run(args.port)
        return

    if args.cmd == "stop":
        if not _is_daemon_running(args.port):
            indent = 2 if args.pretty else None
            print(json.dumps({"shutdown": True, "message": "daemon is not running"}, indent=indent))
            sys.exit(0)
        sys.exit(_run_command(args, "shutdown", {}))

    if args.cmd == "prerequisites":
        sys.exit(_run_command(args, "prerequisites", {}))
    elif args.cmd == "attach":
        sys.exit(_run_command(args, "attach", {"package": args.package, "device": args.device}))
    elif args.cmd == "start-tracking":
        params = {"session_id": args.session_id, "reset": not args.no_reset}
        sys.exit(_run_command(args, "start-tracking", params))
    elif args.cmd == "snapshot":
        params = {
            "session_id": args.session_id,
            "app_only": not args.all,
            "changed_only": args.changed_only,
        }
        sys.exit(_run_command(args, "snapshot", params))
    elif args.cmd == "observe":
        sys.exit(
            _run_command(
                args,
                "observe",
                {
                    "session_id": args.session_id,
                    "duration_ms": args.duration_ms,
                    "sample_interval_ms": args.sample_interval_ms,
                    "app_only": not args.all,
                    "limit": args.limit,
                },
            )
        )
    elif args.cmd == "reset-counts":
        sys.exit(_run_command(args, "reset-counts", {"session_id": args.session_id}))
    elif args.cmd == "stop-tracking":
        sys.exit(_run_command(args, "stop-tracking", {"session_id": args.session_id}))
    elif args.cmd == "detach":
        sys.exit(_run_command(args, "detach", {"session_id": args.session_id}))
    elif args.cmd == "sessions":
        sys.exit(_run_command(args, "sessions", {}))


if __name__ == "__main__":
    main()
