from __future__ import annotations

import asyncio
import os
import re
import sys
import urllib.request
import zipfile
from pathlib import Path

from .errors import PrerequisiteError

VERSION_RE = re.compile(r"^[0-9A-Za-z][0-9A-Za-z.+_-]*$")
MAVEN_BASE_URL = "https://dl.google.com/dl/android/maven2"


def compose_artifact_id(version: str) -> str:
    parts = version.split(".")
    try:
        major, minor = int(parts[0]), int(parts[1])
    except (IndexError, ValueError):
        return "ui"
    return "ui" if (major, minor) < (1, 5) else "ui-android"


def default_cache_dir() -> Path:
    override = os.environ.get("ANDROID_COMPOSE_INSPECTOR_CACHE")
    if override:
        return Path(override).expanduser()
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Caches" / "android-compose-inspector"
    root = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))
    return root / "android-compose-inspector"


async def resolve_compose_inspector(version: str) -> Path:
    if not VERSION_RE.fullmatch(version):
        raise PrerequisiteError(f"Unsafe Compose version returned by device: {version!r}")
    return await asyncio.to_thread(_resolve_compose_inspector, version)


def _resolve_compose_inspector(version: str) -> Path:
    artifact = compose_artifact_id(version)
    destination = default_cache_dir() / version / "inspector.jar"
    if destination.is_file() and destination.stat().st_size:
        return destination

    destination.parent.mkdir(parents=True, exist_ok=True)
    aar = _find_gradle_aar(artifact, version)
    if aar is None:
        aar = destination.parent / f"{artifact}-{version}.aar"
        url = f"{MAVEN_BASE_URL}/androidx/compose/ui/{artifact}/{version}/{artifact}-{version}.aar"
        request = urllib.request.Request(
            url, headers={"User-Agent": "android-compose-inspector/0.2"}
        )
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                aar.write_bytes(response.read())
        except Exception as exc:
            raise PrerequisiteError(
                f"Could not resolve Compose inspector {version} from {url}: {exc}"
            ) from exc

    try:
        with zipfile.ZipFile(aar) as archive:
            payload = archive.read("inspector.jar")
    except (OSError, KeyError, zipfile.BadZipFile) as exc:
        raise PrerequisiteError(
            f"Compose artifact {aar} does not contain a valid inspector.jar"
        ) from exc
    destination.write_bytes(payload)
    return destination


def _find_gradle_aar(artifact: str, version: str) -> Path | None:
    root = (
        Path.home()
        / ".gradle"
        / "caches"
        / "modules-2"
        / "files-2.1"
        / "androidx.compose.ui"
        / artifact
        / version
    )
    if not root.is_dir():
        return None
    expected = f"{artifact}-{version}.aar"
    return next((path for path in root.glob(f"*/{expected}") if path.is_file()), None)
