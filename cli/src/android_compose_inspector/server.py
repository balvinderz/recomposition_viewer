from contextlib import asynccontextmanager
from typing import Any

from mcp.server.fastmcp import FastMCP

from .registry import SessionRegistry

registry = SessionRegistry()


@asynccontextmanager
async def lifespan(_):
    try:
        yield
    finally:
        await registry.close_all()


mcp = FastMCP(
    "Android Compose Inspector",
    instructions=(
        "Attach only to a running debuggable app that the user placed in scope. "
        "Start tracking before observing. Prefer bounded observe calls of 3-10 seconds, "
        "then detach when diagnosis is complete. Counts come from the official Compose inspector."
    ),
    lifespan=lifespan,
)


@mcp.tool()
async def compose_prerequisites() -> dict[str, Any]:
    """Check whether adb and packaged UI Inspector agent binaries are available."""
    return registry.bridge.prerequisite_status()


@mcp.tool()
async def compose_attach(package: str, device: str | None = None) -> dict[str, Any]:
    """Attach the official UI Inspector agent to a running foreground debuggable Compose app."""
    session_id, session = await registry.create(package, device)
    return {"session_id": session_id, **session.status()}


@mcp.tool()
async def compose_start_tracking(session_id: str, reset: bool = True) -> dict[str, Any]:
    """Enable live recomposition and skip counting for an attached session."""
    session = registry.get(session_id)
    return {"session_id": session_id, **(await session.start_tracking(reset=reset))}


@mcp.tool()
async def compose_snapshot(
    session_id: str,
    app_only: bool = True,
    changed_only: bool = False,
) -> dict[str, Any]:
    """Return the current Compose hierarchy and cumulative/delta recomposition counters."""
    session = registry.get(session_id)
    return await session.snapshot(app_only=app_only, changed_only=changed_only)


@mcp.tool()
async def compose_observe(
    session_id: str,
    duration_ms: int = 5_000,
    sample_interval_ms: int = 250,
    app_only: bool = True,
    limit: int = 50,
) -> dict[str, Any]:
    """Watch live recompositions for a bounded duration and return aggregated changed nodes."""
    session = registry.get(session_id)
    return await session.observe(
        duration_ms=duration_ms,
        sample_interval_ms=sample_interval_ms,
        app_only=app_only,
        limit=limit,
    )


@mcp.tool()
async def compose_reset_counts(session_id: str) -> dict[str, Any]:
    """Reset device-side recomposition/skip counts and the host delta baseline."""
    session = registry.get(session_id)
    return {"session_id": session_id, **(await session.reset_counts())}


@mcp.tool()
async def compose_stop_tracking(session_id: str) -> dict[str, Any]:
    """Stop collecting new recomposition counts while retaining the current values."""
    session = registry.get(session_id)
    return {"session_id": session_id, **(await session.stop_tracking())}


@mcp.tool()
async def compose_detach(session_id: str) -> dict[str, Any]:
    """Close the inspector socket and remove its adb port forward."""
    await registry.remove(session_id)
    return {"session_id": session_id, "detached": True}


@mcp.tool()
async def compose_sessions() -> dict[str, Any]:
    """List active inspector sessions owned by this MCP server process."""
    return {
        "sessions": [
            {"session_id": session_id, **session.status()}
            for session_id, session in registry.sessions.items()
        ]
    }


def main() -> None:
    mcp.run(transport="stdio")


if __name__ == "__main__":
    main()
