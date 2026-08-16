class InspectorError(RuntimeError):
    """Base error surfaced by the inspector MCP server."""


class PrerequisiteError(InspectorError):
    """A required local tool, device, or app condition is missing."""


class ProtocolError(InspectorError):
    """The device agent returned an invalid or unsupported protocol message."""


class InspectorConnectionError(ProtocolError):
    """The inspector transport closed, timed out, or can no longer be reused."""
